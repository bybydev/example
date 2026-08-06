import Foundation
import Testing

@testable import BYOKchatProviderCore

@Test func keepExistingConversationImportIsIdempotent() async throws {
  let source = ConversationStore(persistence: InMemoryConversationWorkspacePersistence())
  try await source.load()
  let conversation = try await source.createConversation(
    providerID: "deepseek",
    accountID: "account",
    modelID: "deepseek-chat",
    systemPrompt: "Be direct."
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
  try await restored.importWorkspace(data, strategy: .keepExisting)
  try await restored.importWorkspace(data, strategy: .keepExisting)

  #expect(await restored.allConversations().count == 1)
}

@Test func providerRedirectsAreRestrictedToSameOrigin() throws {
  let source = try #require(URL(string: "http://192.168.1.20:11434/v1/chat/completions"))
  let sameOrigin = try #require(URL(string: "http://192.168.1.20:11434/v1/redirected"))
  let changedPort = try #require(URL(string: "http://192.168.1.20:8080/v1/redirected"))
  let changedHost = try #require(URL(string: "http://192.168.1.21:11434/v1/redirected"))
  let upgradedScheme = try #require(URL(string: "https://192.168.1.20:11434/v1/redirected"))

  #expect(ProviderHTTP.isSameOriginRedirect(from: source, to: sameOrigin))
  #expect(!ProviderHTTP.isSameOriginRedirect(from: source, to: changedPort))
  #expect(!ProviderHTTP.isSameOriginRedirect(from: source, to: changedHost))
  #expect(!ProviderHTTP.isSameOriginRedirect(from: source, to: upgradedScheme))
}
