import BYOKchatProviderCore
import Foundation
import Observation

@MainActor
@Observable
final class ProviderManagementModel {
  private(set) var definitions: [ProviderDefinition] = []
  private(set) var accounts: [ProviderAccount] = []
  private(set) var modelsByAccount: [ProviderAccountID: [AccountModelRecord]] = [:]
  private(set) var credentialAccountIDs: Set<ProviderAccountID> = []
  var isBusy = false
  var errorMessage: String?
  var statusMessage: String?

  private let registry: ProviderRegistry
  private let workspace: ProviderWorkspaceStore
  private let vault: KeychainCredentialVault
  private let accountManager: ProviderAccountManager
  private let runtime: ProviderRuntime

  init(
    registry: ProviderRegistry,
    workspace: ProviderWorkspaceStore,
    vault: KeychainCredentialVault,
    accountManager: ProviderAccountManager,
    runtime: ProviderRuntime
  ) {
    self.registry = registry
    self.workspace = workspace
    self.vault = vault
    self.accountManager = accountManager
    self.runtime = runtime
  }

  func load() async {
    await perform("Provider workspace loaded") {
      try await workspace.load()
      try await accountManager.synchronizeCustomProviders()
      try await ensureDefaultModelsExist()
      try await reloadSnapshot()
    }
  }

  func reloadFromStorage() async {
    await perform("Provider workspace reloaded") {
      try await accountManager.synchronizeCustomProviders()
      try await ensureDefaultModelsExist()
      try await reloadSnapshot()
    }
  }

  func accounts(for providerID: ProviderID) -> [ProviderAccount] {
    accounts.filter { $0.providerID == providerID }
  }

  func provider(for id: ProviderID) -> ProviderDefinition? {
    definitions.first { $0.id == id }
  }

  func models(for accountID: ProviderAccountID, includeHidden: Bool = false) -> [AccountModelRecord]
  {
    let values = modelsByAccount[accountID] ?? []
    return includeHidden ? values : values.filter { !$0.isHidden }
  }

  func createAccount(
    providerID: ProviderID,
    label: String,
    credential: String,
    baseURL: String,
    defaultModel: String,
    headers: [String: String],
    metadata: [String: String]
  ) async -> Bool {
    await performResult("Account saved") {
      let override = try optionalURL(baseURL)
      let account = try await accountManager.createAccount(
        providerID: providerID,
        label: label,
        credential: credential.isEmpty ? nil : credential,
        baseURLOverride: override,
        additionalHeaders: headers,
        metadata: metadata,
        defaultModelID: defaultModel.isEmpty ? nil : ModelID(rawValue: defaultModel)
      )
      if let definition = provider(for: providerID), !definition.seedModels.isEmpty {
        try await workspace.mergeModels(definition.seedModels, for: account.id)
      }
      if let defaultModelID = account.defaultModelID,
        !(await workspace.modelRecords(for: account.id, includeHidden: true)).contains(where: {
          $0.model.id == defaultModelID
        })
      {
        try await workspace.addManualModel(
          ProviderModel(
            providerID: account.providerID,
            id: defaultModelID,
            displayName: defaultModelID.rawValue
          ),
          for: account.id
        )
      }
      try await reloadSnapshot()
    }
  }

  func updateAccount(
    _ account: ProviderAccount,
    newCredential: String?,
    baseURL: String,
    headers: [String: String],
    metadata: [String: String]
  ) async -> Bool {
    await performResult("Account updated") {
      var updated = account
      updated.baseURLOverride = try optionalURL(baseURL)
      updated.additionalHeaders = headers
      updated.metadata = metadata
      try await accountManager.updateAccount(updated)
      if let newCredential, !newCredential.isEmpty {
        try await accountManager.setCredential(newCredential, accountID: account.id)
      }
      try await reloadSnapshot()
    }
  }

  func deleteAccount(_ id: ProviderAccountID) async {
    await perform("Account deleted") {
      try await accountManager.deleteAccount(id)
      try await reloadSnapshot()
    }
  }

  func setDefaultModel(_ modelID: ModelID, accountID: ProviderAccountID) async {
    await perform("Default model updated") {
      var account = try await workspace.account(id: accountID)
      account.defaultModelID = modelID
      try await accountManager.updateAccount(account)
      try await reloadSnapshot()
    }
  }

  func testConnection(accountID: ProviderAccountID, modelID: ModelID?) async {
    await perform("Connection successful") {
      try await runtime.testConnection(accountID: accountID, modelID: modelID)
    }
  }

  func refreshModels(accountID: ProviderAccountID) async {
    await perform("Models refreshed") {
      _ = try await runtime.refreshModels(accountID: accountID)
      try await reloadSnapshot()
    }
  }

  func addManualModel(_ modelID: String, accountID: ProviderAccountID) async -> Bool {
    await performResult("Model added") {
      let account = try await workspace.account(id: accountID)
      let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { throw ProviderError.invalidModel }
      try await workspace.addManualModel(
        ProviderModel(
          providerID: account.providerID, id: ModelID(rawValue: trimmed), displayName: trimmed),
        for: accountID
      )
      try await reloadSnapshot()
    }
  }

  func setFavorite(_ favorite: Bool, modelID: ModelID, accountID: ProviderAccountID) async {
    await perform(nil) {
      try await workspace.setFavorite(favorite, modelID: modelID, accountID: accountID)
      try await reloadSnapshot()
    }
  }

  func setHidden(_ hidden: Bool, modelID: ModelID, accountID: ProviderAccountID) async {
    await perform(nil) {
      try await workspace.setHidden(hidden, modelID: modelID, accountID: accountID)
      try await reloadSnapshot()
    }
  }

  func createCustomProvider(
    id: String,
    name: String,
    baseURL: String,
    chatPath: String,
    modelsPath: String,
    authentication: ProviderAuthentication,
    seedModels: [String],
    allowsLocalHTTP: Bool
  ) async -> Bool {
    await performResult("Custom provider added") {
      guard let url = URL(string: baseURL) else { throw ProviderError.invalidBaseURL }
      let definition = try CustomProviderFactory.makeOpenAICompatible(
        id: id,
        displayName: name,
        baseURL: url,
        chatCompletionsPath: chatPath,
        modelsPath: modelsPath.isEmpty ? nil : modelsPath,
        authentication: authentication,
        seedModelIDs: seedModels,
        allowsLocalHTTP: allowsLocalHTTP
      )
      try await runtime.registerCustomProvider(definition)
      try await reloadSnapshot()
    }
  }

  func deleteCustomProvider(_ id: ProviderID) async {
    await perform("Custom provider deleted") {
      try await runtime.deleteCustomProvider(id)
      try await reloadSnapshot()
    }
  }

  func stream(
    accountID: ProviderAccountID,
    modelID: ModelID,
    prompt: String,
    reasoning: Bool
  ) async throws -> AsyncThrowingStream<ProviderStreamEvent, Error> {
    try await runtime.stream(
      request: ProviderRequest(
        model: modelID,
        messages: [.init(role: .user, content: prompt)],
        options: ProviderRequestOptions(
          reasoning: ReasoningOptions(enabled: reasoning, effort: .high))
      ),
      accountID: accountID
    )
  }

  private func ensureDefaultModelsExist() async throws {
    for account in await workspace.allAccounts() {
      guard let defaultModelID = account.defaultModelID else { continue }
      let records = await workspace.modelRecords(for: account.id, includeHidden: true)
      guard !records.contains(where: { $0.model.id == defaultModelID }) else { continue }
      try await workspace.addManualModel(
        ProviderModel(
          providerID: account.providerID,
          id: defaultModelID,
          displayName: defaultModelID.rawValue
        ),
        for: account.id
      )
    }
  }

  private func reloadSnapshot() async throws {
    definitions = await registry.allDefinitions()
    accounts = await workspace.allAccounts()
    var modelValues: [ProviderAccountID: [AccountModelRecord]] = [:]
    var credentialValues: Set<ProviderAccountID> = []
    for account in accounts {
      modelValues[account.id] = await workspace.modelRecords(for: account.id, includeHidden: true)
      if try await accountManager.hasCredential(accountID: account.id) {
        credentialValues.insert(account.id)
      }
    }
    modelsByAccount = modelValues
    credentialAccountIDs = credentialValues
  }

  private func optionalURL(_ value: String) throws -> URL? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard let url = URL(string: trimmed) else { throw ProviderError.invalidBaseURL }
    return url
  }

  private func perform(_ success: String?, operation: () async throws -> Void) async {
    isBusy = true
    defer { isBusy = false }
    do {
      try await operation()
      statusMessage = success
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func performResult(_ success: String?, operation: () async throws -> Void) async -> Bool {
    isBusy = true
    defer { isBusy = false }
    do {
      try await operation()
      statusMessage = success
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }
}
