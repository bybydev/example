import BYOKchatProviderCore
import Testing

@testable import BYOKchat

@MainActor
@Suite("Provider management defaults")
struct ProviderManagementModelTests {
  @Test("Unavailable default model is repaired to an available model")
  func repairsUnavailableDefaultModel() async throws {
    let environment = try await makeEnvironment()
    let oldModel = ProviderModel(
      providerID: BuiltInProviders.openAIID,
      id: "old-model",
      displayName: "Old Model"
    )
    let newModel = ProviderModel(
      providerID: BuiltInProviders.openAIID,
      id: "new-model",
      displayName: "New Model"
    )
    let account = try await environment.manager.createAccount(
      providerID: BuiltInProviders.openAIID,
      label: "Primary",
      credential: "test-key",
      defaultModelID: oldModel.id
    )
    try await environment.workspace.mergeModels([oldModel, newModel], for: account.id)
    try await environment.workspace.mergeModels([newModel], for: account.id)
    try await environment.workspace.setDefaultAccount(account.id)

    await environment.model.load()

    #expect(environment.model.errorMessage == nil)
    #expect(environment.model.defaultAccountID == account.id)
    #expect(environment.model.accounts.first?.id == account.id)
    #expect(environment.model.accounts.first?.defaultModelID == newModel.id)
    #expect(await environment.workspace.defaultAccountID() == account.id)
  }

  @Test("Unusable persisted default fails over to a ready connection")
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
      providerID: BuiltInProviders.openAIID,
      label: "First",
      credential: "first-key",
      defaultModelID: firstModel.id
    )
    let second = try await environment.manager.createAccount(
      providerID: BuiltInProviders.anthropicID,
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

    #expect(environment.model.errorMessage == nil)
    #expect(environment.model.defaultAccountID == second.id)
    #expect(environment.model.accounts.first?.id == second.id)
    #expect(await environment.workspace.defaultAccountID() == second.id)
  }

  private func makeEnvironment() async throws -> (
    model: ProviderManagementModel,
    workspace: ProviderWorkspaceStore,
    manager: ProviderAccountManager
  ) {
    let registry = try ProviderRegistry.builtIn()
    let workspace = ProviderWorkspaceStore(persistence: InMemoryProviderWorkspacePersistence())
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
      accounts: manager
    )
    let model = ProviderManagementModel(
      registry: registry,
      workspace: workspace,
      vault: vault,
      accountManager: manager,
      runtime: runtime
    )
    return (model, workspace, manager)
  }
}
