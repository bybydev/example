import BYOKchatProviderCore
import Foundation
import Observation

struct MacChatTarget: Sendable, Equatable {
  var accountID: ProviderAccountID
  var modelID: ModelID
  var reasoning: ReasoningOptions?
}

@MainActor
@Observable
final class MacProviderModel {
  enum CatalogRefreshResult: Sendable, Equatable {
    case refreshed
    case current
    case throttled
    case unsupported
  }

  static let catalogRefreshInterval: TimeInterval = 24 * 60 * 60
  static let catalogRetryInterval: TimeInterval = 15 * 60

  private(set) var definitions: [ProviderDefinition] = []
  private(set) var accounts: [ProviderAccount] = []
  private(set) var modelsByAccount: [ProviderAccountID: [AccountModelRecord]] = [:]
  private var visibleModelsByAccount: [ProviderAccountID: [AccountModelRecord]] = [:]
  private var modelRecordsByAccountAndID: [ProviderAccountID: [ModelID: AccountModelRecord]] = [:]
  private(set) var lastModelRefreshByAccount: [ProviderAccountID: Date] = [:]
  private(set) var modelCatalogStatus: ModelCatalogStatus?
  private(set) var modelCatalogRevision: Int = ModelCatalogRegistry.current?.revision ?? 0
  private(set) var isRefreshingModelCatalog = false
  private(set) var credentialAccountIDs: Set<ProviderAccountID> = []
  private(set) var defaultAccountID: ProviderAccountID?
  var isBusy = false
  var errorMessage: String?

  @ObservationIgnored private var catalogRefreshTasks: [ProviderAccountID: Task<Void, Error>] = [:]
  @ObservationIgnored private var catalogRefreshFailures: [ProviderAccountID: Date] = [:]
  @ObservationIgnored private var modelCatalogRefreshTask: Task<ModelCatalogRefreshResult, Error>?

  private let registry: ProviderRegistry
  private let workspace: ProviderWorkspaceStore
  private let accountManager: ProviderAccountManager
  private let runtime: ProviderRuntime
  private let modelCatalog: ModelCatalogStore
  private let restrictions: MacProResourceRestrictions
  private let entitlementAccessOverride: MacProEntitlementAccess?

  init(
    services: BYOKCoreServices,
    restrictions: MacProResourceRestrictions = MacPurchaseStore.restrictions,
    entitlementAccessOverride: MacProEntitlementAccess? = nil,
    runtime: ProviderRuntime? = nil
  ) {
    registry = services.providerRegistry
    workspace = services.providerWorkspace
    accountManager = services.accountManager
    self.runtime = runtime ?? services.providerRuntime
    modelCatalog = services.modelCatalog
    self.restrictions = restrictions
    self.entitlementAccessOverride = entitlementAccessOverride
  }

  func load() async throws {
    await modelCatalog.load()
    try await registry.refreshBuiltIns()
    try await workspace.load()
    try await accountManager.synchronizeCustomProviders()
    try await synchronizeConfiguredSeedModelsForStoredAccounts()
    try await reloadSnapshot()
  }

  func reload() async {
    await perform {
      await modelCatalog.load()
      try await registry.refreshBuiltIns()
      try await accountManager.synchronizeCustomProviders()
      try await synchronizeConfiguredSeedModelsForStoredAccounts()
      try await reloadSnapshot()
    }
  }

  /// Background non-blocking refresh of the remote Layer 2 catalog.
  /// Errors are absorbed so offline launches and transient outages stay quiet.
  func refreshModelCatalogIfNeeded() async {
    _ = try? await refreshModelCatalog(force: false)
  }

  /// Forces an immediate conditional refresh of the Layer 2 remote model catalog.
  @discardableResult
  func forceRefreshModelCatalog(now: Date = .now) async throws -> ModelCatalogRefreshResult {
    try await refreshModelCatalog(force: true, now: now)
  }

  /// Fetches Layer 2 static catalog JSON using ETag conditional requests,
  /// persists valid newer revisions, and merges updated seed models into
  /// existing built-in cloud accounts.
  @discardableResult
  func refreshModelCatalog(
    force: Bool = true,
    now: Date = .now
  ) async throws -> ModelCatalogRefreshResult {
    if let existing = modelCatalogRefreshTask {
      return try await existing.value
    }
    isRefreshingModelCatalog = true
    let task: Task<ModelCatalogRefreshResult, Error> = Task { @MainActor in
      let result = try await modelCatalog.refresh(force: force, now: now)
      switch result {
      case .updated:
        try await applyActiveModelCatalogToWorkspace()
      case .ignoredOlderThanBundled:
        try await registry.refreshBuiltIns()
        try await reloadSnapshot()
      case .notModified, .upToDate, .throttled:
        let status = await modelCatalog.status()
        modelCatalogStatus = status
        modelCatalogRevision = status.revision
      }
      return result
    }
    modelCatalogRefreshTask = task
    defer {
      modelCatalogRefreshTask = nil
      isRefreshingModelCatalog = false
    }
    do {
      return try await task.value
    } catch {
      let status = await modelCatalog.status()
      modelCatalogStatus = status
      modelCatalogRevision = status.revision
      throw error
    }
  }

  /// Removes any cached Layer 2 remote catalog and reverts to the bundled Layer 1 baseline.
  func clearModelCatalogCache() async throws {
    try await modelCatalog.clearCache()
    try await registry.refreshBuiltIns()
    try await reloadSnapshot()
  }

  private func applyActiveModelCatalogToWorkspace() async throws {
    try await registry.refreshBuiltIns()
    let activeSnapshot = await modelCatalog.activeCatalog()
    let existingAccounts = await workspace.allAccounts()
    for account in existingAccounts
    where account.kind != .openAICompatible && !account.kind.isLocalServer {
      let rawSeeds = activeSnapshot?.seedModels(for: account.kind) ?? account.kind.seedModels
      let seeds = rawSeeds.map { model in
        var value = model
        value.providerID = account.providerID
        return value
      }
      guard !seeds.isEmpty else { continue }
      _ = try await workspace.mergeModels(
        seeds,
        for: account.id,
        expectedAccount: account,
        markRefreshed: false
      )
    }
    try await reloadSnapshot()
  }

  func provider(for id: ProviderID) -> ProviderDefinition? {
    definitions.first { $0.id == id }
  }

  func account(_ id: ProviderAccountID?) -> ProviderAccount? {
    guard let id else { return nil }
    return accounts.first { $0.id == id }
  }

  func lastModelRefreshAt(for accountID: ProviderAccountID) -> Date? {
    lastModelRefreshByAccount[accountID]
  }

  func models(for accountID: ProviderAccountID, includeHidden: Bool = false) -> [AccountModelRecord] {
    includeHidden
      ? (modelsByAccount[accountID] ?? [])
      : (visibleModelsByAccount[accountID] ?? [])
  }

  func modelRecord(for accountID: ProviderAccountID, modelID: ModelID) -> AccountModelRecord? {
    modelRecordsByAccountAndID[accountID]?[modelID]
  }

  func usableModelID(for accountID: ProviderAccountID) -> ModelID? {
    guard let account = account(accountID) else { return nil }
    return usableModelID(for: account)
  }

  func capabilities(accountID: ProviderAccountID, modelID: ModelID) -> ResolvedModelCapabilities {
    let record = modelRecord(for: accountID, modelID: modelID)
    return ModelCapabilityResolver.resolve(
      kind: account(accountID)?.kind ?? .openAICompatible,
      modelID: modelID,
      model: record?.model
    )
  }

  func supportsReasoning(accountID: ProviderAccountID, modelID: ModelID) -> Bool {
    capabilities(accountID: accountID, modelID: modelID)[.reasoning] == .supported
  }

  var resolvedDefaultAccount: ProviderAccount? {
    defaultAccountID.flatMap { id in accounts.first { $0.id == id } }
  }

  func isProviderRestricted(_ accountID: ProviderAccountID) -> Bool {
    restrictions.isProviderRestricted(
      accountID,
      currentIDs: accounts.map(\.id),
      entitlement: effectiveEntitlementAccess
    )
  }

  func preferredTarget() -> MacChatTarget? {
    let candidates = accounts.filter { isReady($0) && !isProviderRestricted($0.id) }
    guard let account = resolvedDefaultAccount.flatMap({ resolved in
      candidates.first { $0.id == resolved.id }
    }) ?? candidates.first,
      let modelID = usableModelID(for: account)
    else {
      return nil
    }
    return MacChatTarget(
      accountID: account.id,
      modelID: modelID,
      reasoning: nil
    )
  }

  func isReady(_ account: ProviderAccount) -> Bool {
    guard account.isEnabled else { return false }
    if account.definition.requiresCredential {
      guard credentialAccountIDs.contains(account.id) else { return false }
    }
    return (visibleModelsByAccount[account.id] ?? []).contains { $0.isAvailable }
  }

  func hasCredential(_ accountID: ProviderAccountID) -> Bool {
    credentialAccountIDs.contains(accountID)
  }

  @discardableResult
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
    guard MacProAccess.requireProviderAccountCapacity(currentCount: accounts.count) else {
      errorMessage = MacProAccess.blockedMessage(
        freeMessage: "Free includes 1 provider connection. Upgrade to BYOK Pro to add more."
      )
      return nil
    }

    isBusy = true
    errorMessage = nil
    defer { isBusy = false }

    let account: ProviderAccount
    do {
      let trimmedCredential = credential.trimmingCharacters(in: .whitespacesAndNewlines)
      let trimmedDefaultModel = defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
      account = try await accountManager.createAccount(
        kind: kind,
        label: normalizedLabel(label, kind: kind),
        credential: trimmedCredential.isEmpty ? nil : trimmedCredential,
        chatCompletionsPath: kind == .openAICompatible
          ? normalizedPath(chatCompletionsPath, fallback: "/chat/completions")
          : nil,
        modelsPath: kind == .openAICompatible ? normalizedOptionalPath(modelsPath) : nil,
        authChoice: kind == .openAICompatible ? authChoice : nil,
        seedModelIDs: kind == .openAICompatible ? normalizedSeedModelIDs(seedModelIDs) : nil,
        baseURLOverride: try optionalURL(baseURL, kind: kind),
        additionalHeaders: headers,
        metadata: metadata,
        defaultModelID: trimmedDefaultModel.isEmpty ? nil : ModelID(rawValue: trimmedDefaultModel)
      )
    } catch {
      MacAppAnalytics.reportError("provider_save_failed", component: "provider")
      errorMessage = error.localizedDescription
      return nil
    }

    do {
      try await installConfiguredModels(
        for: account,
        discoveredModels: discoveredModels,
        manualModelIDs: manualModelIDs
      )
    } catch {
      MacAppAnalytics.reportError("provider_model_setup_failed", component: "provider")
      let setupError = error
      let rollbackWarning = await rollbackCreatedAccount(account.id)
      try? await reloadSnapshot()
      errorMessage = joinedError(
        primary: setupError.localizedDescription,
        warning: rollbackWarning
      )
      return nil
    }

    do {
      try await reloadSnapshot()
    } catch {
      MacAppAnalytics.reportError("provider_refresh_failed", component: "provider")
      errorMessage = "Connection was saved, but the provider list could not refresh: \(error.localizedDescription)"
    }
    MacAppAnalytics.track(.connectionCreated, dimension: .init(providerKind: kind))
    return account.id
  }

  func updateConnection(
    accountID: ProviderAccountID,
    label: String,
    newCredential: String?,
    clearCredential: Bool = false,
    baseURL: String,
    headers: [String: String],
    metadata: [String: String],
    chatCompletionsPath: String?,
    modelsPath: String?,
    authChoice: ProviderAuthentication?,
    seedModelIDs: [String]?,
    defaultModelID: ModelID? = nil,
    clearDefaultModel: Bool = false,
    discoveredModels: [ProviderModel]? = nil,
    manualModelIDs: [String] = [],
    removedManualModelIDs: Set<ModelID> = []
  ) async -> Bool {
    guard requireProviderAccess(accountID) else { return false }

    isBusy = true
    errorMessage = nil
    defer { isBusy = false }

    let original: ProviderAccount
    do {
      original = try await workspace.account(id: accountID)
    } catch {
      MacAppAnalytics.reportError("provider_load_failed", component: "provider")
      errorMessage = error.localizedDescription
      return false
    }

    let addedManualIDs = Set(
      manualModelIDs
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .map(ModelID.init(rawValue:))
    )
    var effectiveRemoved = removedManualModelIDs.subtracting(addedManualIDs)
    if let defaultModelID, !clearDefaultModel {
      effectiveRemoved.remove(defaultModelID)
    }

    var updated = original
    let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedLabel.isEmpty else {
      errorMessage = ProviderError.invalidRequest("Connection name cannot be empty.").localizedDescription
      return false
    }

    do {
      updated.label = trimmedLabel
      updated.baseURLOverride = try optionalURL(baseURL, kind: updated.kind)
      updated.additionalHeaders = headers
      updated.metadata = metadata
      if clearDefaultModel {
        updated.defaultModelID = nil
      } else if let defaultModelID {
        updated.defaultModelID = defaultModelID
      }
      if updated.kind == .openAICompatible {
        updated.chatCompletionsPath = normalizedPath(chatCompletionsPath, fallback: "/chat/completions")
        updated.modelsPath = normalizedOptionalPath(modelsPath)
        updated.authChoice = authChoice ?? .bearer
        let normalizedSeeds = normalizedSeedModelIDs(seedModelIDs)
        let previousSeeds = Set((original.seedModelIDs ?? []).map(ModelID.init(rawValue:)))
        let nextSeeds: [String]?
        if !effectiveRemoved.isEmpty, let normalizedSeeds {
          let filtered = normalizedSeeds.filter { !effectiveRemoved.contains(ModelID(rawValue: $0)) }
          nextSeeds = filtered.isEmpty ? nil : filtered
        } else {
          nextSeeds = normalizedSeeds
        }
        updated.seedModelIDs = nextSeeds
        let nextSeedSet = Set((nextSeeds ?? []).map(ModelID.init(rawValue:)))
        let deletedSeeds = previousSeeds
          .subtracting(nextSeedSet)
          .subtracting(addedManualIDs)
        effectiveRemoved.formUnion(deletedSeeds)
        if let defaultModelID, !clearDefaultModel {
          effectiveRemoved.remove(defaultModelID)
        }
      }
      try await accountManager.updateAccount(updated)
    } catch {
      MacAppAnalytics.reportError("provider_update_failed", component: "provider")
      errorMessage = error.localizedDescription
      return false
    }

    let shouldClearCredential =
      clearCredential || (updated.kind == .openAICompatible && updated.authChoice == .none)
    if shouldClearCredential {
      do {
        try await accountManager.setCredential(nil, accountID: accountID)
      } catch {
        MacAppAnalytics.reportError("provider_credential_save_failed", component: "provider")
        let credentialError = error
        let rollbackWarning = await rollbackUpdatedAccount(original)
        try? await reloadSnapshot()
        errorMessage = joinedError(
          primary: credentialError.localizedDescription,
          warning: rollbackWarning
        )
        return false
      }
    } else if let newCredential {
      let trimmedCredential = newCredential.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmedCredential.isEmpty {
        do {
          try await accountManager.setCredential(trimmedCredential, accountID: accountID)
        } catch {
          MacAppAnalytics.reportError("provider_credential_save_failed", component: "provider")
          let credentialError = error
          let rollbackWarning = await rollbackUpdatedAccount(original)
          try? await reloadSnapshot()
          errorMessage = joinedError(
            primary: credentialError.localizedDescription,
            warning: rollbackWarning
          )
          return false
        }
      }
    }

    var warnings: [String] = []
    if defaultModelID != nil || discoveredModels != nil || !manualModelIDs.isEmpty {
      do {
        try await saveModels(
          for: updated,
          defaultModelID: updated.defaultModelID,
          discoveredModels: discoveredModels,
          manualModelIDs: manualModelIDs,
          markRefreshed: discoveredModels != nil
        )
      } catch {
        MacAppAnalytics.reportError("provider_model_sync_failed", component: "provider")
        warnings.append("Connection changes were saved, but models could not be updated: \(error.localizedDescription)")
      }
    }
    do {
      try await installConfiguredSeedModels(for: updated)
    } catch {
      MacAppAnalytics.reportError("provider_model_sync_failed", component: "provider")
      warnings.append("Connection changes were saved, but seed models could not be synchronized: \(error.localizedDescription)")
    }
    if !effectiveRemoved.isEmpty {
      do {
        let removableManualIDs = Set(
          await workspace.modelRecords(for: accountID, includeHidden: true)
            .filter { $0.isManual && effectiveRemoved.contains($0.model.id) }
            .map(\.model.id)
        )
        if !removableManualIDs.isEmpty {
          try await workspace.removeManualModels(removableManualIDs, for: accountID)
        }
      } catch {
        MacAppAnalytics.reportError("provider_model_sync_failed", component: "provider")
        warnings.append("Connection changes were saved, but manual models could not be removed: \(error.localizedDescription)")
      }
    }
    do {
      try await accountManager.synchronizeCustomProviders()
    } catch {
      MacAppAnalytics.reportError("provider_refresh_failed", component: "provider")
      warnings.append("Connection changes were saved, but provider registration could not refresh: \(error.localizedDescription)")
    }
    do {
      try await reloadSnapshot()
    } catch {
      MacAppAnalytics.reportError("provider_refresh_failed", component: "provider")
      warnings.append("Connection changes were saved, but the provider list could not refresh: \(error.localizedDescription)")
    }

    errorMessage = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
    return true
  }

  func setAccountEnabled(_ enabled: Bool, accountID: ProviderAccountID) async -> Bool {
    if enabled, !requireProviderAccess(accountID) { return false }
    return await performCommittedResult(
      warningPrefix: "Connection state was saved, but the provider list could not refresh:"
    ) {
      var account = try await workspace.account(id: accountID)
      account.isEnabled = enabled
      try await accountManager.updateAccount(account)
    }
  }

  func setDefaultAccount(_ accountID: ProviderAccountID) async -> Bool {
    guard requireProviderAccess(accountID) else { return false }
    return await performCommittedResult(
      warningPrefix: "Default connection was saved, but the provider list could not refresh:"
    ) {
      guard let account = account(accountID), isReady(account) else {
        throw ProviderError.invalidRequest("This connection needs an available model and credential first.")
      }
      try await workspace.setDefaultAccount(accountID)
    }
  }

  func setDefaultModel(_ modelID: ModelID, accountID: ProviderAccountID) async -> Bool {
    guard requireProviderAccess(accountID) else { return false }
    return await performCommittedResult(
      warningPrefix: "Default model was saved, but the provider list could not refresh:"
    ) {
      guard models(for: accountID).contains(where: { $0.model.id == modelID && $0.isAvailable }) else {
        throw ProviderError.modelUnavailable
      }
      var account = try await workspace.account(id: accountID)
      account.defaultModelID = modelID
      try await accountManager.updateAccount(account)
    }
  }

  /// Cached-first per-account model discovery with 24h freshness TTL, 15m failure
  /// backoff, and in-flight deduplication. Does not set global `isBusy` / `errorMessage`.
  @discardableResult
  func refreshModelsIfNeeded(
    accountID: ProviderAccountID,
    force: Bool = false,
    now: Date = .now
  ) async throws -> CatalogRefreshResult {
    guard let account = accounts.first(where: { $0.id == accountID }) else {
      throw ProviderError.accountNotFound(accountID)
    }
    guard !isProviderRestricted(accountID) else { return .throttled }
    guard account.definition.modelsPath != nil else { return .unsupported }

    if let existing = catalogRefreshTasks[accountID] {
      try await existing.value
      return .refreshed
    }
    if !force {
      if let last = lastModelRefreshByAccount[accountID],
        now.timeIntervalSince(last) < Self.catalogRefreshInterval
      {
        return .current
      }
      if let failed = catalogRefreshFailures[accountID],
        now.timeIntervalSince(failed) < Self.catalogRetryInterval
      {
        return .throttled
      }
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
      MacAppAnalytics.reportError("provider_refresh_failed", component: "provider")
      catalogRefreshFailures[accountID] = now
      throw error
    }
  }

  /// Refreshes all ready, unrestricted accounts whose discovery cache is stale (>24h).
  /// Errors are absorbed per account and subject to the 15m retry backoff.
  func refreshReadyAccountsIfNeeded(now: Date = .now) async {
    let candidates = accounts.filter {
      isReady($0) && !isProviderRestricted($0.id) && $0.definition.modelsPath != nil
    }
    for account in candidates {
      _ = try? await refreshModelsIfNeeded(accountID: account.id, force: false, now: now)
    }
  }

  /// Explicit user-triggered model discovery. Always unthrottled and deduplicated
  /// against any in-flight refresh for the same account.
  func refreshModels(accountID: ProviderAccountID) async -> Bool {
    guard requireProviderAccess(accountID) else { return false }
    if let existing = catalogRefreshTasks[accountID] {
      let succeeded = await performResult {
        try await existing.value
      }
      if succeeded {
        catalogRefreshFailures[accountID] = nil
      }
      return succeeded
    }

    isBusy = true
    errorMessage = nil
    defer { isBusy = false }

    let task = Task { @MainActor in
      _ = try await runtime.refreshModels(accountID: accountID)
      try await reloadSnapshot()
    }
    catalogRefreshTasks[accountID] = task
    defer { catalogRefreshTasks[accountID] = nil }

    do {
      try await task.value
      catalogRefreshFailures[accountID] = nil
      return true
    } catch {
      MacAppAnalytics.reportError("provider_operation_failed", component: "provider")
      errorMessage = error.localizedDescription
      return false
    }
  }

  /// Pre-save discovery using the editor's unsaved endpoint, auth, headers, and credential draft.
  /// Only an unchanged stored credential is read from Keychain; preview never writes to storage.
  func previewModels(
    for account: ResolvedProviderAccount,
    storedCredentialAccountID: ProviderAccountID? = nil
  ) async throws -> [ProviderModel] {
    let resolved = try await resolveDraftAccountForPreview(
      account,
      storedCredentialAccountID: storedCredentialAccountID
    )
    return try await runtime.listModels(account: resolved)
  }

  /// Pre-save connection test against a specific model ID using unsaved draft values.
  /// Useful for providers with discovery disabled (`modelsPath == nil`).
  func testConnectionPreview(
    for account: ResolvedProviderAccount,
    modelID: ModelID,
    storedCredentialAccountID: ProviderAccountID? = nil
  ) async throws {
    let trimmedModel = modelID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedModel.isEmpty else {
      throw ProviderError.invalidModel
    }
    let resolved = try await resolveDraftAccountForPreview(
      account,
      storedCredentialAccountID: storedCredentialAccountID
    )
    try await runtime.testConnection(account: resolved, modelID: ModelID(rawValue: trimmedModel))
  }

  /// Persists an exact manually entered model ID from the target picker on Done,
  /// without modifying the connection's default model.
  func ensureSelectableModel(_ modelID: ModelID, for accountID: ProviderAccountID) async throws {
    guard requireProviderAccess(accountID) else {
      throw ProviderError.invalidRequest(
        MacProAccess.restoredResourceBlockedMessage("provider connection")
      )
    }
    let trimmed = modelID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw ProviderError.invalidModel
    }
    let normalizedID = ModelID(rawValue: trimmed)
    let existing = modelRecord(for: accountID, modelID: normalizedID)
    if existing?.isAvailable == true && existing?.isHidden == false { return }
    let account = try await workspace.account(id: accountID)
    if existing?.isAvailable != true {
      try await workspace.addManualModel(
        existing?.model ?? ProviderModel(
          providerID: account.providerID,
          id: normalizedID,
          displayName: normalizedID.rawValue
        ),
        for: accountID
      )
    }
    if existing?.isHidden == true {
      try await workspace.setHidden(false, modelID: normalizedID, accountID: accountID)
    }
    try await reloadSnapshot()
  }

  /// Removes user-added manual models from an account without touching chat history.
  func removeManualModels(_ ids: Set<ModelID>, for accountID: ProviderAccountID) async throws {
    guard !ids.isEmpty else { return }
    guard requireProviderAccess(accountID) else {
      throw ProviderError.invalidRequest(
        MacProAccess.restoredResourceBlockedMessage("provider connection")
      )
    }
    try await workspace.removeManualModels(ids, for: accountID)
    try await reloadSnapshot()
  }

  /// Removes a single manually added model and surfaces errors via `errorMessage`.
  @discardableResult
  func removeManualModel(_ modelID: ModelID, accountID: ProviderAccountID) async -> Bool {
    guard requireProviderAccess(accountID) else { return false }
    return await performCommittedResult(
      warningPrefix: "The custom model was removed, but the provider list could not refresh:"
    ) {
      try await workspace.removeManualModels([modelID], for: accountID)
    }
  }

  func addManualModel(_ value: String, accountID: ProviderAccountID) async -> Bool {
    guard requireProviderAccess(accountID) else { return false }
    return await performCommittedResult(
      warningPrefix: "The model was added, but the provider list could not refresh:"
    ) {
      let account = try await workspace.account(id: accountID)
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { throw ProviderError.invalidModel }
      try await workspace.addManualModel(
        ProviderModel(providerID: account.providerID, id: ModelID(rawValue: trimmed), displayName: trimmed),
        for: accountID
      )
    }
  }

  func setFavorite(_ favorite: Bool, modelID: ModelID, accountID: ProviderAccountID) async {
    await performCommitted(
      warningPrefix: "Favorite state was saved, but the provider list could not refresh:"
    ) {
      try await workspace.setFavorite(favorite, modelID: modelID, accountID: accountID)
    }
  }

  func setHidden(_ hidden: Bool, modelID: ModelID, accountID: ProviderAccountID) async {
    await performCommitted(
      warningPrefix: "Model visibility was saved, but the provider list could not refresh:"
    ) {
      try await workspace.setHidden(hidden, modelID: modelID, accountID: accountID)
    }
  }

  func testConnection(accountID: ProviderAccountID, modelID: ModelID?) async -> Bool {
    guard requireProviderAccess(accountID) else { return false }
    let succeeded = await performResult {
      let selectedModelID: ModelID
      if let modelID {
        guard models(for: accountID).contains(where: { $0.model.id == modelID && $0.isAvailable }) else {
          throw ProviderError.modelUnavailable
        }
        selectedModelID = modelID
      } else if let fallback = usableModelID(for: accountID) {
        selectedModelID = fallback
      } else {
        throw ProviderError.invalidModel
      }
      try await runtime.testConnection(accountID: accountID, modelID: selectedModelID)
    }
    MacAppAnalytics.track(
      succeeded ? .connectionTestSucceeded : .connectionTestFailed,
      dimension: .init(providerKind: account(accountID)?.kind ?? .openAICompatible)
    )
    return succeeded
  }

  func revealCredential(accountID: ProviderAccountID) async -> String? {
    guard requireProviderAccess(accountID) else { return nil }
    return (try? await accountManager.resolvedAccount(id: accountID))?.apiKey
  }

  func deleteConnection(_ accountID: ProviderAccountID) async {
    isBusy = true
    errorMessage = nil
    defer { isBusy = false }

    do {
      let cleanupFailures = try await accountManager.deleteAccount(accountID)
      catalogRefreshFailures[accountID] = nil
      var warnings: [String] = []
      if !cleanupFailures.isEmpty {
        warnings.append(ProviderError.credentialCleanupFailed(cleanupFailures).localizedDescription)
      }
      do {
        try await reloadSnapshot()
      } catch {
        MacAppAnalytics.reportError("provider_refresh_failed", component: "provider")
        warnings.append("Connection was deleted, but the provider list could not refresh: \(error.localizedDescription)")
      }
      errorMessage = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
    } catch {
      MacAppAnalytics.reportError("provider_delete_failed", component: "provider")
      errorMessage = error.localizedDescription
    }
  }

  func autoName(for kind: ProviderKind, customBase: String? = nil) -> String {
    let base: String
    if kind == .openAICompatible {
      let custom = customBase?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !custom.isEmpty else { return "" }
      base = custom
    } else {
      base = kind.displayName
    }

    let existing = Set(accounts.map(\.label))
    guard existing.contains(base) else { return base }
    var index = 2
    while existing.contains("\(base) \(index)") { index += 1 }
    return "\(base) \(index)"
  }

  private var effectiveEntitlementAccess: MacProEntitlementAccess {
    entitlementAccessOverride ?? MacProAccess.entitlementAccess
  }

  @discardableResult
  private func requireProviderAccess(_ accountID: ProviderAccountID) -> Bool {
    guard !isProviderRestricted(accountID) else {
      errorMessage = MacProAccess.restoredResourceBlockedMessage("provider connection")
      if effectiveEntitlementAccess == .free {
        MacProGateCenter.shared.request(.providerAccounts)
      }
      return false
    }
    return true
  }

  private func resolveDraftAccountForPreview(
    _ account: ResolvedProviderAccount,
    storedCredentialAccountID: ProviderAccountID?
  ) async throws -> ResolvedProviderAccount {
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
        guard requireProviderAccess(storedCredentialAccountID) else {
          throw ProviderError.invalidRequest(
            MacProAccess.restoredResourceBlockedMessage("provider connection")
          )
        }
        resolved.apiKey = try await accountManager.resolvedAccount(id: storedCredentialAccountID).apiKey
      }
      if definition.requiresCredential {
        guard resolved.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
          throw ProviderError.missingCredential(resolved.providerID)
        }
      }
    }
    return resolved
  }

  private func reloadSnapshot() async throws {
    let registry = self.registry
    let workspace = self.workspace
    let modelCatalog = self.modelCatalog
    let accountManager = self.accountManager

    async let registeredDefinitionsTask = registry.allDefinitions()
    async let workspaceSnapshotTask = workspace.snapshot()
    async let catalogStatusTask = modelCatalog.status()

    let registeredDefinitions = await registeredDefinitionsTask
    let workspaceSnapshot = await workspaceSnapshotTask
    let catalogStatus = await catalogStatusTask

    let loadedAccounts = workspaceSnapshot.accounts.sorted { lhs, rhs in
      if lhs.providerID == rhs.providerID {
        return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
      }
      return lhs.providerID.rawValue < rhs.providerID.rawValue
    }

    var definitionsByID = Dictionary(uniqueKeysWithValues: registeredDefinitions.map { ($0.id, $0) })
    for account in loadedAccounts
    where account.kind == .openAICompatible || definitionsByID[account.providerID] == nil {
      definitionsByID[account.providerID] = account.definition
    }
    definitions = definitionsByID.values.sorted {
      $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }

    let rawGrouped = Dictionary(grouping: workspaceSnapshot.modelRecords, by: \.accountID)
    var records: [ProviderAccountID: [AccountModelRecord]] = [:]
    var visibleRecords: [ProviderAccountID: [AccountModelRecord]] = [:]
    var recordsByID: [ProviderAccountID: [ModelID: AccountModelRecord]] = [:]
    var refreshDates: [ProviderAccountID: Date] = [:]
    records.reserveCapacity(loadedAccounts.count)
    visibleRecords.reserveCapacity(loadedAccounts.count)
    recordsByID.reserveCapacity(loadedAccounts.count)

    let modelSort: (AccountModelRecord, AccountModelRecord) -> Bool = { lhs, rhs in
      if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
      if lhs.isAvailable != rhs.isAvailable { return lhs.isAvailable }
      return lhs.model.displayName.localizedCaseInsensitiveCompare(rhs.model.displayName) == .orderedAscending
    }

    var authAccountIDs: [ProviderAccountID] = []
    authAccountIDs.reserveCapacity(loadedAccounts.count)

    for account in loadedAccounts {
      let sortedAll = (rawGrouped[account.id] ?? []).sorted(by: modelSort)
      records[account.id] = sortedAll
      visibleRecords[account.id] = sortedAll.filter { !$0.isHidden }
      recordsByID[account.id] = Dictionary(
        sortedAll.map { ($0.model.id, $0) },
        uniquingKeysWith: { first, _ in first }
      )
      if let refreshedAt = workspaceSnapshot.lastSuccessfulModelRefreshAt?[account.id.rawValue] {
        refreshDates[account.id] = refreshedAt
      }
      switch account.definition.authentication {
      case .none:
        break
      case .bearer, .header:
        authAccountIDs.append(account.id)
      }
    }

    let credentials: Set<ProviderAccountID> = try await withThrowingTaskGroup(
      of: ProviderAccountID?.self
    ) { group in
      for accountID in authAccountIDs {
        group.addTask {
          try await accountManager.hasCredential(accountID: accountID) ? accountID : nil
        }
      }
      var result: Set<ProviderAccountID> = []
      for try await accountID in group {
        if let accountID { result.insert(accountID) }
      }
      return result
    }

    modelsByAccount = records
    visibleModelsByAccount = visibleRecords
    modelRecordsByAccountAndID = recordsByID
    lastModelRefreshByAccount = refreshDates
    credentialAccountIDs = credentials
    modelCatalogStatus = catalogStatus
    modelCatalogRevision = catalogStatus.revision

    let loadedIDs = loadedAccounts.map(\.id)
    let entitlement = effectiveEntitlementAccess

    func ready(_ account: ProviderAccount) -> Bool {
      guard account.isEnabled else { return false }
      guard !restrictions.isProviderRestricted(
        account.id,
        currentIDs: loadedIDs,
        entitlement: entitlement
      ) else { return false }
      if account.definition.requiresCredential {
        guard credentials.contains(account.id) else { return false }
      }
      return (visibleRecords[account.id] ?? []).contains { $0.isAvailable }
    }

    let storedDefaultID = workspaceSnapshot.defaultAccountID
    if let storedDefaultID,
      let storedDefault = loadedAccounts.first(where: { $0.id == storedDefaultID }),
      ready(storedDefault)
    {
      defaultAccountID = storedDefaultID
    } else {
      defaultAccountID = loadedAccounts.first(where: ready)?.id
    }

    let presentedAccounts = loadedAccounts.map { account -> ProviderAccount in
      var presented = account
      let visibleAvailable = (visibleRecords[account.id] ?? []).filter(\.isAvailable)
      if let defaultModelID = account.defaultModelID,
        visibleAvailable.contains(where: { $0.model.id == defaultModelID })
      {
        presented.defaultModelID = defaultModelID
      } else {
        presented.defaultModelID = visibleAvailable.first?.model.id
      }
      return presented
    }

    accounts = presentedAccounts.sorted { lhs, rhs in
      if lhs.id == defaultAccountID { return true }
      if rhs.id == defaultAccountID { return false }
      return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
    }
  }

  private func usableModelID(for account: ProviderAccount) -> ModelID? {
    let records = models(for: account.id)
    if let defaultModelID = account.defaultModelID,
      records.contains(where: { $0.model.id == defaultModelID && $0.isAvailable })
    {
      return defaultModelID
    }
    return records.first(where: { $0.isAvailable })?.model.id
  }

  private func installConfiguredModels(
    for account: ProviderAccount,
    discoveredModels: [ProviderModel]? = nil,
    manualModelIDs: [String] = []
  ) async throws {
    let catalogToMerge = discoveredModels ?? (account.kind.seedModels.isEmpty ? nil : account.kind.seedModels)
    try await saveModels(
      for: account,
      defaultModelID: account.defaultModelID,
      discoveredModels: catalogToMerge,
      manualModelIDs: manualModelIDs,
      markRefreshed: discoveredModels != nil
    )
    try await installConfiguredSeedModels(for: account)
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
        remapped,
        for: account.id,
        expectedAccount: account,
        markRefreshed: markRefreshed
      )
    }
    let explicitManualIDs = Set(
      manualModelIDs
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .map(ModelID.init(rawValue:))
    )
    var manualIDs = explicitManualIDs
    if let defaultModelID { manualIDs.insert(defaultModelID) }
    for id in manualIDs {
      let record = await workspace.modelRecords(for: account.id, includeHidden: true)
        .first { $0.model.id == id }
      if record?.isAvailable != true || explicitManualIDs.contains(id) {
        try await workspace.addManualModel(
          record?.model ?? ProviderModel(
            providerID: account.providerID,
            id: id,
            displayName: id.rawValue
          ),
          for: account.id
        )
      }
      if record?.isHidden == true {
        try await workspace.setHidden(false, modelID: id, accountID: account.id)
      }
    }
  }

  private func installConfiguredSeedModels(for account: ProviderAccount) async throws {
    guard account.kind == .openAICompatible else { return }
    let existing = await workspace.modelRecords(for: account.id, includeHidden: true)
    for model in account.definition.seedModels {
      if let record = existing.first(where: { $0.model.id == model.id }),
        record.isManual,
        record.isAvailable
      {
        continue
      }
      try await workspace.addManualModel(model, for: account.id)
    }
  }

  private func synchronizeConfiguredSeedModelsForStoredAccounts() async throws {
    for account in await workspace.allAccounts() where account.kind == .openAICompatible {
      try await installConfiguredSeedModels(for: account)
    }
  }

  private func rollbackCreatedAccount(_ accountID: ProviderAccountID) async -> String? {
    do {
      let cleanupFailures = try await accountManager.deleteAccount(accountID)
      guard !cleanupFailures.isEmpty else { return nil }
      return ProviderError.credentialCleanupFailed(cleanupFailures).localizedDescription
    } catch {
      return "The incomplete connection could not be rolled back: \(error.localizedDescription)"
    }
  }

  private func rollbackUpdatedAccount(_ original: ProviderAccount) async -> String? {
    do {
      try await accountManager.updateAccount(original)
      return nil
    } catch {
      return "The previous connection settings could not be restored: \(error.localizedDescription)"
    }
  }

  private func normalizedLabel(_ value: String, kind: ProviderKind) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { return trimmed }
    return autoName(for: kind)
  }

  private func optionalURL(_ value: String, kind: ProviderKind) throws -> URL? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard let url = URL(string: trimmed),
      let scheme = url.scheme?.lowercased(),
      ["http", "https"].contains(scheme),
      let host = url.host, !host.isEmpty
    else {
      throw ProviderError.invalidBaseURL
    }
    return kind.normalizedBaseURL(url)
  }

  private func normalizedPath(_ value: String?, fallback: String) -> String {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else { return fallback }
    return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
  }

  private func normalizedOptionalPath(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else { return nil }
    return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
  }

  private func normalizedSeedModelIDs(_ values: [String]?) -> [String]? {
    guard let values else { return nil }
    var seen: Set<String> = []
    let normalized = values.compactMap { value -> String? in
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
      return trimmed
    }
    return normalized.isEmpty ? nil : normalized
  }

  private func joinedError(primary: String, warning: String?) -> String {
    guard let warning, !warning.isEmpty else { return primary }
    return "\(primary)\n\(warning)"
  }

  private func perform(_ operation: () async throws -> Void) async {
    isBusy = true
    errorMessage = nil
    defer { isBusy = false }
    do {
      try await operation()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func performResult(_ operation: () async throws -> Void) async -> Bool {
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

  private func performCommitted(
    warningPrefix: String,
    _ mutation: () async throws -> Void
  ) async {
    isBusy = true
    errorMessage = nil
    defer { isBusy = false }
    do {
      try await mutation()
    } catch {
      MacAppAnalytics.reportError("provider_operation_failed", component: "provider")
      errorMessage = error.localizedDescription
      return
    }
    do {
      try await reloadSnapshot()
    } catch {
      MacAppAnalytics.reportError("provider_refresh_failed", component: "provider")
      errorMessage = "\(warningPrefix) \(error.localizedDescription)"
    }
  }

  private func performCommittedResult(
    warningPrefix: String,
    _ mutation: () async throws -> Void
  ) async -> Bool {
    isBusy = true
    errorMessage = nil
    defer { isBusy = false }
    do {
      try await mutation()
    } catch {
      MacAppAnalytics.reportError("provider_operation_failed", component: "provider")
      errorMessage = error.localizedDescription
      return false
    }
    do {
      try await reloadSnapshot()
    } catch {
      MacAppAnalytics.reportError("provider_refresh_failed", component: "provider")
      errorMessage = "\(warningPrefix) \(error.localizedDescription)"
    }
    return true
  }
}
