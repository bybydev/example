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
