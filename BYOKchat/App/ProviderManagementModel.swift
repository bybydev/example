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

  private let registry: ProviderRegistry
  private let workspace: ProviderWorkspaceStore
  private let accountManager: ProviderAccountManager
  private let runtime: ProviderRuntime

  init(
    registry: ProviderRegistry,
    workspace: ProviderWorkspaceStore,
    accountManager: ProviderAccountManager,
    runtime: ProviderRuntime
  ) {
    self.registry = registry
    self.workspace = workspace
    self.accountManager = accountManager
    self.runtime = runtime
  }

  func load() async {
    await perform() {
      try await workspace.load()
      try await accountManager.synchronizeCustomProviders()
      try await reloadSnapshot()
    }
  }

  func reloadFromStorage() async {
    await perform() {
      try await accountManager.synchronizeCustomProviders()
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
    kind: ProviderKind,
    label: String,
    credential: String,
    baseURL: String,
    defaultModel: String,
    headers: [String: String],
    metadata: [String: String],
    chatCompletionsPath: String? = nil,
    modelsPath: String? = nil,
    authChoice: ProviderAuthentication? = nil,
    seedModelIDs: [String]? = nil
  ) async -> ProviderAccountID? {
    isBusy = true
    errorMessage = nil
    defer { isBusy = false }
    do {
      let override = try optionalURL(baseURL)
      let account = try await accountManager.createAccount(
        kind: kind,
        label: label,
        credential: credential.isEmpty ? nil : credential,
        chatCompletionsPath: chatCompletionsPath,
        modelsPath: modelsPath,
        authChoice: authChoice,
        seedModelIDs: seedModelIDs,
        baseURLOverride: override,
        additionalHeaders: headers,
        metadata: metadata,
        defaultModelID: defaultModel.isEmpty ? nil : ModelID(rawValue: defaultModel)
      )
      if !kind.seedModels.isEmpty {
        try await workspace.mergeModels(kind.seedModels, for: account.id)
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
      return account.id
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func createAccount(
    kind: ProviderKind,
    label: String,
    credential: String,
    baseURL: String,
    defaultModel: String,
    headers: [String: String],
    metadata: [String: String],
    chatCompletionsPath: String? = nil,
    modelsPath: String? = nil,
    authChoice: ProviderAuthentication? = nil,
    seedModelIDs: [String]? = nil
  ) async -> Bool {
    await createConnection(
      kind: kind,
      label: label,
      credential: credential,
      baseURL: baseURL,
      defaultModel: defaultModel,
      headers: headers,
      metadata: metadata,
      chatCompletionsPath: chatCompletionsPath,
      modelsPath: modelsPath,
      authChoice: authChoice,
      seedModelIDs: seedModelIDs
    ) != nil
  }

  func updateAccount(
    _ account: ProviderAccount,
    newCredential: String?,
    baseURL: String,
    headers: [String: String],
    metadata: [String: String]
  ) async -> Bool {
    await performResult() {
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

  /// Scoped account update: fetches the current account from the workspace by
  /// ID and applies only the fields the caller passed. Callers never hand over
  /// a captured account struct, so concurrent edits to other fields survive.
  /// - `newCredential`: non-nil non-empty replaces the keychain secret.
  /// - `baseURLString`: "" (or whitespace) clears the endpoint override.
  func updateAccount(
    accountID: ProviderAccountID,
    label: String? = nil,
    newCredential: String? = nil,
    baseURLString: String? = nil,
    headers: [String: String]? = nil,
    metadata: [String: String]? = nil
  ) async -> Bool {
    await performResult() {
      var updated = try await workspace.account(id: accountID)
      if let label {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
          throw ProviderError.invalidRequest("Account label cannot be empty.")
        }
        updated.label = trimmed
      }
      if let baseURLString {
        updated.baseURLOverride = try optionalURL(baseURLString)
      }
      if let headers { updated.additionalHeaders = headers }
      if let metadata { updated.metadata = metadata }
      try await accountManager.updateAccount(updated)
      if let newCredential, !newCredential.isEmpty {
        try await accountManager.setCredential(newCredential, accountID: accountID)
      }
      try await reloadSnapshot()
    }
  }

  /// Next auto-name for a kind: the provider display name, numbered on
  /// collision ("Anthropic", "Anthropic 2", …).
  func autoName(for kind: ProviderKind) -> String {
    let base = kind == .openAICompatible ? "" : kind.displayName
    guard !base.isEmpty else { return "" }
    let existing = Set(accounts.map(\.label))
    guard existing.contains(base) else { return base }
    var index = 2
    while existing.contains("\(base) \(index)") { index += 1 }
    return "\(base) \(index)"
  }

  func setDefaultAccount(_ id: ProviderAccountID) async -> Bool {
    await performResult() {
      let account = try await workspace.account(id: id)
      guard account.isEnabled else {
        throw ProviderError.invalidRequest("Enable this connection before making it the default.")
      }
      guard isReady(account) else {
        throw ProviderError.invalidRequest(
          "Add a credential and an available model before making this connection the default."
        )
      }
      try await workspace.setDefaultAccount(id)
      try await reloadSnapshot()
    }
  }

  func setAccountEnabled(_ enabled: Bool, accountID: ProviderAccountID) async -> Bool {
    await performResult() {
      var account = try await workspace.account(id: accountID)
      account.isEnabled = enabled
      try await accountManager.updateAccount(account)
      try await reloadSnapshot()
    }
  }

  func deleteAccount(_ id: ProviderAccountID) async {
    await perform() {
      let cleanupFailures = try await accountManager.deleteAccount(id)
      try await reloadSnapshot()
      guard cleanupFailures.isEmpty else {
        throw ProviderError.credentialCleanupFailed(cleanupFailures)
      }
    }
  }

  func setDefaultModel(_ modelID: ModelID, accountID: ProviderAccountID) async {
    await perform() {
      var account = try await workspace.account(id: accountID)
      account.defaultModelID = modelID
      try await accountManager.updateAccount(account)
      try await reloadSnapshot()
    }
  }

  func testConnectionResult(accountID: ProviderAccountID, modelID: ModelID?) async -> Bool {
    await performResult() {
      try await runtime.testConnection(accountID: accountID, modelID: modelID)
    }
  }

  /// Preview-only model discovery against an unsaved account (create mode).
  /// Reads nothing from the workspace and persists nothing.
  func previewModels(for account: ResolvedProviderAccount) async throws -> [ProviderModel] {
    try await runtime.listModels(account: account)
  }

  func refreshModelsResult(accountID: ProviderAccountID) async -> Bool {
    await performResult() {
      _ = try await runtime.refreshModels(accountID: accountID)
      try await reloadSnapshot()
    }
  }

  func addManualModel(_ modelID: String, accountID: ProviderAccountID) async -> Bool {
    await performResult() {
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
    await perform() {
      try await workspace.setFavorite(favorite, modelID: modelID, accountID: accountID)
      try await reloadSnapshot()
    }
  }

  func setHidden(_ hidden: Bool, modelID: ModelID, accountID: ProviderAccountID) async {
    await perform() {
      try await workspace.setHidden(hidden, modelID: modelID, accountID: accountID)
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

  /// Builds one coherent snapshot. This read never writes: the persisted
  /// default is not rewritten here and stale defaults are not repaired.
  /// Resolution falls back in memory via `workspace.resolvedDefaultAccountID`.
  private func reloadSnapshot() async throws {
    definitions = await registry.allDefinitions()
    let loadedAccounts = await workspace.allAccounts()

    var modelValues: [ProviderAccountID: [AccountModelRecord]] = [:]
    var credentialValues: Set<ProviderAccountID> = []
    for account in loadedAccounts {
      modelValues[account.id] = await workspace.modelRecords(for: account.id, includeHidden: true)
      if try await accountManager.hasCredential(accountID: account.id) {
        credentialValues.insert(account.id)
      }
    }

    modelsByAccount = modelValues
    credentialAccountIDs = credentialValues

    // Plain-value inputs instead of closures: the resolver runs on the
    // workspace actor, and closures capturing MainActor-isolated state would
    // be non-Sendable across that hop.
    var credentialRequiredByProvider: [ProviderID: Bool] = [:]
    for definition in definitions {
      let required: Bool
      switch definition.authentication {
      case .none: required = false
      case .bearer, .header: required = true
      }
      credentialRequiredByProvider[definition.id] = required
    }

    defaultAccountID = await workspace.resolvedDefaultAccountID(
      credentialRequiredByProvider: credentialRequiredByProvider,
      credentialAccountIDs: credentialValues
    )

    accounts = loadedAccounts.sorted { lhs, rhs in
      if lhs.id == defaultAccountID { return true }
      if rhs.id == defaultAccountID { return false }
      if lhs.providerID == rhs.providerID {
        return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
      }
      return lhs.providerID.rawValue < rhs.providerID.rawValue
    }
  }

  /// The one readiness predicate, shared by every surface (list rows, chip,
  /// picker, chat creation policy).
  func isReady(_ account: ProviderAccount) -> Bool {
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

  var resolvedDefaultAccount: ProviderAccount? {
    defaultAccountID.flatMap { id in accounts.first { $0.id == id } }
  }

  private func optionalURL(_ value: String) throws -> URL? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard let url = URL(string: trimmed) else { throw ProviderError.invalidBaseURL }
    return url
  }

  private func perform(operation: () async throws -> Void) async {
    isBusy = true
    errorMessage = nil
    defer { isBusy = false }
    do {
      try await operation()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func performResult(operation: () async throws -> Void) async -> Bool {
    isBusy = true
    errorMessage = nil
    defer { isBusy = false }
    do {
      try await operation()
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }
}
