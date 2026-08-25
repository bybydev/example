import Foundation
import Testing

@testable import BYOKchatProviderCore

@Test func editAndResendRuntimeUsesEditedContext() async throws {
  let environment = try await makeConversationEnvironment()
  for try await _ in await environment.chat.send(
    conversationID: environment.conversation.id,
    userText: "Original question"
  ) {}
  let initial = try await environment.conversations.conversation(id: environment.conversation.id)
  let user = try #require(initial.messages.first(where: { $0.role == .user }))

  for try await _ in await environment.chat.editAndResend(
    conversationID: environment.conversation.id,
    messageID: user.id,
    newText: "Edited question"
  ) {}

  let updated = try await environment.conversations.conversation(id: environment.conversation.id)
  #expect(updated.messages.count == 2)
  #expect(updated.messages.first?.content == "Edited question")
  #expect(updated.messages.last?.status == .complete)
  #expect(await environment.runtime.requestCount() == 2)
  let requests = await environment.runtime.requests
  #expect(requests.last?.messages.last?.content == "Edited question")
}

@Test func regenerateRuntimeReplacesAssistantWithoutDuplicatingUser() async throws {
  let environment = try await makeConversationEnvironment()
  for try await _ in await environment.chat.send(
    conversationID: environment.conversation.id,
    userText: "Question"
  ) {}
  let before = try await environment.conversations.conversation(id: environment.conversation.id)
  let originalAssistantID = before.messages.last?.id

  for try await _ in await environment.chat.regenerate(
    conversationID: environment.conversation.id
  ) {}

  let updated = try await environment.conversations.conversation(id: environment.conversation.id)
  #expect(updated.messages.count == 2)
  #expect(updated.messages.filter { $0.role == .user }.count == 1)
  #expect(updated.messages.last?.id != originalAssistantID)
  #expect(updated.messages.last?.status == .complete)
  #expect(await environment.runtime.requestCount() == 2)
}

@Test func backgroundFlushPersistsNewestPartialOutput() async throws {
  let providerPersistence = InMemoryProviderWorkspacePersistence()
  let providerWorkspace = ProviderWorkspaceStore(persistence: providerPersistence)
  try await providerWorkspace.load()
  let account = ProviderAccount(
    id: "account",
    providerID: "deepseek",
    label: "DeepSeek",
    defaultModelID: "model"
  )
  try await providerWorkspace.upsertAccount(account)
  try await providerWorkspace.addManualModel(
    ProviderModel(providerID: "deepseek", id: "model", displayName: "Model"),
    for: account.id
  )

  let store = ConversationStore(persistence: InMemoryConversationWorkspacePersistence())
  try await store.load()
  let conversation = try await store.createConversation(
    providerID: "deepseek",
    accountID: account.id,
    modelID: "model"
  )
  let chat = ChatRuntime(
    providerRuntime: PartialThenSuspendRuntime(),
    providerWorkspace: providerWorkspace,
    conversations: store,
    partialPersistenceInterval: .seconds(30)
  )
  let stream = await chat.send(conversationID: conversation.id, userText: "Hello")
  let consumer = Task {
    do {
      for try await _ in stream {}
    } catch {}
  }
  try await Task.sleep(for: .milliseconds(30))
  await chat.flushActiveGenerations()

  let flushed = try await store.conversation(id: conversation.id)
  #expect(flushed.messages.last?.status == .streaming)
  #expect(flushed.messages.last?.content == "Partial")

  await chat.cancel(conversationID: conversation.id)
  consumer.cancel()
  _ = await consumer.result
}

@Test func olderConversationJSONRemainsDecodable() async throws {
  let message = ChatMessage(role: .user, content: "Legacy", status: .complete)
  let conversation = ChatConversation(
    providerID: "deepseek",
    accountID: "account",
    modelID: "model",
    messages: [message]
  )
  // Strip keys that older files lacked; shard decoding must tolerate them.
  let encoded = try JSONEncoder.providerEncoder.encode(conversation)
  var shard = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
  shard.removeValue(forKey: "draftText")
  var messages = try #require(shard["messages"] as? [[String: Any]])
  messages[0].removeValue(forKey: "completionUncertain")
  shard["messages"] = messages
  let legacyData = try JSONSerialization.data(withJSONObject: shard)

  let store = ConversationStore(
    persistence: InMemoryConversationWorkspacePersistence(
      shards: [conversation.id.rawValue: legacyData]
    )
  )
  try await store.load()
  let decoded = try await store.conversation(id: conversation.id)
  #expect(decoded.draftText == nil)
  #expect(decoded.messages.first?.completionUncertain == nil)
}
