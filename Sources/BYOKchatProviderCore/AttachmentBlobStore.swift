import Foundation

/// Stores attachment byte payloads as individual files keyed by ID so
/// workspace JSON stays metadata-only (see `ConversationStore.persist`).
public protocol AttachmentBlobStoring: Sendable {
  /// Writes the payload unless the ID is already stored. Idempotent; safe to
  /// call on every persist.
  func writeIfAbsent(_ id: String, data: Data) async throws
  /// Returns nil when no blob exists for the ID.
  func loadData(_ id: String) async throws -> Data?
  func deleteIDs(_ ids: Set<String>) async throws
  func storedIDs() async throws -> Set<String>
}

public actor FileAttachmentBlobStore: AttachmentBlobStoring {
  private let directory: URL
  private let fileManager: FileManager
  /// Lazily-seeded cache of what is on disk so repeated writes during stream
  /// persistence never stat the directory.
  private var knownIDs: Set<String>?

  public init(directory: URL, fileManager: FileManager = .default) {
    self.directory = directory
    self.fileManager = fileManager
  }

  public func writeIfAbsent(_ id: String, data: Data) async throws {
    guard !data.isEmpty else { return }
    guard Self.isValidID(id) else {
      throw ProviderError.invalidRequest("Attachment blob ID is not usable as a file name.")
    }
    var known = knownIDs ?? Set((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [])
    if known.contains(id) { return }

    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let target = url(for: id)
    if !fileManager.fileExists(atPath: target.path) {
      try data.write(to: target, options: .atomic)
    }
    known.insert(id)
    knownIDs = known
  }

  public func loadData(_ id: String) async throws -> Data? {
    guard Self.isValidID(id) else { return nil }
    guard fileManager.fileExists(atPath: url(for: id).path) else { return nil }
    return try Data(contentsOf: url(for: id), options: .mappedIfSafe)
  }

  public func deleteIDs(_ ids: Set<String>) async throws {
    guard !ids.isEmpty else { return }
    for id in ids where Self.isValidID(id) {
      try? fileManager.removeItem(at: url(for: id))
      knownIDs?.remove(id)
    }
  }

  public func storedIDs() async throws -> Set<String> {
    if let knownIDs { return knownIDs }
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let contents = try fileManager.contentsOfDirectory(atPath: directory.path)
    let ids = Set(contents)
    knownIDs = ids
    return ids
  }

  private func url(for id: String) -> URL {
    directory.appendingPathComponent(id, isDirectory: false)
  }

  /// Blob names are generated UUIDs. Imported payloads could carry hostile
  /// strings, so anything outside the lowercase-hex/dash alphabet (UUID
  /// lowercase format) never touches disk.
  private static func isValidID(_ id: String) -> Bool {
    !id.isEmpty && id.count <= 64 && id.allSatisfy { character in
      ("a"..."z").contains(character) || ("0"..."9").contains(character) || character == "-"
    }
  }
}

public actor InMemoryAttachmentBlobStore: AttachmentBlobStoring {
  private var blobs: [String: Data]

  public init(initial: [String: Data] = [:]) {
    blobs = initial
  }

  public func writeIfAbsent(_ id: String, data: Data) async throws {
    guard !data.isEmpty else { return }
    if blobs[id] == nil { blobs[id] = data }
  }

  public func loadData(_ id: String) async throws -> Data? {
    blobs[id]
  }

  public func deleteIDs(_ ids: Set<String>) async throws {
    for id in ids { blobs.removeValue(forKey: id) }
  }

  public func storedIDs() async throws -> Set<String> {
    Set(blobs.keys)
  }
}
