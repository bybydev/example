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

    let environment = BYOKStorageEnvironment(
      rootDirectory: root,
      userDefaultsSuiteName: "byok-core-services-tests-\(UUID().uuidString)",
      credentialService: "tests.byok.credentials",
      mcpCredentialService: "tests.byok.mcp.credentials",
      telemetryDirectory: telemetry
    )

    try await BYOKStorageBootstrap.prepare(environment: environment)
    let services = try BYOKCoreServices(
      environment: environment,
      credentialVault: InMemoryCredentialVault(),
      mcpCredentialVault: InMemoryMCPCredentialVault()
    )

    try await services.loadStoredState()

    #expect(await services.providerWorkspace.snapshot().accounts.isEmpty)
    #expect(await services.projectWorkspace.allProjects().isEmpty)
    #expect(await services.mcpRuntime.servers().isEmpty)
    #expect(await services.conversationStore.conversationSummaries().isEmpty)
    #expect(await services.libraryStore.entries().isEmpty)
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
