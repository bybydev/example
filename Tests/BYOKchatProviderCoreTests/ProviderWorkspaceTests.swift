import XCTest

@testable import BYOKchatProviderCore

final class ProviderWorkspaceTests: XCTestCase {
  func testBuiltInRegistryContainsPriorityProviders() async throws {
    let registry = try ProviderRegistry.builtIn()
    let ids = Set(await registry.allDefinitions().map(\.id))
    XCTAssertEqual(
      ids, [BuiltInProviders.deepSeekID, BuiltInProviders.openRouterID, BuiltInProviders.nvidiaID])
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
      providerID: BuiltInProviders.deepSeekID,
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
      providerID: BuiltInProviders.openRouterID,
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

  func testModelRefreshPreservesFavoritesManualModelsAndMarksMissingModelsUnavailable() async throws
  {
    let (workspace, manager, _) = try await makeEnvironment()
    let account = try await manager.createAccount(
      providerID: BuiltInProviders.nvidiaID,
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
    XCTAssertEqual(records.first(where: { $0.model.id == second.id })?.isAvailable, false)
    XCTAssertEqual(records.first(where: { $0.model.id == manual.id })?.isManual, true)
    XCTAssertEqual(records.first(where: { $0.model.id == manual.id })?.isAvailable, true)
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
      providerID: definition.id, label: "Local", credential: nil, defaultModelID: "model")

    let resolved = try await manager.resolvedAccount(id: account.id)
    XCTAssertNil(resolved.apiKey)
  }

  func testKeepExistingImportDoesNotReplaceExistingAccount() async throws {
    let persistence = InMemoryProviderWorkspacePersistence()
    let workspace = ProviderWorkspaceStore(persistence: persistence)
    try await workspace.load()
    let existing = ProviderAccount(
      id: "same", providerID: BuiltInProviders.deepSeekID, label: "Existing")
    try await workspace.upsertAccount(existing)

    let importedState = ProviderWorkspaceState(accounts: [
      ProviderAccount(id: "same", providerID: BuiltInProviders.deepSeekID, label: "Imported"),
      ProviderAccount(id: "new", providerID: BuiltInProviders.openRouterID, label: "New"),
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
