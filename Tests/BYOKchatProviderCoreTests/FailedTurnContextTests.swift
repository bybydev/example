import Foundation
import Testing

@testable import BYOKchatProviderCore

@Test func failedAttachmentTurnDoesNotPoisonLaterTextRequest() throws {
  let image = ChatAttachment(
    kind: .image,
    filename: "screen.jpg",
    mimeType: "image/jpeg",
    data: Data([0x01])
  )
  let conversation = ChatConversation(
    providerID: "deepseek",
    accountID: "account",
    modelID: "deepseek-v4-flash",
    messages: [
      ChatMessage(
        role: .user,
        content: "Can you read this?",
        attachments: [image],
        status: .complete
      ),
      ChatMessage(
        role: .assistant,
        status: .failed,
        errorDescription: "This model can’t read images."
      ),
      ChatMessage(role: .user, content: "Just text here", status: .complete),
      ChatMessage(role: .assistant, status: .pending),
    ]
  )

  let context = try ChatContextBuilder.build(conversation: conversation, contextWindow: nil)

  #expect(context.messages.map(\.role) == [.user])
  #expect(context.messages.first?.content == "Just text here")
  #expect(context.messages.first?.attachments?.isEmpty != false)
}

@Test func completedAttachmentTurnRemainsAvailableForFollowUp() throws {
  let image = ChatAttachment(
    kind: .image,
    filename: "receipt.jpg",
    mimeType: "image/jpeg",
    data: Data([0x01])
  )
  let conversation = ChatConversation(
    providerID: "openrouter",
    accountID: "account",
    modelID: "vision-model",
    messages: [
      ChatMessage(
        role: .user,
        content: "What is in this image?",
        attachments: [image],
        status: .complete
      ),
      ChatMessage(role: .assistant, content: "A receipt.", status: .complete),
      ChatMessage(role: .user, content: "What is the total?", status: .complete),
      ChatMessage(role: .assistant, status: .pending),
    ]
  )

  let context = try ChatContextBuilder.build(conversation: conversation, contextWindow: nil)

  #expect(context.messages.map(\.role) == [.user, .assistant, .user])
  #expect(context.messages[0].attachments == [image])
  #expect(context.messages[1].content == "A receipt.")
  #expect(context.messages[2].content == "What is the total?")
}

@Test func cancelledAndInterruptedTurnsAreNotHistoricalContext() throws {
  let conversation = ChatConversation(
    providerID: "openrouter",
    accountID: "account",
    modelID: "model",
    messages: [
      ChatMessage(role: .user, content: "cancelled prompt", status: .complete),
      ChatMessage(role: .assistant, content: "partial", status: .cancelled),
      ChatMessage(role: .user, content: "interrupted prompt", status: .complete),
      ChatMessage(role: .assistant, content: "partial", status: .interrupted),
      ChatMessage(role: .user, content: "current prompt", status: .complete),
      ChatMessage(role: .assistant, status: .pending),
    ]
  )

  let context = try ChatContextBuilder.build(conversation: conversation, contextWindow: nil)

  #expect(context.messages.map(\.content) == ["current prompt"])
}

@Test func failedMessagesExposeStableFailureOrigin() {
  let local = ChatMessage(
    role: .assistant,
    status: .failed,
    errorCode: "invalidRequest(\"This model can’t read images.\")"
  )
  let remoteHTTP = ChatMessage(
    role: .assistant,
    status: .failed,
    errorCode: "provider(status: 500, message: \"Server error\")"
  )
  let remoteTransport = ChatMessage(
    role: .assistant,
    status: .failed,
    errorCode: "transport(message: \"The Internet connection appears to be offline.\", completionUnknown: false)"
  )
  let completed = ChatMessage(role: .assistant, status: .complete)

  #expect(local.failureOrigin == .local)
  #expect(remoteHTTP.failureOrigin == .remote)
  #expect(remoteTransport.failureOrigin == .remote)
  #expect(completed.failureOrigin == nil)
}
