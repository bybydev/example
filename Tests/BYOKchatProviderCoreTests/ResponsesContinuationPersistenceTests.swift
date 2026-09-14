import Foundation
import Testing

@testable import BYOKchatProviderCore

@Test func completedMessagePersistsTypedResponsesContinuationAcrossReload() async throws {
  let persistence = InMemoryConversationWorkspacePersistence()
  let store = ConversationStore(persistence: persistence)
  try await store.load()
  let conversation = try await store.createConversation(
    providerID: "openai",
    accountID: "openai-account",
    modelID: "gpt-5.6-sol"
  )
  let turn = try await store.beginTurn(
    conversationID: conversation.id,
    userText: "Hello"
  )
  let continuation = responsesPersistenceFixture()

  let completed = try await store.completeMessage(
    conversationID: conversation.id,
    messageID: turn.assistantMessage.id,
    response: ProviderResponse(
      text: "Hi",
      providerID: "openai",
      accountID: "openai-account",
      modelID: "gpt-5.6-sol",
      toolContinuation: continuation
    )
  )
  #expect(completed.providerContinuation == continuation)

  let summaries = await store.conversationSummaries()
  let summary = try #require(summaries.first)
  #expect(summary.messages.last?.providerContinuation == nil)

  let reloadedStore = ConversationStore(persistence: persistence)
  try await reloadedStore.load()
  let reloaded = try await reloadedStore.conversation(id: conversation.id)
  #expect(reloaded.messages.last?.providerContinuation == continuation)
}

@Test func responsesContinuationSurvivesPortableExportImport() async throws {
  let source = ConversationStore(persistence: InMemoryConversationWorkspacePersistence())
  try await source.load()
  let conversation = try await source.createConversation(
    providerID: "xai",
    accountID: "xai-account",
    modelID: "grok-4.6"
  )
  let turn = try await source.beginTurn(
    conversationID: conversation.id,
    userText: "Hello"
  )
  let continuation = responsesPersistenceFixture()
  _ = try await source.completeMessage(
    conversationID: conversation.id,
    messageID: turn.assistantMessage.id,
    response: ProviderResponse(
      text: "Hi",
      providerID: "xai",
      accountID: "xai-account",
      modelID: "grok-4.6",
      toolContinuation: continuation
    )
  )

  let exported = try await source.exportWorkspace()
  let destination = ConversationStore(persistence: InMemoryConversationWorkspacePersistence())
  try await destination.load()
  let mapping = try await destination.importWorkspace(exported, strategy: .replaceExisting)
  let restoredID = try #require(mapping[conversation.id])
  let restored = try await destination.conversation(id: restoredID)
  #expect(restored.messages.last?.providerContinuation == continuation)
}

@Test func chatMessageDecodesWhenLegacyPayloadLacksProviderContinuation() throws {
  let message = ChatMessage(
    role: .assistant,
    content: "Legacy answer",
    status: .complete,
    providerID: "openai",
    accountID: "openai-account",
    modelID: "legacy-model"
  )
  let encoded = try JSONEncoder.providerEncoder.encode(message)
  var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
  object.removeValue(forKey: "providerContinuation")
  let legacy = try JSONSerialization.data(withJSONObject: object)

  let decoded = try JSONDecoder.provider.decode(ChatMessage.self, from: legacy)
  #expect(decoded.content == "Legacy answer")
  #expect(decoded.providerContinuation == nil)
}

private func responsesPersistenceFixture() -> ProviderToolContinuation {
  ProviderToolContinuation(
    apiFamily: .openAIResponses,
    payload: .array([
      .object([
        "id": .string("rs_persisted"),
        "type": .string("reasoning"),
        "encrypted_content": .string("opaque-persisted-state"),
      ]),
      .object([
        "id": .string("msg_persisted"),
        "type": .string("message"),
        "role": .string("assistant"),
        "content": .array([
          .object(["type": .string("output_text"), "text": .string("Hi")])
        ]),
      ]),
    ])
  )
}
