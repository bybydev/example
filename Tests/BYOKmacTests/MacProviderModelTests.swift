import BYOKchatProviderCore
import Foundation
import Testing

@testable import BYOKmac

@MainActor
@Suite("macOS provider and model workflows")
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

  @Test("Restored provider overflow is blocked at the model boundary and unlocks after deletion")
  func restoredProviderOverflowModelBoundary() async throws {
    let context = try await makeMacProviderTestContext()
    defer { context.cleanup() }

    let first = try await context.services.accountManager.createAccount(
      kind: .deepSeek,
      label: "First",
      credential: "first-key",
      defaultModelID: "deepseek-chat"
    )
    let second = try await context.services.accountManager.createAccount(
      kind: .deepSeek,
      label: "Second",
      credential: "second-key",
      defaultModelID: "deepseek-chat"
    )
    for account in [first, second] {
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
    }

    let restrictionSuite = "byok-mac-provider-restrictions-\(UUID().uuidString)"
    let restrictionDefaults = UserDefaults(suiteName: restrictionSuite)!
    defer { restrictionDefaults.removePersistentDomain(forName: restrictionSuite) }
    let restrictions = MacProResourceRestrictions(
      defaults: restrictionDefaults,
      keyPrefix: "test"
    )
    restrictions.recordFullBackupImport(
      before: MacProResourceSnapshot(),
      after: MacProResourceSnapshot(
        providerAccountIDs: [first.id.rawValue, second.id.rawValue]
      ),
      strategy: .replaceExisting,
      entitlement: .free
    )

    let model = MacProviderModel(
      services: context.services,
      restrictions: restrictions,
      entitlementAccessOverride: .free
    )
    try await model.load()

    #expect(!model.isProviderRestricted(first.id))
    #expect(model.isProviderRestricted(second.id))
    #expect(model.preferredTarget()?.accountID == first.id)

    let updated = await model.updateConnection(
      accountID: second.id,
      label: "Blocked Edit",
      newCredential: "changed-key",
      baseURL: "",
      headers: [:],
      metadata: [:],
      chatCompletionsPath: nil,
      modelsPath: nil,
      authChoice: nil,
      seedModelIDs: nil
    )
    #expect(!updated)
    #expect((try await context.services.providerWorkspace.account(id: second.id)).label == "Second")
    #expect(!(await model.setDefaultAccount(second.id)))
    #expect(!(await model.refreshModels(accountID: second.id)))
    #expect(!(await model.testConnection(accountID: second.id, modelID: "deepseek-chat")))
    #expect(await model.revealCredential(accountID: second.id) == nil)
    #expect(model.errorMessage != nil)

    await model.deleteConnection(first.id)

    #expect(!model.isProviderRestricted(second.id))
    #expect(model.preferredTarget()?.accountID == second.id)
    #expect(await model.revealCredential(accountID: second.id) == "second-key")
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
}

@MainActor
private struct MacProviderTestContext {
  let parent: URL
  let suiteName: String
  let services: BYOKCoreServices

  func cleanup() {
    try? FileManager.default.removeItem(at: parent)
    UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
  }
}

@MainActor
private func makeMacProviderTestContext(
  credentialVault: any CredentialVault = InMemoryCredentialVault()
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
    mcpCredentialVault: InMemoryMCPCredentialVault()
  )
  try await services.loadStoredState()
  return MacProviderTestContext(parent: parent, suiteName: suiteName, services: services)
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
