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
  private(set) var definitions: [ProviderDefinition] = []
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
  private let restrictions: MacProResourceRestrictions
  private let entitlementAccessOverride: MacProEntitlementAccess?

  init(
    services: BYOKCoreServices,
    restrictions: MacProResourceRestrictions = MacPurchaseStore.restrictions,
    entitlementAccessOverride: MacProEntitlementAccess? = nil
  ) {
    registry = services.providerRegistry
    workspace = services.providerWorkspace
    accountManager = services.accountManager
    runtime = services.providerRuntime
    self.restrictions = restrictions
    self.entitlementAccessOverride = entitlementAccessOverride
  }

  func load() async throws {
    try await workspace.load()
    try await accountManager.synchronizeCustomProviders()
    try await synchronizeConfiguredSeedModelsForStoredAccounts()
    try await reloadSnapshot()
  }

  func reload() async {
    await perform {
      try await accountManager.synchronizeCustomProviders()
      try await synchronizeConfiguredSeedModelsForStoredAccounts()
      try await reloadSnapshot()
    }
  }

  func provider(for id: ProviderID) -> ProviderDefinition? {
    definitions.first { $0.id == id }
  }

  func account(_ id: ProviderAccountID?) -> ProviderAccount? {
    guard let id else { return nil }
    return accounts.first { $0.id == id }
  }

  func models(for accountID: ProviderAccountID, includeHidden: Bool = false) -> [AccountModelRecord] {
    let records = modelsByAccount[accountID] ?? []
    let visible = includeHidden ? records : records.filter { !$0.isHidden }
    return visible.sorted { lhs, rhs in
      if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
      if lhs.isAvailable != rhs.isAvailable { return lhs.isAvailable }
      return lhs.model.displayName.localizedCaseInsensitiveCompare(rhs.model.displayName) == .orderedAscending
    }
  }

  func usableModelID(for accountID: ProviderAccountID) -> ModelID? {
    guard let account = account(accountID) else { return nil }
    return usableModelID(for: account)
  }

  func capabilities(accountID: ProviderAccountID, modelID: ModelID) -> ResolvedModelCapabilities {
    let record = models(for: accountID, includeHidden: true).first { $0.model.id == modelID }
    return ModelCapabilityResolver.resolve(kind: account(accountID)?.kind ?? .openAICompatible,
      modelID: modelID, model: record?.model)
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
    switch account.definition.authentication {
    case .none:
      break
    case .bearer, .header:
      guard credentialAccountIDs.contains(account.id) else { return false }
    }
    return models(for: account.id).contains { $0.isAvailable }
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
    seedModelIDs: [String]? = nil
  ) async -> ProviderAccountID? {
    guard MacProAccess.requireProviderAccountCapacity(currentCount: accounts.count) else {
      errorMessage = "Free includes 1 provider connection. Upgrade to BYOK Pro to add more."
      return nil
    }

    isBusy = true
    errorMessage = nil
    defer { isBusy = false }

    let account: ProviderAccount
    do {
      let trimmedCredential = credential.trimmingCharacters(in: .whitespacesAndNewlines)
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
        baseURLOverride: try optionalURL(baseURL),
        additionalHeaders: headers,
        metadata: metadata,
        defaultModelID: defaultModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? nil
          : ModelID(rawValue: defaultModel.trimmingCharacters(in: .whitespacesAndNewlines))
      )
    } catch {
      MacAppAnalytics.reportError("provider_save_failed", component: "provider")
      errorMessage = error.localizedDescription
      return nil
    }

    do {
      try await installConfiguredModels(for: account)
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
    return account.id
  }

  func updateConnection(
    accountID: ProviderAccountID,
    label: String,
    newCredential: String?,
    baseURL: String,
    headers: [String: String],
    metadata: [String: String],
    chatCompletionsPath: String?,
    modelsPath: String?,
    authChoice: ProviderAuthentication?,
    seedModelIDs: [String]?
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

    var updated = original
    let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedLabel.isEmpty else {
      errorMessage = ProviderError.invalidRequest("Connection name cannot be empty.").localizedDescription
      return false
    }

    do {
      updated.label = trimmedLabel
      updated.baseURLOverride = try optionalURL(baseURL)
      updated.additionalHeaders = headers
      updated.metadata = metadata
      if updated.kind == .openAICompatible {
        updated.chatCompletionsPath = normalizedPath(chatCompletionsPath, fallback: "/chat/completions")
        updated.modelsPath = normalizedOptionalPath(modelsPath)
        updated.authChoice = authChoice ?? .bearer
        updated.seedModelIDs = normalizedSeedModelIDs(seedModelIDs)
      }
      try await accountManager.updateAccount(updated)
    } catch {
      MacAppAnalytics.reportError("provider_update_failed", component: "provider")
      errorMessage = error.localizedDescription
      return false
    }

    if let newCredential {
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
    do {
      try await installConfiguredSeedModels(for: updated)
    } catch {
      MacAppAnalytics.reportError("provider_model_sync_failed", component: "provider")
      warnings.append("Connection changes were saved, but seed models could not be synchronized: \(error.localizedDescription)")
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

  func refreshModels(accountID: ProviderAccountID) async -> Bool {
    guard requireProviderAccess(accountID) else { return false }
    return await performCommittedResult(
      warningPrefix: "Models were refreshed, but the provider list could not refresh:"
    ) {
      _ = try await runtime.refreshModels(accountID: accountID)
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
    return await performResult {
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

  private func reloadSnapshot() async throws {
    definitions = await registry.allDefinitions()
    let loadedAccounts = await workspace.allAccounts()

    var records: [ProviderAccountID: [AccountModelRecord]] = [:]
    var credentials: Set<ProviderAccountID> = []
    for account in loadedAccounts {
      records[account.id] = await workspace.modelRecords(for: account.id, includeHidden: true)
      switch account.definition.authentication {
      case .none:
        break
      case .bearer, .header:
        if try await accountManager.hasCredential(accountID: account.id) {
          credentials.insert(account.id)
        }
      }
    }

    modelsByAccount = records
    credentialAccountIDs = credentials

    func ready(_ account: ProviderAccount) -> Bool {
      guard account.isEnabled else { return false }
      switch account.definition.authentication {
      case .none:
        break
      case .bearer, .header:
        guard credentials.contains(account.id) else { return false }
      }
      return (records[account.id] ?? []).contains { $0.isAvailable && !$0.isHidden }
    }

    let storedDefaultID = await workspace.defaultAccountID()
    if let storedDefaultID,
      let storedDefault = loadedAccounts.first(where: { $0.id == storedDefaultID }),
      ready(storedDefault)
    {
      defaultAccountID = storedDefaultID
    } else {
      defaultAccountID = loadedAccounts.first(where: ready)?.id
        ?? loadedAccounts.first(where: \.isEnabled)?.id
        ?? loadedAccounts.first?.id
    }

    let presentedAccounts = loadedAccounts.map { account -> ProviderAccount in
      var presented = account
      let visibleAvailable = (records[account.id] ?? [])
        .filter { $0.isAvailable && !$0.isHidden }
        .sorted { lhs, rhs in
          if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
          return lhs.model.displayName.localizedCaseInsensitiveCompare(rhs.model.displayName) == .orderedAscending
        }
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

  private func installConfiguredModels(for account: ProviderAccount) async throws {
    if !account.kind.seedModels.isEmpty {
      try await workspace.mergeModels(account.kind.seedModels, for: account.id)
    }
    try await installConfiguredSeedModels(for: account)

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

  private func optionalURL(_ value: String) throws -> URL? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
      throw ProviderError.invalidBaseURL
    }
    return url
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
