import Foundation
import Testing

@testable import BYOKchatProviderCore

@Suite("Library store transactions")
struct LibraryStoreTransactionTests {
  @Test("Library saves have no default entry-count cap")
  func savesBeyondFormerFreeLimit() async throws {
    let store = LibraryStore(
      persistence: InMemoryLibraryWorkspacePersistence(),
      blobs: InMemoryAttachmentBlobStore()
    )
    try await store.load()
    for index in 1...12 {
      _ = try await store.add(
        filename: "file-\(index).txt",
        mimeType: "text/plain",
        data: Data("payload".utf8)
      )
    }

    #expect(await store.entries().count == 12)
  }

  @Test("Failed add does not publish an unpersisted Library entry")
  func failedAddKeepsCommittedState() async throws {
    let persistence = ToggleFailureLibraryPersistence()
    let store = LibraryStore(
      persistence: persistence,
      blobs: InMemoryAttachmentBlobStore()
    )
    try await store.load()
    await persistence.setFailSaves(true)

    var failed = false
    do {
      _ = try await store.add(
        filename: "draft.txt",
        mimeType: "text/plain",
        data: Data("draft".utf8)
      )
    } catch {
      failed = true
    }

    #expect(failed)
    #expect(await store.entries().isEmpty)
  }

  @Test("Failed rename and delete preserve the last committed Library state")
  func failedMutationsPreserveCommittedState() async throws {
    let persistence = ToggleFailureLibraryPersistence()
    let store = LibraryStore(
      persistence: persistence,
      blobs: InMemoryAttachmentBlobStore()
    )
    try await store.load()
    let entry = try await store.add(
      filename: "original.txt",
      mimeType: "text/plain",
      data: Data("payload".utf8)
    )

    await persistence.setFailSaves(true)

    var renameFailed = false
    do {
      try await store.rename(entry.id, filename: "changed.txt")
    } catch {
      renameFailed = true
    }
    #expect(renameFailed)
    #expect(await store.entry(id: entry.id)?.filename == "original.txt")

    var deleteFailed = false
    do {
      try await store.deleteEntries([entry.id])
    } catch {
      deleteFailed = true
    }
    #expect(deleteFailed)
    #expect(await store.entry(id: entry.id)?.filename == "original.txt")
  }

  @Test("Batch add commits all entries together")
  func batchAddIsAtomicAtMetadataBoundary() async throws {
    let persistence = ToggleFailureLibraryPersistence()
    let store = LibraryStore(
      persistence: persistence,
      blobs: InMemoryAttachmentBlobStore()
    )
    try await store.load()
    await persistence.setFailSaves(true)

    let attachments = [
      ChatAttachment(
        kind: .file,
        filename: "one.txt",
        mimeType: "text/plain",
        data: Data("one".utf8)
      ),
      ChatAttachment(
        kind: .file,
        filename: "two.txt",
        mimeType: "text/plain",
        data: Data("two".utf8)
      ),
    ]

    var failed = false
    do {
      _ = try await store.addAttachments(attachments)
    } catch {
      failed = true
    }

    #expect(failed)
    #expect(await store.entries().isEmpty)

    await persistence.setFailSaves(false)
    let added = try await store.addAttachments(attachments)
    #expect(added.count == 2)
    #expect(await store.entries().count == 2)
  }

  @Test("Saving a historical attachment requires the shared blob to exist")
  func ensureListedRejectsMissingBlob() async throws {
    let store = LibraryStore(
      persistence: InMemoryLibraryWorkspacePersistence(),
      blobs: InMemoryAttachmentBlobStore()
    )
    try await store.load()

    var failed = false
    do {
      _ = try await store.ensureListed(
        fileID: "missing-attachment",
        filename: "missing.pdf",
        mimeType: "application/pdf",
        byteCount: 4_096,
        source: .chat(conversationID: "chat-a", messageID: "message-a")
      )
    } catch {
      failed = true
    }

    #expect(failed)
    #expect(await store.entries().isEmpty)
  }

  @Test("Saving a stored attachment reuses its blob-backed ID")
  func ensureListedAcceptsExistingBlob() async throws {
    let blobs = InMemoryAttachmentBlobStore()
    let data = Data("stored bytes".utf8)
    try await blobs.writeIfAbsent(
      "stored-attachment",
      data: data,
      metadata: AttachmentBlobMetadata(
        filename: "stored.txt",
        mimeType: "text/plain",
        byteCount: data.count,
        createdAt: .now
      )
    )
    let store = LibraryStore(
      persistence: InMemoryLibraryWorkspacePersistence(),
      blobs: blobs
    )
    try await store.load()

    let entry = try await store.ensureListed(
      fileID: "stored-attachment",
      filename: "stored.txt",
      mimeType: "text/plain",
      byteCount: data.count,
      source: .chat(conversationID: "chat-a", messageID: "message-a")
    )

    #expect(entry.id.rawValue == "stored-attachment")
    #expect(await store.entries().map(\.id) == [entry.id])
  }

  @Test("Concurrent Library adds do not lose a committed entry")
  func concurrentAddsSerialize() async throws {
    let store = LibraryStore(
      persistence: InMemoryLibraryWorkspacePersistence(),
      blobs: InMemoryAttachmentBlobStore()
    )
    try await store.load()

    async let first = store.add(
      filename: "first.txt",
      mimeType: "text/plain",
      data: Data("first".utf8)
    )
    async let second = store.add(
      filename: "second.txt",
      mimeType: "text/plain",
      data: Data("second".utf8)
    )

    _ = try await (first, second)
    #expect(await store.entries().count == 2)
  }

  @Test("Rename rejects path separators and dot-only filenames")
  func renameRejectsPathSeparators() async throws {
    let store = LibraryStore(
      persistence: InMemoryLibraryWorkspacePersistence(),
      blobs: InMemoryAttachmentBlobStore()
    )
    try await store.load()
    let entry = try await store.add(
      filename: "report.pdf",
      mimeType: "application/pdf",
      data: Data("pdf".utf8)
    )

    for invalid in ["2026/04 report.pdf", ".", "..", "nested/path/file.txt"] {
      var threw = false
      do {
        try await store.rename(entry.id, filename: invalid)
      } catch {
        threw = true
      }
      #expect(threw)
    }
    #expect(await store.entry(id: entry.id)?.filename == "report.pdf")
  }

  @Test("No-op rename skips persistence and keeps updatedAt unchanged")
  func renameNoOpSkipsPersistence() async throws {
    let persistence = ToggleFailureLibraryPersistence()
    let store = LibraryStore(
      persistence: persistence,
      blobs: InMemoryAttachmentBlobStore()
    )
    try await store.load()
    let entry = try await store.add(
      filename: "notes.md",
      mimeType: "text/markdown",
      data: Data("hello".utf8)
    )

    await persistence.setFailSaves(true)
    try await store.rename(entry.id, filename: "  notes.md  ")
    #expect(await store.entry(id: entry.id)?.updatedAt == entry.updatedAt)
  }

  @Test("Add sanitizes path separators and rejects dot-only filenames")
  func addSanitizesUnsafeFilenames() async throws {
    let store = LibraryStore(
      persistence: InMemoryLibraryWorkspacePersistence(),
      blobs: InMemoryAttachmentBlobStore()
    )
    try await store.load()

    let entry = try await store.add(
      filename: "2026/04/report\0.pdf",
      mimeType: "application/pdf",
      data: Data("pdf".utf8)
    )
    #expect(entry.filename == "2026-04-report.pdf")

    for invalid in ["", "   ", ".", ".."] {
      var threw = false
      do {
        _ = try await store.add(
          filename: invalid,
          mimeType: "text/plain",
          data: Data("x".utf8)
        )
      } catch {
        threw = true
      }
      #expect(threw)
    }
  }
}

private enum LibraryTransactionTestError: Error {
  case saveFailed
}

private actor ToggleFailureLibraryPersistence: LibraryWorkspacePersistence {
  private var data: Data?
  private var failSaves = false

  func setFailSaves(_ value: Bool) {
    failSaves = value
  }

  func loadData() -> Data? {
    data
  }

  func saveData(_ data: Data) throws {
    if failSaves {
      throw LibraryTransactionTestError.saveFailed
    }
    self.data = data
  }
}
