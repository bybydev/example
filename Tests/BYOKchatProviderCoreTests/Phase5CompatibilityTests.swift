import Foundation
import Testing

@testable import BYOKchatProviderCore

@Test func privateHTTPProvidersRequirePrivateHosts() throws {
  let local = try CustomProviderFactory.makeOpenAICompatible(
    id: "ollama",
    displayName: "Ollama",
    baseURL: URL(string: "http://192.168.1.20:11434/v1")!,
    authentication: .none,
    seedModelIDs: ["qwen3"],
    allowsLocalHTTP: true
  )
  #expect(local.allowsLocalHTTP)

  #expect(throws: ProviderError.self) {
    _ = try CustomProviderFactory.makeOpenAICompatible(
      id: "unsafe",
      displayName: "Unsafe",
      baseURL: URL(string: "http://example.com/v1")!,
      allowsLocalHTTP: true
    )
  }
}

@Test func portableConversationRoundTripRecreatesMessages() async throws {
  let source = ConversationStore(persistence: InMemoryConversationWorkspacePersistence())
  try await source.load()
  let conversation = try await source.createConversation(
    providerID: "deepseek",
    accountID: "account",
    modelID: "deepseek-chat"
  )
  let turn = try await source.beginTurn(conversationID: conversation.id, userText: "Hello")
  _ = try await source.completeMessage(
    conversationID: conversation.id,
    messageID: turn.assistantMessage.id,
    response: ProviderResponse(
      text: "Hi",
      providerID: "deepseek",
      accountID: "account",
      modelID: "deepseek-chat"
    )
  )

  let data = try await source.exportWorkspace()
  let restored = ConversationStore(persistence: InMemoryConversationWorkspacePersistence())
  try await restored.load()
  try await restored.importWorkspace(data, strategy: .replaceExisting)

  let conversations = await restored.allConversations()
  #expect(conversations.count == 1)
  #expect(conversations[0].messages.map(\.content) == ["Hello", "Hi"])
}
