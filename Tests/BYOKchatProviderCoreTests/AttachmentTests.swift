import Foundation
import Testing

@testable import BYOKchatProviderCore

@Test func openRouterEncodesImageAsDataURLContentPart() throws {
  let adapter = OpenAICompatibleAdapter(definition: BuiltInProviders.openRouter)
  let image = ChatAttachment(
    kind: .image,
    filename: "photo.jpg",
    mimeType: "image/jpeg",
    data: Data([0x01, 0x02, 0x03])
  )
  let request = ProviderRequest(
    model: "openrouter/free",
    messages: [
      .init(role: .user, content: "Describe this image", attachments: [image])
    ]
  )

  let body = adapter.requestBody(request, streaming: false)
  let parts = try userContentParts(body)
  #expect(parts.count == 2)

  guard case .object(let textPart) = parts[0] else {
    Issue.record("Missing text content part")
    return
  }
  #expect(textPart["type"] == .string("text"))
  #expect(textPart["text"] == .string("Describe this image"))

  guard case .object(let imagePart) = parts[1],
    case .object(let imageURL)? = imagePart["image_url"]
  else {
    Issue.record("Missing image_url content part")
    return
  }
  #expect(imagePart["type"] == .string("image_url"))
  #expect(imageURL["url"] == .string("data:image/jpeg;base64,AQID"))
}

@Test func textFileIsInlinedAsTextContent() throws {
  let adapter = OpenAICompatibleAdapter(definition: BuiltInProviders.openRouter)
  let file = ChatAttachment(
    kind: .file,
    filename: "notes.txt",
    mimeType: "text/plain",
    data: Data("alpha\nbeta".utf8)
  )
  let request = ProviderRequest(
    model: "openrouter/free",
    messages: [.init(role: .user, content: "Summarize", attachments: [file])]
  )

  let parts = try userContentParts(adapter.requestBody(request, streaming: false))
  guard case .object(let filePart) = parts.last else {
    Issue.record("Missing text file content part")
    return
  }
  #expect(filePart["type"] == .string("text"))
  guard case .string(let text)? = filePart["text"] else {
    Issue.record("Missing inline text")
    return
  }
  #expect(text.contains("File: notes.txt"))
  #expect(text.contains("alpha\nbeta"))
}

@Test func binaryFileIsEncodedAsFileDataPart() throws {
  let adapter = OpenAICompatibleAdapter(definition: BuiltInProviders.openRouter)
  let file = ChatAttachment(
    kind: .file,
    filename: "document.pdf",
    mimeType: "application/pdf",
    data: Data([0x25, 0x50, 0x44, 0x46])
  )
  let request = ProviderRequest(
    model: "openrouter/free",
    messages: [.init(role: .user, content: "Read this", attachments: [file])]
  )

  let parts = try userContentParts(adapter.requestBody(request, streaming: false))
  guard case .object(let filePart) = parts.last,
    case .object(let payload)? = filePart["file"]
  else {
    Issue.record("Missing file content part")
    return
  }
  #expect(filePart["type"] == .string("file"))
  #expect(payload["filename"] == .string("document.pdf"))
  #expect(payload["file_data"] == .string("data:application/pdf;base64,JVBERg=="))
}

@Test func attachmentOnlyTurnPersistsAndEntersContext() async throws {
  let persistence = InMemoryConversationWorkspacePersistence()
  let store = ConversationStore(persistence: persistence)
  try await store.load()
  let conversation = try await store.createConversation(
    providerID: "openrouter",
    accountID: "account",
    modelID: "vision-model"
  )
  let image = ChatAttachment(
    kind: .image,
    filename: "receipt.jpg",
    mimeType: "image/jpeg",
    data: Data([0x01])
  )

  let turn = try await store.beginTurn(
    conversationID: conversation.id,
    userText: "",
    attachments: [image]
  )
  #expect(turn.userMessage.content.isEmpty)
  #expect(turn.userMessage.attachments == [image])

  let stored = try await store.conversation(id: conversation.id)
  #expect(stored.title == "receipt.jpg")
  let context = try ChatContextBuilder.build(conversation: stored, contextWindow: nil)
  let user = try #require(context.messages.first { $0.role == .user })
  #expect(user.content.isEmpty)
  #expect(user.attachments == [image])
}

@Test func attachmentLimitsRejectOversizedMessages() async throws {
  let persistence = InMemoryConversationWorkspacePersistence()
  let store = ConversationStore(persistence: persistence)
  try await store.load()
  let conversation = try await store.createConversation(
    providerID: "openrouter",
    accountID: "account",
    modelID: "model"
  )
  let attachments = (0..<9).map { index in
    ChatAttachment(
      kind: .file,
      filename: "file-\(index).txt",
      mimeType: "text/plain",
      data: Data("x".utf8)
    )
  }

  await #expect(throws: ProviderError.self) {
    _ = try await store.beginTurn(
      conversationID: conversation.id,
      userText: "Analyze",
      attachments: attachments
    )
  }
}

@Test func providerValidationAppliesAttachmentLimitsPerMessage() throws {
  let adapter = OpenAICompatibleAdapter(definition: BuiltInProviders.openRouter)
  let attachment = ChatAttachment(
    kind: .image,
    filename: "pixel.jpg",
    mimeType: "image/jpeg",
    data: Data([0x01])
  )
  let eight = Array(repeating: attachment, count: 8)
  let request = ProviderRequest(
    model: "openrouter/free",
    messages: [
      .init(role: .user, content: "First", attachments: eight),
      .init(role: .assistant, content: "Seen"),
      .init(role: .user, content: "Second", attachments: eight),
    ]
  )
  let account = ResolvedProviderAccount(
    id: "account",
    providerID: "openrouter",
    label: "OpenRouter",
    apiKey: "secret"
  )

  let validated = try adapter.validate(request: request, account: account)
  #expect(validated.messages.count == 3)
  #expect(validated.messages[0].attachments?.count == 8)
  #expect(validated.messages[2].attachments?.count == 8)
}

private func userContentParts(_ body: [String: JSONValue]) throws -> [JSONValue] {
  guard case .array(let messages)? = body["messages"],
    let first = messages.first,
    case .object(let message) = first,
    case .array(let content)? = message["content"]
  else {
    throw ProviderError.invalidRequest("Expected multipart message content.")
  }
  return content
}
