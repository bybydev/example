import Foundation
import Testing

@testable import BYOKchatProviderCore

@Test func conversationImportPreservesAttachmentsToolRoundsAndReturnsIDMapping() async throws {
  let environment = try await makeConversationEnvironment()
  let attachment = ChatAttachment(
    id: "attachment-1",
    kind: .file,
    filename: "notes.txt",
    mimeType: "text/plain",
    data: Data("hello attachment".utf8)
  )
  let turn = try await environment.conversations.beginTurn(
    conversationID: environment.conversation.id,
    userText: "Use this file",
    attachments: [attachment]
  )
  let round = ChatToolRound(
    calls: [
      ChatToolCall(
        id: "tool-call-1",
        name: "tool_one",
        arguments: .object(["value": .string("hello")])
      )
    ],
    results: [
      ChatToolResult(
        callID: "tool-call-1",
        name: "tool_one",
        content: .string("done")
      )
    ],
    assistantText: "Checking",
    usage: ProviderUsage(inputTokens: 3, outputTokens: 2)
  )
  _ = try await environment.conversations.appendToolRound(
    conversationID: environment.conversation.id,
    messageID: turn.assistantMessage.id,
    round: round
  )
  _ = try await environment.conversations.completeMessage(
    conversationID: environment.conversation.id,
    messageID: turn.assistantMessage.id,
    response: ProviderResponse(
      text: "Finished",
      providerID: "deepseek",
      accountID: "account",
      modelID: "deepseek-v4-flash",
      finishReason: "stop",
      usage: ProviderUsage(inputTokens: 5, outputTokens: 4)
    )
  )

  let sourceID = environment.conversation.id
  let exported = try await environment.conversations.exportWorkspace()
  let mapping = try await environment.conversations.importWorkspace(
    exported,
    strategy: .replaceExisting
  )
  let restoredID = try #require(mapping[sourceID])
  #expect(restoredID != sourceID)

  let restored = try await environment.conversations.conversation(id: restoredID)
  #expect(restored.messages.count == 2)
  #expect(restored.messages[0].attachments == [attachment])
  #expect(restored.messages[1].toolRounds == [round])
  #expect(restored.messages[1].content == "Finished")
  #expect(restored.messages[1].status == .complete)
}

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
