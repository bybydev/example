import Foundation
import Testing

@testable import BYOKchatProviderCore

@Suite("Shared core services")
struct BYOKCoreServicesTests {
  @Test("Fresh shared graph loads without hydrating chats")
  func loadsFreshSharedGraph() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("byok-core-services-\(UUID().uuidString)", isDirectory: true)
    let telemetry = root.appendingPathComponent("Telemetry", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let suiteName = "byok-core-services-tests-\(UUID().uuidString)"
    let environment = BYOKStorageEnvironment(
      rootDirectory: root,
      userDefaultsSuiteName: suiteName,
      credentialService: "tests.byok.credentials",
      mcpCredentialService: "tests.byok.mcp.credentials",
      telemetryDirectory: telemetry
    )
    defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

    try await BYOKStorageBootstrap.prepare(environment: environment)
    let services = try BYOKCoreServices(
      environment: environment,
      credentialVault: InMemoryCredentialVault(),
      mcpCredentialVault: InMemoryMCPCredentialVault()
    )

    try await services.loadStoredState()

    let providers = await services.providerWorkspace.snapshot()
    let projects = await services.projectWorkspace.allProjects()
    let mcpServers = await services.mcpRuntime.servers()
    let conversations = await services.conversationStore.conversationSummaries()
    let libraryEntries = await services.libraryStore.entries()

    #expect(providers.accounts.isEmpty)
    #expect(projects.isEmpty)
    #expect(mcpServers.isEmpty)
    #expect(conversations.isEmpty)
    #expect(libraryEntries.isEmpty)
  }

  @Test("Composition uses host telemetry policy")
  func usesHostTelemetryPolicy() throws {
    let root = URL(fileURLWithPath: "/tmp/byok-core", isDirectory: true)
    let telemetry = URL(fileURLWithPath: "/tmp/byok-core-telemetry", isDirectory: true)
    let environment = BYOKStorageEnvironment(
      rootDirectory: root,
      userDefaultsSuiteName: nil,
      credentialService: "tests.byok.credentials",
      mcpCredentialService: "tests.byok.mcp.credentials",
      telemetryDirectory: telemetry
    )

    let services = try BYOKCoreServices(
      environment: environment,
      credentialVault: InMemoryCredentialVault(),
      mcpCredentialVault: InMemoryMCPCredentialVault(),
      telemetryRecorder: environment.makeTelemetryRecorder(sessionID: "test-session")
    )

    #expect(services.environment == environment)
    #expect(environment.telemetryDatabaseURL.path.hasSuffix("/byok-core-telemetry/telemetry.sqlite"))
  }
}
