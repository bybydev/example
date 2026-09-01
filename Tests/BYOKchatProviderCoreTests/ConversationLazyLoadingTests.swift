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
