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
