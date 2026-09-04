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

  init(services: BYOKCoreServices) {
    registry = services.providerRegistry
    workspace = services.providerWorkspace
    accountManager = services.accountManager
    runtime = services.providerRuntime
  }

  func load() async throws {
    try await workspace.load()
    try await accountManager.synchronizeCustomProviders()
    try await reloadSnapshot()
  }

  func reload() async {
    await perform {
      try await accountManager.synchronizeCustomProviders()
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

  func reasoningDefault(for accountID: ProviderAccountID?) -> ReasoningOptions? {
    account(accountID)?.kind.reasoningDefault
  }

  func supportsReasoning(accountID: ProviderAccountID, modelID: ModelID) -> Bool {
    guard let record = models(for: accountID, includeHidden: true).first(where: { $0.model.id == modelID })
    else { return false }
    let parameters = record.model.supportedParameters
    return !parameters.isDisjoint(with: [
      "reasoning", "thinking", "reasoning_effort", "thinkingConfig", "effort",
    ])
  }

  var resolvedDefaultAccount: ProviderAccount? {
    defaultAccountID.flatMap { id in accounts.first { $0.id == id } }
  }

  func preferredTarget() -> MacChatTarget? {
    let candidates = accounts.filter { isReady($0) }
    guard let account = resolvedDefaultAccount.flatMap({ isReady($0) ? $0 : nil }) ?? candidates.first else {
      return nil
    }
    guard let modelID = account.defaultModelID
      ?? models(for: account.id).first(where: { $0.isAvailable })?.model.id
    else { return nil }
    return MacChatTarget(
      accountID: account.id,
      modelID: modelID,
      reasoning: supportsReasoning(accountID: account.id, modelID: modelID)
        ? account.kind.reasoningDefault
        : nil
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
    isBusy = true
    errorMessage = nil
    defer { isBusy = false }

    do {
      let account = try await accountManager.createAccount(
        kind: kind,
        label: normalizedLabel(label, kind: kind),
        credential: credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : credential,
        chatCompletionsPath: kind == .openAICompatible
          ? normalizedPath(chatCompletionsPath, fallback: "/chat/completions")
          : nil,
        modelsPath: kind == .openAICompatible ? normalizedOptionalPath(modelsPath) : nil,
        authChoice: kind == .openAICompatible ? authChoice : nil,
        seedModelIDs: kind == .openAICompatible ? seedModelIDs : nil,
        baseURLOverride: try optionalURL(baseURL),
        additionalHeaders: headers,
        metadata: metadata,
        defaultModelID: defaultModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? nil
          : ModelID(rawValue: defaultModel.trimmingCharacters(in: .whitespacesAndNewlines))
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
    await performResult {
      var account = try await workspace.account(id: accountID)
      let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedLabel.isEmpty else {
        throw ProviderError.invalidRequest("Connection name cannot be empty.")
      }

      account.label = trimmedLabel
      account.baseURLOverride = try optionalURL(baseURL)
      account.additionalHeaders = headers
      account.metadata = metadata
      if account.kind == .openAICompatible {
        account.chatCompletionsPath = normalizedPath(chatCompletionsPath, fallback: "/chat/completions")
        account.modelsPath = normalizedOptionalPath(modelsPath)
        account.authChoice = authChoice ?? .bearer
        account.seedModelIDs = seedModelIDs
      }
      try await accountManager.updateAccount(account)
      if let newCredential, !newCredential.isEmpty {
        try await accountManager.setCredential(newCredential, accountID: accountID)
      }
      try await accountManager.synchronizeCustomProviders()
      try await reloadSnapshot()
    }
  }

  func setAccountEnabled(_ enabled: Bool, accountID: ProviderAccountID) async -> Bool {
    await performResult {
      var account = try await workspace.account(id: accountID)
      account.isEnabled = enabled
      try await accountManager.updateAccount(account)
      try await reloadSnapshot()
    }
  }

  func setDefaultAccount(_ accountID: ProviderAccountID) async -> Bool {
    await performResult {
      let account = try await workspace.account(id: accountID)
      guard isReady(account) else {
        throw ProviderError.invalidRequest("This connection needs an available model and credential first.")
      }
      try await workspace.setDefaultAccount(accountID)
      try await reloadSnapshot()
    }
  }

  func setDefaultModel(_ modelID: ModelID, accountID: ProviderAccountID) async -> Bool {
    await performResult {
      var account = try await workspace.account(id: accountID)
      account.defaultModelID = modelID
      try await accountManager.updateAccount(account)
      try await reloadSnapshot()
    }
  }

  func refreshModels(accountID: ProviderAccountID) async -> Bool {
    await performResult {
      _ = try await runtime.refreshModels(accountID: accountID)
      try await reloadSnapshot()
    }
  }

  func addManualModel(_ value: String, accountID: ProviderAccountID) async -> Bool {
    await performResult {
      let account = try await workspace.account(id: accountID)
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { throw ProviderError.invalidModel }
      try await workspace.addManualModel(
        ProviderModel(providerID: account.providerID, id: ModelID(rawValue: trimmed), displayName: trimmed),
        for: accountID
      )
      try await reloadSnapshot()
    }
  }

  func setFavorite(_ favorite: Bool, modelID: ModelID, accountID: ProviderAccountID) async {
    await perform {
      try await workspace.setFavorite(favorite, modelID: modelID, accountID: accountID)
      try await reloadSnapshot()
    }
  }

  func setHidden(_ hidden: Bool, modelID: ModelID, accountID: ProviderAccountID) async {
    await perform {
      try await workspace.setHidden(hidden, modelID: modelID, accountID: accountID)
      try await reloadSnapshot()
    }
  }

  func testConnection(accountID: ProviderAccountID, modelID: ModelID?) async -> Bool {
    await performResult {
      try await runtime.testConnection(accountID: accountID, modelID: modelID)
    }
  }

  func revealCredential(accountID: ProviderAccountID) async -> String? {
    (try? await accountManager.resolvedAccount(id: accountID))?.apiKey
  }

  func deleteConnection(_ accountID: ProviderAccountID) async {
    await perform {
      let cleanupFailures = try await accountManager.deleteAccount(accountID)
      try await reloadSnapshot()
      guard cleanupFailures.isEmpty else {
        throw ProviderError.credentialCleanupFailed(cleanupFailures)
      }
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

  private func reloadSnapshot() async throws {
    definitions = await registry.allDefinitions()
    let loadedAccounts = await workspace.allAccounts()

    var records: [ProviderAccountID: [AccountModelRecord]] = [:]
    var credentials: Set<ProviderAccountID> = []
    for account in loadedAccounts {
      records[account.id] = await workspace.modelRecords(for: account.id, includeHidden: true)
      if try await accountManager.hasCredential(accountID: account.id) {
        credentials.insert(account.id)
      }
    }

    modelsByAccount = records
    credentialAccountIDs = credentials

    var credentialRequiredByProvider: [ProviderID: Bool] = [:]
    for definition in definitions {
      switch definition.authentication {
      case .none:
        credentialRequiredByProvider[definition.id] = false
      case .bearer, .header:
        credentialRequiredByProvider[definition.id] = true
      }
    }

    defaultAccountID = await workspace.resolvedDefaultAccountID(
      credentialRequiredByProvider: credentialRequiredByProvider,
      credentialAccountIDs: credentials
    )

    accounts = loadedAccounts.sorted { lhs, rhs in
      if lhs.id == defaultAccountID { return true }
      if rhs.id == defaultAccountID { return false }
      return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
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
}
