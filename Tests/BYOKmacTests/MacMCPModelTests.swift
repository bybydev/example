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

  @Test("Draft MCP configuration supports toggling servers, policies, project inheritance, and empty override")
  func draftConfigurationSupportsPreSendMutationsAndProjectInheritance() async throws {
    let fixture = try await MacMCPFixture.make()
    let server = MCPRemoteServer(
      id: "draft-server",
      name: "Draft MCP",
      endpoint: URL(string: "https://draft.example.com/mcp")!,
      isEnabled: true
    )
    try await fixture.workspace.upsertServer(server)
    try await fixture.workspace.storeSnapshot(
      MCPServerSnapshot(
        serverID: server.id,
        protocolVersion: "2025-03-26",
        era: .modern,
        tools: [
          MCPRemoteTool(
            remoteName: "search",
            title: "Search",
            description: "Search docs",
            inputSchema: .object([:])
          )
        ],
        expiresAt: Date.now.addingTimeInterval(300)
      )
    )
    let project = try await fixture.projectWorkspace.createProject(
      name: "Research",
      symbolName: "folder.fill",
      accentID: "blue",
      accountID: nil,
      modelID: nil,
      instructions: "",
      mcpConfiguration: MCPChatToolConfiguration(enabledServerIDs: [server.id])
    )
    await fixture.model.reloadFromStorage()

    // Without a draft override, a new chat in a project inherits project tools.
    #expect(fixture.model.inheritsProjectToolsForDraft(draft: nil, projectID: project.id))
    #expect(
      fixture.model.effectiveDraftConfiguration(draft: nil, projectID: project.id).enabledServerIDs
        == [server.id]
    )

    // Disabling the inherited server produces an explicit empty override rather than reverting to nil.
    let disabledResult = await fixture.model.updatedDraftServerEnabled(
      false,
      serverID: server.id,
      currentDraft: nil,
      projectID: project.id
    )
    #expect(disabledResult.succeeded)
    #expect(disabledResult.configuration == MCPChatToolConfiguration())
    #expect(!fixture.model.inheritsProjectToolsForDraft(draft: disabledResult.configuration, projectID: project.id))

    // Standalone new chat: enabling server + setting tool policy + resetting back to empty clears to nil.
    let enabledStandalone = await fixture.model.updatedDraftServerEnabled(
      true,
      serverID: server.id,
      currentDraft: nil,
      projectID: nil
    )
    #expect(enabledStandalone.succeeded)
    #expect(enabledStandalone.configuration?.enabledServerIDs == [server.id])

    let exposedTool = MCPToolNamespace.exposedName(serverID: server.id, remoteName: "search")
    let policyUpdated = fixture.model.updatedDraftToolPolicy(
      .alwaysAllow,
      exposedToolName: exposedTool,
      currentDraft: enabledStandalone.configuration,
      projectID: nil
    )
    #expect(policyUpdated.succeeded)
    #expect(policyUpdated.configuration?.policy(for: exposedTool) == .alwaysAllow)

    let policyCleared = fixture.model.updatedDraftToolPolicy(
      .ask,
      exposedToolName: exposedTool,
      currentDraft: policyUpdated.configuration,
      projectID: nil
    )
    #expect(policyCleared.succeeded)
    #expect(policyCleared.configuration?.toolPolicies.isEmpty == true)

    let disabledStandalone = await fixture.model.updatedDraftServerEnabled(
      false,
      serverID: server.id,
      currentDraft: policyCleared.configuration,
      projectID: nil
    )
    #expect(disabledStandalone.succeeded)
    #expect(disabledStandalone.configuration == nil)
  }

  @Test("Draft preset application filters unknown servers and strips Ask policies")
  func draftPresetApplication() async throws {
    let fixture = try await MacMCPFixture.make()

    let allowedServer = MCPRemoteServer(
      id: "allowed-server",
      name: "Allowed",
      endpoint: URL(string: "https://allowed.example.com/mcp")!,
      isEnabled: true
    )
    try await fixture.workspace.upsertServer(allowedServer)
    await fixture.model.reloadFromStorage()

    let preset = MCPChatToolConfiguration(
      enabledServerIDs: [allowedServer.id, "deleted-server"],
      toolPolicies: [
        "mcp_allowed_read": .alwaysAllow,
        "mcp_allowed_ask": .ask,
      ]
    )
    let applied = fixture.model.validatedDraftPresetConfiguration(preset, projectID: nil)
    #expect(applied.succeeded)
    #expect(applied.configuration?.enabledServerIDs == [allowedServer.id])
    #expect(applied.configuration?.toolPolicies == ["mcp_allowed_read": .alwaysAllow])
    #expect(fixture.model.statusMessage == "Tool configuration applied")
  }

  @Test("activeToolCount excludes disabled servers, missing credentials, and disabled tools")
  func activeToolCountReflectsUsableServersAndTools() async throws {
    let fixture = try await MacMCPFixture.make()
    let readyServer = MCPRemoteServer(
      id: "ready-server",
      name: "Ready",
      endpoint: URL(string: "https://ready.example.com/mcp")!,
      authentication: MCPAuthentication(kind: .none),
      isEnabled: true
    )
    let disabledServer = MCPRemoteServer(
      id: "disabled-server",
      name: "Disabled",
      endpoint: URL(string: "https://disabled.example.com/mcp")!,
      authentication: MCPAuthentication(kind: .none),
      isEnabled: false
    )
    let missingCredServer = MCPRemoteServer(
      id: "missing-cred-server",
      name: "Missing Cred",
      endpoint: URL(string: "https://cred.example.com/mcp")!,
      authentication: MCPAuthentication(kind: .bearer),
      isEnabled: true
    )
    for server in [readyServer, disabledServer, missingCredServer] {
      try await fixture.workspace.upsertServer(server)
      try await fixture.workspace.storeSnapshot(
        MCPServerSnapshot(
          serverID: server.id,
          protocolVersion: "2025-03-26",
          era: .modern,
          tools: [
            MCPRemoteTool(remoteName: "read", title: "Read", description: "", inputSchema: .object([:])),
            MCPRemoteTool(remoteName: "write", title: "Write", description: "", inputSchema: .object([:])),
          ],
          expiresAt: Date.now.addingTimeInterval(300)
        )
      )
    }
    await fixture.model.reloadFromStorage()

    let disabledToolName = MCPToolNamespace.exposedName(serverID: readyServer.id, remoteName: "write")
    let config = MCPChatToolConfiguration(
      enabledServerIDs: [readyServer.id, disabledServer.id, missingCredServer.id],
      toolPolicies: [disabledToolName: .disabled]
    )

    #expect(fixture.model.activeServerCount(for: config) == 1)
    #expect(fixture.model.activeToolCount(for: config) == 1)
  }

  @Test("Bulk tool policy updates apply across all tools for a server in chats and drafts")
  func bulkToolPoliciesUpdateServerTools() async throws {
    let fixture = try await MacMCPFixture.make()
    let server = MCPRemoteServer(
      id: "bulk-server",
      name: "Bulk",
      endpoint: URL(string: "https://bulk.example.com/mcp")!,
      isEnabled: true
    )
    try await fixture.workspace.upsertServer(server)
    try await fixture.workspace.storeSnapshot(
      MCPServerSnapshot(
        serverID: server.id,
        protocolVersion: "2025-03-26",
        era: .modern,
        tools: [
          MCPRemoteTool(remoteName: "one", title: "One", description: "", inputSchema: .object([:])),
          MCPRemoteTool(remoteName: "two", title: "Two", description: "", inputSchema: .object([:])),
        ],
        expiresAt: Date.now.addingTimeInterval(300)
      )
    )
    await fixture.model.reloadFromStorage()

    let conversationID: ConversationID = "bulk-chat"
    try await fixture.workspace.replaceChatConfiguration(
      MCPChatToolConfiguration(enabledServerIDs: [server.id]),
      conversationID: conversationID
    )
    await fixture.model.reloadFromStorage()

    #expect(await fixture.model.setAllChatToolPolicies(.alwaysAllow, serverID: server.id, conversationID: conversationID))
    let firstExposed = MCPToolNamespace.exposedName(serverID: server.id, remoteName: "one")
    let secondExposed = MCPToolNamespace.exposedName(serverID: server.id, remoteName: "two")
    #expect(fixture.model.toolPolicy(firstExposed, for: conversationID) == .alwaysAllow)
    #expect(fixture.model.toolPolicy(secondExposed, for: conversationID) == .alwaysAllow)

    #expect(await fixture.model.setAllChatToolPolicies(.ask, serverID: server.id, conversationID: conversationID))
    #expect(fixture.model.toolPolicy(firstExposed, for: conversationID) == .ask)
    #expect(fixture.model.chatConfiguration(for: conversationID).toolPolicies.isEmpty)

    let draftUpdated = fixture.model.updatedDraftAllToolPolicies(
      .disabled,
      serverID: server.id,
      currentDraft: MCPChatToolConfiguration(enabledServerIDs: [server.id]),
      projectID: nil
    )
    #expect(draftUpdated.succeeded)
    #expect(draftUpdated.configuration?.policy(for: firstExposed) == .disabled)
    #expect(draftUpdated.configuration?.policy(for: secondExposed) == .disabled)
  }

  @Test("Elicitation form support provides specific per-field validation errors")
  func elicitationFieldValidationErrors() {
    let requiredText = MCPElicitationField(name: "query", kind: .string, isRequired: true)
    #expect(MacMCPElicitationFormSupport.fieldError(for: requiredText, storedValue: "   ") != nil)
    #expect(MacMCPElicitationFormSupport.fieldError(for: requiredText, storedValue: "hello") == nil)

    let integerField = MCPElicitationField(name: "limit", kind: .integer, isRequired: false)
    #expect(MacMCPElicitationFormSupport.fieldError(for: integerField, storedValue: "") == nil)
    #expect(MacMCPElicitationFormSupport.fieldError(for: integerField, storedValue: "abc") != nil)
    #expect(MacMCPElicitationFormSupport.fieldError(for: integerField, storedValue: "42") == nil)

    let enumArray = MCPElicitationField(
      name: "tags",
      kind: .stringArray,
      isRequired: true,
      allowedValues: ["alpha", "beta"]
    )
    #expect(MacMCPElicitationFormSupport.fieldError(for: enumArray, storedValue: "alpha, gamma") != nil)
    #expect(MacMCPElicitationFormSupport.fieldError(for: enumArray, storedValue: "alpha, beta") == nil)
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
    transport: any ProviderHTTPTransport = FailingMCPTransport()
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
      elicitations: elicitations
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
