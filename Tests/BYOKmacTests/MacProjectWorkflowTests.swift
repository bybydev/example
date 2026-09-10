import BYOKchatProviderCore
import Foundation
import Testing

@testable import BYOKmac

@MainActor
@Suite("macOS Project workflows")
struct MacProjectWorkflowTests {
  @Test("Project account-default target falls back from an unavailable stored default")
  func projectAccountDefaultUsesUsableModelFallback() async throws {
    let context = try await makeMacProjectTestContext()
    defer { context.cleanup() }

    let providerID = try #require(ProviderKind.deepSeek.defaultProviderID)
    let stale = ProviderModel(providerID: providerID, id: "stale-model", displayName: "Stale")
    let available = ProviderModel(providerID: providerID, id: "available-model", displayName: "Available")
    let account = try await context.services.accountManager.createAccount(
      kind: .deepSeek,
      label: "DeepSeek",
      credential: "test-key",
      defaultModelID: stale.id
    )
    try await context.services.providerWorkspace.mergeModels([stale, available], for: account.id)
    try await context.services.providerWorkspace.mergeModels([available], for: account.id)

    let providers = MacProviderModel(services: context.services)
    try await providers.load()
    let project = ChatProject(
      name: "Fallback",
      accountID: account.id,
      modelID: nil
    )

    let target = try #require(resolveMacProjectTarget(project: project, providers: providers))
    #expect(target.accountID == account.id)
    #expect(target.modelID == available.id)
  }

  @Test("Project explicit unavailable model does not silently change targets")
  func explicitUnavailableProjectModelFails() async throws {
    let context = try await makeMacProjectTestContext()
    defer { context.cleanup() }

    let providerID = try #require(ProviderKind.deepSeek.defaultProviderID)
    let available = ProviderModel(providerID: providerID, id: "available-model", displayName: "Available")
    let account = try await context.services.accountManager.createAccount(
      kind: .deepSeek,
      label: "DeepSeek",
      credential: "test-key",
      defaultModelID: available.id
    )
    try await context.services.providerWorkspace.mergeModels([available], for: account.id)

    let providers = MacProviderModel(services: context.services)
    try await providers.load()
    let project = ChatProject(
      name: "Explicit",
      accountID: account.id,
      modelID: "removed-model"
    )

    #expect(resolveMacProjectTarget(project: project, providers: providers) == nil)
  }

  @Test("Focused Mac Project mutations preserve unrelated state")
  func focusedMacProjectMutationsPreserveState() async throws {
    let context = try await makeMacProjectTestContext()
    defer { context.cleanup() }

    let workspace = MacWorkspaceModel(services: context.services)
    await workspace.reload()
    let projectID = try #require(
      await workspace.createProject(
        name: "Product",
        symbolName: "shippingbox.fill",
        accentID: "orange",
        accountID: nil,
        modelID: nil,
        instructions: "Initial",
        files: [],
        mcpConfiguration: MCPChatToolConfiguration(),
        promptPresets: [],
        toolPresets: []
      )
    )

    #expect(
      await workspace.updateProjectIdentity(
        id: projectID,
        name: "Renamed",
        symbolName: "folder.fill",
        accentID: "teal"
      )
    )
    #expect(await workspace.updateProjectInstructions(id: projectID, instructions: "Keep this"))
    let preset = ProjectPromptPreset(name: "Review", prompt: "Review carefully")
    #expect(await workspace.upsertProjectPromptPreset(preset, projectID: projectID))

    let project = try #require(workspace.project(projectID))
    #expect(project.name == "Renamed")
    #expect(project.instructions == "Keep this")
    #expect(project.projectPromptPresets == [preset])
  }
}

@MainActor
private struct MacProjectTestContext {
  let parent: URL
  let suiteName: String
  let services: BYOKCoreServices

  func cleanup() {
    try? FileManager.default.removeItem(at: parent)
    UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
  }
}

@MainActor
private func makeMacProjectTestContext() async throws -> MacProjectTestContext {
  let parent = FileManager.default.temporaryDirectory
    .appendingPathComponent("byok-mac-project-tests-\(UUID().uuidString)", isDirectory: true)
  let root = parent.appendingPathComponent("Workspace", isDirectory: true)
  let telemetry = parent.appendingPathComponent("Telemetry", isDirectory: true)
  let suiteName = "byok-mac-project-tests-\(UUID().uuidString)"
  let storage = BYOKStorageEnvironment(
    rootDirectory: root,
    userDefaultsSuiteName: suiteName,
    credentialService: "tests.byok.mac.project.credentials.\(UUID().uuidString)",
    mcpCredentialService: "tests.byok.mac.project.mcp.\(UUID().uuidString)",
    telemetryDirectory: telemetry
  )

  try await BYOKStorageBootstrap.prepare(environment: storage)
  let services = try BYOKCoreServices(
    environment: storage,
    credentialVault: InMemoryCredentialVault(),
    mcpCredentialVault: InMemoryMCPCredentialVault()
  )
  try await services.loadStoredState()
  return MacProjectTestContext(parent: parent, suiteName: suiteName, services: services)
}
