import BYOKchatProviderCore
import Foundation
import Testing

@testable import BYOKchat

@MainActor
@Suite("Provider management defaults")
struct ProviderManagementModelTests {
  @Test("Snapshot default fails over to a ready account without repairing state")
  func failsOverUnusableDefault() async throws {
    let environment = try await makeEnvironment()
    let firstModel = ProviderModel(
      providerID: BuiltInProviders.openAIID,
      id: "first-model",
      displayName: "First Model"
    )
    let secondModel = ProviderModel(
      providerID: BuiltInProviders.anthropicID,
      id: "second-model",
      displayName: "Second Model"
    )

    var first = try await environment.manager.createAccount(
      kind: .openai,
      label: "First",
      credential: "first-key",
      defaultModelID: firstModel.id
    )
    let second = try await environment.manager.createAccount(
      kind: .anthropic,
      label: "Second",
      credential: "second-key",
      defaultModelID: secondModel.id
    )
    try await environment.workspace.mergeModels([firstModel], for: first.id)
    try await environment.workspace.mergeModels([secondModel], for: second.id)
    try await environment.workspace.setDefaultAccount(first.id)

    first.isEnabled = false
    try await environment.manager.updateAccount(first)

    await environment.model.load()
    let storedDefault = await environment.workspace.defaultAccountID()

    #expect(environment.model.errorMessage == nil)
    #expect(environment.model.defaultAccountID == second.id)
    #expect(environment.model.accounts.first?.id == second.id)
    // Failover is in-memory only; the snapshot read does not repair the store.
    #expect(storedDefault == first.id)
  }

  @Test("Hidden default model leaves stored state untouched; chat falls back in memory")
  func hiddenDefaultDoesNotRepairState() async throws {
    let environment = try await makeEnvironment()
    let onlyModel = ProviderModel(
      providerID: BuiltInProviders.openAIID,
      id: "only-model",
      displayName: "Only Model"
    )
    let account = try await environment.manager.createAccount(
      kind: .openai,
      label: "Primary",
      credential: "test-key",
      defaultModelID: onlyModel.id
    )
    try await environment.workspace.mergeModels([onlyModel], for: account.id)
    try await environment.workspace.setHidden(true, modelID: onlyModel.id, accountID: account.id)

    await environment.model.load()
    let storedAccount = try await environment.workspace.account(id: account.id)

    #expect(environment.model.errorMessage == nil)
    #expect(environment.model.accounts.first?.id == account.id)
    // Snapshot resolves to no model (the only one is hidden) but the stored
    // account's default is untouched — the read did not write.
    #expect(storedAccount.defaultModelID == onlyModel.id)
  }

  @Test("Create keeps every discovered model and its metadata across reload")
  func createKeepsDiscovery() async throws {
    let environment = try await makeEnvironment()
    let models = [
      ProviderModel(
        providerID: "preview", id: "vendor/first", displayName: "First",
        contextWindow: 128_000, inputModalities: ["text", "image"],
        promptPricePerToken: "0.000002", completionPricePerToken: "0.000008"),
      ProviderModel(providerID: "preview", id: "vendor/second", displayName: "Second"),
    ]
    let created = await environment.model.createConnection(
      kind: .openRouter, label: "Router", credential: "key",
      baseURL: "", defaultModel: "vendor/first", headers: [:], metadata: [:],
      discoveredModels: models, manualModelIDs: ["manual/third"])
    let id = try #require(created)
    let reloaded = ProviderWorkspaceStore(persistence: environment.persistence)
    try await reloaded.load()
    let records = await reloaded.modelRecords(for: id)
    #expect(Set(records.map { $0.model.id.rawValue }) == ["vendor/first", "vendor/second", "manual/third"])
    let first = try #require(records.first { $0.model.id == "vendor/first" })
    #expect(first.model.providerID == BuiltInProviders.openRouterID)
    #expect(first.model.promptPricePerToken == "0.000002")
    #expect(first.model.completionPricePerToken == "0.000008")
    #expect(first.model.contextWindow == 128_000)
    #expect(first.model.inputModalities.contains("image"))
    #expect(!first.isManual)
    #expect(records.first { $0.model.id == "manual/third" }?.isManual == true)
  }

  @Test("Compatible connection uses its endpoint and is ready without a legacy definition")
  func compatibleConnectionIsReady() async throws {
    let environment = try await makeEnvironment()
    let created = await environment.model.createConnection(
      kind: .openAICompatible, label: "Private server", credential: "",
      baseURL: "http://localhost:11434/v1", defaultModel: "local-model",
      headers: [:], metadata: [:], chatCompletionsPath: "/chat/completions",
      modelsPath: nil, authChoice: ProviderAuthentication.none)
    let id = try #require(created)
    let account = try await environment.workspace.account(id: id)
    #expect(account.baseURLOverride?.absoluteString == "http://localhost:11434/v1")
    #expect(environment.model.provider(for: account.providerID) != nil)
    #expect(environment.model.isReady(account))
    #expect(environment.model.models(for: id).first?.model.id == "local-model")
  }

  @Test("Preview uses draft configuration and does not change stored models")
  func previewDoesNotPersist() async throws {
    let transport = EditorDiscoveryTransport()
    let environment = try await makeEnvironment(transport: transport)
    let account = try await environment.manager.createAccount(
      kind: .openAICompatible, label: "Server", credential: "saved-key",
      modelsPath: "/models", authChoice: .bearer,
      baseURLOverride: URL(string: "https://old.example/v1"), defaultModelID: "old-model")
    try await environment.workspace.addManualModel(
      ProviderModel(providerID: account.providerID, id: "old-model", displayName: "Old"),
      for: account.id)
    let before = await environment.workspace.snapshot()
    var draft = ResolvedProviderAccount(
      kind: account.kind, id: account.id, providerID: account.providerID, label: account.label,
      apiKey: "replacement-key", baseURLOverride: URL(string: "https://new.example/v2"),
      additionalHeaders: ["X-Route": "draft"], modelsPath: "/catalog", authChoice: .bearer)
    let models = try await environment.model.previewModels(
      for: draft, storedCredentialAccountID: account.id)
    #expect(models.first?.id == "new-model")
    let firstRequest = try #require(await transport.lastRequest())
    #expect(firstRequest.url?.absoluteString == "https://new.example/v2/catalog")
    #expect(firstRequest.value(forHTTPHeaderField: "Authorization") == "Bearer replacement-key")
    #expect(firstRequest.value(forHTTPHeaderField: "X-Route") == "draft")
    draft.apiKey = nil
    _ = try await environment.model.previewModels(for: draft, storedCredentialAccountID: account.id)
    let secondRequest = try #require(await transport.lastRequest())
    #expect(secondRequest.value(forHTTPHeaderField: "Authorization") == "Bearer saved-key")
    let after = await environment.workspace.snapshot()
    #expect(after == before)
    let resolved = try await environment.manager.resolvedAccount(id: account.id)
    #expect(resolved.apiKey == "saved-key")
  }

  @Test("Edit saves discovery and manual default while preserving model preferences")
  func editKeepsPreferences() async throws {
    let environment = try await makeEnvironment()
    let created = await environment.model.createConnection(
      kind: .openRouter, label: "Router", credential: "key", baseURL: "",
      defaultModel: "first", headers: [:], metadata: [:],
      discoveredModels: [
        ProviderModel(providerID: "openrouter", id: "first", displayName: "First"),
        ProviderModel(providerID: "openrouter", id: "second", displayName: "Second"),
        ProviderModel(providerID: "openrouter", id: "removed", displayName: "Removed"),
      ])
    let id = try #require(created)
    try await environment.workspace.setFavorite(true, modelID: "first", accountID: id)
    try await environment.workspace.setHidden(true, modelID: "second", accountID: id)
    let succeeded = await environment.model.updateAccount(
      accountID: id, baseURLString: "https://router.example/v1", defaultModelID: "manual",
      discoveredModels: [
        ProviderModel(providerID: "preview", id: "first", displayName: "First",
          promptPricePerToken: "0.000003", completionPricePerToken: "0.000009"),
        ProviderModel(providerID: "preview", id: "second", displayName: "Second"),
      ], manualModelIDs: ["manual"])
    #expect(succeeded)
    let reloaded = ProviderWorkspaceStore(persistence: environment.persistence)
    try await reloaded.load()
    let records = await reloaded.modelRecords(for: id, includeHidden: true)
    #expect(records.first { $0.model.id == "first" }?.isFavorite == true)
    #expect(records.first { $0.model.id == "first" }?.model.promptPricePerToken == "0.000003")
    #expect(records.first { $0.model.id == "second" }?.isHidden == true)
    #expect(records.first { $0.model.id == "removed" }?.isAvailable == true)
    #expect(records.first { $0.model.id == "manual" }?.isManual == true)
    let account = try await reloaded.account(id: id)
    #expect(account.defaultModelID == "manual")
  }

  @Test("Exact model IDs saved from composer do not replace the provider default")
  func composerCustomModelIsStoredWithoutChangingDefault() async throws {
    let environment = try await makeEnvironment()
    let created = await environment.model.createConnection(
      kind: .deepSeek, label: "DeepSeek", credential: "key", baseURL: "",
      defaultModel: "old-model", headers: [:], metadata: [:]
    )
    let id = try #require(created)
    try await environment.model.ensureSelectableModel("brand-new-model", for: id)
    let records = await environment.workspace.modelRecords(for: id)
    #expect(records.contains(where: { $0.model.id == "brand-new-model" && $0.isManual }))
    let account = try await environment.workspace.account(id: id)
    #expect(account.defaultModelID == "old-model")
  }

  @Test("Provider editor removes a manual ID after choosing another default")
  func editingRemovesManualModels() async throws {
    let environment = try await makeEnvironment()
    let created = await environment.model.createConnection(
      kind: .deepSeek, label: "DeepSeek", credential: "key", baseURL: "",
      defaultModel: "old-custom", headers: [:], metadata: [:],
      manualModelIDs: ["old-custom", "new-custom"]
    )
    let id = try #require(created)
    let succeeded = await environment.model.updateAccount(
      accountID: id, defaultModelID: "new-custom",
      removedManualModelIDs: ["old-custom"]
    )
    #expect(succeeded)
    let records = await environment.workspace.modelRecords(for: id)
    #expect(!records.contains(where: { $0.model.id == "old-custom" }))
    #expect(records.contains(where: { $0.model.id == "new-custom" }))
    let account = try await environment.workspace.account(id: id)
    #expect(account.defaultModelID == "new-custom")
  }

  @Test("Recently saved discovery skips network refresh")
  func freshCatalogUsesCache() async throws {
    let environment = try await makeEnvironment()
    let created = await environment.model.createConnection(
      kind: .deepSeek, label: "DeepSeek", credential: "key", baseURL: "",
      defaultModel: "deepseek-chat", headers: [:], metadata: [:],
      discoveredModels: [
        ProviderModel(providerID: BuiltInProviders.deepSeekID,
          id: "deepseek-chat", displayName: "DeepSeek Chat")
      ]
    )
    let id = try #require(created)
    let outcome = try await environment.model.refreshCatalog(accountID: id)
    #expect(outcome == .current)
  }

  @Test("Two refresh requests for the same account share one network request")
  func catalogRefreshDeduplicates() async throws {
    let transport = EditorDiscoveryTransport()
    let environment = try await makeEnvironment(transport: transport)
    let created = await environment.model.createConnection(
      kind: .deepSeek, label: "DeepSeek", credential: "key", baseURL: "",
      defaultModel: "deepseek-chat", headers: [:], metadata: [:]
    )
    let id = try #require(created)
    async let first = environment.model.refreshCatalog(accountID: id, force: true)
    async let second = environment.model.refreshCatalog(accountID: id, force: true)
    let (firstOutcome, secondOutcome) = try await (first, second)
    #expect(firstOutcome == .refreshed)
    #expect(secondOutcome == .refreshed)
    let requestCount = await transport.callCount()
    #expect(requestCount == 1)
    let stored = await environment.workspace.modelRecords(for: id)
    #expect(stored.contains(where: { $0.model.id == "new-model" }))
    #expect(environment.model.errorMessage == nil)
  }

  private func makeEnvironment(
    transport: any ProviderHTTPTransport = URLSessionProviderHTTPTransport()
  ) async throws -> (
    model: ProviderManagementModel,
    workspace: ProviderWorkspaceStore,
    manager: ProviderAccountManager,
    persistence: InMemoryProviderWorkspacePersistence
  ) {
    let registry = try ProviderRegistry.builtIn()
    let persistence = InMemoryProviderWorkspacePersistence()
    let workspace = ProviderWorkspaceStore(persistence: persistence)
    try await workspace.load()
    let vault = InMemoryCredentialVault()
    let manager = ProviderAccountManager(
      registry: registry,
      workspace: workspace,
      vault: vault
    )
    let runtime = ProviderRuntime(
      registry: registry,
      workspace: workspace,
      accounts: manager,
      transport: transport
    )
    let model = ProviderManagementModel(
      registry: registry,
      workspace: workspace,
      accountManager: manager,
      runtime: runtime
    )
    return (model, workspace, manager, persistence)
  }
}

@Suite("Provider logo catalog")
struct ProviderLogoCatalogTests {
  @Test("Built-in providers use their canonical asset")
  func builtInProvider() {
    #expect(
      ProviderLogoCatalog.assetName(for: BuiltInProviders.anthropic)
        == "provider.anthropic")
    #expect(
      ProviderLogoCatalog.assetName(for: BuiltInProviders.zAI)
        == "provider.zai")
    #expect(
      ProviderLogoCatalog.assetName(for: BuiltInProviders.moonshot)
        == "provider.moonshot")
    #expect(
      ProviderLogoCatalog.assetName(for: BuiltInProviders.minimax)
        == "provider.minimax")
    #expect(
      ProviderLogoCatalog.assetName(for: BuiltInProviders.mistral)
        == "provider.mistral")
  }

  @Test("Custom provider name resolves a prepared brand")
  func customProviderName() {
    let definition = customDefinition(name: "My Together AI")
    #expect(ProviderLogoCatalog.assetName(for: definition) == "provider.together")
  }

  @Test("Custom endpoint resolves a prepared brand")
  func customProviderEndpoint() {
    let definition = customDefinition(name: "Fast inference", url: "https://api.groq.com/openai/v1")
    #expect(ProviderLogoCatalog.assetName(for: definition) == "provider.groq")
  }

  @Test("Unknown custom provider keeps the monogram fallback")
  func unknownProvider() {
    let definition = customDefinition(name: "Private Lab")
    #expect(ProviderLogoCatalog.assetName(for: definition) == nil)
  }

  private func customDefinition(
    name: String,
    url: String = "https://inference.example.com/v1"
  ) -> ProviderDefinition {
    ProviderDefinition(
      id: "custom-provider",
      displayName: name,
      behavior: .genericOpenAICompatible,
      defaultBaseURL: URL(string: url)!
    )
  }
}

private actor EditorDiscoveryTransport: ProviderHTTPTransport {
  private var request: URLRequest?
  private var calls = 0

  func lastRequest() -> URLRequest? { request }
  func callCount() -> Int { calls }

  func data(for request: URLRequest) async throws -> ProviderHTTPResponse {
    self.request = request
    calls += 1
    try await Task.sleep(for: .milliseconds(50))
    return ProviderHTTPResponse(
      statusCode: 200, headers: [:],
      data: Data(#"{"data":[{"id":"new-model","name":"New Model"}]}"#.utf8))
  }

  func stream(for request: URLRequest) async throws -> ProviderHTTPByteStream {
    throw ProviderError.invalidResponse
  }
}

@MainActor
@Suite("Composer target picker layout")
struct TargetPickerLayoutTests {
  @Test("Five or fewer models stay inline and larger catalogs push the selection list")
  func adaptivePickerThreshold() {
    #expect(TargetPickerLayout.showsInlineModels(count: 0))
    #expect(TargetPickerLayout.showsInlineModels(count: 1))
    #expect(TargetPickerLayout.showsInlineModels(count: 5))
    #expect(!TargetPickerLayout.showsInlineModels(count: 6))
    #expect(!TargetPickerLayout.showsInlineModels(count: 100))
  }
}
