import Foundation
import Testing

@testable import BYOKchatProviderCore

@Suite("MCP workspace transaction reliability")
struct MCPWorkspaceTransactionTests {
  @Test("Failed Always Allow persistence never increases live permissions")
  func failedAlwaysAllowDoesNotMutateCommittedState() async throws {
    let persistence = FailingMCPWorkspacePersistence()
    let store = MCPWorkspaceStore(persistence: persistence)
    try await store.load()

    let server = testMCPServer(id: "approval-server")
    try await store.upsertServer(server)
    let conversationID: ConversationID = "approval-chat"
    try await store.setChatServerEnabled(true, serverID: server.id, conversationID: conversationID)

    await persistence.failNextSave()
    do {
      try await store.setChatToolPolicy(
        .alwaysAllow,
        exposedToolName: "mcp_approval_tool",
        conversationID: conversationID
      )
      Issue.record("Expected injected persistence failure")
    } catch {}

    let live = await store.chatConfiguration(for: conversationID)
    #expect(live.policy(for: "mcp_approval_tool") == .ask)

    let storedData = await persistence.loadData()
    let persisted = try #require(storedData)
    let decoded = try JSONDecoder.provider.decode(MCPWorkspaceState.self, from: persisted)
    #expect(
      decoded.chatConfigurations?[conversationID.rawValue]?
        .policy(for: "mcp_approval_tool") == .ask
    )
  }

  @Test("Replacing inherited chat tools commits atomically")
  func replaceChatConfigurationIsAtomic() async throws {
    let persistence = FailingMCPWorkspacePersistence()
    let store = MCPWorkspaceStore(persistence: persistence)
    try await store.load()

    let first = testMCPServer(id: "first-server")
    let second = testMCPServer(id: "second-server")
    try await store.upsertServer(first)
    try await store.upsertServer(second)

    let conversationID: ConversationID = "project-chat"
    let original = MCPChatToolConfiguration(enabledServerIDs: [first.id])
    try await store.replaceChatConfiguration(original, conversationID: conversationID)

    let replacement = MCPChatToolConfiguration(
      enabledServerIDs: [second.id],
      toolPolicies: ["mcp_second_tool": .alwaysAllow]
    )
    await persistence.failNextSave()
    do {
      try await store.replaceChatConfiguration(replacement, conversationID: conversationID)
      Issue.record("Expected injected persistence failure")
    } catch {}

    #expect(await store.chatConfiguration(for: conversationID) == original)
  }

  @Test("Failed server deletion preserves the committed server and chat selection")
  func failedDeletePreservesCommittedState() async throws {
    let persistence = FailingMCPWorkspacePersistence()
    let store = MCPWorkspaceStore(persistence: persistence)
    try await store.load()

    let server = testMCPServer(id: "delete-server")
    let conversationID: ConversationID = "delete-chat"
    try await store.upsertServer(server)
    try await store.setChatServerEnabled(true, serverID: server.id, conversationID: conversationID)

    await persistence.failNextSave()
    do {
      try await store.deleteServer(server.id)
      Issue.record("Expected injected persistence failure")
    } catch {}

    #expect(await store.allServers().map(\.id) == [server.id])
    #expect(await store.chatConfiguration(for: conversationID).enabledServerIDs == [server.id])
  }

  @Test("Concurrent MCP mutations serialize without losing committed changes")
  func concurrentMutationsSerialize() async throws {
    let persistence = FailingMCPWorkspacePersistence(saveDelayNanoseconds: 15_000_000)
    let store = MCPWorkspaceStore(persistence: persistence)
    try await store.load()

    let first = testMCPServer(id: "concurrent-first")
    let second = testMCPServer(id: "concurrent-second")

    async let saveFirst: Void = store.upsertServer(first)
    async let saveSecond: Void = store.upsertServer(second)
    _ = try await (saveFirst, saveSecond)

    #expect(Set(await store.allServers().map(\.id)) == [first.id, second.id])

    let storedData = await persistence.loadData()
    let persisted = try #require(storedData)
    let decoded = try JSONDecoder.provider.decode(MCPWorkspaceState.self, from: persisted)
    #expect(Set(decoded.servers.map(\.id)) == [first.id, second.id])
  }

  @Test("Disabling inherited server preserves explicit empty override atomically")
  func preserveEmptyKeepsExplicitOverrideForProjectChat() async throws {
    let persistence = FailingMCPWorkspacePersistence()
    let store = MCPWorkspaceStore(persistence: persistence)
    try await store.load()

    let server = testMCPServer(id: "inherited-server")
    try await store.upsertServer(server)

    let conversationID: ConversationID = "project-chat"
    let inherited = MCPChatToolConfiguration(enabledServerIDs: [server.id])

    // Turning off the only inherited server stores an explicit empty override
    // so the chat stops inheriting rather than snapping back to enabled.
    try await store.setChatServerEnabled(
      false,
      serverID: server.id,
      conversationID: conversationID,
      inheritedBase: inherited,
      preserveEmpty: true
    )
    let explicit = try #require(await store.explicitChatConfiguration(for: conversationID))
    #expect(explicit.enabledServerIDs.isEmpty)
    #expect(explicit.toolPolicies.isEmpty)

    // Explicit Reset deletes the override back to nil.
    try await store.removeChatConfiguration(conversationID: conversationID)
    #expect(await store.explicitChatConfiguration(for: conversationID) == nil)
  }

  @Test("Failed load blocks subsequent writes from overwriting existing data")
  func failedLoadBlocksSubsequentWrites() async throws {
    let newerVersion = Data(#"{"schemaVersion":99,"servers":[],"snapshots":[]}"#.utf8)
    let persistence = FailingMCPWorkspacePersistence(data: newerVersion)
    let store = MCPWorkspaceStore(persistence: persistence)

    await #expect(throws: ProviderError.workspaceVersionUnsupported(99)) {
      try await store.load()
    }

    await #expect(throws: MCPError.self) {
      try await store.upsertServer(testMCPServer(id: "new-server"))
    }
    #expect(await persistence.loadData() == newerVersion)
  }

  @Test("Server validation rejects case-insensitive duplicate headers and auth collisions")
  func validateServerRejectsHeaderDuplicatesAndAuthCollisions() {
    let duplicateCase = MCPRemoteServer(
      id: "dup-headers",
      name: "Dup",
      endpoint: URL(string: "https://dup.example.com/mcp")!,
      additionalHeaders: ["X-Tenant": "a", "x-tenant": "b"]
    )
    #expect(throws: MCPError.self) {
      try MCPWorkspaceStore.validateServer(duplicateCase)
    }

    let authCollision = MCPRemoteServer(
      id: "auth-collision",
      name: "Collision",
      endpoint: URL(string: "https://collision.example.com/mcp")!,
      authentication: MCPAuthentication(kind: .customHeader, headerName: "X-API-Key"),
      additionalHeaders: ["x-api-key": "override"]
    )
    #expect(throws: MCPError.self) {
      try MCPWorkspaceStore.validateServer(authCollision)
    }
  }

  @Test("Re-adding or importing a deleted server clears its tombstone")
  func reAddingDeletedServerClearsTombstone() async throws {
    let store = MCPWorkspaceStore(persistence: InMemoryMCPWorkspacePersistence())
    try await store.load()

    let server = testMCPServer(id: "reborn-server")
    try await store.upsertServer(server)
    try await store.deleteServer(server.id)
    #expect(await store.snapshot().tombstones[server.id.rawValue] != nil)

    try await store.upsertServer(server)
    #expect(await store.snapshot().tombstones[server.id.rawValue] == nil)
  }
}

private func testMCPServer(id: MCPServerID) -> MCPRemoteServer {
  MCPRemoteServer(
    id: id,
    name: "Server \(id.rawValue)",
    endpoint: URL(string: "https://\(id.rawValue).example.com/mcp")!
  )
}

private enum InjectedMCPPersistenceError: Error {
  case saveFailed
}

private actor FailingMCPWorkspacePersistence: MCPWorkspacePersistence {
  private var data: Data?
  private var shouldFailNextSave = false
  private let saveDelayNanoseconds: UInt64

  init(data: Data? = nil, saveDelayNanoseconds: UInt64 = 0) {
    self.data = data
    self.saveDelayNanoseconds = saveDelayNanoseconds
  }

  func loadData() -> Data? { data }

  func failNextSave() {
    shouldFailNextSave = true
  }

  func saveData(_ data: Data) async throws {
    if saveDelayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: saveDelayNanoseconds)
    }
    if shouldFailNextSave {
      shouldFailNextSave = false
      throw InjectedMCPPersistenceError.saveFailed
    }
    self.data = data
  }
}
