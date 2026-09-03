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

@Test func deepSeekPassesImageAttachmentThroughToProvider() throws {
  let adapter = OpenAICompatibleAdapter(definition: BuiltInProviders.deepSeek)
  let image = ChatAttachment(
    kind: .image,
    filename: "screen.jpg",
    mimeType: "image/jpeg",
    data: Data([0x01])
  )
  let request = ProviderRequest(
    model: "deepseek-v4-flash",
    messages: [.init(role: .user, content: "Understand this", attachments: [image])]
  )
  let account = ResolvedProviderAccount(
    kind: ProviderKind(providerID: BuiltInProviders.deepSeekID),
    id: "account",
    providerID: BuiltInProviders.deepSeekID,
    label: "DeepSeek",
    apiKey: "secret"
  )

  let validated = try adapter.validate(request: request, account: account)
  #expect(validated.messages.first?.attachments == [image])
}

@Test func deepSeekPassesBinaryDocumentThroughToProvider() throws {
  let adapter = OpenAICompatibleAdapter(definition: BuiltInProviders.deepSeek)
  let pdf = ChatAttachment(
    kind: .file,
    filename: "document.pdf",
    mimeType: "application/pdf",
    data: Data([0x25, 0x50, 0x44, 0x46])
  )
  let request = ProviderRequest(
    model: "deepseek-v4-pro",
    messages: [.init(role: .user, content: "Read this", attachments: [pdf])]
  )
  let account = ResolvedProviderAccount(
    kind: ProviderKind(providerID: BuiltInProviders.deepSeekID),
    id: "account",
    providerID: BuiltInProviders.deepSeekID,
    label: "DeepSeek",
    apiKey: "secret"
  )

  let validated = try adapter.validate(request: request, account: account)
  #expect(validated.messages.first?.attachments == [pdf])
}

@Test func deepSeekStillAllowsTextFileContext() throws {
  let adapter = OpenAICompatibleAdapter(definition: BuiltInProviders.deepSeek)
  let file = ChatAttachment(
    kind: .file,
    filename: "notes.txt",
    mimeType: "text/plain",
    data: Data("alpha\nbeta".utf8)
  )
  let request = ProviderRequest(
    model: "deepseek-v4-flash",
    messages: [.init(role: .user, content: "Summarize", attachments: [file])]
  )
  let account = ResolvedProviderAccount(
    kind: ProviderKind(providerID: BuiltInProviders.deepSeekID),
    id: "account",
    providerID: BuiltInProviders.deepSeekID,
    label: "DeepSeek",
    apiKey: "secret"
  )

  let validated = try adapter.validate(request: request, account: account)
  let parts = try userContentParts(adapter.requestBody(validated, streaming: false))
  #expect(parts.count == 2)
  guard case .object(let filePart) = parts[1] else {
    Issue.record("Missing inline DeepSeek text file")
    return
  }
  #expect(filePart["type"] == .string("text"))
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
  // Persisting the turn offloads bytes to the blob store; the context build
  // happens on metadata-only rows (the runtime refetches bytes before send).
  let context = try ChatContextBuilder.build(conversation: stored, contextWindow: nil)
  let user = try #require(context.messages.first { $0.role == .user })
  #expect(user.content.isEmpty)
  #expect(user.attachments?.first?.data.isEmpty == true)
  #expect(user.attachments?.first?.declaredByteCount == 1)
  #expect(user.attachments?.first?.byteCount == 1)
}

@Test func regenerationReusesFailedTurnAttachments() async throws {
  let persistence = InMemoryConversationWorkspacePersistence()
  let store = ConversationStore(persistence: persistence)
  try await store.load()
  let conversation = try await store.createConversation(
    providerID: "deepseek",
    accountID: "account",
    modelID: "deepseek-v4-flash"
  )
  let image = ChatAttachment(
    kind: .image,
    filename: "screen.jpg",
    mimeType: "image/jpeg",
    data: Data([0x01])
  )

  let first = try await store.beginTurn(
    conversationID: conversation.id,
    userText: "Understand this",
    attachments: [image]
  )
  _ = try await store.failMessage(
    conversationID: conversation.id,
    messageID: first.assistantMessage.id,
    content: "",
    reasoning: "",
    error: ProviderError.invalidRequest(
      "This model can’t read images. Switch to a vision-capable model, then retry."
    )
  )

  let retry = try await store.beginRegeneration(
    conversationID: conversation.id,
    confirmingUncertainCompletion: false
  )
  #expect(retry.turn.userMessage.id == first.userMessage.id)
  // Rows are metadata-only after the first persist; size survives.
  #expect(retry.turn.userMessage.attachments?.first?.id == image.id)
  #expect(retry.turn.userMessage.attachments?.first?.byteCount == 1)
  #expect(retry.turn.assistantMessage.status == .pending)
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
    kind: ProviderKind(providerID: "openrouter"),
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
