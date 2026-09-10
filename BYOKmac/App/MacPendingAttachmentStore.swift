import BYOKchatProviderCore
import Foundation

actor MacPendingAttachmentStore {
  static let newChatKey = "__new_chat__"
  static let fileName = "mac-pending-attachments-v1.json"
  private static let presentationThumbnailPixels: CGFloat = 256

  private struct PersistedState: Codable {
    var schemaVersion = 1
    var attachmentsByKey: [String: [ChatAttachment]] = [:]
  }

  private let fileURL: URL
  private let blobs: FileAttachmentBlobStore
  private let fileManager: FileManager
  private var state = PersistedState()
  private var inFlightIDs: Set<String> = []

  init(
    environment: BYOKStorageEnvironment,
    blobs: FileAttachmentBlobStore,
    fileManager: FileManager = .default
  ) {
    fileURL = environment.rootDirectory.appendingPathComponent(Self.fileName, isDirectory: false)
    self.blobs = blobs
    self.fileManager = fileManager
  }

  static func key(for conversationID: ConversationID?) -> String {
    guard let conversationID else { return newChatKey }
    return "conversation::\(conversationID.rawValue)"
  }

  func load() async {
    guard fileManager.fileExists(atPath: fileURL.path) else {
      state = PersistedState()
      return
    }

    do {
      let data = try Data(contentsOf: fileURL)
      let decoded = try JSONDecoder().decode(PersistedState.self, from: data)
      guard decoded.schemaVersion == 1 else {
        quarantineUnreadableManifest()
        state = PersistedState()
        return
      }
      state = decoded
      let changed = await reconcileStoredBlobs()
      if changed { try? persist(state) }
    } catch {
      quarantineUnreadableManifest()
      state = PersistedState()
    }
  }

  func snapshot() async -> [String: [ChatAttachment]] {
    var result: [String: [ChatAttachment]] = [:]
    for key in state.attachmentsByKey.keys {
      let values = await presentationAttachments(for: key)
      if !values.isEmpty { result[key] = values }
    }
    return result
  }

  func attachments(for key: String) -> [ChatAttachment] {
    state.attachmentsByKey[key] ?? []
  }

  @discardableResult
  func append(_ additions: [ChatAttachment], to key: String) async throws -> [ChatAttachment] {
    guard !additions.isEmpty else { return await presentationAttachments(for: key) }

    let stagedIDs = Set(additions.map(\.id))
    inFlightIDs.formUnion(stagedIDs)
    defer { inFlightIDs.subtract(stagedIDs) }

    var storedAdditions: [ChatAttachment] = []
    storedAdditions.reserveCapacity(additions.count)
    for attachment in additions {
      storedAdditions.append(try await persistAttachmentBytes(attachment))
    }

    let combined = try MacAttachmentImporter.validateCombined(
      existing: state.attachmentsByKey[key] ?? [],
      additions: storedAdditions
    )
    var candidate = state
    candidate.attachmentsByKey[key] = combined
    try persist(candidate)
    state = candidate
    return await presentationAttachments(for: key)
  }

  @discardableResult
  func remove(_ id: String, from key: String) async throws -> [ChatAttachment] {
    guard var values = state.attachmentsByKey[key] else { return [] }
    values.removeAll { $0.id == id }

    var candidate = state
    if values.isEmpty {
      candidate.attachmentsByKey.removeValue(forKey: key)
    } else {
      candidate.attachmentsByKey[key] = values
    }
    try persist(candidate)
    state = candidate
    return await presentationAttachments(for: key)
  }

  @discardableResult
  func transfer(from sourceKey: String, to destinationKey: String) async throws -> [ChatAttachment] {
    guard sourceKey != destinationKey else { return await presentationAttachments(for: destinationKey) }
    guard let source = state.attachmentsByKey[sourceKey], !source.isEmpty else {
      return await presentationAttachments(for: destinationKey)
    }

    let combined = try MacAttachmentImporter.validateCombined(
      existing: state.attachmentsByKey[destinationKey] ?? [],
      additions: source
    )
    var candidate = state
    candidate.attachmentsByKey.removeValue(forKey: sourceKey)
    candidate.attachmentsByKey[destinationKey] = combined
    try persist(candidate)
    state = candidate
    return await presentationAttachments(for: destinationKey)
  }

  func clear(_ key: String) throws {
    guard state.attachmentsByKey[key] != nil else { return }
    var candidate = state
    candidate.attachmentsByKey.removeValue(forKey: key)
    try persist(candidate)
    state = candidate
  }

  func referencedIDs() -> Set<String> {
    Set(state.attachmentsByKey.values.flatMap { $0.map(\.id) }).union(inFlightIDs)
  }

  private func presentationAttachments(for key: String) async -> [ChatAttachment] {
    let values = attachments(for: key)
    var presented: [ChatAttachment] = []
    presented.reserveCapacity(values.count)
    for var attachment in values {
      if attachment.isImage,
        let thumbnail = try? await blobs.thumbnailData(
          attachment.id,
          maxPixelSize: Self.presentationThumbnailPixels
        ),
        !thumbnail.isEmpty
      {
        attachment.data = thumbnail
      }
      presented.append(attachment)
    }
    return presented
  }

  private func persistAttachmentBytes(_ attachment: ChatAttachment) async throws -> ChatAttachment {
    var stored = attachment
    let byteCount = attachment.byteCount
    guard byteCount > 0 else {
      throw ProviderError.invalidRequest("\(attachment.filename) is empty.")
    }

    if !attachment.data.isEmpty {
      try await blobs.writeIfAbsent(
        attachment.id,
        data: attachment.data,
        metadata: AttachmentBlobMetadata(
          filename: attachment.filename,
          mimeType: attachment.mimeType,
          byteCount: attachment.data.count,
          createdAt: .now
        )
      )
      stored.declaredByteCount = attachment.data.count
      stored.data = Data()
      return stored
    }

    guard let metadata = try await blobs.metadata(for: attachment.id), metadata.byteCount > 0 else {
      throw ProviderError.invalidRequest("\(attachment.filename) is no longer available.")
    }
    stored.declaredByteCount = metadata.byteCount
    stored.data = Data()
    return stored
  }

  private func reconcileStoredBlobs() async -> Bool {
    var repaired: [String: [ChatAttachment]] = [:]
    var changed = false

    for (key, values) in state.attachmentsByKey {
      var kept: [ChatAttachment] = []
      kept.reserveCapacity(values.count)

      for attachment in values {
        do {
          let stored = try await persistAttachmentBytes(attachment)
          kept.append(stored)
          if stored != attachment { changed = true }
        } catch {
          changed = true
        }
      }

      if !kept.isEmpty {
        repaired[key] = kept
      } else if !values.isEmpty {
        changed = true
      }
    }

    if repaired != state.attachmentsByKey {
      state.attachmentsByKey = repaired
      changed = true
    }
    return changed
  }

  private func persist(_ value: PersistedState) throws {
    try fileManager.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    try data.write(to: fileURL, options: .atomic)
  }

  private func quarantineUnreadableManifest() {
    guard fileManager.fileExists(atPath: fileURL.path) else { return }
    let suffix = ISO8601DateFormatter().string(from: .now)
      .replacingOccurrences(of: ":", with: "-")
    let quarantine = fileURL.deletingLastPathComponent()
      .appendingPathComponent("\(Self.fileName).corrupt-\(suffix)")
    try? fileManager.moveItem(at: fileURL, to: quarantine)
  }
}
