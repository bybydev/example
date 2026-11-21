import Foundation

public protocol LibraryWorkspacePersistence: Sendable {
  func loadData() async throws -> Data?
  func saveData(_ data: Data) async throws
}

public actor InMemoryLibraryWorkspacePersistence: LibraryWorkspacePersistence {
  private var data: Data?

  public init(data: Data? = nil) { self.data = data }
  public func loadData() -> Data? { data }
  public func saveData(_ data: Data) { self.data = data }
}

public actor JSONFileLibraryWorkspacePersistence: LibraryWorkspacePersistence {
  public let fileURL: URL

  public init(fileURL: URL) { self.fileURL = fileURL }

  public func loadData() throws -> Data? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    return try Data(contentsOf: fileURL)
  }

  public func saveData(_ data: Data) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: fileURL, options: .atomic)
  }
}

/// First-class store of explicitly saved files. Independent of chat
/// conversations — entries exist whether or not any message references them.
/// Bytes rest in a dedicated blob directory; the JSON carries metadata only.
public actor LibraryStore {
  /// Matches the per-attachment limit enforced on chat sends.
  public static let maxByteCount = 20 * 1_024 * 1_024

  private let persistence: any LibraryWorkspacePersistence
  private let blobs: any AttachmentBlobStoring
  private var state = LibraryWorkspaceState()
  private var hasLoaded = false

  /// Actor methods are reentrant while persistence is awaiting I/O. Serialize
  /// mutations so overlapping saves cannot commit candidates derived from the
  /// same old state or publish a failed mutation into the live runtime.
  private var mutationInProgress = false
  private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

  public init(
    persistence: any LibraryWorkspacePersistence,
    blobs: any AttachmentBlobStoring
  ) {
    self.persistence = persistence
    self.blobs = blobs
  }

  public func load() async throws {
    guard !hasLoaded else { return }

    var candidate = LibraryWorkspaceState()
    if let data = try await persistence.loadData() {
      let decoded = try JSONDecoder.provider.decode(LibraryWorkspaceState.self, from: data)
      guard decoded.schemaVersion == LibraryWorkspaceState.currentSchemaVersion else {
        throw ProviderError.libraryVersionUnsupported(decoded.schemaVersion)
      }
      candidate = decoded
    }
    candidate.tombstones = SyncTombstonePolicy.pruned(candidate.tombstones)
    candidate = try await stateByDroppingEntriesWithoutBlobs(candidate)

    state = candidate
    hasLoaded = true
    // Orphaned blobs are swept by the app-level sweepOrphanFiles.
  }

  /// Newest first.
  public func entries() -> [LibraryEntry] {
    state.entries.sorted { lhs, rhs in
      if lhs.createdAt == rhs.createdAt { return lhs.id.rawValue > rhs.id.rawValue }
      return lhs.createdAt > rhs.createdAt
    }
  }

  public func entry(id: LibraryEntryID) -> LibraryEntry? {
    state.entries.first { $0.id == id }
  }

  /// Listed entry IDs, for the app-level blob GC.
  public func referencedEntryIDs() -> Set<String> {
    Set(state.entries.map(\.id.rawValue))
  }

  @discardableResult
  public func add(
    filename: String,
    mimeType: String,
    data: Data,
    source: LibraryEntrySource = .manual,
    maximumEntryCount: Int? = nil,
    at date: Date = .now
  ) async throws -> LibraryEntry {
    let entries = try await addItems([
      LibraryPendingItem(
        filename: filename,
        mimeType: mimeType,
        data: data,
        source: source,
        date: date
      )
    ], maximumEntryCount: maximumEntryCount)
    return entries[0]
  }

  /// Adds a picker/import batch as one metadata transaction. Payload blobs are
  /// written first; if the JSON save fails they are harmless orphans and the
  /// live Library state remains at the last committed snapshot.
  @discardableResult
  public func addAttachments(
    _ attachments: [ChatAttachment],
    source: LibraryEntrySource = .manual,
    maximumEntryCount: Int? = nil,
    at date: Date = .now
  ) async throws -> [LibraryEntry] {
    guard !attachments.isEmpty else { return [] }
    return try await addItems(
      attachments.map {
        LibraryPendingItem(
          filename: $0.filename,
          mimeType: $0.mimeType,
          data: $0.data,
          source: source,
          date: date
        )
      },
      maximumEntryCount: maximumEntryCount
    )
  }

  @discardableResult
  public func addAttachment(
    _ attachment: ChatAttachment,
    source: LibraryEntrySource,
    maximumEntryCount: Int? = nil,
    at date: Date = .now
  ) async throws -> LibraryEntry {
    try await add(
      filename: attachment.filename,
      mimeType: attachment.mimeType,
      data: attachment.data,
      source: source,
      maximumEntryCount: maximumEntryCount,
      at: date
    )
  }

  /// Lists an already-stored file without touching its bytes: the entry ID
  /// doubles as the blob ID in the shared file store, so this only adds the
  /// metadata row (one more reference owner). Idempotent — an existing row for
  /// the same file wins and is returned unchanged.
  @discardableResult
  public func ensureListed(
    fileID: String,
    filename: String,
    mimeType: String,
    byteCount: Int,
    source: LibraryEntrySource,
    maximumEntryCount: Int? = nil,
    at date: Date = .now
  ) async throws -> LibraryEntry {
    await beginMutation()
    defer { endMutation() }

    if let existing = state.entries.first(where: { $0.id.rawValue == fileID }) {
      return existing
    }

    try requireCapacity(for: 1, maximumEntryCount: maximumEntryCount)

    // A positive byteCount in chat metadata does not prove the shared blob is
    // still present. Verify the authoritative blob store before publishing a
    // Library row so stale historical attachments cannot become ghost items.
    let storedIDs = try await blobs.storedIDs()
    guard storedIDs.contains(fileID) else {
      throw ProviderError.invalidRequest("The saved attachment bytes are unavailable.")
    }

    let blobMetadata = try? await blobs.metadata(for: fileID)
    let authoritativeByteCount = (blobMetadata?.byteCount ?? 0) > 0 ? (blobMetadata?.byteCount ?? 0) : byteCount
    guard authoritativeByteCount > 0 else {
      throw ProviderError.invalidRequest("A library entry cannot reference empty bytes.")
    }
    guard let safeFilename = Self.sanitizedImportFilename(filename) else {
      throw ProviderError.invalidRequest("A library entry needs a valid filename.")
    }

    let entry = LibraryEntry(
      id: LibraryEntryID(rawValue: fileID),
      filename: safeFilename,
      kind: mimeType.lowercased().hasPrefix("image/") ? .image : .file,
      mimeType: mimeType,
      byteCount: authoritativeByteCount,
      createdAt: date,
      source: source
    )
    var candidate = state
    candidate.entries.append(entry)
    try await commit(candidate)
    return entry
  }

  public func rename(_ id: LibraryEntryID, filename: String) async throws {
    let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw ProviderError.invalidRequest("A library entry needs a filename.")
    }
    guard !trimmed.contains("/"), !trimmed.contains("\0"), trimmed != ".", trimmed != ".." else {
      throw ProviderError.invalidRequest("Filenames cannot contain '/'.")
    }

    await beginMutation()
    defer { endMutation() }

    var candidate = state
    guard let index = candidate.entries.firstIndex(where: { $0.id == id }) else { return }
    guard candidate.entries[index].filename != trimmed else { return }
    candidate.entries[index].filename = trimmed
    candidate.entries[index].updatedAt = .now
    try await commit(candidate)
  }

  public func deleteEntries(_ ids: Set<LibraryEntryID>) async throws {
    guard !ids.isEmpty else { return }

    await beginMutation()
    defer { endMutation() }

    var candidate = state
    candidate.entries.removeAll { ids.contains($0.id) }
    for id in ids {
      candidate.tombstones[id.rawValue] = .now
    }
    try await commit(candidate)
    // Bytes are NOT removed here: chats/projects may still reference the file.
    // AppModel.sweepOrphanFiles() deletes them once no reference remains.
  }

  /// Loads an entry's bytes. Returns nil when the blob is missing (degraded
  /// but non-fatal).
  public func data(for entry: LibraryEntry) async -> Data? {
    (try? await blobs.loadData(entry.id.rawValue)) ?? nil
  }

  /// Downsampled thumbnail bytes for tiles. The store persists the derived
  /// variant, so the full original is never loaded just to fill a small view.
  public func thumbnailData(for entry: LibraryEntry, maxPixelSize: CGFloat) async -> Data? {
    guard maxPixelSize > 0 else { return nil }
    return (try? await blobs.thumbnailData(entry.id.rawValue, maxPixelSize: maxPixelSize)) ?? nil
  }

  /// Restores self-contained entries from a backup document. keepExisting
  /// merges by entry ID; replaceExisting clears the library first.
  public func restorePortableEntries(
    _ values: [PortableLibraryEntry],
    strategy: ProviderImportStrategy
  ) async throws {
    await beginMutation()
    defer { endMutation() }

    var candidate = state
    if case .replaceExisting = strategy {
      for entry in candidate.entries {
        candidate.tombstones[entry.id.rawValue] = .now
      }
      candidate.entries.removeAll()
    }
    var existing = Set(candidate.entries.map(\.id))
    var pendingBlobs: [AttachmentBlobWriteItem] = []
    var restoredEntries: [LibraryEntry] = []

    for value in values where !existing.contains(value.id) {
      guard !value.data.isEmpty, value.data.count <= Self.maxByteCount else { continue }
      let safeFilename = Self.sanitizedImportFilename(value.filename) ?? "file"
      pendingBlobs.append(
        AttachmentBlobWriteItem(
          id: value.id.rawValue,
          data: value.data,
          metadata: AttachmentBlobMetadata(
            filename: safeFilename,
            mimeType: value.mimeType,
            byteCount: value.data.count,
            createdAt: value.createdAt
          )
        )
      )
      restoredEntries.append(
        LibraryEntry(
          id: value.id,
          filename: safeFilename,
          kind: value.kind,
          mimeType: value.mimeType,
          byteCount: value.data.count,
          createdAt: value.createdAt,
          source: value.source
        )
      )
      existing.insert(value.id)
    }
    if !pendingBlobs.isEmpty {
      try await blobs.writeBatchIfAbsent(pendingBlobs)
      candidate.entries.append(contentsOf: restoredEntries)
    }
    try await commit(candidate)
  }

  private struct LibraryPendingItem {
    let filename: String
    let mimeType: String
    let data: Data
    let source: LibraryEntrySource
    let date: Date
  }

  private func addItems(
    _ items: [LibraryPendingItem],
    maximumEntryCount: Int?
  ) async throws -> [LibraryEntry] {
    guard !items.isEmpty else { return [] }

    let entries = try items.map { item -> LibraryEntry in
      guard let safeName = Self.sanitizedImportFilename(item.filename) else {
        throw ProviderError.invalidRequest("A library entry needs a valid filename.")
      }
      guard !item.data.isEmpty else {
        throw ProviderError.invalidRequest("Library entries cannot be empty.")
      }
      guard item.data.count <= Self.maxByteCount else {
        throw ProviderError.invalidRequest("Library entries cannot exceed 20 MB.")
      }
      return LibraryEntry(
        filename: safeName,
        kind: item.mimeType.lowercased().hasPrefix("image/") ? .image : .file,
        mimeType: item.mimeType,
        byteCount: item.data.count,
        createdAt: item.date,
        source: item.source
      )
    }

    await beginMutation()
    defer { endMutation() }

    try requireCapacity(for: entries.count, maximumEntryCount: maximumEntryCount)

    // Blobs land before metadata for the same crash-ordering reason as
    // ConversationStore.persist. Failed metadata persistence leaves only
    // sweepable orphan blobs, never an uncommitted live Library row.
    try await blobs.writeBatchIfAbsent(
      zip(entries, items).map { entry, item in
        AttachmentBlobWriteItem(
          id: entry.id.rawValue,
          data: item.data,
          metadata: AttachmentBlobMetadata(
            filename: entry.filename,
            mimeType: entry.mimeType,
            byteCount: entry.byteCount,
            createdAt: entry.createdAt
          )
        )
      }
    )

    var candidate = state
    candidate.entries.append(contentsOf: entries)
    try await commit(candidate)
    return entries
  }

  /// Normalizes imported filenames so path separators or NUL bytes never leak
  /// into Library entries (which are later used for QuickLook/Share temp paths).
  private static func sanitizedImportFilename(_ raw: String) -> String? {
    let cleaned = raw
      .replacingOccurrences(of: "\0", with: "")
      .replacingOccurrences(of: "/", with: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else { return nil }
    return cleaned
  }

  /// Must run under the mutation lock, against the last committed state.
  /// Restores and reads intentionally remain unrestricted after entitlement loss.
  private func requireCapacity(for newCount: Int, maximumEntryCount: Int?) throws {
    guard let limit = maximumEntryCount else { return }
    guard newCount <= max(0, limit - state.entries.count) else {
      throw LibraryCapacityError.limitReached(limit)
    }
  }

  private func beginMutation() async {
    if !mutationInProgress {
      mutationInProgress = true
      return
    }

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      mutationWaiters.append(continuation)
    }
  }

  private func endMutation() {
    guard !mutationWaiters.isEmpty else {
      mutationInProgress = false
      return
    }
    mutationWaiters.removeFirst().resume()
  }

  private func commit(_ candidate: LibraryWorkspaceState) async throws {
    try await persistence.saveData(JSONEncoder.providerEncoder.encode(candidate))
    state = candidate
  }

  /// Drops entries whose blob file is gone (bytes lost to a crash or an
  /// older build's over-eager pruning). A metadata row without bytes has
  /// nothing to open, preview, or share, so it would only render as a row
  /// that never loads. Enumerating the blob store failing is treated as
  /// "don't know" — cleanup is skipped rather than dropping every entry.
  private func stateByDroppingEntriesWithoutBlobs(
    _ input: LibraryWorkspaceState
  ) async throws -> LibraryWorkspaceState {
    guard let stored = try? await blobs.storedIDs() else { return input }
    let deadIDs = Set(
      input.entries.filter { !stored.contains($0.id.rawValue) }.map(\.id)
    )
    guard !deadIDs.isEmpty else { return input }

    var candidate = input
    candidate.entries.removeAll { deadIDs.contains($0.id) }
    for id in deadIDs {
      candidate.tombstones[id.rawValue] = .now
    }
    try await persistence.saveData(JSONEncoder.providerEncoder.encode(candidate))
    return candidate
  }
}
