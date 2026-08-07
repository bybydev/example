import Foundation
import Testing

@testable import BYOKchatProviderCore

@Test func importedConversationRejectsTooManyAttachments() {
  let attachments = (0..<9).map { index in
    ChatAttachment(
      kind: .file,
      filename: "file-\(index).txt",
      mimeType: "text/plain",
      data: Data("x".utf8)
    )
  }
  let message = ChatMessage(
    role: .user,
    content: "Imported",
    attachments: attachments,
    status: .complete
  )
  let conversation = ChatConversation(
    providerID: "openrouter",
    accountID: "account",
    modelID: "model",
    messages: [message]
  )
  let workspace = ConversationWorkspaceState(conversations: [conversation])

  #expect(throws: ProviderError.self) {
    try WorkspaceImportValidator.validateConversationWorkspace(workspace)
  }
}

@Test func importedConversationRejectsDuplicateAttachmentIDs() {
  let first = ChatAttachment(
    id: "duplicate",
    kind: .file,
    filename: "a.txt",
    mimeType: "text/plain",
    data: Data("a".utf8)
  )
  let second = ChatAttachment(
    id: "duplicate",
    kind: .file,
    filename: "b.txt",
    mimeType: "text/plain",
    data: Data("b".utf8)
  )
  let message = ChatMessage(
    role: .user,
    content: "Imported",
    attachments: [first, second],
    status: .complete
  )
  let conversation = ChatConversation(
    providerID: "openrouter",
    accountID: "account",
    modelID: "model",
    messages: [message]
  )
  let workspace = ConversationWorkspaceState(conversations: [conversation])

  #expect(throws: ProviderError.self) {
    try WorkspaceImportValidator.validateConversationWorkspace(workspace)
  }
}

@Test func importedConversationRejectsMismatchedToolResults() {
  let round = ChatToolRound(
    calls: [
      ChatToolCall(
        id: "call-1",
        name: "lookup",
        arguments: .object(["query": .string("value")])
      )
    ],
    results: [
      ChatToolResult(
        callID: "different-call",
        name: "lookup",
        content: .string("result")
      )
    ]
  )
  let message = ChatMessage(
    role: .assistant,
    toolRounds: [round],
    status: .complete
  )
  let conversation = ChatConversation(
    providerID: "openrouter",
    accountID: "account",
    modelID: "model",
    messages: [message]
  )

  #expect(throws: ProviderError.self) {
    try WorkspaceImportValidator.validateConversationWorkspace(
      ConversationWorkspaceState(conversations: [conversation])
    )
  }
}

@Test func importedConversationAcceptsValidToolRound() throws {
  let call = ChatToolCall(
    id: "call-1",
    name: "lookup",
    arguments: .object(["query": .string("value")])
  )
  let round = ChatToolRound(
    calls: [call],
    results: [
      ChatToolResult(
        callID: call.id,
        name: call.name,
        content: .object(["value": .string("result")])
      )
    ],
    providerContinuation: ProviderToolContinuation(
      apiFamily: .geminiGenerateContent,
      payload: .object([call.id: .string("opaque-signature")])
    )
  )
  let message = ChatMessage(
    role: .assistant,
    content: "Done",
    toolRounds: [round],
    status: .complete
  )
  let conversation = ChatConversation(
    providerID: "gemini",
    accountID: "account",
    modelID: "model",
    messages: [message]
  )

  try WorkspaceImportValidator.validateConversationWorkspace(
    ConversationWorkspaceState(conversations: [conversation])
  )
}
