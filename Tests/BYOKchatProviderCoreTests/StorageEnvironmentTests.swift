import Foundation
import Testing

@testable import BYOKchatProviderCore

@Suite("Shared storage environment")
struct StorageEnvironmentTests {
  @Test("Canonical layout is target-independent")
  func canonicalLayout() {
    let root = URL(fileURLWithPath: "/tmp/byok-storage", isDirectory: true)
    let layout = BYOKStorageLayout(rootDirectory: root)

    #expect(layout.providersFile.lastPathComponent == "providers-v1.json")
    #expect(layout.conversationsDirectory.lastPathComponent == "conversations-v1")
    #expect(layout.libraryFile.lastPathComponent == "library-v1.json")
    #expect(layout.projectsFile.lastPathComponent == "projects-v1.json")
    #expect(layout.mcpServersFile.lastPathComponent == "mcp-servers-v1.json")
    #expect(layout.filesDirectory.lastPathComponent == "files-v1")
    #expect(layout.searchDirectory.lastPathComponent == "search-v1")
    #expect(layout.searchIndexDatabaseFile.lastPathComponent == "conversations-fts.sqlite")
  }

  @Test("Telemetry database path comes from host environment")
  func telemetryDatabasePath() {
    let root = URL(fileURLWithPath: "/tmp/byok-storage", isDirectory: true)
    let telemetry = URL(fileURLWithPath: "/tmp/byok-telemetry", isDirectory: true)
    let environment = BYOKStorageEnvironment(
      rootDirectory: root,
      userDefaultsSuiteName: nil,
      credentialService: "test.credentials",
      mcpCredentialService: "test.mcp.credentials",
      telemetryDirectory: telemetry
    )

    #expect(
      environment.telemetryDatabaseURL
        == telemetry.appendingPathComponent("telemetry.sqlite", isDirectory: false)
    )
  }

  @Test("Schema-less library workspace migrates to schema one")
  func migratesLegacyLibraryWorkspace() throws {
    let input = try JSONSerialization.data(withJSONObject: [:])
    let output = try BYOKStorageBootstrap.migrateDataForTesting(
      input,
      kind: .library,
      currentSchemaVersion: 1
    )
    let object = try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
    #expect((object["schemaVersion"] as? NSNumber)?.intValue == 1)
    #expect((object["entries"] as? [Any])?.isEmpty == true)
    #expect((object["tombstones"] as? [String: Any])?.isEmpty == true)
  }

  @Test("Newer workspace is rejected without mutation")
  func rejectsNewerWorkspace() throws {
    let input = Data("{\"schemaVersion\":2,\"entries\":[],\"tombstones\":{}}".utf8)
    #expect(throws: BYOKStorageMigrationError.self) {
      _ = try BYOKStorageBootstrap.migrateDataForTesting(
        input,
        kind: .library,
        currentSchemaVersion: 1
      )
    }
  }
}
