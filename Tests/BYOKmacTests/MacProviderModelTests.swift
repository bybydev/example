import BYOKchatProviderCore
import Foundation
import Testing

@testable import BYOKmac

@MainActor
@Suite("macOS provider and model workflows", .serialized)
struct MacProviderModelTests {
  @Test("Unavailable stored default model falls back in memory without rewriting persistence")
  func staleDefaultModelFallsBackInMemory() async throws {
    let context = try await makeMacProviderTestContext()
    defer { context.cleanup() }

    let staleModel = ProviderModel(
      providerID: ProviderKind.deepSeek.defaultProviderID!,
      id: "stale-model",
      displayName: "Stale"
    )
    let availableModel = ProviderModel(
      providerID: ProviderKind.deepSeek.defaultProviderID!,
      id: "available-model",
      displayName: "Available"
    )
    let account = try await context.services.accountManager.createAccount(
      kind: .deepSeek,
      label: "DeepSeek",
      credential: "test-key",
      defaultModelID: staleModel.id
    )
    try await context.services.providerWorkspace.mergeModels(
      [staleModel, availableModel],
      for: account.id
    )
    try await context.services.providerWorkspace.mergeModels(
      [availableModel],
      for: account.id
    )

    let model = MacProviderModel(services: context.services)
    try await model.load()

    #expect(model.account(account.id)?.defaultModelID == availableModel.id)
    #expect(model.preferredTarget()?.modelID == availableModel.id)
    #expect((try await context.services.providerWorkspace.account(id: account.id)).defaultModelID == staleModel.id)
  }

  @Test("Hiding the stored default immediately falls back to another available model")
  func hiddenDefaultModelFallsBack() async throws {
    let context = try await makeMacProviderTestContext()
    defer { context.cleanup() }

    let first = ProviderModel(
      providerID: ProviderKind.deepSeek.defaultProviderID!,
      id: "first-model",
      displayName: "First"
    )
    let second = ProviderModel(
      providerID: ProviderKind.deepSeek.defaultProviderID!,
      id: "second-model",
      displayName: "Second"
    )
    let account = try await context.services.accountManager.createAccount(
      kind: .deepSeek,
      label: "DeepSeek",
      credential: "test-key",
      defaultModelID: first.id
    )
    try await context.services.providerWorkspace.mergeModels([first, second], for: account.id)

    let model = MacProviderModel(services: context.services)
    try await model.load()
    #expect(model.preferredTarget()?.modelID == first.id)

    await model.setHidden(true, modelID: first.id, accountID: account.id)

    #expect(model.preferredTarget()?.modelID == second.id)
    #expect(model.account(account.id)?.defaultModelID == second.id)
    #expect((try await context.services.providerWorkspace.account(id: account.id)).defaultModelID == first.id)
  }

  @Test("No-auth OpenAI-compatible seed connection is ready and can remain the global default")
  func noAuthSeedConnectionIsReadyDefault() async throws {
    let context = try await makeMacProviderTestContext()
    defer { context.cleanup() }

    let fallback = try await context.services.accountManager.createAccount(
      kind: .deepSeek,
      label: "Fallback",
      credential: "test-key",
      defaultModelID: "deepseek-chat"
    )
    try await context.services.providerWorkspace.mergeModels(
      [
        ProviderModel(
          providerID: fallback.providerID,
          id: "deepseek-chat",
          displayName: "DeepSeek Chat"
        )
      ],
      for: fallback.id
    )

    let local = try await context.services.accountManager.createAccount(
      kind: .openAICompatible,
      label: "Local",
      credential: nil,
      chatCompletionsPath: "/chat/completions",
      modelsPath: nil,
      authChoice: .none,
      seedModelIDs: ["local-model"],
      baseURLOverride: URL(string: "https://local.example.test/v1")
    )
    try await context.services.providerWorkspace.setDefaultAccount(local.id)

    let model = MacProviderModel(services: context.services)
    try await model.load()
    let localAccount = try #require(model.account(local.id))

    #expect(model.defaultAccountID == local.id)
    #expect(model.isReady(localAccount))
    #expect(model.preferredTarget()?.accountID == local.id)
    #expect(model.preferredTarget()?.modelID == ModelID(rawValue: "local-model"))
    #expect(model.models(for: local.id).contains { $0.model.id == ModelID(rawValue: "local-model") })
  }

  @Test("Creating a custom seed-only connection installs its models immediately")
  func createSeedOnlyConnectionInstallsModels() async throws {
    let context = try await makeMacProviderTestContext()
    defer { context.cleanup() }

    let model = MacProviderModel(services: context.services)
    try await model.load()

    let accountID = await model.createConnection(
      kind: .openAICompatible,
      label: "Local Server",
      credential: "",
      baseURL: "https://local.example.test/v1",
      defaultModel: "",
      headers: [:],
      metadata: [:],
      chatCompletionsPath: "/chat/completions",
      modelsPath: nil,
      authChoice: .none,
      seedModelIDs: ["local-a", "local-b", "local-a"]
    )
    let accountID = try #require(accountID)

    let ids = Set(model.models(for: accountID).map(\.model.id))
    let expected: Set<ModelID> = ["local-a", "local-b"]
    #expect(ids == expected)
    #expect(model.preferredTarget()?.accountID == accountID)
    #expect(model.preferredTarget()?.modelID != nil)
    #expect(model.errorMessage == nil)
  }

  @Test("Editing custom seed models installs newly configured model IDs")
  func updateSeedModelsSynchronizesAddedIDs() async throws {
    let context = try await makeMacProviderTestContext()
    defer { context.cleanup() }

    let model = MacProviderModel(services: context.services)
    try await model.load()
    let createdID = await model.createConnection(
      kind: .openAICompatible,
      label: "Local Server",
      credential: "",
      baseURL: "https://local.example.test/v1",
      defaultModel: "",
      headers: [:],
      metadata: [:],
      chatCompletionsPath: "/chat/completions",
      modelsPath: nil,
      authChoice: .none,
      seedModelIDs: ["model-a"]
    )
    let accountID = try #require(createdID)

    let succeeded = await model.updateConnection(
      accountID: accountID,
      label: "Local Server",
      newCredential: nil,
      baseURL: "https://local.example.test/v1",
      headers: [:],
      metadata: [:],
      chatCompletionsPath: "/chat/completions",
      modelsPath: nil,
      authChoice: .none,
      seedModelIDs: ["model-a", "model-b"]
    )

    #expect(succeeded)
    #expect(model.models(for: accountID).contains { $0.model.id == ModelID(rawValue: "model-b") })

    // Removing a seed model from seedModelIDs deletes its manual model record on save.
    let pruned = await model.updateConnection(
      accountID: accountID,
      label: "Local Server",
      newCredential: nil,
      baseURL: "https://local.example.test/v1",
      headers: [:],
      metadata: [:],
      chatCompletionsPath: "/chat/completions",
      modelsPath: nil,
      authChoice: .none,
      seedModelIDs: ["model-b"]
    )
    #expect(pruned)
    #expect(!model.models(for: accountID, includeHidden: true).contains { $0.model.id == ModelID(rawValue: "model-a") })
    #expect(model.models(for: accountID).contains { $0.model.id == ModelID(rawValue: "model-b") })
  }

  @Test("Credential update failure restores the previous provider configuration")
  func credentialFailureRollsBackConfiguration() async throws {
    let vault = FailingMacProviderCredentialVault()
    let context = try await makeMacProviderTestContext(credentialVault: vault)
    defer { context.cleanup() }

    let account = try await context.services.accountManager.createAccount(
      kind: .deepSeek,
      label: "Original",
      credential: "old-key",
      defaultModelID: "deepseek-chat"
    )
    try await context.services.providerWorkspace.mergeModels(
      [
        ProviderModel(
          providerID: account.providerID,
          id: "deepseek-chat",
          displayName: "DeepSeek Chat"
        )
      ],
      for: account.id
    )

    let model = MacProviderModel(services: context.services)
    try await model.load()
    await vault.failNextSet()

    let succeeded = await model.updateConnection(
      accountID: account.id,
      label: "Changed",
      newCredential: "new-key",
      baseURL: "",
      headers: ["X-Test": "changed"],
      metadata: ["changed": "true"],
      chatCompletionsPath: nil,
      modelsPath: nil,
      authChoice: nil,
      seedModelIDs: nil
    )

    #expect(!succeeded)
    let stored = try await context.services.providerWorkspace.account(id: account.id)
    #expect(stored.label == "Original")
    #expect(stored.additionalHeaders.isEmpty)
    #expect(stored.metadata.isEmpty)
    #expect((try await context.services.accountManager.resolvedAccount(id: account.id)).apiKey == "old-key")
    #expect(model.errorMessage != nil)
  }

  @Test("Model boundary rejects unavailable models as defaults")
  func unavailableModelCannotBecomeDefault() async throws {
    let context = try await makeMacProviderTestContext()
    defer { context.cleanup() }

    let available = ProviderModel(
      providerID: ProviderKind.deepSeek.defaultProviderID!,
      id: "available-model",
      displayName: "Available"
    )
    let unavailable = ProviderModel(
      providerID: ProviderKind.deepSeek.defaultProviderID!,
      id: "unavailable-model",
      displayName: "Unavailable"
    )
    let account = try await context.services.accountManager.createAccount(
      kind: .deepSeek,
      label: "DeepSeek",
      credential: "test-key",
      defaultModelID: available.id
    )
    try await context.services.providerWorkspace.mergeModels([available, unavailable], for: account.id)
    try await context.services.providerWorkspace.mergeModels([available], for: account.id)

    let model = MacProviderModel(services: context.services)
    try await model.load()

    #expect(!(await model.setDefaultModel(unavailable.id, accountID: account.id)))
    #expect((try await context.services.providerWorkspace.account(id: account.id)).defaultModelID == available.id)
  }

  @Test("Ollama connection is ready without an API key and normalizes /v1 base URL")
  func ollamaConnectionIsReadyWithoutCredentialAndNormalizesBaseURL() async throws {
    let context = try await makeMacProviderTestContext()
    defer { context.cleanup() }

    let model = MacProviderModel(services: context.services)
    try await model.load()

    let createdID = await model.createConnection(
      kind: .ollama,
      label: "LAN Ollama",
      credential: "",
      baseURL: "http://192.168.1.50:11434",
      defaultModel: "llama3.2",
      headers: [:],
      metadata: [:]
    )
    let accountID = try #require(createdID)
    let account = try #require(model.account(accountID))

    #expect(account.baseURLOverride == URL(string: "http://192.168.1.50:11434/v1"))
    #expect(!model.hasCredential(accountID))
    #expect(model.isReady(account))
    #expect(macProviderPresentationState(model: model, account: account) == .ready)
    #expect(model.preferredTarget()?.accountID == accountID)
  }

  @Test("Optional credentials can be removed and switching custom auth to none clears stored secrets")
  func optionalCredentialRemovalAndAuthNoneCleanup() async throws {
    let context = try await makeMacProviderTestContext()
    defer { context.cleanup() }

    let model = MacProviderModel(services: context.services)
    try await model.load()

    let createdID = await model.createConnection(
      kind: .openAICompatible,
      label: "Custom LAN",
      credential: "optional-secret",
      baseURL: "http://192.168.1.60:8000/v1",
      defaultModel: "",
      headers: [:],
      metadata: [:],
      chatCompletionsPath: "/chat/completions",
      modelsPath: nil,
      authChoice: .bearer,
      seedModelIDs: ["local-1"]
    )
    let accountID = try #require(createdID)
    #expect(model.hasCredential(accountID))

    let cleared = await model.updateConnection(
      accountID: accountID,
      label: "Custom LAN",
      newCredential: nil,
      clearCredential: true,
      baseURL: "http://192.168.1.60:8000/v1",
      headers: [:],
      metadata: [:],
      chatCompletionsPath: "/chat/completions",
      modelsPath: nil,
      authChoice: .bearer,
      seedModelIDs: ["local-1"]
    )
    #expect(cleared)
    #expect(!model.hasCredential(accountID))
    let afterClear = try #require(model.account(accountID))
    #expect(model.isReady(afterClear))

    let restored = await model.updateConnection(
      accountID: accountID,
      label: "Custom LAN",
      newCredential: "second-secret",
      baseURL: "http://192.168.1.60:8000/v1",
      headers: [:],
      metadata: [:],
      chatCompletionsPath: "/chat/completions",
      modelsPath: nil,
      authChoice: .bearer,
      seedModelIDs: ["local-1"]
    )
    #expect(restored)
    #expect(model.hasCredential(accountID))

    let switchedToNone = await model.updateConnection(
      accountID: accountID,
      label: "Custom LAN",
      newCredential: nil,
      baseURL: "http://192.168.1.60:8000/v1",
      headers: [:],
      metadata: [:],
      chatCompletionsPath: "/chat/completions",
      modelsPath: nil,
      authChoice: .none,
      seedModelIDs: ["local-1"]
    )
    #expect(switchedToNone)
    #expect(!model.hasCredential(accountID))
  }

  // MARK: - Layer 2 Remote Model Catalog

  @Test("Layer 2 remote catalog refresh updates status, applies cloud seeds, and clears cleanly")
  func remoteModelCatalogRefreshApplyAndClear() async throws {
    defer { ModelCatalogRegistry.resetToBundled() }
    ModelCatalogRegistry.resetToBundled()

    let bundled = try #require(ModelCatalog.bundled)
    var remote = bundled
    remote.revision = bundled.revision + 10
    remote.version = "2026-12-20"
    remote.providers["openai"]?.models.insert(
      ModelCatalog.ModelEntry(
        id: "gpt-mac-catalog-test",
        displayName: "GPT Mac Catalog Test",
        contextWindow: 512_000,
        contextWindowKind: .combined,
        maxOutputTokens: 64_000,
        inputModalities: ["text", "image", "file"],
        outputModalities: ["text"],
        supportedParameters: ["reasoning", "tools"]
      ),
      at: 0
    )
    let encodedRemote = try JSONEncoder().encode(remote)

    let catalogTransport = StubMacHTTPTransport(responses: [
      .success(
        ProviderHTTPResponse(
          statusCode: 200,
          headers: ["ETag": "\"mac-rev-10\""],
          data: encodedRemote
        )
      ),
      .success(
        ProviderHTTPResponse(
          statusCode: 304,
          headers: ["ETag": "\"mac-rev-10\""],
          data: Data()
        )
      ),
    ])
    let catalogStore = ModelCatalogStore(
      persistence: InMemoryModelCatalogPersistence(),
      transport: catalogTransport,
      activatesGlobally: true
    )

    let context = try await makeMacProviderTestContext(modelCatalog: catalogStore)
    defer { context.cleanup() }

    let openAI = try await context.services.accountManager.createAccount(
      kind: .openai,
      label: "OpenAI",
      credential: "sk-test",
      defaultModelID: "gpt-4o"
    )
    try await context.services.providerWorkspace.mergeModels(
      [ProviderModel(providerID: openAI.providerID, id: "gpt-4o", displayName: "GPT-4o")],
      for: openAI.id
    )
    let ollama = try await context.services.accountManager.createAccount(
      kind: .ollama,
      label: "Local Ollama",
      credential: nil,
      baseURLOverride: URL(string: "http://localhost:11434/v1"),
      defaultModelID: "llama3.2"
    )
    try await context.services.providerWorkspace.addManualModel(
      ProviderModel(providerID: ollama.providerID, id: "llama3.2", displayName: "llama3.2"),
      for: ollama.id
    )

    let model = MacProviderModel(services: context.services)
    try await model.load()
    #expect(model.modelCatalogStatus?.source == .bundled)
    #expect(model.modelCatalogRevision == bundled.revision)

    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let refreshResult = try await model.forceRefreshModelCatalog(now: t0)
    #expect(refreshResult == .updated(revision: remote.revision, version: "2026-12-20"))
    #expect(model.modelCatalogStatus?.source == .remote)
    #expect(model.modelCatalogStatus?.revision == remote.revision)
    #expect(model.modelCatalogRevision == remote.revision)

    // Updated seed model was merged into built-in cloud account without marking discovery refreshed.
    let openAIModels = model.models(for: openAI.id)
    #expect(openAIModels.contains { $0.model.id == "gpt-mac-catalog-test" })
    #expect(model.lastModelRefreshAt(for: openAI.id) == nil)

    // Local server account was untouched.
    #expect(!model.models(for: ollama.id).contains { $0.model.id == "gpt-mac-catalog-test" })

    // Conditional 304 keeps remote catalog active.
    let notModified = try await model.refreshModelCatalog(force: true, now: t0.addingTimeInterval(60))
    #expect(notModified == .notModified)
    #expect(model.modelCatalogStatus?.source == .remote)

    // Clearing cache reverts to Layer 1 bundled baseline.
    try await model.clearModelCatalogCache()
    #expect(model.modelCatalogStatus?.source == .bundled)
    #expect(model.modelCatalogRevision == bundled.revision)
  }

  @Test("Background refreshModelCatalogIfNeeded absorbs network failures quietly")
  func backgroundModelCatalogRefreshAbsorbsErrors() async throws {
    defer { ModelCatalogRegistry.resetToBundled() }
    ModelCatalogRegistry.resetToBundled()

    let catalogTransport = StubMacHTTPTransport(responses: [
      .failure(ProviderError.transport(message: "Offline", completionUnknown: true))
    ])
    let catalogStore = ModelCatalogStore(
      persistence: InMemoryModelCatalogPersistence(),
      transport: catalogTransport,
      activatesGlobally: false
    )

    let context = try await makeMacProviderTestContext(modelCatalog: catalogStore)
    defer { context.cleanup() }

    let model = MacProviderModel(services: context.services)
    try await model.load()

    await model.refreshModelCatalogIfNeeded()
    #expect(model.errorMessage == nil)
    #expect(model.modelCatalogStatus?.lastFailureMessage != nil)
    #expect(!model.isRefreshingModelCatalog)
  }

  // MARK: - 24h TTL & 15m Failure-Throttled Per-Account Refresh

  @Test("Per-account refresh respects 24h TTL, 15m failure backoff, deduplication, and explicit force")
  func perAccountRefreshTTLThrottleAndDeduplication() async throws {
    let modelsJSON = Data(#"{"data":[{"id":"discovered-1"},{"id":"discovered-2"}]}"#.utf8)
    let transport = StubMacHTTPTransport(
      responses: [
        .success(ProviderHTTPResponse(statusCode: 200, headers: [:], data: modelsJSON)),
        .failure(ProviderError.transport(message: "Temporary outage", completionUnknown: true)),
        .success(ProviderHTTPResponse(statusCode: 200, headers: [:], data: modelsJSON)),
        .success(ProviderHTTPResponse(statusCode: 200, headers: [:], data: modelsJSON)),
      ],
      delayMilliseconds: 30
    )
    let context = try await makeMacProviderTestContext(providerTransport: transport)
    defer { context.cleanup() }

    let account = try await context.services.accountManager.createAccount(
      kind: .deepSeek,
      label: "DeepSeek",
      credential: "sk-key",
      defaultModelID: "deepseek-chat"
    )
    try await context.services.providerWorkspace.mergeModels(
      [ProviderModel(providerID: account.providerID, id: "deepseek-chat", displayName: "DeepSeek Chat")],
      for: account.id
    )
    let unsupported = try await context.services.accountManager.createAccount(
      kind: .openAICompatible,
      label: "No Discovery",
      credential: nil,
      chatCompletionsPath: "/chat/completions",
      modelsPath: nil,
      authChoice: .none,
      seedModelIDs: ["local-only"],
      baseURLOverride: URL(string: "https://nodiscovery.example.test/v1")
    )

    let model = MacProviderModel(services: context.services, runtime: context.runtime)
    try await model.load()

    // Discovery-disabled account reports .unsupported.
    let unsupportedOutcome = try await model.refreshModelsIfNeeded(accountID: unsupported.id)
    #expect(unsupportedOutcome == .unsupported)

    // Concurrent calls for the same account share a single network request.
    async let firstConcurrent = model.refreshModelsIfNeeded(accountID: account.id, force: false)
    async let secondConcurrent = model.refreshModelsIfNeeded(accountID: account.id, force: false)
    let (r1, r2) = try await (firstConcurrent, secondConcurrent)
    #expect(r1 == .refreshed)
    #expect(r2 == .refreshed)
    #expect(await transport.requestCount == 1)
    #expect(model.lastModelRefreshAt(for: account.id) != nil)
    #expect(model.models(for: account.id).contains { $0.model.id == "discovered-1" })

    // Within 24h TTL returns .current without hitting transport.
    let currentOutcome = try await model.refreshModelsIfNeeded(
      accountID: account.id,
      force: false,
      now: Date.now.addingTimeInterval(60 * 60)
    )
    #expect(currentOutcome == .current)
    #expect(await transport.requestCount == 1)

    // After 24h TTL expires, a failing request records failure backoff.
    let afterTTL = Date.now.addingTimeInterval(MacProviderModel.catalogRefreshInterval + 60)
    await #expect(throws: ProviderError.self) {
      _ = try await model.refreshModelsIfNeeded(accountID: account.id, force: false, now: afterTTL)
    }
    #expect(await transport.requestCount == 2)

    // Within 15m of failure returns .throttled without hitting transport.
    let throttledOutcome = try await model.refreshModelsIfNeeded(
      accountID: account.id,
      force: false,
      now: afterTTL.addingTimeInterval(5 * 60)
    )
    #expect(throttledOutcome == .throttled)
    #expect(await transport.requestCount == 2)

    // After 15m failure backoff expires, retries and succeeds.
    let retriedOutcome = try await model.refreshModelsIfNeeded(
      accountID: account.id,
      force: false,
      now: afterTTL.addingTimeInterval(MacProviderModel.catalogRetryInterval + 5)
    )
    #expect(retriedOutcome == .refreshed)
    #expect(await transport.requestCount == 3)

    // Explicit refreshModels(accountID:) is always unthrottled even immediately after refresh.
    let explicitSuccess = await model.refreshModels(accountID: account.id)
    #expect(explicitSuccess)
    #expect(await transport.requestCount == 4)
  }

  @Test("refreshReadyAccountsIfNeeded refreshes only stale ready discovery-capable accounts")
  func refreshReadyAccountsIfNeededFiltersCandidates() async throws {
    let modelsJSON = Data(#"{"data":[{"id":"fresh-model"}]}"#.utf8)
    let transport = StubMacHTTPTransport(responses: [
      .success(ProviderHTTPResponse(statusCode: 200, headers: [:], data: modelsJSON))
    ])
    let context = try await makeMacProviderTestContext(providerTransport: transport)
    defer { context.cleanup() }

    let ready = try await context.services.accountManager.createAccount(
      kind: .deepSeek,
      label: "Ready",
      credential: "sk-ready",
      defaultModelID: "deepseek-chat"
    )
    try await context.services.providerWorkspace.mergeModels(
      [ProviderModel(providerID: ready.providerID, id: "deepseek-chat", displayName: "DeepSeek Chat")],
      for: ready.id
    )
    let unready = try await context.services.accountManager.createAccount(
      kind: .deepSeek,
      label: "Missing Key",
      credential: nil,
      defaultModelID: "deepseek-chat"
    )
    try await context.services.providerWorkspace.mergeModels(
      [ProviderModel(providerID: unready.providerID, id: "deepseek-chat", displayName: "DeepSeek Chat")],
      for: unready.id
    )

    let model = MacProviderModel(services: context.services, runtime: context.runtime)
    try await model.load()

    await model.refreshReadyAccountsIfNeeded()
    #expect(await transport.requestCount == 1)
    #expect(model.models(for: ready.id).contains { $0.model.id == "fresh-model" })
    #expect(model.lastModelRefreshAt(for: ready.id) != nil)
    #expect(model.lastModelRefreshAt(for: unready.id) == nil)
  }

  // MARK: - Pre-Save Discovery (previewModels)

  @Test("previewModels uses draft values, falls back to stored key, and never writes to workspace")
  func previewModelsUsesDraftWithoutPersisting() async throws {
    let modelsJSON = Data(#"{"data":[{"id":"preview-model-a"},{"id":"preview-model-b"}]}"#.utf8)
    let transport = StubMacHTTPTransport(responses: [
      .success(ProviderHTTPResponse(statusCode: 200, headers: [:], data: modelsJSON)),
      .success(ProviderHTTPResponse(statusCode: 200, headers: [:], data: modelsJSON)),
      .success(ProviderHTTPResponse(statusCode: 200, headers: [:], data: modelsJSON)),
    ])
    let context = try await makeMacProviderTestContext(providerTransport: transport)
    defer { context.cleanup() }

    let account = try await context.services.accountManager.createAccount(
      kind: .openAICompatible,
      label: "Custom Server",
      credential: "saved-secret",
      modelsPath: "/models",
      authChoice: .bearer,
      baseURLOverride: URL(string: "https://old.example.test/v1"),
      defaultModelID: "old-model"
    )
    try await context.services.providerWorkspace.addManualModel(
      ProviderModel(providerID: account.providerID, id: "old-model", displayName: "Old"),
      for: account.id
    )

    let model = MacProviderModel(services: context.services, runtime: context.runtime)
    try await model.load()
    let snapshotBefore = await context.services.providerWorkspace.snapshot()

    var draft = ResolvedProviderAccount(
      kind: .openAICompatible,
      id: account.id,
      providerID: account.providerID,
      label: "Custom Server",
      apiKey: "draft-secret",
      baseURLOverride: URL(string: "https://new.example.test/v2"),
      additionalHeaders: ["X-Custom-Route": "canary"],
      modelsPath: "/catalog",
      authChoice: .bearer
    )

    let discovered = try await model.previewModels(
      for: draft,
      storedCredentialAccountID: account.id
    )
    #expect(discovered.map(\.id) == ["preview-model-a", "preview-model-b"])

    let firstReq = try #require(await transport.lastRequest)
    #expect(firstReq.url?.absoluteString == "https://new.example.test/v2/catalog")
    #expect(firstReq.value(forHTTPHeaderField: "Authorization") == "Bearer draft-secret")
    #expect(firstReq.value(forHTTPHeaderField: "X-Custom-Route") == "canary")

    // Leaving draft apiKey nil falls back to the stored Keychain secret.
    draft.apiKey = nil
    _ = try await model.previewModels(for: draft, storedCredentialAccountID: account.id)
    let secondReq = try #require(await transport.lastRequest)
    #expect(secondReq.value(forHTTPHeaderField: "Authorization") == "Bearer saved-secret")

    // Local Ollama normalizes /v1 and works without any API key.
    let ollamaDraft = ResolvedProviderAccount(
      kind: .ollama,
      id: "",
      providerID: BuiltInProviders.ollamaID,
      label: "Ollama",
      apiKey: nil,
      baseURLOverride: URL(string: "http://192.168.1.40:11434")
    )
    _ = try await model.previewModels(for: ollamaDraft)
    let thirdReq = try #require(await transport.lastRequest)
    #expect(thirdReq.url?.absoluteString == "http://192.168.1.40:11434/v1/models")
    #expect(thirdReq.value(forHTTPHeaderField: "Authorization") == nil)

    // Cloud provider without key throws missingCredential.
    let missingKeyCloud = ResolvedProviderAccount(
      kind: .openai,
      id: "",
      providerID: BuiltInProviders.openAIID,
      label: "OpenAI",
      apiKey: nil
    )
    await #expect(throws: ProviderError.self) {
      _ = try await model.previewModels(for: missingKeyCloud)
    }

    // Workspace and stored credential remain completely untouched.
    let snapshotAfter = await context.services.providerWorkspace.snapshot()
    #expect(snapshotAfter == snapshotBefore)
    #expect((try await context.services.accountManager.resolvedAccount(id: account.id)).apiKey == "saved-secret")
  }

  @Test("Saving pre-save discovered models marks account refreshed so immediate TTL check is current")
  func createWithDiscoveredModelsMarksFresh() async throws {
    let context = try await makeMacProviderTestContext()
    defer { context.cleanup() }

    let model = MacProviderModel(services: context.services)
    try await model.load()

    let createdID = await model.createConnection(
      kind: .deepSeek,
      label: "DeepSeek",
      credential: "sk-test",
      baseURL: "",
      defaultModel: "deepseek-r1",
      headers: [:],
      metadata: [:],
      discoveredModels: [
        ProviderModel(
          providerID: "preview",
          id: "deepseek-r1",
          displayName: "DeepSeek R1",
          contextWindow: 128_000,
          inputModalities: ["text"]
        )
      ],
      manualModelIDs: ["custom-manual-1"]
    )
    let accountID = try #require(createdID)

    #expect(model.lastModelRefreshAt(for: accountID) != nil)
    #expect(model.models(for: accountID).contains { $0.model.id == "deepseek-r1" && !$0.isManual })
    #expect(model.models(for: accountID).contains { $0.model.id == "custom-manual-1" && $0.isManual })

    let refreshOutcome = try await model.refreshModelsIfNeeded(accountID: accountID, force: false)
    #expect(refreshOutcome == .current)
  }

  // MARK: - Manual Model Selection & Removal

  @Test("Manual models can be staged via ensureSelectableModel and removed without affecting discovered models")
  func manualModelAdditionAndRemoval() async throws {
    let context = try await makeMacProviderTestContext()
    defer { context.cleanup() }

    let model = MacProviderModel(services: context.services)
    try await model.load()

    let createdID = await model.createConnection(
      kind: .deepSeek,
      label: "DeepSeek",
      credential: "sk-key",
      baseURL: "",
      defaultModel: "discovered-default",
      headers: [:],
      metadata: [:],
      discoveredModels: [
        ProviderModel(
          providerID: BuiltInProviders.deepSeekID,
          id: "discovered-default",
          displayName: "Discovered Default"
        )
      ],
      manualModelIDs: ["manual-a", "manual-b"]
    )
    let accountID = try #require(createdID)

    // ensureSelectableModel adds a manual model without overwriting defaultModelID.
    try await model.ensureSelectableModel("picker-custom-id", for: accountID)
    #expect(model.models(for: accountID).contains { $0.model.id == "picker-custom-id" && $0.isManual })
    #expect((try await context.services.providerWorkspace.account(id: accountID)).defaultModelID == "discovered-default")

    // Single manual model removal succeeds and updates snapshot.
    let removedSingle = await model.removeManualModel("manual-a", accountID: accountID)
    #expect(removedSingle)
    #expect(!model.models(for: accountID, includeHidden: true).contains { $0.model.id == "manual-a" })

    // Batch removal via updateConnection removes manual-b and keeps new default.
    let updated = await model.updateConnection(
      accountID: accountID,
      label: "DeepSeek",
      newCredential: nil,
      baseURL: "",
      headers: [:],
      metadata: [:],
      chatCompletionsPath: nil,
      modelsPath: nil,
      authChoice: nil,
      seedModelIDs: nil,
      defaultModelID: "picker-custom-id",
      removedManualModelIDs: ["manual-b"]
    )
    #expect(updated)
    #expect(!model.models(for: accountID, includeHidden: true).contains { $0.model.id == "manual-b" })
    #expect(model.account(accountID)?.defaultModelID == "picker-custom-id")

    // Removing the current manual default falls back to the remaining discovered model.
    try await model.removeManualModels(["picker-custom-id"], for: accountID)
    #expect(!model.models(for: accountID, includeHidden: true).contains { $0.model.id == "picker-custom-id" })
    #expect(model.account(accountID)?.defaultModelID == "discovered-default")

    // Removing a non-manual discovered model is rejected.
    let removedDiscovered = await model.removeManualModel("discovered-default", accountID: accountID)
    #expect(!removedDiscovered)
    #expect(model.errorMessage != nil)
    #expect(model.models(for: accountID).contains { $0.model.id == "discovered-default" })
  }

  @Test("Composer model popover support pre-indexes rows, filters quickly, and partitions favorites")
  func composerModelPickerSupportIndexingAndFiltering() {
    let accountID = ProviderAccountID(rawValue: "acct-anthropic")
    let records = [
      AccountModelRecord(
        accountID: accountID,
        model: ProviderModel(
          providerID: BuiltInProviders.anthropicID,
          id: "claude-sonnet-4-5",
          displayName: "Claude Sonnet 4.5",
          inputModalities: ["text", "image"]
        ),
        isFavorite: true,
        isHidden: false,
        isManual: false,
        isAvailable: true
      ),
      AccountModelRecord(
        accountID: accountID,
        model: ProviderModel(
          providerID: BuiltInProviders.anthropicID,
          id: "custom-model",
          displayName: "custom-model",
          inputModalities: ["text"]
        ),
        isFavorite: false,
        isHidden: false,
        isManual: true,
        isAvailable: true
      ),
      AccountModelRecord(
        accountID: accountID,
        model: ProviderModel(
          providerID: BuiltInProviders.anthropicID,
          id: "retired-model",
          displayName: "Retired Model",
          inputModalities: ["text"]
        ),
        isFavorite: false,
        isHidden: false,
        isManual: false,
        isAvailable: false
      ),
    ]

    let rows = MacComposerModelPickerSupport.makeRows(from: records)
    #expect(rows.count == 3)
    #expect(rows[0].subtitleID == "claude-sonnet-4-5")
    #expect(rows[0].supportsVision)
    #expect(rows[1].subtitleID == nil)
    #expect(!rows[1].supportsVision)
    #expect(rows[1].isManual)
    #expect(!rows[2].isAvailable)

    let partitionedNoQuery = MacComposerModelPickerSupport.partitionRows(rows, hasQuery: false)
    #expect(partitionedNoQuery.favorites.map(\.id) == ["claude-sonnet-4-5"])
    #expect(partitionedNoQuery.others.map(\.id) == ["custom-model", "retired-model"])

    let partitionedWithQuery = MacComposerModelPickerSupport.partitionRows(rows, hasQuery: true)
    #expect(partitionedWithQuery.favorites.isEmpty)
    #expect(partitionedWithQuery.others.count == 3)

    #expect(
      MacComposerModelPickerSupport.filterRows(rows, query: "  SONNET ").map(\.id)
        == ["claude-sonnet-4-5"]
    )
    #expect(
      MacComposerModelPickerSupport.filterRows(rows, query: "custom").map(\.id)
        == ["custom-model"]
    )
    #expect(MacComposerModelPickerSupport.filterRows(rows, query: "   ").count == 3)

    let capabilityRows = MacComposerModelPickerSupport.makeRows(from: records) { record in
      ModelCapabilityResolver.resolve(
        kind: .anthropic,
        modelID: record.model.id,
        model: record.model
      )
    }
    #expect(capabilityRows[0].supportsVision)
    #expect(capabilityRows[0].hasMetadataLine)

    let unlisted = MacComposerModelPickerSupport.makeUnlistedRow(modelID: "removed-model")
    #expect(unlisted.id == "removed-model")
    #expect(!unlisted.isAvailable)
    #expect(unlisted.hasMetadataLine)
  }
}

@MainActor
private struct MacProviderTestContext {
  let parent: URL
  let suiteName: String
  let services: BYOKCoreServices
  let runtime: ProviderRuntime

  func cleanup() {
    try? FileManager.default.removeItem(at: parent)
    UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
  }
}

@MainActor
private func makeMacProviderTestContext(
  credentialVault: any CredentialVault = InMemoryCredentialVault(),
  modelCatalog: ModelCatalogStore? = nil,
  providerTransport: (any ProviderHTTPTransport)? = nil
) async throws -> MacProviderTestContext {
  let parent = FileManager.default.temporaryDirectory
    .appendingPathComponent("byok-mac-provider-tests-\(UUID().uuidString)", isDirectory: true)
  let root = parent.appendingPathComponent("Workspace", isDirectory: true)
  let telemetry = parent.appendingPathComponent("Telemetry", isDirectory: true)
  let suiteName = "byok-mac-provider-tests-\(UUID().uuidString)"
  let storage = BYOKStorageEnvironment(
    rootDirectory: root,
    userDefaultsSuiteName: suiteName,
    credentialService: "tests.byok.mac.provider.credentials.\(UUID().uuidString)",
    mcpCredentialService: "tests.byok.mac.provider.mcp.\(UUID().uuidString)",
    telemetryDirectory: telemetry
  )

  try await BYOKStorageBootstrap.prepare(environment: storage)
  let services = try BYOKCoreServices(
    environment: storage,
    credentialVault: credentialVault,
    mcpCredentialVault: InMemoryMCPCredentialVault(),
    modelCatalog: modelCatalog
  )
  try await services.loadStoredState()
  let runtime: ProviderRuntime
  if let providerTransport {
    runtime = ProviderRuntime(
      registry: services.providerRegistry,
      workspace: services.providerWorkspace,
      accounts: services.accountManager,
      transport: providerTransport
    )
  } else {
    runtime = services.providerRuntime
  }
  return MacProviderTestContext(parent: parent, suiteName: suiteName, services: services, runtime: runtime)
}

private actor StubMacHTTPTransport: ProviderHTTPTransport {
  private var responses: [Result<ProviderHTTPResponse, Error>]
  private let delayMilliseconds: Int
  private(set) var recordedRequests: [URLRequest] = []

  init(responses: [Result<ProviderHTTPResponse, Error>], delayMilliseconds: Int = 0) {
    self.responses = responses
    self.delayMilliseconds = delayMilliseconds
  }

  var requestCount: Int { recordedRequests.count }
  var lastRequest: URLRequest? { recordedRequests.last }

  func data(for request: URLRequest) async throws -> ProviderHTTPResponse {
    recordedRequests.append(request)
    if delayMilliseconds > 0 {
      try await Task.sleep(for: .milliseconds(delayMilliseconds))
    }
    guard !responses.isEmpty else {
      throw ProviderError.transport(message: "No stubbed HTTP response.", completionUnknown: true)
    }
    return try responses.removeFirst().get()
  }

  func stream(for request: URLRequest) async throws -> ProviderHTTPByteStream {
    throw ProviderError.invalidResponse
  }
}

private actor FailingMacProviderCredentialVault: CredentialVault {
  private var values: [String: String] = [:]
  private var shouldFailNextSet = false

  func failNextSet() {
    shouldFailNextSet = true
  }

  func secret(accountID: ProviderAccountID, field: String) -> String? {
    values[key(accountID, field)]
  }

  func setSecret(_ value: String?, accountID: ProviderAccountID, field: String) throws {
    if shouldFailNextSet {
      shouldFailNextSet = false
      throw ProviderError.transport(message: "Injected credential write failure.", completionUnknown: false)
    }
    let storageKey = key(accountID, field)
    if let value, !value.isEmpty {
      values[storageKey] = value
    } else {
      values.removeValue(forKey: storageKey)
    }
  }

  func removeAll(accountID: ProviderAccountID) {
    let prefix = "\(accountID.rawValue):"
    values = values.filter { !$0.key.hasPrefix(prefix) }
  }

  private func key(_ accountID: ProviderAccountID, _ field: String) -> String {
    "\(accountID.rawValue):\(field)"
  }
}
