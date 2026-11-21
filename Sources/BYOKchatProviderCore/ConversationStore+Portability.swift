import Foundation

extension ConversationStore {
  /// Imports conversations and returns a mapping from source conversation IDs to the
  /// effective local IDs. Merge imports can map a source conversation onto an existing
  /// local conversation when the ID or portable fingerprint already exists.
  @discardableResult
  public func importWorkspace(
    _ data: Data,
    strategy: ProviderImportStrategy
  ) async throws -> [ConversationID: ConversationID] {
    let imported = try JSONDecoder.provider.decode(ConversationWorkspaceState.self, from: data)
    guard imported.schemaVersion == ConversationWorkspaceState.currentSchemaVersion else {
      throw ProviderError.conversationVersionUnsupported(imported.schemaVersion)
    }
    try WorkspaceImportValidator.validateConversationWorkspace(imported)

    let replacing: Bool
    switch strategy {
    case .replaceExisting: replacing = true
    case .keepExisting: replacing = false
    }

    if replacing {
      try await deleteAllConversations()
    }

    let current = await allConversations()
    let existingByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
    var fingerprintToID: [String: ConversationID] = [:]
    if !replacing {
      for conversation in current {
        fingerprintToID[try Self.portableFingerprint(conversation)] = conversation.id
      }
    }

    var mapping: [ConversationID: ConversationID] = [:]
    var didImportAny = false
    for source in imported.conversations {
      if !replacing, let existing = existingByID[source.id] {
        mapping[source.id] = existing.id
        continue
      }

      let fingerprint = try Self.portableFingerprint(source)
      if !replacing, let existingID = fingerprintToID[fingerprint] {
        mapping[source.id] = existingID
        continue
      }

      let restoredID = try await restorePortableConversation(source)
      mapping[source.id] = restoredID
      fingerprintToID[fingerprint] = restoredID
      didImportAny = true
    }
    if didImportAny {
      try await flushImportedIndex()
    }
    return mapping
  }

  private func restorePortableConversation(_ source: ChatConversation) async throws -> ConversationID {
    let now = Date.now
    let trimmedTitle = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let title = trimmedTitle.isEmpty ? "New Chat" : trimmedTitle
    let draft = source.draftText?.isEmpty == true ? nil : source.draftText

    var restoredMessages: [ChatMessage] = []
    restoredMessages.reserveCapacity(source.messages.count)

    var index = 0
    while index < source.messages.count {
      let message = source.messages[index]
      guard message.role == .user else {
        index += 1
        continue
      }

      let trimmedUser = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
      let userAttachments = message.attachments ?? []
      guard !trimmedUser.isEmpty || !userAttachments.isEmpty else {
        throw ProviderError.invalidMessages
      }

      let userMessage = ChatMessage(
        role: .user,
        content: trimmedUser,
        attachments: userAttachments.isEmpty ? nil : userAttachments,
        createdAt: now,
        updatedAt: now,
        status: .complete,
        providerID: source.providerID,
        accountID: source.accountID,
        modelID: source.modelID
      )
      restoredMessages.append(userMessage)

      let assistant = index + 1 < source.messages.count ? source.messages[index + 1] : nil
      if let assistant, assistant.role == .assistant {
        let assistantMessage: ChatMessage
        switch assistant.status {
        case .complete:
          assistantMessage = ChatMessage(
            role: .assistant,
            content: assistant.content,
            reasoning: assistant.reasoning,
            toolRounds: assistant.toolRounds,
            createdAt: now,
            updatedAt: now,
            status: .complete,
            providerID: assistant.providerID ?? source.providerID,
            accountID: assistant.accountID ?? source.accountID,
            modelID: assistant.modelID ?? source.modelID,
            finishReason: assistant.finishReason,
            usage: assistant.usage,
            providerContinuation: assistant.providerContinuation,
            metadata: assistant.metadata,
            completionUncertain: false
          )
        case .cancelled:
          assistantMessage = ChatMessage(
            role: .assistant,
            content: assistant.content,
            reasoning: assistant.reasoning,
            toolRounds: assistant.toolRounds,
            createdAt: now,
            updatedAt: now,
            status: .cancelled,
            providerID: assistant.providerID ?? source.providerID,
            accountID: assistant.accountID ?? source.accountID,
            modelID: assistant.modelID ?? source.modelID,
            completionUncertain: false
          )
        case .failed, .interrupted, .pending, .streaming:
          let description = assistant.errorDescription ?? "Imported generation did not complete."
          let error = ProviderError.invalidRequest(description)
          assistantMessage = ChatMessage(
            role: .assistant,
            content: assistant.content,
            reasoning: assistant.reasoning,
            toolRounds: assistant.toolRounds,
            createdAt: now,
            updatedAt: now,
            status: .failed,
            providerID: assistant.providerID ?? source.providerID,
            accountID: assistant.accountID ?? source.accountID,
            modelID: assistant.modelID ?? source.modelID,
            errorCode: String(describing: error),
            errorDescription: error.errorDescription ?? description,
            completionUncertain: false
          )
        }
        restoredMessages.append(assistantMessage)
        index += 2
      } else {
        restoredMessages.append(
          ChatMessage(
            role: .assistant,
            content: "",
            reasoning: "",
            createdAt: now,
            updatedAt: now,
            status: .cancelled,
            providerID: source.providerID,
            accountID: source.accountID,
            modelID: source.modelID,
            completionUncertain: false
          )
        )
        index += 1
      }
    }

    let restored = ChatConversation(
      id: ConversationID(),
      title: title,
      createdAt: now,
      updatedAt: now,
      providerID: source.providerID,
      accountID: source.accountID,
      modelID: source.modelID,
      systemPrompt: source.systemPrompt,
      options: source.options,
      messages: restoredMessages,
      lastContextOmittedMessageCount: max(0, source.lastContextOmittedMessageCount),
      draftText: draft
    )
    try await commitImportedConversation(restored)
    return restored.id
  }

  private static func portableFingerprint(_ conversation: ChatConversation) throws -> String {
    let value = PortableConversationFingerprint(
      title: conversation.title,
      providerID: conversation.providerID,
      accountID: conversation.accountID,
      modelID: conversation.modelID,
      systemPrompt: conversation.systemPrompt,
      options: conversation.options,
      messages: conversation.messages.map(PortableMessageFingerprint.init),
      lastContextOmittedMessageCount: conversation.lastContextOmittedMessageCount,
      draftText: conversation.draftText
    )
    return try JSONEncoder.providerEncoder.encode(value).base64EncodedString()
  }
}

private struct PortableConversationFingerprint: Encodable {
  var title: String
  var providerID: ProviderID
  var accountID: ProviderAccountID
  var modelID: ModelID
  var systemPrompt: String
  var options: ProviderRequestOptions
  var messages: [PortableMessageFingerprint]
  var lastContextOmittedMessageCount: Int
  var draftText: String?
}

private struct PortableMessageFingerprint: Encodable {
  var role: ChatMessageRole
  var content: String
  var reasoning: String
  var attachments: [ChatAttachment]?
  var toolRounds: [ChatToolRound]?
  var status: ChatMessageStatus
  var providerID: ProviderID?
  var accountID: ProviderAccountID?
  var modelID: ModelID?
  var finishReason: String?
  var usage: ProviderUsage?
  var providerContinuation: ProviderToolContinuation?
  var metadata: [String: String]
  var errorCode: String?
  var errorDescription: String?
  var completionUncertain: Bool?

  init(_ message: ChatMessage) {
    role = message.role
    content = message.content
    reasoning = message.reasoning
    attachments = message.attachments
    toolRounds = message.toolRounds
    status = switch message.status {
    case .complete: .complete
    case .cancelled: .cancelled
    case .failed, .interrupted, .pending, .streaming: .failed
    }
    providerID = message.providerID
    accountID = message.accountID
    modelID = message.modelID
    finishReason = message.finishReason
    usage = message.usage
    providerContinuation = message.providerContinuation
    metadata = message.metadata
    errorCode = message.errorCode
    errorDescription = message.errorDescription
    completionUncertain = message.completionUncertain
  }
}
