import Foundation
import Testing

@testable import BYOKchatProviderCore

@Test func currentIndexLaunchDoesNotReadConversationShards() async throws {
  let conversation = ChatConversation(
    id: "lazy-chat",
    title: "Lazy Chat",
    providerID: "provider",
    accountID: "account",
    modelID: "model",
    messages: [
      ChatMessage(role: .user, content: "full body stays in shard", status: .complete)
    ]
  )
  let record = ConversationShardRecord(conversation: conversation)
  let shard = try JSONEncoder.providerEncoderWithoutAttachmentData.encode(record)
  let index = ConversationIndexState(entries: [ConversationIndexEntry(conversation: conversation)])
  let indexData = try JSONEncoder.providerEncoder.encode(index)

  let persistence = InMemoryConversationWorkspacePersistence(
    shards: [conversation.id.rawValue: shard]
  )
  await persistence.saveIndex(indexData)

  let store = ConversationStore(persistence: persistence)
  try await store.load()

  #expect(await persistence.shardLoadCount() == 0)
  let summaries = await store.conversationSummaries()
  #expect(summaries.count == 1)
  #expect(summaries[0].title == "Lazy Chat")
  #expect(summaries[0].lastMessagePreview == "full body stays in shard")
  #expect(summaries[0].messages.first?.content == "")

  let loaded = try await store.conversation(id: conversation.id)
  #expect(loaded.messages.first?.content == "full body stays in shard")
  #expect(await persistence.shardLoadCount() == 1)
}

@Test func newerShardIsRejectedWithoutQuarantine() async throws {
  let conversation = ChatConversation(
    id: "future-chat",
    title: "Future Chat",
    providerID: "provider",
    accountID: "account",
    modelID: "model"
  )
  let index = ConversationIndexState(entries: [ConversationIndexEntry(conversation: conversation)])
  let persistence = InMemoryConversationWorkspacePersistence(
    shards: [
      conversation.id.rawValue: Data(
        "{\"schemaVersion\":999,\"minimumReaderVersion\":999}".utf8
      )
    ]
  )
  await persistence.saveIndex(try JSONEncoder.providerEncoder.encode(index))

  let store = ConversationStore(persistence: persistence)
  try await store.load()
  #expect(await persistence.shardLoadCount() == 0)

  do {
    _ = try await store.conversation(id: conversation.id)
    Issue.record("Expected a newer shard version to be rejected")
  } catch ProviderError.conversationVersionUnsupported(let version) {
    #expect(version == 999)
  } catch {
    Issue.record("Expected conversationVersionUnsupported, got \(error)")
  }

  #expect(await store.quarantinedShardCount == 0)
  #expect(await persistence.shardIDs() == [conversation.id.rawValue])
}

@Test func legacyBareShardMigratesToVersionedRecordAndIndex() async throws {
  let conversation = ChatConversation(
    id: "legacy-chat",
    title: "Legacy",
    providerID: "provider",
    accountID: "account",
    modelID: "model",
    messages: [ChatMessage(role: .user, content: "legacy body", status: .complete)]
  )
  let legacyData = try JSONEncoder.providerEncoderWithoutAttachmentData.encode(conversation)
  let persistence = InMemoryConversationWorkspacePersistence(
    shards: [conversation.id.rawValue: legacyData]
  )
  let store = ConversationStore(persistence: persistence)

  try await store.load()

  let migratedShard = try #require(await persistence.loadShard(id: conversation.id.rawValue))
  let record = try JSONDecoder.provider.decode(ConversationShardRecord.self, from: migratedShard)
  #expect(record.schemaVersion == ConversationShardRecord.currentSchemaVersion)
  #expect(record.conversation.messages.first?.content == "legacy body")

  let indexData = try #require(await persistence.loadIndex())
  let index = try JSONDecoder.provider.decode(ConversationIndexState.self, from: indexData)
  #expect(index.schemaVersion == ConversationIndexState.currentSchemaVersion)
  #expect(index.entries.map(\.id) == [conversation.id])
}

@Test func indexEntryTruncatesLongPreviewsAndDrafts() {
  let longReply = String(repeating: "A", count: 1_500)
  let longDraft = String(repeating: "B", count: 900)
  let conversation = ChatConversation(
    id: "long-preview-chat",
    title: "Long",
    providerID: "provider",
    accountID: "account",
    modelID: "model",
    messages: [ChatMessage(role: .assistant, content: longReply, status: .complete)],
    draftText: longDraft
  )

  let entry = ConversationIndexEntry(conversation: conversation)
  #expect(entry.lastMessagePreview?.count == ConversationIndexEntry.maxPreviewLength)
  #expect(entry.lastMessagePreview?.hasSuffix("…") == true)
  #expect(entry.draftText?.count == ConversationIndexEntry.maxPreviewLength)
  #expect(entry.draftText?.hasSuffix("…") == true)
}

@Test func storeEvictsIdleShardsByLRUAndProtectsActiveShards() async throws {
  let persistence = InMemoryConversationWorkspacePersistence()
  let store = ConversationStore(persistence: persistence, maxCachedConversations: 2)
  try await store.load()

  let first = try await store.createConversation(
    providerID: "provider",
    accountID: "account",
    modelID: "model",
    id: "chat-1"
  )
  let second = try await store.createConversation(
    providerID: "provider",
    accountID: "account",
    modelID: "model",
    id: "chat-2"
  )
  let third = try await store.createConversation(
    providerID: "provider",
    accountID: "account",
    modelID: "model",
    id: "chat-3"
  )

  #expect(await store.cachedConversationCount() == 2)
  #expect(await store.cachedConversation(id: first.id) == nil)
  #expect(await store.cachedConversation(id: second.id) != nil)
  #expect(await store.cachedConversation(id: third.id) != nil)

  // Evicted shards transparently reload from persistence when opened again.
  let reloaded = try await store.conversation(id: first.id)
  #expect(reloaded.id == first.id)
  #expect(await store.cachedConversationCount() == 2)

  // Memory-warning eviction drops everything except pinned IDs.
  await store.evictCachedConversations(keeping: [first.id])
  #expect(await store.cachedConversationCount() == 1)
  #expect(await store.cachedConversation(id: first.id) != nil)
}

@Test func draftNoOpSkipsRedundantWritesAndCorruptShardsPurgeCleanly() async throws {
  let persistence = InMemoryConversationWorkspacePersistence(
    shards: ["corrupt-chat": Data("not-valid-json".utf8)]
  )
  let store = ConversationStore(persistence: persistence)
  try await store.load()
  #expect(await store.quarantinedShardCount == 1)
  #expect(try await persistence.quarantinedShardIDs() == ["corrupt-chat"])

  let created = try await store.createConversation(
    providerID: "provider",
    accountID: "account",
    modelID: "model",
    id: "draft-chat"
  )
  try await store.setDraft("hello", conversationID: created.id)
  let writesAfterFirstDraft = await persistence.indexSaveCount()
  try await store.setDraft("hello", conversationID: created.id)
  #expect(await persistence.indexSaveCount() == writesAfterFirstDraft)

  let purged = try await store.purgeQuarantinedShards()
  #expect(purged == 1)
  #expect(await store.quarantinedShardCount == 0)
  #expect(try await persistence.quarantinedShardIDs().isEmpty)
}

@Test func derivedThumbnailCacheClearsWithoutDeletingOriginals() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("byok-derived-clear-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }

  let store = FileAttachmentBlobStore(directory: root)
  let id = UUID().uuidString.lowercased()
  let payload = Data("original-bytes".utf8)
  try await store.writeIfAbsent(
    id,
    data: payload,
    metadata: AttachmentBlobMetadata(
      filename: "photo.jpg",
      mimeType: "image/jpeg",
      byteCount: payload.count,
      createdAt: .now
    )
  )

  let derivedDir = root.appendingPathComponent("derived", isDirectory: true)
  try FileManager.default.createDirectory(at: derivedDir, withIntermediateDirectories: true)
  try Data("thumb".utf8).write(to: derivedDir.appendingPathComponent("\(id)-200"))

  let removed = await store.clearDerivedCache()
  #expect(removed == 1)
  #expect(try await store.loadData(id) == payload)
}
