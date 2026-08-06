import Foundation

extension ConversationStore {
  public func exportWorkspace() throws -> Data {
    try JSONEncoder.providerEncoder.encode(snapshot())
  }

  public func deleteAllConversations() async throws {
    for conversation in allConversations() {
      try await deleteConversation(conversation.id)
    }
  }

  public func importWorkspace(
    _ data: Data,
    strategy: ProviderImportStrategy
  ) async throws {
    let imported = try JSONDecoder.provider.decode(ConversationWorkspaceState.self, from: data)
    guard imported.schemaVersion == ConversationWorkspaceState.currentSchemaVersion else {
      throw ProviderError.conversationVersionUnsupported(imported.schemaVersion)
    }

    let replacing: Bool
    switch strategy {
    case .replaceExisting: replacing = true
    case .keepExisting: replacing = false
    }

    let existingIDs = Set(allConversations().map(\.id))
    if replacing { try await deleteAllConversations() }

    for source in imported.conversations {
      if !replacing && existingIDs.contains(source.id) { continue }
      try await restorePortableConversation(source)
    }
  }

  private func restorePortableConversation(_ source: ChatConversation) async throws {
    let created = try await createConversation(
      providerID: source.providerID,
      accountID: source.accountID,
      modelID: source.modelID,
      systemPrompt: source.systemPrompt,
      options: source.options
    )
    try await renameConversation(created.id, title: source.title)
    if let draft = source.draftText { try await setDraft(draft, conversationID: created.id) }

    var index = 0
    while index < source.messages.count {
      let message = source.messages[index]
      guard message.role == .user else {
        index += 1
        continue
      }

      let turn = try await beginTurn(conversationID: created.id, userText: message.content)
      let assistant = index + 1 < source.messages.count ? source.messages[index + 1] : nil
      if let assistant, assistant.role == .assistant {
        switch assistant.status {
        case .complete:
          _ = try await completeMessage(
            conversationID: created.id,
            messageID: turn.assistantMessage.id,
            response: ProviderResponse(
              text: assistant.content,
              reasoning: assistant.reasoning,
              providerID: assistant.providerID ?? source.providerID,
              accountID: assistant.accountID ?? source.accountID,
              modelID: assistant.modelID ?? source.modelID,
              finishReason: assistant.finishReason,
              usage: assistant.usage,
              metadata: assistant.metadata
            )
          )
        case .cancelled:
          _ = try await cancelMessage(
            conversationID: created.id,
            messageID: turn.assistantMessage.id,
            content: assistant.content,
            reasoning: assistant.reasoning
          )
        case .failed, .interrupted, .pending, .streaming:
          _ = try await failMessage(
            conversationID: created.id,
            messageID: turn.assistantMessage.id,
            content: assistant.content,
            reasoning: assistant.reasoning,
            error: ProviderError.invalidRequest(
              assistant.errorDescription ?? "Imported generation did not complete.")
          )
        }
        index += 2
      } else {
        _ = try await cancelMessage(
          conversationID: created.id,
          messageID: turn.assistantMessage.id,
          content: "",
          reasoning: ""
        )
        index += 1
      }
    }

    try await setContextOmissionCount(
      source.lastContextOmittedMessageCount,
      conversationID: created.id
    )
  }
}
