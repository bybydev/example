import BYOKchatProviderCore
import Foundation
import Observation

@MainActor
@Observable
final class ProviderManagementModel {
  private(set) var definitions: [ProviderDefinition] = []
  /// Accounts are ordered with the persisted global default first. This keeps
  /// every UI fallback aligned with the account ChatManagementModel will use.
  private(set) var accounts: [ProviderAccount] = []
  private(set) var modelsByAccount: [ProviderAccountID: [AccountModelRecord]] = [:]
  private(set) var credentialAccountIDs: Set<ProviderAccountID> = []
  private(set) var defaultAccountID: ProviderAccountID?
  var isBusy = false
  var errorMessage: String?
  var statusMessage: String?

  private let registry: ProviderRegistry
  private let workspace: ProviderWorkspaceStore
  private let vault: any CredentialVault
  private let accountManager: ProviderAccountManager
  private let runtime: ProviderRuntime

  init(
    registry: ProviderRegistry,
    workspace: ProviderWorkspaceStore,
    vault: any CredentialVault,
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

  func isDefaultAccount(_ id: ProviderAccountID) -> Bool {
    defaultAccountID == id
  }

  func createConnection(
    providerID: ProviderID,
    label: String,
    credential: String,
    baseURL: String,
    defaultModel: String,
    headers: [String: String],
    metadata: [String: String]
  ) async -> ProviderAccountID? {
    isBusy = true
    errorMessage = nil
    defer { isBusy = false }
    do {
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
      statusMessage = "Connection saved"
      return account.id
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
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
    await createConnection(
      providerID: providerID,
      label: label,
      credential: credential,
      baseURL: baseURL,
      defaultModel: defaultModel,
      headers: headers,
      metadata: metadata
    ) != nil
  }

  func updateAccount(
    _ account: ProviderAccount,
    newCredential: String?,
    baseURL: String,
    headers: [String: String],
    metadata: [String: String]
  ) async -> Bool {
    await performResult("Connection updated") {
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

  func setDefaultAccount(_ id: ProviderAccountID) async -> Bool {
    await performResult("Default connection updated") {
      let account = try await workspace.account(id: id)
      guard account.isEnabled else {
        throw ProviderError.invalidRequest("Enable this connection before making it the default.")
      }
      guard connectionIsReady(account) else {
        throw ProviderError.invalidRequest(
          "Add a credential and an available model before making this connection the default."
        )
      }
      try await workspace.setDefaultAccount(id)
      try await reloadSnapshot()
    }
  }

  func setAccountEnabled(_ enabled: Bool, accountID: ProviderAccountID) async -> Bool {
    await performResult(enabled ? "Connection enabled" : "Connection disabled") {
      var account = try await workspace.account(id: accountID)
      account.isEnabled = enabled
      try await accountManager.updateAccount(account)
      try await reloadSnapshot()
    }
  }

  func deleteAccount(_ id: ProviderAccountID) async {
    await perform("Connection deleted") {
      let cleanupFailures = try await accountManager.deleteAccount(id)
      try await reloadSnapshot()
      guard cleanupFailures.isEmpty else {
        throw ProviderError.credentialCleanupFailed(cleanupFailures)
      }
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

  func testConnectionResult(accountID: ProviderAccountID, modelID: ModelID?) async -> Bool {
    await performResult("Connection successful") {
      try await runtime.testConnection(accountID: accountID, modelID: modelID)
    }
  }

  func testConnection(accountID: ProviderAccountID, modelID: ModelID?) async {
    _ = await testConnectionResult(accountID: accountID, modelID: modelID)
  }

  func refreshModelsResult(accountID: ProviderAccountID) async -> Bool {
    await performResult("Models refreshed") {
      _ = try await runtime.refreshModels(accountID: accountID)
      try await reloadSnapshot()
    }
  }

  func refreshModels(accountID: ProviderAccountID) async {
    _ = await refreshModelsResult(accountID: accountID)
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

  /// Builds one coherent snapshot and repairs only invalid defaults. The
  /// persisted default account remains stable while usable; when it is deleted,
  /// disabled, loses its credential, or has no model, the first usable account
  /// becomes the new default. This keeps fresh-chat presentation and creation
  /// on the same target without inventing a second UI-only default policy.
  private func reloadSnapshot() async throws {
    definitions = await registry.allDefinitions()
    var loadedAccounts = await workspace.allAccounts()

    var modelValues: [ProviderAccountID: [AccountModelRecord]] = [:]
    var credentialValues: Set<ProviderAccountID> = []
    for account in loadedAccounts {
      modelValues[account.id] = await workspace.modelRecords(for: account.id, includeHidden: true)
      if try await accountManager.hasCredential(accountID: account.id) {
        credentialValues.insert(account.id)
      }
    }

    // If model discovery invalidated a stored default, repair it to the first
    // visible available model. Chat creation otherwise could use a stale model
    // while the composer displayed a different fallback.
    for index in loadedAccounts.indices {
      var account = loadedAccounts[index]
      let available = (modelValues[account.id] ?? []).filter { $0.isAvailable && !$0.isHidden }
      let currentIsAvailable = account.defaultModelID.map { current in
        available.contains { $0.model.id == current }
      } ?? false
      if !currentIsAvailable, let fallback = available.first?.model.id {
        account.defaultModelID = fallback
        try await accountManager.updateAccount(account)
        loadedAccounts[index] = account
      }
    }

    modelsByAccount = modelValues
    credentialAccountIDs = credentialValues

    let storedDefault = await workspace.defaultAccountID()
    let usableDefault = storedDefault.flatMap { id in
      loadedAccounts.first { $0.id == id && connectionIsReady($0) }?.id
    }
    let resolvedDefault = usableDefault
      ?? loadedAccounts.first(where: connectionIsReady)?.id
      ?? loadedAccounts.first(where: \.isEnabled)?.id
      ?? loadedAccounts.first?.id

    if resolvedDefault != storedDefault {
      try await workspace.setDefaultAccount(resolvedDefault)
    }
    defaultAccountID = resolvedDefault

    accounts = loadedAccounts.sorted { lhs, rhs in
      if lhs.id == resolvedDefault { return true }
      if rhs.id == resolvedDefault { return false }
      if lhs.providerID == rhs.providerID {
        return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
      }
      return lhs.providerID.rawValue < rhs.providerID.rawValue
    }
  }

  private func connectionIsReady(_ account: ProviderAccount) -> Bool {
    guard account.isEnabled, let definition = provider(for: account.providerID) else { return false }
    switch definition.authentication {
    case .none:
      break
    case .bearer, .header:
      guard credentialAccountIDs.contains(account.id) else { return false }
    }
    let available = (modelsByAccount[account.id] ?? []).contains { $0.isAvailable && !$0.isHidden }
    return available
  }

  private func optionalURL(_ value: String) throws -> URL? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard let url = URL(string: trimmed) else { throw ProviderError.invalidBaseURL }
    return url
  }

  private func perform(_ success: String?, operation: () async throws -> Void) async {
    isBusy = true
    errorMessage = nil
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
    errorMessage = nil
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
