import BYOKchatProviderCore
import Foundation
import Testing

@testable import BYOKmac

@MainActor
@Suite("macOS MCP workflows")
struct MacMCPModelTests {
  @Test("Failed MCP config save rolls back a newly written credential")
  func failedCreateRollsBackCredential() async throws {
    let fixture = try await MacMCPFixture.make()
    await fixture.persistence.failNextSave()

    let saved = await fixture.model.saveServer(
      existing: nil,
      name: "Secure MCP",
      endpoint: "https://secure.example.com/mcp",
      authenticationKind: .bearer,
      authenticationHeader: "",
      credential: "secret-token",
      additionalHeaders: [:],
      isEnabled: false
    )

    #expect(saved == false)
    #expect(await fixture.workspace.allServers().isEmpty)
    #expect(await fixture.vault.allCredentialServerIDs().isEmpty)
  }

  @Test("Failed MCP edit restores both prior config and prior credential")
  func failedEditRestoresPriorState() async throws {
    let fixture = try await MacMCPFixture.make()
    let original = MCPRemoteServer(
      id: "edit-server",
      name: "Original",
      endpoint: URL(string: "https://original.example.com/mcp")!,
      authentication: MCPAuthentication(kind: .bearer),
      isEnabled: false
    )
    try await fixture.workspace.upsertServer(original)
    try await fixture.vault.setCredential("old-secret", serverID: original.id)
    await fixture.model.reloadFromStorage()

    await fixture.persistence.failNextSave()
    let saved = await fixture.model.saveServer(
      existing: original,
      name: "Edited",
      endpoint: "https://edited.example.com/mcp",
      authenticationKind: .bearer,
      authenticationHeader: "",
      credential: "new-secret",
      additionalHeaders: ["X-Test": "updated"],
      isEnabled: false
    )

    #expect(saved == false)
    let stored = try await fixture.workspace.server(id: original.id)
    #expect(stored.name == original.name)
    #expect(stored.endpoint == original.endpoint)
    #expect(stored.additionalHeaders == original.additionalHeaders)
    #expect(try await fixture.vault.credential(serverID: original.id) == "old-secret")
  }

  @Test("Failed server deletion leaves its credential intact")
  func failedDeleteKeepsCredential() async throws {
    let fixture = try await MacMCPFixture.make()
    let server = MCPRemoteServer(
      id: "delete-fail-server",
      name: "Keep Me",
      endpoint: URL(string: "https://keep-me.example.com/mcp")!,
      authentication: MCPAuthentication(kind: .bearer),
      isEnabled: false
    )
    try await fixture.workspace.upsertServer(server)
    try await fixture.vault.setCredential("keep-secret", serverID: server.id)
    await fixture.model.reloadFromStorage()

    await fixture.persistence.failNextSave()
    let deleted = await fixture.model.deleteServer(server.id)

    #expect(deleted == false)
    let stored = try await fixture.workspace.server(id: server.id)
    #expect(stored.id == server.id)
    #expect(stored.name == server.name)
    #expect(stored.endpoint == server.endpoint)
    #expect(try await fixture.vault.credential(serverID: server.id) == "keep-secret")
  }

  @Test("Keychain cleanup failure does not undo an MCP server deletion")
  func deleteCommitsBeforeCredentialCleanup() async throws {
    let fixture = try await MacMCPFixture.make()
    let server = MCPRemoteServer(
      id: "delete-cleanup-server",
      name: "Delete Me",
      endpoint: URL(string: "https://delete-me.example.com/mcp")!,
      authentication: MCPAuthentication(kind: .bearer),
      isEnabled: false
    )
    try await fixture.workspace.upsertServer(server)
    try await fixture.vault.setCredential("stale-after-delete", serverID: server.id)
    await fixture.model.reloadFromStorage()

    await fixture.vault.failNextRemove()
    let deleted = await fixture.model.deleteServer(server.id)

    #expect(deleted)
    #expect(await fixture.workspace.allServers().isEmpty)
    #expect(fixture.model.servers.isEmpty)
    #expect(fixture.model.statusMessage?.contains("Keychain cleanup failed") == true)
    #expect(try await fixture.vault.credential(serverID: server.id) == "stale-after-delete")
  }

  @Test("Discovery failure is a warning after the server config commits")
  func discoveryFailureDoesNotReportSaveFailure() async throws {
    let fixture = try await MacMCPFixture.make(transport: FailingMCPTransport())

    let saved = await fixture.model.saveServer(
      existing: nil,
      name: "Offline MCP",
      endpoint: "https://offline.example.com/mcp",
      authenticationKind: .none,
      authenticationHeader: "",
      credential: nil,
      additionalHeaders: [:],
      isEnabled: true
    )

    #expect(saved)
    #expect(await fixture.workspace.allServers().count == 1)
    #expect(fixture.model.servers.count == 1)
    #expect(fixture.model.statusMessage?.contains("Tool discovery failed") == true)
    #expect(fixture.model.errorMessage == nil)
  }

  @Test("Failed Project tool customization does not freeze inheritance into an explicit override")
  func failedInheritedCustomizationKeepsInheritance() async throws {
    let fixture = try await MacMCPFixture.make()
    let server = MCPRemoteServer(
      id: "project-server",
      name: "Project MCP",
      endpoint: URL(string: "https://project.example.com/mcp")!,
      isEnabled: false
    )
    try await fixture.workspace.upsertServer(server)

    let project = try await fixture.projectWorkspace.createProject(
      name: "Project",
      symbolName: "folder.fill",
      accentID: "blue",
      accountID: nil,
      modelID: nil,
      instructions: "",
      mcpConfiguration: MCPChatToolConfiguration(enabledServerIDs: [server.id])
    )
    let conversationID: ConversationID = "project-conversation"
    try await fixture.projectWorkspace.assignConversation(conversationID, to: project.id)
    await fixture.model.reloadFromStorage()

    #expect(fixture.model.inheritsProjectTools(conversationID))
    await fixture.persistence.failNextSave()

    let changed = await fixture.model.setChatToolPolicy(
      .alwaysAllow,
      exposedToolName: "mcp_project_tool",
      conversationID: conversationID
    )

    #expect(changed == false)
    #expect(await fixture.workspace.explicitChatConfiguration(for: conversationID) == nil)
    #expect(await fixture.projectWorkspace.mcpConfiguration(for: conversationID)?.enabledServerIDs == [server.id])
    #expect(fixture.model.inheritsProjectTools(conversationID))
  }

  @Test("Restored MCP overflow cannot be activated or configured and unlocks after deletion")
  func restoredMCPOverflowModelBoundary() async throws {
    let suiteName = "byok-mac-mcp-restrictions-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let restrictions = MacProResourceRestrictions(defaults: defaults, keyPrefix: "test")
    let fixture = try await MacMCPFixture.make(
      restrictions: restrictions,
      entitlementAccessOverride: .free
    )

    let first = MCPRemoteServer(
      id: "free-server",
      name: "Free Server",
      endpoint: URL(string: "https://free.example.com/mcp")!,
      isEnabled: false
    )
    let second = MCPRemoteServer(
      id: "overflow-server",
      name: "Overflow Server",
      endpoint: URL(string: "https://overflow.example.com/mcp")!,
      isEnabled: false
    )
    try await fixture.workspace.upsertServer(first)
    try await fixture.workspace.upsertServer(second)
    restrictions.recordFullBackupImport(
      before: MacProResourceSnapshot(),
      after: MacProResourceSnapshot(
        mcpServerIDs: [first.id.rawValue, second.id.rawValue]
      ),
      strategy: .replaceExisting,
      entitlement: .free
    )
    await fixture.model.reloadFromStorage()

    #expect(!fixture.model.isServerRestricted(first.id))
    #expect(fixture.model.isServerRestricted(second.id))

    let edited = await fixture.model.saveServer(
      existing: second,
      name: "Blocked Edit",
      endpoint: second.endpoint.absoluteString,
      authenticationKind: .none,
      authenticationHeader: "",
      credential: nil,
      additionalHeaders: [:],
      isEnabled: false
    )
    #expect(!edited)
    #expect(!(await fixture.model.setEnabled(true, serverID: second.id)))
    #expect(!(await fixture.model.refresh(second.id)))
    #expect(
      !(await fixture.model.setChatServerEnabled(
        true,
        serverID: second.id,
        conversationID: "restricted-chat"
      ))
    )
    #expect(
      !(await fixture.model.applyChatConfiguration(
        MCPChatToolConfiguration(enabledServerIDs: [second.id]),
        conversationID: "restricted-chat"
      ))
    )
    #expect(fixture.model.errorMessage != nil)

    // Teardown remains available while the server is restricted.
    #expect(
      await fixture.model.applyChatConfiguration(
        MCPChatToolConfiguration(),
        conversationID: "restricted-chat"
      )
    )
    #expect(await fixture.model.deleteServer(first.id))

    #expect(!fixture.model.isServerRestricted(second.id))
    #expect(await fixture.model.setEnabled(true, serverID: second.id))
  }

  @Test("Deleting an MCP server removes stale project references and notifies project observer")
  func deleteServerRemovesProjectReferences() async throws {
    let fixture = try await MacMCPFixture.make()
    let server = MCPRemoteServer(
      id: "project-ref-server",
      name: "Project Ref MCP",
      endpoint: URL(string: "https://project-ref.example.com/mcp")!,
      isEnabled: false
    )
    try await fixture.workspace.upsertServer(server)
    let project = try await fixture.projectWorkspace.createProject(
      name: "Work",
      symbolName: "folder.fill",
      accentID: "blue",
      accountID: nil,
      modelID: nil,
      instructions: "",
      mcpConfiguration: MCPChatToolConfiguration(enabledServerIDs: [server.id])
    )
    await fixture.model.reloadFromStorage()

    @MainActor
    final class CallbackBox {
      var count = 0
    }
    let callback = CallbackBox()
    fixture.model.onProjectStateChanged = {
      callback.count += 1
    }

    #expect(await fixture.model.deleteServer(server.id))
    #expect(callback.count >= 1)
    let updatedProject = await fixture.projectWorkspace.snapshot().projects.first { $0.id == project.id }
    #expect(updatedProject?.mcpConfiguration?.enabledServerIDs.contains(server.id) != true)
  }

  @Test("Disabling an inherited project MCP server preserves an explicit empty chat override")
  func disablingInheritedServerPreservesEmptyOverride() async throws {
    let fixture = try await MacMCPFixture.make()
    let server = MCPRemoteServer(
      id: "inherited-server",
      name: "Inherited MCP",
      endpoint: URL(string: "https://inherited.example.com/mcp")!,
      isEnabled: true
    )
    try await fixture.workspace.upsertServer(server)
    let project = try await fixture.projectWorkspace.createProject(
      name: "Project",
      symbolName: "folder.fill",
      accentID: "blue",
      accountID: nil,
      modelID: nil,
      instructions: "",
      mcpConfiguration: MCPChatToolConfiguration(enabledServerIDs: [server.id])
    )
    let conversationID: ConversationID = "inherited-override-chat"
    try await fixture.projectWorkspace.assignConversation(conversationID, to: project.id)
    await fixture.model.reloadFromStorage()

    #expect(fixture.model.inheritsProjectTools(conversationID))
    #expect(fixture.model.isServerEnabled(server.id, for: conversationID))

    let disabled = await fixture.model.setChatServerEnabled(
      false,
      serverID: server.id,
      conversationID: conversationID
    )

    #expect(disabled)
    #expect(fixture.model.hasChatOverride(conversationID))
    #expect(!fixture.model.inheritsProjectTools(conversationID))
    #expect(!fixture.model.isServerEnabled(server.id, for: conversationID))
    #expect(fixture.model.chatConfiguration(for: conversationID).enabledServerIDs.isEmpty)
  }
}

@MainActor
private struct MacMCPFixture {
  let persistence: FailingMacMCPWorkspacePersistence
  let workspace: MCPWorkspaceStore
  let vault: FailingMacMCPCredentialVault
  let projectWorkspace: ProjectWorkspaceStore
  let model: MacMCPModel

  static func make(
    transport: any ProviderHTTPTransport = FailingMCPTransport(),
    restrictions: MacProResourceRestrictions = MacPurchaseStore.restrictions,
    entitlementAccessOverride: MacProEntitlementAccess? = nil
  ) async throws -> MacMCPFixture {
    let persistence = FailingMacMCPWorkspacePersistence()
    let workspace = MCPWorkspaceStore(persistence: persistence)
    let vault = FailingMacMCPCredentialVault()
    let projectWorkspace = ProjectWorkspaceStore(
      persistence: InMemoryProjectWorkspacePersistence()
    )
    let approvals = MCPToolApprovalCenter()
    let elicitations = MCPElicitationCenter()
    let runtime = MCPRemoteRuntime(
      workspace: workspace,
      vault: vault,
      transport: transport
    )

    try await workspace.load()
    try await projectWorkspace.load()

    let model = MacMCPModel(
      runtime: runtime,
      workspace: workspace,
      credentialVault: vault,
      projectWorkspace: projectWorkspace,
      approvals: approvals,
      elicitations: elicitations,
      restrictions: restrictions,
      entitlementAccessOverride: entitlementAccessOverride
    )
    try await model.load()

    return MacMCPFixture(
      persistence: persistence,
      workspace: workspace,
      vault: vault,
      projectWorkspace: projectWorkspace,
      model: model
    )
  }
}

private enum InjectedMacMCPPersistenceError: Error {
  case saveFailed
}

private actor FailingMacMCPWorkspacePersistence: MCPWorkspacePersistence {
  private var data: Data?
  private var shouldFailNextSave = false

  func loadData() -> Data? { data }

  func failNextSave() {
    shouldFailNextSave = true
  }

  func saveData(_ data: Data) throws {
    if shouldFailNextSave {
      shouldFailNextSave = false
      throw InjectedMacMCPPersistenceError.saveFailed
    }
    self.data = data
  }
}

private actor FailingMacMCPCredentialVault: MCPCredentialVault {
  private var values: [MCPServerID: String] = [:]
  private var shouldFailNextSet = false
  private var shouldFailNextRemove = false

  func failNextSet() {
    shouldFailNextSet = true
  }

  func failNextRemove() {
    shouldFailNextRemove = true
  }

  func credential(serverID: MCPServerID) -> String? {
    values[serverID]
  }

  func setCredential(_ value: String?, serverID: MCPServerID) throws {
    if shouldFailNextSet {
      shouldFailNextSet = false
      throw MCPError.transport("Injected MCP credential write failure.")
    }
    if let value, !value.isEmpty {
      values[serverID] = value
    } else {
      values.removeValue(forKey: serverID)
    }
  }

  func removeCredential(serverID: MCPServerID) throws {
    if shouldFailNextRemove {
      shouldFailNextRemove = false
      throw MCPError.transport("Injected MCP credential cleanup failure.")
    }
    values.removeValue(forKey: serverID)
  }

  func allCredentialServerIDs() -> Set<MCPServerID> {
    Set(values.keys)
  }
}

private actor FailingMCPTransport: ProviderHTTPTransport {
  func data(for request: URLRequest) async throws -> ProviderHTTPResponse {
    throw MCPError.transport("Injected MCP discovery failure.")
  }

  func stream(for request: URLRequest) async throws -> ProviderHTTPByteStream {
    throw MCPError.transport("Injected MCP discovery failure.")
  }
}
