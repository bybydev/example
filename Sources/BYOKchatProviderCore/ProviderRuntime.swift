import Foundation

public actor ProviderAccountManager {
  public static let apiKeyField = "apiKey"
  private let registry: ProviderRegistry
  private let workspace: ProviderWorkspaceStore
  private let vault: any CredentialVault

  public init(
    registry: ProviderRegistry, workspace: ProviderWorkspaceStore, vault: any CredentialVault
  ) {
    self.registry = registry
    self.workspace = workspace
    self.vault = vault
  }

  public func synchronizeCustomProviders() async throws {
    let custom = await workspace.customProviderDefinitions()
    let customIDs = Set(custom.map(\.id))
    for definition in await registry.allDefinitions()
    where !definition.isBuiltIn && !customIDs.contains(definition.id) {
      try await registry.remove(definition.id)
    }
    for definition in custom {
      try await registry.replace(definition)
    }
  }

  @discardableResult
  public func createAccount(
    providerID: ProviderID,
    label: String,
    credential: String?,
    baseURLOverride: URL? = nil,
    additionalHeaders: [String: String] = [:],
    metadata: [String: String] = [:],
    defaultModelID: ModelID? = nil
  ) async throws -> ProviderAccount {
    let definition = try await registry.definition(for: providerID)
    if let baseURLOverride {
      _ = try ProviderHTTP.endpoint(
        baseURL: baseURLOverride,
        path: definition.chatCompletionsPath,
        allowsLocalHTTP: definition.allowsLocalHTTP
      )
    }
    for name in additionalHeaders.keys where ProviderHTTP.isForbiddenCustomHeader(name) {
      throw ProviderError.unsafeHeader(name)
    }
    let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedLabel.isEmpty else {
      throw ProviderError.invalidRequest("Account label cannot be empty.")
    }
    let account = ProviderAccount(
      providerID: providerID,
      label: trimmedLabel,
      baseURLOverride: baseURLOverride,
      additionalHeaders: additionalHeaders,
      metadata: metadata,
      defaultModelID: defaultModelID
    )
    try await workspace.upsertAccount(account)
    do {
      try await vault.setSecret(credential, accountID: account.id, field: Self.apiKeyField)
    } catch {
      try? await workspace.deleteAccount(account.id)
      throw error
    }
    return account
  }

  public func updateAccount(_ account: ProviderAccount) async throws {
    _ = try await registry.definition(for: account.providerID)
    if let url = account.baseURLOverride {
      let definition = try await registry.definition(for: account.providerID)
      _ = try ProviderHTTP.endpoint(
        baseURL: url, path: "/", allowsLocalHTTP: definition.allowsLocalHTTP)
    }
    for name in account.additionalHeaders.keys where ProviderHTTP.isForbiddenCustomHeader(name) {
      throw ProviderError.unsafeHeader(name)
    }
    try await workspace.upsertAccount(account)
  }

  public func setCredential(_ value: String?, accountID: ProviderAccountID) async throws {
    _ = try await workspace.account(id: accountID)
    try await vault.setSecret(value, accountID: accountID, field: Self.apiKeyField)
  }

  public func hasCredential(accountID: ProviderAccountID) async throws -> Bool {
    guard let value = try await vault.secret(accountID: accountID, field: Self.apiKeyField) else {
      return false
    }
    return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  public func resolvedAccount(id: ProviderAccountID) async throws -> ResolvedProviderAccount {
    let account = try await workspace.account(id: id)
    let definition = try await registry.definition(for: account.providerID)
    let secret = try await vault.secret(accountID: id, field: Self.apiKeyField)
    if definition.authentication != .none,
      secret?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    {
      throw ProviderError.missingCredential(account.providerID)
    }
    return .init(
      id: account.id,
      providerID: account.providerID,
      label: account.label,
      apiKey: secret,
      baseURLOverride: account.baseURLOverride,
      additionalHeaders: account.additionalHeaders,
      metadata: account.metadata
    )
  }

  @discardableResult
  public func deleteAccount(_ id: ProviderAccountID) async throws -> [ProviderAccountID] {
    try await workspace.deleteAccount(id)
    return await removeCredentialsBestEffort(accountIDs: [id])
  }

  public func removeAllCredentials() async throws {
    try await removeCredentials(accountIDs: await workspace.allAccounts().map(\.id))
  }

  public func removeCredentials(accountIDs: [ProviderAccountID]) async throws {
    let failures = await removeCredentialsBestEffort(accountIDs: accountIDs)
    guard failures.isEmpty else {
      throw ProviderError.credentialCleanupFailed(failures)
    }
  }

  public func removeCredentialsBestEffort(
    accountIDs: [ProviderAccountID]
  ) async -> [ProviderAccountID] {
    var failures: [ProviderAccountID] = []
    let uniqueIDs = Set(accountIDs).sorted { $0.rawValue < $1.rawValue }
    for accountID in uniqueIDs {
      do {
        try await vault.removeAll(accountID: accountID)
      } catch {
        failures.append(accountID)
      }
    }
    return failures
  }
}

public actor ProviderRuntime {
  private let registry: ProviderRegistry
  private let workspace: ProviderWorkspaceStore
  private let accounts: ProviderAccountManager
  private let transport: any ProviderHTTPTransport

  public init(
    registry: ProviderRegistry,
    workspace: ProviderWorkspaceStore,
    accounts: ProviderAccountManager,
    transport: any ProviderHTTPTransport = URLSessionProviderHTTPTransport()
  ) {
    self.registry = registry
    self.workspace = workspace
    self.accounts = accounts
    self.transport = transport
  }

  public func registerCustomProvider(_ definition: ProviderDefinition) async throws {
    try await workspace.upsertCustomProvider(definition)
    try await registry.replace(definition)
  }

  public func deleteCustomProvider(_ id: ProviderID) async throws {
    try await workspace.deleteCustomProvider(id)
    try await registry.remove(id)
  }

  public func testConnection(accountID: ProviderAccountID, modelID: ModelID? = nil) async throws {
    let stored = try await workspace.account(id: accountID)
    let cachedModels = await workspace.modelRecords(for: accountID)
    let selectedModel = modelID ?? stored.defaultModelID ?? cachedModels.first?.model.id
    guard let selectedModel else { throw ProviderError.invalidModel }
    let resolved = try await accounts.resolvedAccount(id: accountID)
    let adapter = try await adapter(providerID: resolved.providerID)
    try await adapter.testConnection(account: resolved, model: selectedModel)
  }

  @discardableResult
  public func refreshModels(accountID: ProviderAccountID) async throws -> [AccountModelRecord] {
    let resolved = try await accounts.resolvedAccount(id: accountID)
    let adapter = try await adapter(providerID: resolved.providerID)
    let models = try await adapter.listModels(account: resolved)
    try await workspace.mergeModels(models, for: accountID)
    return await workspace.modelRecords(for: accountID)
  }

  public func generate(request: ProviderRequest, accountID: ProviderAccountID) async throws
    -> ProviderResponse
  {
    let resolved = try await accounts.resolvedAccount(id: accountID)
    let selectedAdapter = try await adapter(providerID: resolved.providerID)
    return try await selectedAdapter.generate(request: request, account: resolved)
  }

  public func stream(request: ProviderRequest, accountID: ProviderAccountID) async throws
    -> AsyncThrowingStream<ProviderStreamEvent, Error>
  {
    let resolved = try await accounts.resolvedAccount(id: accountID)
    let selectedAdapter = try await adapter(providerID: resolved.providerID)
    return selectedAdapter.stream(request: request, account: resolved)
  }

  private func adapter(providerID: ProviderID) async throws -> any ProviderAdapter {
    let definition = try await registry.definition(for: providerID)
    switch definition.apiFamily {
    case .openAIChatCompletions:
      return OpenAICompatibleAdapter(definition: definition, transport: transport)
    }
  }
}
