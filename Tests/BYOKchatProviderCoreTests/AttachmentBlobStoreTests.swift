import Foundation
import Testing

@testable import BYOKchatProviderCore

/// Covers the on-demand blob store: the metadata index, persisted downsampled
/// derivatives, and metadata-only rows (attachment bytes live in the store,
/// never in the workspace JSON).
struct AttachmentBlobStoreTests {
  private func makeStore() -> (FileAttachmentBlobStore, URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("byok-blob-tests-\(UUID().uuidString)", isDirectory: true)
    let store = FileAttachmentBlobStore(directory: directory)
    return (store, directory)
  }

  private let metadata = AttachmentBlobMetadata(
    filename: "photo.jpg",
    mimeType: "image/jpeg",
    byteCount: 3,
    createdAt: Date(timeIntervalSince1970: 100)
  )

  @Test func writeAndReadBackMetadata() async throws {
    let (store, directory) = makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    try await store.writeIfAbsent("abc-1", data: Data([1, 2, 3]), metadata: metadata)
    let loaded = try #require(await store.metadata(for: "abc-1"))
    #expect(loaded.filename == "photo.jpg")
    #expect(loaded.mimeType == "image/jpeg")
    #expect(loaded.byteCount == 3)

    // Unknown IDs read as absent, not as errors.
    #expect(try await store.metadata(for: "missing-id") == nil)
    #expect(try await store.loadData("missing-id") == nil)
  }

  @Test func indexSurvivesReinstantiation() async throws {
    let (store, directory) = makeStore()
    try await store.writeIfAbsent("abc-2", data: Data([9]), metadata: metadata)

    let reloaded = FileAttachmentBlobStore(directory: directory)
    let loaded = try #require(await reloaded.metadata(for: "abc-2"))
    #expect(loaded.byteCount == 3)
    #expect(await reloaded.storedIDs() == ["abc-2"])
    try? FileManager.default.removeItem(at: directory)
  }

  @Test func deleteRemovesBlobAndDerivatives() async throws {
    let (store, directory) = makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    let id = "abc-3"
    try await store.writeIfAbsent(id, data: Data([1, 2, 3]), metadata: metadata)
    _ = try await store.deleteIDs([id])

    #expect(try await store.metadata(for: id) == nil)
    #expect(try await store.loadData(id) == nil)
    let derived = directory.appendingPathComponent("derived", isDirectory: true)
    #expect(FileManager.default.fileExists(atPath: derived.appendingPathComponent(id).path) == false)
  }

  @Test func storedIDsExcludeIndexAndDerivedDirectory() async throws {
    let (store, directory) = makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    try await store.writeIfAbsent("abc-4", data: Data([1]), metadata: metadata)
    _ = try await store.thumbnailData("abc-4", maxPixelSize: 64)
    let ids = await store.storedIDs()
    #expect(ids == ["abc-4"])
  }

  @Test func metadataOnlyRoundTripKeepsByteCount() async throws {
    let persistence = InMemoryConversationWorkspacePersistence()
    let blobs = InMemoryAttachmentBlobStore()
    let store = ConversationStore(persistence: persistence, blobs: blobs)
    try await store.load()
    let conversation = try await store.createConversation(
      providerID: "openrouter",
      accountID: "account",
      modelID: "model"
    )
    let image = ChatAttachment(
      kind: .image,
      filename: "photo.jpg",
      mimeType: "image/jpeg",
      data: Data([1, 2, 3])
    )
    _ = try await store.beginTurn(
      conversationID: conversation.id,
      userText: "Look",
      attachments: [image]
    )

    // Persist drops the bytes and records the size; the row stays metadata-only.
    let stored = try await store.conversation(id: conversation.id)
    let row = try #require(stored.messages.first?.attachments?.first)
    #expect(row.data.isEmpty)
    #expect(row.declaredByteCount == 3)
    #expect(row.byteCount == 3)

    // JIT hydration fills exactly the request messages.
    var messages: [ProviderMessage] = [
      .init(role: .user, content: "Look", attachments: [row])
    ]
    try await store.hydrateRequestAttachments(in: &messages)
    #expect(messages[0].attachments?.first?.data == Data([1, 2, 3]))
  }

  @Test func hydrationDropsMissingBlobsButKeepsReadErrorRows() async throws {
    let persistence = InMemoryConversationWorkspacePersistence()
    let blobs = InMemoryAttachmentBlobStore(
      initial: ["present": Data([7])]
    )
    let store = ConversationStore(persistence: persistence, blobs: blobs)
    try await store.load()

    var messages: [ProviderMessage] = [
      .init(
        role: .user,
        content: "Mixed",
        attachments: [
          ChatAttachment(
            kind: .image, filename: "present.jpg", mimeType: "image/jpeg",
            data: Data(), declaredByteCount: 1
          ),
          ChatAttachment(
            kind: .file, filename: "gone.pdf", mimeType: "application/pdf",
            data: Data(), declaredByteCount: 4
          ),
        ]
      )
    ]
    try await store.hydrateRequestAttachments(in: &messages)

    let kept = try #require(messages[0].attachments)
    #expect(kept.count == 2)
    #expect(kept[0].data == Data([7]))
    // Confirmed-missing stays as metadata (surfaces show "unavailable"); the
    // row is no longer silently deleted.
    #expect(kept[1].data.isEmpty && kept[1].declaredByteCount == 4)
  }
}
