import Foundation
import Testing

@testable import BYOKchat

@Suite("App storage bootstrap")
struct AppStorageBootstrapTests {
  @Test("Schema-less provider workspace migrates to schema one")
  func migratesLegacyProviderWorkspace() throws {
    let input = try JSONSerialization.data(withJSONObject: [:])
    let output = try AppStorageBootstrap.migrateDataForTesting(
      input,
      kind: .providers,
      currentSchemaVersion: 1
    )
    let object = try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
    #expect((object["schemaVersion"] as? NSNumber)?.intValue == 1)
    #expect((object["accounts"] as? [Any])?.isEmpty == true)
    #expect((object["modelRecords"] as? [Any])?.isEmpty == true)
    #expect((object["customProviders"] as? [Any])?.isEmpty == true)
  }

  @Test("Current workspace is left byte-for-byte unchanged")
  func currentDataIsUnchanged() throws {
    let input = Data("{\"schemaVersion\":1,\"conversations\":[]}".utf8)
    let output = try AppStorageBootstrap.migrateDataForTesting(
      input,
      kind: .conversations,
      currentSchemaVersion: 1
    )
    #expect(output == input)
  }

  @Test("Newer workspace is rejected without migration")
  func rejectsNewerWorkspace() throws {
    let input = Data("{\"schemaVersion\":2,\"projects\":[],\"conversationProjectIDs\":{}}".utf8)
    do {
      _ = try AppStorageBootstrap.migrateDataForTesting(
        input,
        kind: .projects,
        currentSchemaVersion: 1
      )
      Issue.record("Expected newer schema to be rejected")
    } catch let error as AppStorageMigrationError {
      #expect(error == .newerVersion(store: "projects", stored: 2, supported: 1))
    }
  }
}
