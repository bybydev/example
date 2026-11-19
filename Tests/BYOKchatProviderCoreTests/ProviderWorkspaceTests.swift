import XCTest

@testable import BYOKchatProviderCore

final class ProviderWorkspaceTests: XCTestCase {
  func testBuiltInRegistryContainsPriorityProviders() async throws {
    let registry = try ProviderRegistry.builtIn()
    let ids = Set(await registry.allDefinitions().map(\.id))
    XCTAssertEqual(
      ids,
      [
        BuiltInProviders.openAIID,
        BuiltInProviders.xAIID,
        BuiltInProviders.anthropicID,
        BuiltInProviders.geminiID,
        BuiltInProviders.nvidiaID,
        BuiltInProviders.openRouterID,
        BuiltInProviders.deepSeekID,
        BuiltInProviders.zAIID,
        BuiltInProviders.moonshotID,
        BuiltInProviders.minimaxID,
        BuiltInProviders.mistralID,
        BuiltInProviders.ollamaID,
        BuiltInProviders.lmStudioID,
      ]
    )
  }

  func testBuiltInAccountsAllowHTTPSBaseURLOverride() async throws {
    let (_, manager, _) = try await makeEnvironment()
    let initialSimulatorURL = URL(string: "https://simulator.example.test/v1")!
    let editedSimulatorURL = URL(string: "https://simulator-alt.example.test/api")!

    for definition in BuiltInProviders.all {
      let account = try await manager.createAccount(
        kind: ProviderKind(providerID: definition.id),
        label: "\(definition.displayName) Simulator",
        credential: definition.authentication == .none ? nil : "test-key",
        baseURLOverride: initialSimulatorURL
      )
      let initialResolved = try await manager.resolvedAccount(id: account.id)
      XCTAssertEqual(initialResolved.baseURLOverride, initialSimulatorURL)

      var edited = account
      edited.baseURLOverride = editedSimulatorURL
      try await manager.updateAccount(edited)

      let editedResolved = try await manager.resolvedAccount(id: account.id)
      XCTAssertEqual(editedResolved.baseURLOverride, editedSimulatorURL)
    }
  }

  func testLegacyCustomXAIAccountDoesNotReplaceBuiltInXAI() async throws {
    let legacyEndpoint = URL(string: "https://legacy-xai.example.test/v1")!
    let legacyDefinition = try CustomProviderFactory.makeOpenAICompatible(
      id: "xai",
      displayName: "Legacy xAI Compatible",
      baseURL: legacyEndpoint,
      chatCompletionsPath: "/chat/completions",
      modelsPath: "/models",
      authentication: .bearer,
      seedModelIDs: ["legacy-grok"]
    )
    let legacyAccount = ProviderAccount(
      kind: .openAICompatible,
      id: "legacy-xai-account",
      providerID: "xai",
      label: "Legacy xAI",
      chatCompletionsPath: "/chat/completions",
      modelsPath: "/models",
      authChoice: .bearer,
      seedModelIDs: ["legacy-grok"],
      baseURLOverride: legacyEndpoint,
      defaultModelID: "legacy-grok"
    )
    let legacyState = ProviderWorkspaceState(
      customProviders: [legacyDefinition],
      accounts: [legacyAccount]
    )
    let persistence = InMemoryProviderWorkspacePersistence(
      data: try JSONEncoder.providerEncoder.encode(legacyState)
    )
    let workspace = ProviderWorkspaceStore(persistence: persistence)
    try await workspace.load()

    let registry = try ProviderRegistry.builtIn()
    let manager = ProviderAccountManager(
      registry: registry,
      workspace: workspace,
      vault: InMemoryCredentialVault()
    )
    try await manager.synchronizeCustomProviders()

    let registeredXAI = try await registry.definition(for: BuiltInProviders.xAIID)
    XCTAssertTrue(registeredXAI.isBuiltIn)
    XCTAssertEqual(registeredXAI.defaultBaseURL, BuiltInProviders.xAI.defaultBaseURL)
    XCTAssertEqual(registeredXAI.chatCompletionsPath, "/responses")

    let storedLegacy = try await workspace.account(id: legacyAccount.id)
    XCTAssertEqual(storedLegacy.kind, .openAICompatible)
    XCTAssertEqual(storedLegacy.providerID, BuiltInProviders.xAIID)
    XCTAssertEqual(storedLegacy.definition.defaultBaseURL, legacyEndpoint)
    XCTAssertEqual(storedLegacy.definition.chatCompletionsPath, "/chat/completions")
  }

  func testCustomProviderFactoryRejectsInsecureURL() throws {
    XCTAssertThrowsError(
      try CustomProviderFactory.makeOpenAICompatible(
        id: "custom.test",
        displayName: "Test",
        baseURL: URL(string: "http://example.com/v1")!
      )
    )
  }

  func testCredentialIsSeparateFromExportedWorkspace() async throws {
    let (workspace, manager, vault) = try await makeEnvironment()
    let account = try await manager.createAccount(
      kind: .deepSeek,
      label: "Personal",
      credential: "super-secret-api-key",
      defaultModelID: "deepseek-v4-flash"
    )

    let hasCredential = try await manager.hasCredential(accountID: account.id)
    XCTAssertTrue(hasCredential)
    let data = try await workspace.exportConfiguration()
    let exported = String(decoding: data, as: UTF8.self)
    XCTAssertFalse(exported.contains("super-secret-api-key"))
    let savedSecret = await vault.secret(
      accountID: account.id, field: ProviderAccountManager.apiKeyField)
    XCTAssertEqual(savedSecret, "super-secret-api-key")
  }

  func testDeletingAccountRemovesCredentialAndModelState() async throws {
    let (workspace, manager, vault) = try await makeEnvironment()
    let account = try await manager.createAccount(
      kind: .openRouter,
      label: "Main",
      credential: "secret"
    )
    try await workspace.mergeModels(BuiltInProviders.openRouter.seedModels, for: account.id)

    try await manager.deleteAccount(account.id)

    let deletedSecret = await vault.secret(
      accountID: account.id, field: ProviderAccountManager.apiKeyField)
    let remainingModels = await workspace.modelRecords(for: account.id, includeHidden: true)
    XCTAssertNil(deletedSecret)
    XCTAssertTrue(remainingModels.isEmpty)
    do {
      _ = try await workspace.account(id: account.id)
      XCTFail("Expected missing account")
    } catch ProviderError.accountNotFound {
      // Expected.
    }
  }

  func testModelRefreshPreservesFavoritesManualModelsAndOlderCatalogEntries() async throws
  {
    let (workspace, manager, _) = try await makeEnvironment()
    let account = try await manager.createAccount(
      kind: .nvidia,
      label: "NVIDIA",
      credential: "secret"
    )
    let first = ProviderModel(
      providerID: BuiltInProviders.nvidiaID, id: "model-a", displayName: "Model A")
    let second = ProviderModel(
      providerID: BuiltInProviders.nvidiaID, id: "model-b", displayName: "Model B")
    try await workspace.mergeModels([first, second], for: account.id)
    try await workspace.setFavorite(true, modelID: first.id, accountID: account.id)

    let manual = ProviderModel(
      providerID: BuiltInProviders.nvidiaID, id: "manual-model", displayName: "Manual")
    try await workspace.addManualModel(manual, for: account.id)
    try await workspace.mergeModels([first], for: account.id)

    let records = await workspace.modelRecords(for: account.id, includeHidden: true)
    XCTAssertEqual(records.first(where: { $0.model.id == first.id })?.isFavorite, true)
    XCTAssertEqual(records.first(where: { $0.model.id == second.id })?.isAvailable, true)
    XCTAssertEqual(records.first(where: { $0.model.id == manual.id })?.isManual, true)
    XCTAssertEqual(records.first(where: { $0.model.id == manual.id })?.isAvailable, true)
  }

  func testModelRefreshTimestampPersistsAndInvalidatesOnConnectionChange() async throws {
    let persistence = InMemoryProviderWorkspacePersistence()
    let workspace = ProviderWorkspaceStore(persistence: persistence)
    try await workspace.load()
    let account = ProviderAccount(kind: .deepSeek, label: "Saved")
    try await workspace.upsertAccount(account)
    let initialRefresh = await workspace.lastModelRefreshAt(for: account.id)
    XCTAssertNil(initialRefresh)
    let model = ProviderModel(providerID: account.providerID, id: "new-model", displayName: "New Model")
    let checkedAt = Date(timeIntervalSince1970: 1_780_000_000)
    try await workspace.mergeModels([model], for: account.id, at: checkedAt, markRefreshed: true)
    let reloaded = ProviderWorkspaceStore(persistence: persistence)
    try await reloaded.load()
    let reloadedRefresh = await reloaded.lastModelRefreshAt(for: account.id)
    XCTAssertEqual(reloadedRefresh, checkedAt)

    var changed = account
    changed.baseURLOverride = URL(string: "https://example.org/v1")
    try await reloaded.upsertAccount(changed)
    let invalidatedRefresh = await reloaded.lastModelRefreshAt(for: account.id)
    XCTAssertNil(invalidatedRefresh)
    let staleApplied = try await reloaded.mergeModels(
      [model], for: account.id, expectedAccount: account, markRefreshed: true
    )
    XCTAssertFalse(staleApplied)
    let staleRefresh = await reloaded.lastModelRefreshAt(for: account.id)
    XCTAssertNil(staleRefresh)
  }

  func testDeletingManualModelPreservesOtherModelsAndUpdatesDefault() async throws {
    let (workspace, manager, _) = try await makeEnvironment()
    let account = try await manager.createAccount(
      kind: .deepSeek, label: "Saved", credential: "key", defaultModelID: "manual-a"
    )
    let discovered = ProviderModel(providerID: account.providerID, id: "catalog", displayName: "Catalog")
    let manual = ProviderModel(providerID: account.providerID, id: "manual-a", displayName: "Manual A")
    try await workspace.mergeModels([discovered], for: account.id)
    try await workspace.addManualModel(manual, for: account.id)
    try await workspace.setFavorite(true, modelID: discovered.id, accountID: account.id)
    try await workspace.removeManualModels([manual.id], for: account.id)
    let models = await workspace.modelRecords(for: account.id)
    XCTAssertFalse(models.contains { $0.model.id == manual.id })
    XCTAssertEqual(models.first(where: { $0.model.id == discovered.id })?.isFavorite, true)
    let changedAccount = try await workspace.account(id: account.id)
    XCTAssertEqual(changedAccount.defaultModelID, discovered.id)
    do {
      try await workspace.removeManualModels([discovered.id], for: account.id)
      XCTFail("Catalog-only entries must not be removable as manual models")
    } catch ProviderError.invalidRequest {
      // Expected.
    }
    let afterInvalidRemoval = await workspace.modelRecords(for: account.id)
    XCTAssertEqual(afterInvalidRemoval.count, 1)
  }

  func testRemovingOnlyManualDefaultClearsConnectionDefault() async throws {
    let (workspace, manager, _) = try await makeEnvironment()
    let account = try await manager.createAccount(
      kind: .deepSeek, label: "Saved", credential: "key", defaultModelID: "manual-only"
    )
    let manual = ProviderModel(providerID: account.providerID, id: "manual-only", displayName: "Only")
    try await workspace.addManualModel(manual, for: account.id)
    try await workspace.removeManualModels([manual.id], for: account.id)
    let changed = try await workspace.account(id: account.id)
    XCTAssertNil(changed.defaultModelID)
    let remaining = await workspace.modelRecords(for: account.id)
    XCTAssertTrue(remaining.isEmpty)
  }

  func testNoAuthCustomProviderCanResolveWithoutCredential() async throws {
    let registry = try ProviderRegistry.builtIn()
    let persistence = InMemoryProviderWorkspacePersistence()
    let workspace = ProviderWorkspaceStore(persistence: persistence)
    try await workspace.load()
    let vault = InMemoryCredentialVault()
    let manager = ProviderAccountManager(registry: registry, workspace: workspace, vault: vault)
    let definition = try CustomProviderFactory.makeOpenAICompatible(
      id: "custom.noauth",
      displayName: "No Auth",
      baseURL: URL(string: "https://example.com/v1")!,
      authentication: .none,
      seedModelIDs: ["model"]
    )
    let runtime = ProviderRuntime(registry: registry, workspace: workspace, accounts: manager)
    try await runtime.registerCustomProvider(definition)
    let account = try await manager.createAccount(
      kind: .openAICompatible,
      label: "Local",
      credential: nil,
      providerID: definition.id,
      chatCompletionsPath: definition.chatCompletionsPath,
      modelsPath: definition.modelsPath,
      authChoice: definition.authentication,
      seedModelIDs: definition.seedModels.map { $0.id.rawValue },
      baseURLOverride: definition.defaultBaseURL,
      defaultModelID: "model"
    )

    let resolved = try await manager.resolvedAccount(id: account.id)
    XCTAssertNil(resolved.apiKey)
  }

  func testKeepExistingImportDoesNotReplaceExistingAccount() async throws {
    let persistence = InMemoryProviderWorkspacePersistence()
    let workspace = ProviderWorkspaceStore(persistence: persistence)
    try await workspace.load()
    let existing = ProviderAccount(
      kind: ProviderKind(providerID: BuiltInProviders.deepSeekID),
      id: "same", providerID: BuiltInProviders.deepSeekID, label: "Existing")
    try await workspace.upsertAccount(existing)

    let importedState = ProviderWorkspaceState(accounts: [
      ProviderAccount(kind: ProviderKind(providerID: BuiltInProviders.deepSeekID), id: "same", providerID: BuiltInProviders.deepSeekID, label: "Imported"),
      ProviderAccount(kind: ProviderKind(providerID: BuiltInProviders.openRouterID), id: "new", providerID: BuiltInProviders.openRouterID, label: "New"),
    ])
    let data = try JSONEncoder.providerEncoder.encode(importedState)
    try await workspace.importConfiguration(data, strategy: .keepExisting)

    let same = try await workspace.account(id: "same")
    let new = try await workspace.account(id: "new")
    XCTAssertEqual(same.label, "Existing")
    XCTAssertEqual(new.label, "New")
  }

  private func makeEnvironment() async throws -> (
    ProviderWorkspaceStore,
    ProviderAccountManager,
    InMemoryCredentialVault
  ) {
    let registry = try ProviderRegistry.builtIn()
    let workspace = ProviderWorkspaceStore(persistence: InMemoryProviderWorkspacePersistence())
    try await workspace.load()
    let vault = InMemoryCredentialVault()
    let manager = ProviderAccountManager(registry: registry, workspace: workspace, vault: vault)
    return (workspace, manager, vault)
  }
}
