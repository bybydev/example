import Foundation

public enum WorkspaceImportValidator {
  private struct AccountModelKey: Hashable {
    var accountID: ProviderAccountID
    var modelID: ModelID
  }

  private static func validateCapabilityEvidence(_ model: ProviderModel) throws {
    func invalid(_ message: String) -> ProviderError {
      .importConflict("Model \(model.id.rawValue): \(message)")
    }
    if let value = model.contextWindow, value <= 0 { throw invalid("context window must be positive.") }
    if let value = model.maxOutputTokens, value <= 0 { throw invalid("maximum output tokens must be positive.") }
    guard let control = model.capabilityEvidence?.reasoningControl else { return }
    guard Set(control.efforts).count == control.efforts.count else { throw invalid("duplicate reasoning efforts.") }
    if control.kind == .efforts, control.efforts.isEmpty { throw invalid("effort controls must contain valid choices.") }
    if let value = control.defaultEffort, control.kind == .efforts, !control.efforts.contains(value) {
      throw invalid("default effort is not in the supported choices.")
    }
    if control.allowsOff, control.offWireValue == nil { throw invalid("Off requires an explicit wire representation.") }
    if control.kind == .budget, control.budget == nil { throw invalid("budget control is missing its bounds.") }
    if control.combinesEffortAndBudget == true, control.budget == nil || control.efforts.isEmpty {
      throw invalid("combined controls require both an effort list and a budget.")
    }
    if let support = model.capabilityEvidence?.facts[.reasoning]?.support,
      (support == .unsupported && control.kind != .unsupported && control.kind != .unknown)
        || (support == .supported && control.kind == .unsupported) {
      throw invalid("reasoning support contradicts the control metadata.")
    }
    if let budget = control.budget {
      guard budget.minimum > 0, budget.maximum.map({ $0 >= budget.minimum }) ?? true,
        (budget.defaultTokens == -1 && budget.allowsAutomatic)
          || (budget.defaultTokens >= budget.minimum && budget.defaultTokens <= (budget.maximum ?? Int.max))
      else { throw invalid("invalid thinking budget bounds or default.") }
    }
  }

  public static func validateProviderWorkspace(_ workspace: ProviderWorkspaceState) throws {
    try requireUnique(
      workspace.customProviders,
      id: \ProviderDefinition.id,
      description: { "Duplicate custom provider ID: \($0.rawValue)" }
    )
    try requireUnique(
      workspace.accounts,
      id: \ProviderAccount.id,
      description: { "Duplicate provider account ID: \($0.rawValue)" }
    )
    try requireUnique(
      workspace.modelRecords,
      id: { AccountModelKey(accountID: $0.accountID, modelID: $0.model.id) },
      description: {
        "Duplicate model record for account \($0.accountID.rawValue) and model \($0.modelID.rawValue)."
      }
    )

    let builtInDefinitions = BuiltInProviders.all
    let builtInByID = Dictionary(uniqueKeysWithValues: builtInDefinitions.map { ($0.id, $0) })

    for definition in workspace.customProviders {
      guard !definition.isBuiltIn else {
        throw ProviderError.importConflict(
          "Imported custom provider \(definition.id.rawValue) is incorrectly marked as built in."
        )
      }
      // A workspace created before a provider became first-class can still
      // contain a custom definition with the same stable ID (for example
      // `xai`). Account.kind is authoritative in schema v2, so retaining that
      // legacy definition is safe as long as it never replaces the built-in
      // registry entry. New collisions remain blocked by upsertCustomProvider.
      do {
        try ProviderRegistry.validate(definition)
      } catch {
        throw ProviderError.importConflict(
          "Custom provider \(definition.id.rawValue) is invalid: \(error.localizedDescription)"
        )
      }
      try requireUnique(
        definition.seedModels,
        id: \ProviderModel.id,
        description: {
          "Custom provider \(definition.id.rawValue) contains duplicate seed model \($0.rawValue)."
        }
      )
      for model in definition.seedModels { try validateCapabilityEvidence(model) }
      for model in definition.seedModels where model.providerID != definition.id {
        throw ProviderError.importConflict(
          "Seed model \(model.id.rawValue) does not belong to provider \(definition.id.rawValue)."
        )
      }
    }

    let accountsByID = Dictionary(uniqueKeysWithValues: workspace.accounts.map { ($0.id, $0) })
    for account in workspace.accounts {
      guard !account.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ProviderError.importConflict(
          "Provider account \(account.id.rawValue) has an empty label."
        )
      }

      let definition: ProviderDefinition
      if account.kind == .openAICompatible {
        guard account.baseURLOverride != nil else {
          throw ProviderError.importConflict(
            "Custom provider account \(account.label) is missing its endpoint."
          )
        }
        definition = account.definition
      } else {
        guard let expectedProviderID = account.kind.defaultProviderID,
          expectedProviderID == account.providerID,
          let builtIn = builtInByID[expectedProviderID]
        else {
          throw ProviderError.importConflict(
            "Account \(account.label) does not match its built-in provider kind."
          )
        }
        definition = builtIn
      }

      if let baseURL = account.baseURLOverride {
        do {
          try ProviderHTTP.validateBaseURL(
            baseURL,
            allowsLocalHTTP: definition.allowsLocalHTTP
              || account.kind == .openAICompatible && isPrivateNetworkURL(baseURL)
          )
        } catch {
          throw ProviderError.importConflict(
            "Account \(account.label) contains an invalid endpoint override."
          )
        }
      }
      if let unsafe = account.additionalHeaders.keys.first(where: ProviderHTTP.isForbiddenCustomHeader) {
        throw ProviderError.importConflict(
          "Account \(account.label) contains forbidden header \(unsafe)."
        )
      }

      if account.kind == .openAICompatible,
        let auth = account.authChoice,
        case .header(let name) = auth,
        ProviderHTTP.isForbiddenCustomHeader(name)
      {
        throw ProviderError.importConflict(
          "Account \(account.label) uses a forbidden authentication header \(name)."
        )
      }
    }

    for record in workspace.modelRecords {
      try validateCapabilityEvidence(record.model)
      guard let account = accountsByID[record.accountID] else {
        throw ProviderError.importConflict(
          "Model \(record.model.id.rawValue) references unknown account \(record.accountID.rawValue)."
        )
      }
      guard record.model.providerID == account.providerID else {
        throw ProviderError.importConflict(
          "Model \(record.model.id.rawValue) does not match account \(account.label)'s provider."
        )
      }
    }

    if let defaultAccountID = workspace.defaultAccountID,
      accountsByID[defaultAccountID] == nil
    {
      throw ProviderError.importConflict(
        "The default provider account \(defaultAccountID.rawValue) does not exist."
      )
    }

    for (providerValue, accountValue) in workspace.providerDefaultAccountIDs {
      let accountID = ProviderAccountID(rawValue: accountValue)
      guard let account = accountsByID[accountID] else {
        throw ProviderError.importConflict(
          "A provider-specific default references unknown account \(accountValue)."
        )
      }
      guard account.providerID.rawValue == providerValue else {
        throw ProviderError.importConflict(
          "Default account \(accountValue) belongs to a different provider than \(providerValue)."
        )
      }
    }
  }

  public static func validateConversationWorkspace(_ workspace: ConversationWorkspaceState) throws {
    try requireUnique(
      workspace.conversations,
      id: \ChatConversation.id,
      description: { "Duplicate conversation ID: \($0.rawValue)" }
    )

    var messageIDs: Set<ChatMessageID> = []
    for conversation in workspace.conversations {
      for message in conversation.messages {
        guard messageIDs.insert(message.id).inserted else {
          throw ProviderError.importConflict(
            "Duplicate chat message ID: \(message.id.rawValue)"
          )
        }
        try validateAttachments(message.attachments ?? [], messageID: message.id)
        try validateProviderContinuation(message.providerContinuation, messageID: message.id)
        let toolRounds = message.toolRounds ?? []
        if message.role == .user, !toolRounds.isEmpty {
          throw ProviderError.importConflict(
            "User message \(message.id.rawValue) cannot contain assistant tool-call rounds."
          )
        }
        try validateToolRounds(toolRounds, messageID: message.id)
      }
    }
  }

  public static func validateConversationTargets(
    _ conversations: [ChatConversation],
    accounts: [ProviderAccount]
  ) throws {
    try requireUnique(
      accounts,
      id: \ProviderAccount.id,
      description: { "Duplicate provider account ID: \($0.rawValue)" }
    )
    let accountsByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
    for conversation in conversations {
      guard let account = accountsByID[conversation.accountID] else {
        throw ProviderError.importConflict(
          "Conversation \(conversation.title) references unknown provider account \(conversation.accountID.rawValue)."
        )
      }
      guard account.providerID == conversation.providerID else {
        throw ProviderError.importConflict(
          "Conversation \(conversation.title) does not match its provider account."
        )
      }
    }
  }

  private static func validateAttachments(
    _ attachments: [ChatAttachment],
    messageID: ChatMessageID
  ) throws {
    guard attachments.count <= 8 else {
      throw ProviderError.importConflict(
        "Message \(messageID.rawValue) contains more than 8 attachments."
      )
    }
    guard attachments.allSatisfy({ !$0.data.isEmpty && $0.byteCount <= 20 * 1_024 * 1_024 }) else {
      throw ProviderError.importConflict(
        "Message \(messageID.rawValue) contains an empty attachment or one larger than 20 MB."
      )
    }
    guard attachments.reduce(0, { $0 + $1.byteCount }) <= 40 * 1_024 * 1_024 else {
      throw ProviderError.importConflict(
        "Message \(messageID.rawValue) contains more than 40 MB of attachments."
      )
    }
    try requireUnique(
      attachments,
      id: \ChatAttachment.id,
      description: { "Message \(messageID.rawValue) contains duplicate attachment ID: \($0)" }
    )
    for attachment in attachments {
      guard !attachment.filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ProviderError.importConflict(
          "Message \(messageID.rawValue) contains an attachment with an empty filename."
        )
      }
      guard !attachment.mimeType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ProviderError.importConflict(
          "Message \(messageID.rawValue) contains an attachment with an empty MIME type."
        )
      }
    }
  }

  private static func validateToolRounds(
    _ rounds: [ChatToolRound],
    messageID: ChatMessageID
  ) throws {
    guard rounds.count <= 8 else {
      throw ProviderError.importConflict(
        "Message \(messageID.rawValue) contains more than 8 tool-call rounds."
      )
    }
    try requireUnique(
      rounds,
      id: \ChatToolRound.id,
      description: { "Message \(messageID.rawValue) contains duplicate tool round ID: \($0)" }
    )

    for round in rounds {
      guard !round.calls.isEmpty, round.calls.count <= 32 else {
        throw ProviderError.importConflict(
          "Message \(messageID.rawValue) contains an invalid tool-call round."
        )
      }
      try requireUnique(
        round.calls,
        id: \ChatToolCall.id,
        description: { "Message \(messageID.rawValue) contains duplicate tool call ID: \($0)" }
      )
      try requireUnique(
        round.results,
        id: \ChatToolResult.callID,
        description: { "Message \(messageID.rawValue) contains duplicate tool result ID: \($0)" }
      )

      let callsByID = Dictionary(uniqueKeysWithValues: round.calls.map { ($0.id, $0) })
      guard Set(callsByID.keys) == Set(round.results.map(\.callID)) else {
        throw ProviderError.importConflict(
          "Message \(messageID.rawValue) contains tool results that do not match its tool calls."
        )
      }

      for call in round.calls {
        guard !call.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !call.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
          throw ProviderError.importConflict(
            "Message \(messageID.rawValue) contains a tool call with an empty ID or name."
          )
        }
      }
      for result in round.results {
        guard !result.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          callsByID[result.callID]?.name == result.name
        else {
          throw ProviderError.importConflict(
            "Message \(messageID.rawValue) contains a tool result with invalid call metadata."
          )
        }
      }

      try validateProviderContinuation(round.providerContinuation, messageID: messageID)
    }
  }

  private static func validateProviderContinuation(
    _ continuation: ProviderToolContinuation?,
    messageID: ChatMessageID
  ) throws {
    guard let continuation else { return }
    let byteCount = continuation.payload.compactJSONString().utf8.count
    guard byteCount <= 1_024 * 1_024 else {
      throw ProviderError.importConflict(
        "Message \(messageID.rawValue) contains oversized provider continuation metadata."
      )
    }
  }

  private static func isPrivateNetworkURL(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "http", let host = url.host else { return false }
    return ProviderHTTP.isPrivateNetworkHost(host)
  }

  private static func requireUnique<Value, ID: Hashable>(
    _ values: [Value],
    id: (Value) -> ID,
    description: (ID) -> String
  ) throws {
    var seen: Set<ID> = []
    for value in values {
      let identifier = id(value)
      guard seen.insert(identifier).inserted else {
        throw ProviderError.importConflict(description(identifier))
      }
    }
  }
}
