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
    #expect(storedDefault == second.id)
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
      accountManager: manager,
      runtime: runtime
    )
    return (model, workspace, manager)
  }
}

@Suite("Provider logo catalog")
struct ProviderLogoCatalogTests {
  @Test("Built-in providers use their canonical asset")
  func builtInProvider() {
    #expect(
      ProviderLogoCatalog.assetName(for: BuiltInProviders.anthropic)
        == "provider.anthropic")
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
