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

  public init(
    persistence: any LibraryWorkspacePersistence,
    blobs: any AttachmentBlobStoring
  ) {
    self.persistence = persistence
    self.blobs = blobs
  }

  public func load() async throws {
    guard !hasLoaded else { return }
    if let data = try await persistence.loadData() {
      let decoded = try JSONDecoder.provider.decode(LibraryWorkspaceState.self, from: data)
      guard decoded.schemaVersion == LibraryWorkspaceState.currentSchemaVersion else {
        throw ProviderError.libraryVersionUnsupported(decoded.schemaVersion)
      }
      state = decoded
    }
    hasLoaded = true
    await pruneOrphanBlobs()
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

  @discardableResult
  public func add(
    filename: String,
    mimeType: String,
    data: Data,
    source: LibraryEntrySource = .manual,
    at date: Date = .now
  ) async throws -> LibraryEntry {
    let trimmedName = filename.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      throw ProviderError.invalidRequest("A library entry needs a filename.")
    }
    guard !data.isEmpty else {
      throw ProviderError.invalidRequest("Library entries cannot be empty.")
    }
    guard data.count <= Self.maxByteCount else {
      throw ProviderError.invalidRequest("Library entries cannot exceed 20 MB.")
    }

    let entry = LibraryEntry(
      filename: trimmedName,
      kind: mimeType.lowercased().hasPrefix("image/") ? .image : .file,
      mimeType: mimeType,
      byteCount: data.count,
      createdAt: date,
      source: source
    )
    // Blobs land before metadata for the same crash-ordering reason as
    // ConversationStore.persist.
    try await blobs.writeIfAbsent(entry.id.rawValue, data: data)
    state.entries.append(entry)
    try await persist()
    return entry
  }

  @discardableResult
  public func addAttachment(
    _ attachment: ChatAttachment,
    source: LibraryEntrySource,
    at date: Date = .now
  ) async throws -> LibraryEntry {
    try await add(
      filename: attachment.filename,
      mimeType: attachment.mimeType,
      data: attachment.data,
      source: source,
      at: date
    )
  }

  public func rename(_ id: LibraryEntryID, filename: String) async throws {
    let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw ProviderError.invalidRequest("A library entry needs a filename.")
    }
    guard let index = state.entries.firstIndex(where: { $0.id == id }) else { return }
    state.entries[index].filename = trimmed
    try await persist()
  }

  public func deleteEntries(_ ids: Set<LibraryEntryID>) async throws {
    guard !ids.isEmpty else { return }
    state.entries.removeAll { ids.contains($0.id) }
    try await persist()
    try await blobs.deleteIDs(Set(ids.map(\.rawValue)))
  }

  /// Loads an entry's bytes. Returns nil when the blob is missing (degraded
  /// but non-fatal).
  public func data(for entry: LibraryEntry) async -> Data? {
    (try? await blobs.loadData(entry.id.rawValue)) ?? nil
  }

  /// Restores self-contained entries from a backup document. keepExisting
  /// merges by entry ID; replaceExisting clears the library first.
  public func restorePortableEntries(
    _ values: [PortableLibraryEntry],
    strategy: ProviderImportStrategy
  ) async throws {
    if case .replaceExisting = strategy {
      state.entries.removeAll()
    }
    let existing = Set(state.entries.map(\.id))

    for value in values where !existing.contains(value.id) {
      guard !value.data.isEmpty, value.data.count <= Self.maxByteCount else { continue }
      try await blobs.writeIfAbsent(value.id.rawValue, data: value.data)
      state.entries.append(
        LibraryEntry(
          id: value.id,
          filename: value.filename,
          kind: value.kind,
          mimeType: value.mimeType,
          byteCount: value.data.count,
          createdAt: value.createdAt,
          source: value.source
        )
      )
    }
    try await persist()
  }

  /// Removes blob files whose entries no longer exist (e.g. after a crash
  /// between blob write and JSON write, or an interrupted delete).
  private func pruneOrphanBlobs() async {
    let referenced = Set(state.entries.map(\.id.rawValue))
    let stored = (try? await blobs.storedIDs()) ?? []
    let orphans = stored.subtracting(referenced)
    guard !orphans.isEmpty else { return }
    try? await blobs.deleteIDs(orphans)
  }

  private func persist() async throws {
    try await persistence.saveData(JSONEncoder.providerEncoder.encode(state))
  }
}
