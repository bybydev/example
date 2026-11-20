import Foundation
import Testing

@testable import BYOKchatProviderCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Test func mcpToolsAreScopedToSelectedConversation() async throws {
  let fixture = try await MCPChatFixture.make()
  let chatA: ConversationID = "chat-a"
  let chatB: ConversationID = "chat-b"
  try await fixture.workspace.setChatServerEnabled(
    true,
    serverID: fixture.server.id,
    conversationID: chatA
  )

  let toolsA = await fixture.coordinator.availableTools(conversationID: chatA)
  let toolsB = await fixture.coordinator.availableTools(conversationID: chatB)

  #expect(toolsA.map(\.name) == [fixture.exposedToolName])
  #expect(toolsB.isEmpty)
}

@Test func askPolicyBlocksRemoteCallUntilAllowOnce() async throws {
  let fixture = try await MCPChatFixture.make()
  let conversationID: ConversationID = "chat-ask"
  try await fixture.workspace.setChatServerEnabled(
    true,
    serverID: fixture.server.id,
    conversationID: conversationID
  )

  let execution = Task {
    await fixture.coordinator.execute(
      fixture.call(id: "call-ask"),
      conversationID: conversationID
    )
  }

  let request = try await waitForApproval(fixture.approvals)
  #expect(request.conversationID == conversationID)
  #expect(request.exposedToolName == fixture.exposedToolName)
  #expect(await fixture.transport.toolCallCount == 0)

  await fixture.approvals.resolve(request.id, decision: .allowOnce)
  let result = await execution.value

  #expect(result.isError == false)
  #expect(result.content == .string("remote-result"))
  #expect(await fixture.transport.toolCallCount == 1)
  #expect(
    await fixture.workspace.chatConfiguration(for: conversationID)
      .policy(for: fixture.exposedToolName) == .ask
  )
}

@Test func denyingMCPToolNeverExecutesRemoteCall() async throws {
  let fixture = try await MCPChatFixture.make()
  let conversationID: ConversationID = "chat-deny"
  try await fixture.workspace.setChatServerEnabled(
    true,
    serverID: fixture.server.id,
    conversationID: conversationID
  )

  let execution = Task {
    await fixture.coordinator.execute(
      fixture.call(id: "call-deny"),
      conversationID: conversationID
    )
  }
  let request = try await waitForApproval(fixture.approvals)
  await fixture.approvals.resolve(request.id, decision: .deny)
  let result = await execution.value

  #expect(result.isError)
  #expect(result.content == .string("The user denied this tool call."))
  #expect(await fixture.transport.toolCallCount == 0)
}

@Test func cancellingDuringApprovalReportsCancelledInsteadOfDenied() async throws {
  let fixture = try await MCPChatFixture.make()
  let conversationID: ConversationID = "chat-cancel-approval"
  try await fixture.workspace.setChatServerEnabled(
    true,
    serverID: fixture.server.id,
    conversationID: conversationID
  )

  let execution = Task {
    await fixture.coordinator.execute(
      fixture.call(id: "call-cancel"),
      conversationID: conversationID
    )
  }
  _ = try await waitForApproval(fixture.approvals)
  execution.cancel()
  let result = await execution.value

  #expect(result.isError)
  #expect(result.content == .string("Tool execution was cancelled."))
  #expect(await fixture.transport.toolCallCount == 0)
}

@Test func alwaysAllowPersistsOnlyForThatChatAndSkipsNextPrompt() async throws {
  let fixture = try await MCPChatFixture.make()
  let conversationID: ConversationID = "chat-always"
  let otherConversationID: ConversationID = "chat-other"
  try await fixture.workspace.setChatServerEnabled(
    true,
    serverID: fixture.server.id,
    conversationID: conversationID
  )
  try await fixture.workspace.setChatServerEnabled(
    true,
    serverID: fixture.server.id,
    conversationID: otherConversationID
  )

  let firstExecution = Task {
    await fixture.coordinator.execute(
      fixture.call(id: "call-first"),
      conversationID: conversationID
    )
  }
  let request = try await waitForApproval(fixture.approvals)
  await fixture.approvals.resolve(request.id, decision: .alwaysAllow)
  let firstResult = await firstExecution.value
  #expect(firstResult.isError == false)

  let stored = await fixture.workspace.chatConfiguration(for: conversationID)
  #expect(stored.policy(for: fixture.exposedToolName) == .alwaysAllow)
  #expect(
    await fixture.workspace.chatConfiguration(for: otherConversationID)
      .policy(for: fixture.exposedToolName) == .ask
  )

  let secondResult = await fixture.coordinator.execute(
    fixture.call(id: "call-second"),
    conversationID: conversationID
  )
  #expect(secondResult.isError == false)
  #expect(await fixture.transport.toolCallCount == 2)
  #expect(await fixture.approvals.currentRequests().isEmpty)
}

@Test func disabledMCPToolIsNotExposedAndCannotExecute() async throws {
  let fixture = try await MCPChatFixture.make()
  let conversationID: ConversationID = "chat-disabled"
  try await fixture.workspace.setChatServerEnabled(
    true,
    serverID: fixture.server.id,
    conversationID: conversationID
  )
  try await fixture.workspace.setChatToolPolicy(
    .disabled,
    exposedToolName: fixture.exposedToolName,
    conversationID: conversationID
  )

  #expect(await fixture.coordinator.availableTools(conversationID: conversationID).isEmpty)

  let result = await fixture.coordinator.execute(
    fixture.call(id: "call-disabled"),
    conversationID: conversationID
  )
  #expect(result.isError)
  #expect(await fixture.transport.toolCallCount == 0)
}

@Test func deletingMCPServerScrubsPerChatSelection() async throws {
  let fixture = try await MCPChatFixture.make()
  let conversationID: ConversationID = "chat-delete"
  try await fixture.workspace.setChatServerEnabled(
    true,
    serverID: fixture.server.id,
    conversationID: conversationID
  )
  try await fixture.workspace.setChatToolPolicy(
    .alwaysAllow,
    exposedToolName: fixture.exposedToolName,
    conversationID: conversationID
  )

  try await fixture.remote.deleteServer(fixture.server.id)

  let configuration = await fixture.workspace.chatConfiguration(for: conversationID)
  #expect(configuration.enabledServerIDs.isEmpty)
  #expect(configuration.toolPolicies.isEmpty)
}

@Test func oldMCPWorkspaceWithoutChatConfigurationsStillDecodes() throws {
  let json = """
    {
      "schemaVersion": 1,
      "servers": [],
      "snapshots": []
    }
    """
  let value = try JSONDecoder.provider.decode(MCPWorkspaceState.self, from: Data(json.utf8))
  #expect(value.chatConfigurations == nil)
}

private struct MCPChatFixture: Sendable {
  let workspace: MCPWorkspaceStore
  let remote: MCPRemoteRuntime
  let coordinator: MCPConversationToolRuntime
  let approvals: MCPToolApprovalCenter
  let transport: MCPChatTestTransport
  let server: MCPRemoteServer
  let exposedToolName: String

  static func make() async throws -> MCPChatFixture {
    let transport = MCPChatTestTransport()
    let workspace = MCPWorkspaceStore(persistence: InMemoryMCPWorkspacePersistence())
    let remote = MCPRemoteRuntime(
      workspace: workspace,
      vault: InMemoryMCPCredentialVault(),
      transport: transport
    )
    try await remote.load()

    let server = MCPRemoteServer(
      id: "mcp-chat-server",
      name: "MCP Chat Server",
      endpoint: URL(string: "https://mcp-chat.example.com/mcp")!
    )
    try await remote.saveServer(server, credential: nil)
    _ = try await remote.refreshServer(server.id, force: true)

    let approvals = MCPToolApprovalCenter()
    let coordinator = MCPConversationToolRuntime(
      mcpRuntime: remote,
      workspace: workspace,
      approvals: approvals,
      elicitations: MCPElicitationCenter()
    )
    let exposed = MCPToolNamespace.exposedName(
      serverID: server.id,
      remoteName: "change_value"
    )
    return MCPChatFixture(
      workspace: workspace,
      remote: remote,
      coordinator: coordinator,
      approvals: approvals,
      transport: transport,
      server: server,
      exposedToolName: exposed
    )
  }

  func call(id: String) -> ChatToolCall {
    ChatToolCall(
      id: id,
      name: exposedToolName,
      arguments: .object(["value": .string("hello")])
    )
  }
}

private actor MCPChatTestTransport: ProviderHTTPTransport {
  private(set) var toolCallCount = 0

  func data(for request: URLRequest) async throws -> ProviderHTTPResponse {
    let stream = try await stream(for: request)
    var data = Data()
    for try await chunk in stream.chunks { data.append(chunk) }
    return ProviderHTTPResponse(statusCode: stream.statusCode, headers: stream.headers, data: data)
  }

  func stream(for request: URLRequest) async throws -> ProviderHTTPByteStream {
    let method = requestMethod(request)
    let id = requestID(request) ?? 1
    let json: String
    switch method {
    case "server/discover":
      json = """
        {"jsonrpc":"2.0","id":\(id),"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}},"_meta":{"io.modelcontextprotocol/serverInfo":{"name":"MCP Chat Test","version":"1.0"}}}}
        """
    case "tools/list":
      json = """
        {"jsonrpc":"2.0","id":\(id),"result":{"resultType":"complete","tools":[{"name":"change_value","title":"Change Value","description":"Change a remote value","inputSchema":{"type":"object","properties":{"value":{"type":"string"}},"required":["value"]},"annotations":{"readOnlyHint":false,"destructiveHint":true}}],"ttlMs":60000,"cacheScope":"private"}}
        """
    case "tools/call":
      toolCallCount += 1
      json = """
        {"jsonrpc":"2.0","id":\(id),"result":{"resultType":"complete","content":[{"type":"text","text":"remote-result"}],"isError":false}}
        """
    default:
      json = """
        {"jsonrpc":"2.0","id":\(id),"error":{"code":-32601,"message":"Method not found"}}
        """
    }

    return ProviderHTTPByteStream(
      statusCode: method == nil ? 400 : 200,
      headers: ["Content-Type": "application/json"],
      chunks: AsyncThrowingStream { continuation in
        continuation.yield(Data(json.utf8))
        continuation.finish()
      }
    )
  }
}

private func waitForApproval(
  _ center: MCPToolApprovalCenter,
  attempts: Int = 100
) async throws -> MCPToolApprovalRequest {
  for _ in 0..<attempts {
    if let request = await center.currentRequests().first { return request }
    try await Task.sleep(for: .milliseconds(5))
  }
  throw ProviderError.invalidRequest("Timed out waiting for MCP approval request.")
}

private func requestMethod(_ request: URLRequest) -> String? {
  guard let body = request.httpBody,
    let value = try? JSONDecoder.provider.decode(JSONValue.self, from: body),
    case .object(let root) = value,
    case .string(let method)? = root["method"]
  else { return nil }
  return method
}

private func requestID(_ request: URLRequest) -> Int? {
  guard let body = request.httpBody,
    let value = try? JSONDecoder.provider.decode(JSONValue.self, from: body),
    case .object(let root) = value,
    case .number(let id)? = root["id"]
  else { return nil }
  return Int(id)
}
