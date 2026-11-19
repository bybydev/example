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
  private(set) var lastModelRefreshByAccount: [ProviderAccountID: Date] = [:]
  @ObservationIgnored private var catalogRefreshTasks: [ProviderAccountID: Task<Void, Error>] = [:]
  @ObservationIgnored private var catalogRefreshFailures: [ProviderAccountID: Date] = [:]

  enum CatalogRefreshResult: Equatable {
    case refreshed, current, throttled, unsupported
  }

  static let catalogRefreshInterval: TimeInterval = 24 * 60 * 60
  static let catalogRetryInterval: TimeInterval = 15 * 60
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

  func capabilities(accountID: ProviderAccountID, modelID: ModelID) -> ResolvedModelCapabilities {
    let record = models(for: accountID, includeHidden: true).first { $0.model.id == modelID }
    let account = accounts.first { $0.id == accountID }
    return ModelCapabilityResolver.resolve(kind: account?.kind ?? .openAICompatible, modelID: modelID, model: record?.model)
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
    seedModelIDs: [String]? = nil,
    discoveredModels: [ProviderModel]? = nil,
    manualModelIDs: [String] = []
  ) async -> ProviderAccountID? {
    isBusy = true
    errorMessage = nil
    defer { isBusy = false }
    var createdAccountID: ProviderAccountID?
    do {
      let override = try optionalURL(baseURL)
      let trimmedModel = defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
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
        defaultModelID: trimmedModel.isEmpty ? nil : ModelID(rawValue: trimmedModel)
      )
      createdAccountID = account.id
      try await saveModels(
        for: account, defaultModelID: account.defaultModelID,
        discoveredModels: discoveredModels ?? kind.seedModels,
        manualModelIDs: manualModelIDs,
        markRefreshed: discoveredModels != nil
      )
      try await reloadSnapshot()
      BYOKAppAnalytics.track(.connectionCreated, dimension: .init(providerKind: kind))
      return account.id
    } catch {
      BYOKAppAnalytics.reportError("provider_save_failed", component: "provider")
      if let createdAccountID {
        _ = try? await accountManager.deleteAccount(createdAccountID)
        try? await reloadSnapshot()
      }
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
    clearCredential: Bool = false,
    baseURLString: String? = nil,
    headers: [String: String]? = nil,
    metadata: [String: String]? = nil,
    defaultModelID: ModelID? = nil,
    clearDefaultModel: Bool = false,
    discoveredModels: [ProviderModel]? = nil,
    manualModelIDs: [String] = [],
    removedManualModelIDs: Set<ModelID> = []
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
      if clearDefaultModel { updated.defaultModelID = nil }
      else if let defaultModelID { updated.defaultModelID = defaultModelID }
      try await accountManager.updateAccount(updated)
      if clearCredential {
        do {
          try await accountManager.setCredential(nil, accountID: accountID)
        } catch {
          BYOKAppAnalytics.reportError("provider_credential_save_failed", component: "provider")
          throw error
        }
      } else if let newCredential, !newCredential.isEmpty {
        do {
          try await accountManager.setCredential(newCredential, accountID: accountID)
        } catch {
          BYOKAppAnalytics.reportError("provider_credential_save_failed", component: "provider")
          throw error
        }
      }
      if defaultModelID != nil || discoveredModels != nil || !manualModelIDs.isEmpty {
        try await saveModels(
          for: updated, defaultModelID: updated.defaultModelID,
          discoveredModels: discoveredModels, manualModelIDs: manualModelIDs,
          markRefreshed: discoveredModels != nil
        )
      }
      if !removedManualModelIDs.isEmpty {
        try await workspace.removeManualModels(removedManualModelIDs, for: accountID)
      }
      try await reloadSnapshot()
    }
  }

  /// Suggested connection name: the provider display name, numbered on
  /// collision ("Anthropic", "Anthropic 2", …). For `.openAICompatible` the
  /// user names the server at create time, so that typed name is the base.
  func autoName(for kind: ProviderKind, customBase: String? = nil) -> String {
    let base: String
    if kind == .openAICompatible {
      guard let customBase, !customBase.trimmingCharacters(in: .whitespaces).isEmpty else {
        return ""
      }
      base = customBase.trimmingCharacters(in: .whitespaces)
    } else {
      base = kind.displayName
    }
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
    let kind = accounts.first(where: { $0.id == accountID })?.kind ?? .openAICompatible
    let succeeded = await performResult() {
      try await runtime.testConnection(accountID: accountID, modelID: modelID)
    }
    if !succeeded {
      BYOKAppAnalytics.track(.connectionTestFailed, dimension: .init(providerKind: kind))
    }
    return succeeded
  }

  /// Discovery uses the editor's endpoint/headers/auth draft in either mode.
  /// Only the unchanged credential comes from storage; preview never writes.
  func previewModels(
    for account: ResolvedProviderAccount,
    storedCredentialAccountID: ProviderAccountID? = nil
  ) async throws -> [ProviderModel] {
    var resolved = account
    if let baseURL = resolved.baseURLOverride {
      resolved.baseURLOverride = resolved.kind.normalizedBaseURL(baseURL)
    }
    let definition = resolved.definition
    try ProviderRegistry.validate(definition)
    if let baseURL = resolved.baseURLOverride, resolved.kind != .openAICompatible {
      try ProviderHTTP.validateBaseURL(
        baseURL,
        allowsLocalHTTP: definition.allowsLocalHTTP
      )
    }
    if definition.authentication != .none {
      if resolved.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
        let storedCredentialAccountID
      {
        resolved.apiKey = try await accountManager.resolvedAccount(id: storedCredentialAccountID).apiKey
      }
      if definition.requiresCredential {
        guard resolved.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
          throw ProviderError.missingCredential(resolved.providerID)
        }
      }
    }
    return try await runtime.listModels(account: resolved)
  }

  private func saveModels(
    for account: ProviderAccount,
    defaultModelID: ModelID?,
    discoveredModels: [ProviderModel]?,
    manualModelIDs: [String],
    markRefreshed: Bool = false
  ) async throws {
    if let discoveredModels {
      let remapped = discoveredModels.map { model in
        var value = model
        value.providerID = account.providerID
        return value
      }
      _ = try await workspace.mergeModels(
        remapped, for: account.id, expectedAccount: account, markRefreshed: markRefreshed
      )
    }
    let explicitManualIDs = Set(manualModelIDs.map {
      ModelID(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines))
    }.filter { !$0.rawValue.isEmpty })
    var manualIDs = explicitManualIDs
    if let defaultModelID { manualIDs.insert(defaultModelID) }
    for id in manualIDs {
      let record = await workspace.modelRecords(for: account.id, includeHidden: true)
        .first { $0.model.id == id }
      if record?.isAvailable != true || explicitManualIDs.contains(id) {
        try await workspace.addManualModel(
          record?.model ?? ProviderModel(providerID: account.providerID, id: id, displayName: id.rawValue),
          for: account.id
        )
      }
      if record?.isHidden == true {
        try await workspace.setHidden(false, modelID: id, accountID: account.id)
      }
    }
  }

  /// Reveal flow: returns the stored credential so the editor can show it on
  /// explicit user request. Keychain is the source of truth; nothing is
  /// logged or persisted by this call.
  func revealCredential(accountID: ProviderAccountID) async -> String? {
    (try? await accountManager.resolvedAccount(id: accountID))?.apiKey
  }

  /// Cached-first picker refresh. No global spinner/alert and at most one fetch per account.
  func refreshCatalog(
    accountID: ProviderAccountID, force: Bool = false, now: Date = .now
  ) async throws -> CatalogRefreshResult {
    guard let account = accounts.first(where: { $0.id == accountID }) else {
      throw ProviderError.accountNotFound(accountID)
    }
    guard account.definition.modelsPath != nil else { return .unsupported }
    if let existing = catalogRefreshTasks[accountID] {
      try await existing.value
      return .refreshed
    }
    if !force {
      if let last = lastModelRefreshByAccount[accountID],
         now.timeIntervalSince(last) < Self.catalogRefreshInterval { return .current }
      if let failed = catalogRefreshFailures[accountID],
         now.timeIntervalSince(failed) < Self.catalogRetryInterval { return .throttled }
    }
    let task = Task { @MainActor in
      _ = try await runtime.refreshModels(accountID: accountID)
      try await reloadSnapshot()
    }
    catalogRefreshTasks[accountID] = task
    defer { catalogRefreshTasks[accountID] = nil }
    do {
      try await task.value
      catalogRefreshFailures[accountID] = nil
      return .refreshed
    } catch {
      BYOKAppAnalytics.reportError("provider_refresh_failed", component: "provider")
      catalogRefreshFailures[accountID] = now
      throw error
    }
  }

  func refreshModelsResult(accountID: ProviderAccountID) async -> Bool {
    await performResult() {
      _ = try await runtime.refreshModels(accountID: accountID)
      try await reloadSnapshot()
    }
  }

  /// Model selection may stage an exact ID not yet reported by discovery.
  /// Persist only on Done; never change the connection's default model.
  func ensureSelectableModel(_ modelID: ModelID, for accountID: ProviderAccountID) async throws {
    guard !modelID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ProviderError.invalidModel
    }
    let existing = models(for: accountID, includeHidden: true).first { $0.model.id == modelID }
    if existing?.isAvailable == true && existing?.isHidden == false { return }
    let account = try await workspace.account(id: accountID)
    try await workspace.addManualModel(
      existing?.model ?? ProviderModel(
        providerID: account.providerID, id: modelID, displayName: modelID.rawValue),
      for: accountID
    )
    if existing?.isHidden == true {
      try await workspace.setHidden(false, modelID: modelID, accountID: accountID)
    }
    try await reloadSnapshot()
  }

  /// Picker deletion never touches existing chats or their history.
  func removeManualModels(_ ids: Set<ModelID>, for accountID: ProviderAccountID) async throws {
    try await workspace.removeManualModels(ids, for: accountID)
    try await reloadSnapshot()
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
    let registeredDefinitions = await registry.allDefinitions()
    let loadedAccounts = await workspace.allAccounts()
    // New compatible accounts are self-contained and need no legacy custom
    // definition. Include their derived definitions in presentation/readiness.
    var definitionsByID = Dictionary(uniqueKeysWithValues: registeredDefinitions.map { ($0.id, $0) })
    for account in loadedAccounts where definitionsByID[account.providerID] == nil {
      definitionsByID[account.providerID] = account.definition
    }
    definitions = definitionsByID.values.sorted {
      $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }

    var modelValues: [ProviderAccountID: [AccountModelRecord]] = [:]
    var refreshDates: [ProviderAccountID: Date] = [:]
    var credentialValues: Set<ProviderAccountID> = []
    for account in loadedAccounts {
      modelValues[account.id] = await workspace.modelRecords(for: account.id, includeHidden: true)
      if let date = await workspace.lastModelRefreshAt(for: account.id) {
        refreshDates[account.id] = date
      }
      if try await accountManager.hasCredential(accountID: account.id) {
        credentialValues.insert(account.id)
      }
    }

    modelsByAccount = modelValues
    lastModelRefreshByAccount = refreshDates
    credentialAccountIDs = credentialValues

    // Plain-value inputs instead of closures: the resolver runs on the
    // workspace actor, and closures capturing MainActor-isolated state would
    // be non-Sendable across that hop.
    var credentialRequiredByProvider: [ProviderID: Bool] = [:]
    for definition in definitions {
      credentialRequiredByProvider[definition.id] = definition.requiresCredential
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
    if definition.requiresCredential {
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
      BYOKAppAnalytics.reportError("provider_operation_failed", component: "provider")
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
      BYOKAppAnalytics.reportError("provider_operation_failed", component: "provider")
      errorMessage = error.localizedDescription
      return false
    }
  }
}

