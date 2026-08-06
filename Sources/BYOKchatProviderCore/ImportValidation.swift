import Foundation

public enum WorkspaceImportValidator {
  private struct AccountModelKey: Hashable {
    var accountID: ProviderAccountID
    var modelID: ModelID
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
    let builtInIDs = Set(builtInDefinitions.map(\.id))
    var definitions = Dictionary(uniqueKeysWithValues: builtInDefinitions.map { ($0.id, $0) })

    for definition in workspace.customProviders {
      guard !definition.isBuiltIn else {
        throw ProviderError.importConflict(
          "Imported custom provider \(definition.id.rawValue) is incorrectly marked as built in."
        )
      }
      guard !builtInIDs.contains(definition.id) else {
        throw ProviderError.importConflict(
          "Custom provider ID \(definition.id.rawValue) conflicts with a built-in provider."
        )
      }
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
      for model in definition.seedModels where model.providerID != definition.id {
        throw ProviderError.importConflict(
          "Seed model \(model.id.rawValue) does not belong to provider \(definition.id.rawValue)."
        )
      }
      definitions[definition.id] = definition
    }

    let accountsByID = Dictionary(uniqueKeysWithValues: workspace.accounts.map { ($0.id, $0) })
    for account in workspace.accounts {
      guard let definition = definitions[account.providerID] else {
        throw ProviderError.importConflict(
          "Account \(account.label) references unknown provider \(account.providerID.rawValue)."
        )
      }
      guard !account.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ProviderError.importConflict(
          "Provider account \(account.id.rawValue) has an empty label."
        )
      }
      if let baseURL = account.baseURLOverride {
        do {
          try ProviderHTTP.validateBaseURL(
            baseURL,
            allowsLocalHTTP: definition.allowsLocalHTTP
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
    }

    for record in workspace.modelRecords {
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
      let providerID = ProviderID(rawValue: providerValue)
      let accountID = ProviderAccountID(rawValue: accountValue)
      guard definitions[providerID] != nil else {
        throw ProviderError.importConflict(
          "A provider-specific default references unknown provider \(providerValue)."
        )
      }
      guard let account = accountsByID[accountID] else {
        throw ProviderError.importConflict(
          "A provider-specific default references unknown account \(accountValue)."
        )
      }
      guard account.providerID == providerID else {
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
