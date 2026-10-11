import BYOKchatProviderCore
import Foundation
import Observation

/// Main-actor observable facade over `LibraryStore`, following the same
/// pattern as the other management models.
@MainActor
@Observable
final class LibraryManagementModel {
  private(set) var entries: [LibraryEntry] = []
  var isBusy = false
  var errorMessage: String?
  /// App-layer hook invoked after mutations that change file references.
  /// AppModel sets it to run the orphan-file sweep.
  var onFileReferencesChanged: (() -> Void)?

  private let store: LibraryStore
  private var analyticsRecordedEntryIDs: Set<LibraryEntryID> = []

  init(store: LibraryStore) {
    self.store = store
  }

  func load() async {
    do {
      try await store.load()
      entries = await store.entries()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func reloadFromStorage() async {
    entries = await store.entries()
  }

  /// Authoritative entry IDs for the app-level orphan sweep.
  func referencedEntryIDs() async -> Set<String> {
    await store.referencedEntryIDs()
  }

  @discardableResult
  func add(
    filename: String,
    mimeType: String,
    data: Data,
    source: LibraryEntrySource = .manual,
    onError: ((Error) -> Void)? = nil
  ) async -> LibraryEntry? {
    let existingIDs = Set(await store.entries().map(\.id))
    let entry = await performReturning(onError: onError) {
      try await self.store.add(
        filename: filename,
        mimeType: mimeType,
        data: data,
        source: source
      )
    }
    if let entry, !existingIDs.contains(entry.id),
      analyticsRecordedEntryIDs.insert(entry.id).inserted
    {
      BYOKAppAnalytics.track(.libraryItemSaved, dimension: entry.kind == .image ? .image : .file)
    }
    return entry
  }

  @discardableResult
  func addAttachment(
    _ attachment: ChatAttachment,
    source: LibraryEntrySource,
    onError: ((Error) -> Void)? = nil
  ) async -> LibraryEntry? {
    let existingIDs = Set(await store.entries().map(\.id))
    let entry = await performReturning(onError: onError) {
      try await self.store.addAttachment(
        attachment,
        source: source
      )
    }
    if let entry, !existingIDs.contains(entry.id),
      analyticsRecordedEntryIDs.insert(entry.id).inserted
    {
      BYOKAppAnalytics.track(.libraryItemSaved, dimension: entry.kind == .image ? .image : .file)
    }
    return entry
  }

  func rename(_ id: LibraryEntryID, filename: String) async {
    await perform {
      try await self.store.rename(id, filename: filename)
    }
  }

  func deleteEntries(_ ids: Set<LibraryEntryID>) async {
    await perform {
      try await self.store.deleteEntries(ids)
    }
    onFileReferencesChanged?()
  }

  @discardableResult
  func ensureListed(
    fileID: String,
    filename: String,
    mimeType: String,
    byteCount: Int,
    source: LibraryEntrySource,
    onError: ((Error) -> Void)? = nil
  ) async -> LibraryEntry? {
    let existingIDs = Set(await store.entries().map(\.id))
    let entry = await performReturning(onError: onError) {
      try await self.store.ensureListed(
        fileID: fileID,
        filename: filename,
        mimeType: mimeType,
        byteCount: byteCount,
        source: source
      )
    }
    if let entry, !existingIDs.contains(entry.id),
      analyticsRecordedEntryIDs.insert(entry.id).inserted
    {
      BYOKAppAnalytics.track(.libraryItemSaved, dimension: entry.kind == .image ? .image : .file)
    }
    return entry
  }

  /// Bytes for previews/viewer/share. nil when the blob is missing.
  func data(for entry: LibraryEntry) async -> Data? {
    await store.data(for: entry)
  }

  /// Downsampled thumbnail bytes, served from the blob store's persisted
  /// derivative when available (never loads the full original for a tile).
  func thumbnailData(for entry: LibraryEntry, maxPixelSize: CGFloat) async -> Data? {
    await store.thumbnailData(for: entry, maxPixelSize: maxPixelSize)
  }

  private func perform(_ operation: () async throws -> Void) async {
    isBusy = true
    defer { isBusy = false }
    do {
      try await operation()
      entries = await store.entries()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  /// A chat/sheet supplies its own error owner. The default preserves LibraryView's
  /// local model-backed alert without also publishing a chat failure there.
  private func performReturning<T>(
    onError: ((Error) -> Void)? = nil,
    _ operation: () async throws -> T?
  ) async -> T? {
    isBusy = true
    defer { isBusy = false }
    do {
      let result = try await operation()
      entries = await store.entries()
      return result
    } catch {
      if let onError {
        onError(error)
      } else {
        errorMessage = error.localizedDescription
      }
      return nil
    }
  }
}
