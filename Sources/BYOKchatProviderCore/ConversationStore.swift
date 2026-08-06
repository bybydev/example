import Foundation

public protocol ConversationWorkspacePersistence: Sendable {
  func loadData() async throws -> Data?
  func saveData(_ data: Data) async throws
}

public actor InMemoryConversationWorkspacePersistence: ConversationWorkspacePersistence {
  private var data: Data?

  public init(data: Data? = nil) { self.data = data }
  public func loadData() -> Data? { data }
  public func saveData(_ data: Data) { self.data = data }
}

public actor JSONFileConversationWorkspacePersistence: ConversationWorkspacePersistence {
  public let fileURL: URL

  public init(fileURL: URL) { self.fileURL = fileURL }

  public func loadData() throws -> Data? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    return try Data(contentsOf: fileURL)
  }

  public func saveData(_ data: Data) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: fileURL, options: .atomic)
  }
}

public actor ConversationStore {
  private let persistence: any ConversationWorkspacePersistence
  private var state = ConversationWorkspaceState()
  private var hasLoaded = false

  public init(persistence: any ConversationWorkspacePersistence) {
    self.persistence = persistence
  }

  public func load() async throws {
    guard !hasLoaded else { return }
    if let data = try await persistence.loadData() {
      let decoded = try JSONDecoder.provider.decode(ConversationWorkspaceState.self, from: data)
      guard decoded.schemaVersion == ConversationWorkspaceState.currentSchemaVersion else {
        throw ProviderError.conversationVersionUnsupported(decoded.schemaVersion)
      }
      state = decoded
    }
    hasLoaded = true
    if repairInterruptedMessages() {
      try await persist()
    }
  }

  public func snapshot() -> ConversationWorkspaceState { state }

  public func allConversations() -> [ChatConversation] {
    state.conversations.sorted { lhs, rhs in
      if lhs.updatedAt == rhs.updatedAt { return lhs.createdAt > rhs.createdAt }
      return lhs.updatedAt > rhs.updatedAt
    }
  }

  public func conversation(id: ConversationID) throws -> ChatConversation {
    guard let value = state.conversations.first(where: { $0.id == id }) else {
      throw ProviderError.conversationNotFound(id)
    }
    return value
  }

  @discardableResult
  public func createConversation(
    providerID: ProviderID,
    accountID: ProviderAccountID,
    modelID: ModelID,
    systemPrompt: String = "",
    options: ProviderRequestOptions = .init()
  ) async throws -> ChatConversation {
    let value = ChatConversation(
      providerID: providerID,
      accountID: accountID,
      modelID: modelID,
      systemPrompt: systemPrompt,
      options: options
    )
    state.conversations.append(value)
    try await persist()
    return value
  }

  public func deleteConversation(_ id: ConversationID) async throws {
    state.conversations.removeAll { $0.id == id }
    try await persist()
  }

  public func renameConversation(_ id: ConversationID, title: String) async throws {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw ProviderError.invalidRequest("Conversation title cannot be empty.")
    }
    try mutateConversation(id) { conversation in
      conversation.title = trimmed
      conversation.updatedAt = .now
    }
    try await persist()
  }

  public func updateTarget(
    _ id: ConversationID,
    providerID: ProviderID,
    accountID: ProviderAccountID,
    modelID: ModelID,
    systemPrompt: String,
    options: ProviderRequestOptions
  ) async throws {
    try mutateConversation(id) { conversation in
      conversation.providerID = providerID
      conversation.accountID = accountID
      conversation.modelID = modelID
      conversation.systemPrompt = systemPrompt
      conversation.options = options
      conversation.updatedAt = .now
    }
    try await persist()
  }

  @discardableResult
  public func beginTurn(
    conversationID: ConversationID,
    userText: String,
    at date: Date = .now
  ) async throws -> ChatTurnStart {
    let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw ProviderError.invalidMessages }

    var result: ChatTurnStart?
    try mutateConversation(conversationID) { conversation in
      let user = ChatMessage(
        role: .user,
        content: trimmed,
        createdAt: date,
        updatedAt: date,
        status: .complete,
        providerID: conversation.providerID,
        accountID: conversation.accountID,
        modelID: conversation.modelID
      )
      let assistant = ChatMessage(
        role: .assistant,
        createdAt: date,
        updatedAt: date,
        status: .pending,
        providerID: conversation.providerID,
        accountID: conversation.accountID,
        modelID: conversation.modelID
      )
      conversation.messages.append(user)
      conversation.messages.append(assistant)
      conversation.updatedAt = date
      if conversation.title == "New Chat" || conversation.messages.count == 2 {
        conversation.title = Self.generatedTitle(from: trimmed)
      }
      result = ChatTurnStart(
        conversationID: conversationID,
        userMessage: user,
        assistantMessage: assistant
      )
    }
    try await persist()
    return result!
  }

  public func updateStreamingMessage(
    conversationID: ConversationID,
    messageID: ChatMessageID,
    content: String,
    reasoning: String,
    usage: ProviderUsage? = nil,
    at date: Date = .now
  ) async throws {
    try mutateMessage(conversationID: conversationID, messageID: messageID) { message in
      message.content = content
      message.reasoning = reasoning
      if let usage { message.usage = usage }
      message.status = .streaming
      message.updatedAt = date
    }
    try mutateConversation(conversationID) { $0.updatedAt = date }
    try await persist()
  }

  public func completeMessage(
    conversationID: ConversationID,
    messageID: ChatMessageID,
    response: ProviderResponse,
    at date: Date = .now
  ) async throws -> ChatMessage {
    var result: ChatMessage?
    try mutateMessage(conversationID: conversationID, messageID: messageID) { message in
      message.content = response.text
      message.reasoning = response.reasoning
      message.providerID = response.providerID
      message.accountID = response.accountID
      message.modelID = response.modelID
      message.finishReason = response.finishReason
      message.usage = response.usage
      message.metadata = response.metadata
      message.status = .complete
      message.errorCode = nil
      message.errorDescription = nil
      message.updatedAt = date
      result = message
    }
    try mutateConversation(conversationID) { $0.updatedAt = date }
    try await persist()
    return result!
  }

  public func cancelMessage(
    conversationID: ConversationID,
    messageID: ChatMessageID,
    content: String,
    reasoning: String,
    at date: Date = .now
  ) async throws -> ChatMessage {
    var result: ChatMessage?
    try mutateMessage(conversationID: conversationID, messageID: messageID) { message in
      message.content = content
      message.reasoning = reasoning
      message.status = .cancelled
      message.updatedAt = date
      result = message
    }
    try mutateConversation(conversationID) { $0.updatedAt = date }
    try await persist()
    return result!
  }

  public func failMessage(
    conversationID: ConversationID,
    messageID: ChatMessageID,
    content: String,
    reasoning: String,
    error: Error,
    at date: Date = .now
  ) async throws -> ChatMessage {
    var result: ChatMessage?
    try mutateMessage(conversationID: conversationID, messageID: messageID) { message in
      message.content = content
      message.reasoning = reasoning
      message.status = .failed
      message.errorCode = Self.errorCode(error)
      message.errorDescription = Self.safeErrorDescription(error)
      message.updatedAt = date
      result = message
    }
    try mutateConversation(conversationID) { $0.updatedAt = date }
    try await persist()
    return result!
  }

  public func setContextOmissionCount(_ count: Int, conversationID: ConversationID) async throws {
    try mutateConversation(conversationID) { conversation in
      conversation.lastContextOmittedMessageCount = max(0, count)
    }
    try await persist()
  }

  private func mutateConversation(
    _ id: ConversationID,
    mutation: (inout ChatConversation) throws -> Void
  ) throws {
    guard let index = state.conversations.firstIndex(where: { $0.id == id }) else {
      throw ProviderError.conversationNotFound(id)
    }
    try mutation(&state.conversations[index])
  }

  private func mutateMessage(
    conversationID: ConversationID,
    messageID: ChatMessageID,
    mutation: (inout ChatMessage) throws -> Void
  ) throws {
    try mutateConversation(conversationID) { conversation in
      guard let index = conversation.messages.firstIndex(where: { $0.id == messageID }) else {
        throw ProviderError.chatMessageNotFound(messageID)
      }
      try mutation(&conversation.messages[index])
    }
  }

  private func repairInterruptedMessages() -> Bool {
    var changed = false
    for conversationIndex in state.conversations.indices {
      for messageIndex in state.conversations[conversationIndex].messages.indices {
        let status = state.conversations[conversationIndex].messages[messageIndex].status
        guard status == .pending || status == .streaming else { continue }
        state.conversations[conversationIndex].messages[messageIndex].status = .interrupted
        state.conversations[conversationIndex].messages[messageIndex].errorCode = "interrupted"
        state.conversations[conversationIndex].messages[messageIndex].errorDescription =
          "Generation was interrupted before completion."
        state.conversations[conversationIndex].messages[messageIndex].updatedAt = .now
        changed = true
      }
    }
    return changed
  }

  private func persist() async throws {
    try await persistence.saveData(JSONEncoder.providerEncoder.encode(state))
  }

  private static func generatedTitle(from text: String) -> String {
    let singleLine = text.replacingOccurrences(of: "\n", with: " ")
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
    guard singleLine.count > 52 else { return singleLine }
    return String(singleLine.prefix(49)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
  }

  private static func errorCode(_ error: Error) -> String {
    switch error {
    case is CancellationError: return "cancelled"
    case let value as ProviderError: return String(describing: value)
    default: return "unknown"
    }
  }

  private static func safeErrorDescription(_ error: Error) -> String {
    if let value = error as? LocalizedError, let description = value.errorDescription {
      return description
    }
    return "Generation failed."
  }
}
