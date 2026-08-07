import Foundation
import Testing

@testable import BYOKchatProviderCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Test func mcpInputRequiredElicitationRetriesWithFreshIDAndOpaqueState() async throws {
  let transport = InputRequiredMCPTransport()
  let workspace = MCPWorkspaceStore(persistence: InMemoryMCPWorkspacePersistence())
  let remote = MCPRemoteRuntime(
    workspace: workspace,
    vault: InMemoryMCPCredentialVault(),
    transport: transport
  )
  try await remote.load()

  let server = MCPRemoteServer(
    id: "input-required-server",
    name: "Interactive MCP",
    endpoint: URL(string: "https://interactive.example.com/mcp")!
  )
  try await remote.saveServer(server, credential: nil)
  _ = try await remote.refreshServer(server.id, force: true)

  let conversationID: ConversationID = "interactive-chat"
  let exposedName = MCPToolNamespace.exposedName(
    serverID: server.id,
    remoteName: "confirm_change"
  )
  try await workspace.setChatServerEnabled(
    true,
    serverID: server.id,
    conversationID: conversationID
  )
  try await workspace.setChatToolPolicy(
    .alwaysAllow,
    exposedToolName: exposedName,
    conversationID: conversationID
  )

  let approvals = MCPToolApprovalCenter()
  let elicitations = MCPElicitationCenter()
  let coordinator = MCPConversationToolRuntime(
    mcpRuntime: remote,
    workspace: workspace,
    approvals: approvals,
    elicitations: elicitations
  )

  let execution = Task {
    await coordinator.execute(
      ChatToolCall(
        id: "model-call",
        name: exposedName,
        arguments: .object(["value": .string("new-value")])
      ),
      conversationID: conversationID
    )
  }

  let request = try await waitForElicitation(elicitations)
  #expect(request.mode == .form)
  #expect(request.message == "Confirm this change")
  #expect(request.fields.count == 1)
  #expect(request.fields.first?.name == "confirm")
  #expect(request.fields.first?.kind == .boolean)
  #expect(request.fields.first?.isRequired == true)

  await elicitations.resolve(
    request.id,
    decision: .accept(["confirm": .bool(true)])
  )

  let result = await execution.value
  #expect(result.isError == false)
  #expect(result.content == .string("confirmed"))

  let calls = await transport.toolCallBodies
  #expect(calls.count == 2)
  let first = try #require(calls.first)
  let second = try #require(calls.last)
  #expect(rpcID(first) != rpcID(second))

  let secondParams = try #require(rpcParams(second))
  #expect(secondParams["requestState"] == .string("opaque-state-α"))
  guard case .object(let responses)? = secondParams["inputResponses"],
    case .object(let confirmation)? = responses["confirmation"],
    case .object(let content)? = confirmation["content"]
  else {
    Issue.record("Missing elicitation response on MCP retry")
    return
  }
  #expect(confirmation["action"] == .string("accept"))
  #expect(content["confirm"] == .bool(true))

  let discover = try #require(await transport.requests.first { requestMethodForInput($0) == "server/discover" })
  let discoverParams = try #require(requestParams(discover))
  guard case .object(let meta)? = discoverParams["_meta"],
    case .object(let capabilities)? = meta["io.modelcontextprotocol/clientCapabilities"],
    case .object(let elicitation)? = capabilities["elicitation"]
  else {
    Issue.record("Missing elicitation client capability")
    return
  }
  #expect(elicitation["form"] == .object([:]))
  #expect(elicitation["url"] == .object([:]))
}

@Test func requestStateOnlyInputRequiredRoundRetriesWithoutPrompt() async throws {
  let transport = StateOnlyMCPTransport()
  let workspace = MCPWorkspaceStore(persistence: InMemoryMCPWorkspacePersistence())
  let remote = MCPRemoteRuntime(
    workspace: workspace,
    vault: InMemoryMCPCredentialVault(),
    transport: transport
  )
  try await remote.load()

  let server = MCPRemoteServer(
    id: "state-only-server",
    name: "State Only",
    endpoint: URL(string: "https://state.example.com/mcp")!
  )
  try await remote.saveServer(server, credential: nil)
  _ = try await remote.refreshServer(server.id, force: true)

  let conversationID: ConversationID = "state-only-chat"
  let exposedName = MCPToolNamespace.exposedName(serverID: server.id, remoteName: "slow_tool")
  try await workspace.setChatServerEnabled(true, serverID: server.id, conversationID: conversationID)
  try await workspace.setChatToolPolicy(
    .alwaysAllow,
    exposedToolName: exposedName,
    conversationID: conversationID
  )

  let elicitations = MCPElicitationCenter()
  let coordinator = MCPConversationToolRuntime(
    mcpRuntime: remote,
    workspace: workspace,
    approvals: MCPToolApprovalCenter(),
    elicitations: elicitations
  )
  let result = await coordinator.execute(
    ChatToolCall(id: "state-call", name: exposedName, arguments: .object([:])),
    conversationID: conversationID
  )

  #expect(result == ChatToolResult(
    callID: "state-call",
    name: exposedName,
    content: .string("ready"),
    isError: false
  ))
  #expect(await elicitations.currentRequests().isEmpty)
  #expect(await transport.toolCallCount == 2)
}

private actor InputRequiredMCPTransport: ProviderHTTPTransport {
  private(set) var requests: [URLRequest] = []
  private(set) var toolCallBodies: [JSONValue] = []

  func data(for request: URLRequest) async throws -> ProviderHTTPResponse {
    let stream = try await stream(for: request)
    var data = Data()
    for try await chunk in stream.chunks { data.append(chunk) }
    return ProviderHTTPResponse(statusCode: stream.statusCode, headers: stream.headers, data: data)
  }

  func stream(for request: URLRequest) async throws -> ProviderHTTPByteStream {
    requests.append(request)
    let body = try requestBody(request)
    let id = rpcID(body) ?? 1
    let method = requestMethodForInput(request)
    let json: String

    switch method {
    case "server/discover":
      json = """
        {"jsonrpc":"2.0","id":\(id),"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}},"_meta":{"io.modelcontextprotocol/serverInfo":{"name":"Interactive","version":"1.0"}}}}
        """
    case "tools/list":
      json = """
        {"jsonrpc":"2.0","id":\(id),"result":{"resultType":"complete","tools":[{"name":"confirm_change","description":"Confirm a change","inputSchema":{"type":"object","properties":{"value":{"type":"string"}}}}],"ttlMs":60000,"cacheScope":"private"}}
        """
    case "tools/call":
      toolCallBodies.append(body)
      if toolCallBodies.count == 1 {
        json = """
          {"jsonrpc":"2.0","id":\(id),"result":{"resultType":"input_required","inputRequests":{"confirmation":{"method":"elicitation/create","params":{"mode":"form","message":"Confirm this change","requestedSchema":{"type":"object","properties":{"confirm":{"type":"boolean","title":"Confirm"}},"required":["confirm"]}}}},"requestState":"opaque-state-α"}}
          """
      } else {
        json = """
          {"jsonrpc":"2.0","id":\(id),"result":{"resultType":"complete","content":[{"type":"text","text":"confirmed"}],"isError":false}}
          """
      }
    default:
      json = """
        {"jsonrpc":"2.0","id":\(id),"error":{"code":-32601,"message":"Method not found"}}
        """
    }
    return inputByteStream(json)
  }
}

private actor StateOnlyMCPTransport: ProviderHTTPTransport {
  private(set) var toolCallCount = 0

  func data(for request: URLRequest) async throws -> ProviderHTTPResponse {
    let stream = try await stream(for: request)
    var data = Data()
    for try await chunk in stream.chunks { data.append(chunk) }
    return ProviderHTTPResponse(statusCode: stream.statusCode, headers: stream.headers, data: data)
  }

  func stream(for request: URLRequest) async throws -> ProviderHTTPByteStream {
    let body = try requestBody(request)
    let id = rpcID(body) ?? 1
    let method = requestMethodForInput(request)
    let json: String
    switch method {
    case "server/discover":
      json = """
        {"jsonrpc":"2.0","id":\(id),"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}},"_meta":{"io.modelcontextprotocol/serverInfo":{"name":"State","version":"1.0"}}}}
        """
    case "tools/list":
      json = """
        {"jsonrpc":"2.0","id":\(id),"result":{"resultType":"complete","tools":[{"name":"slow_tool","description":"Slow tool","inputSchema":{"type":"object"}}],"ttlMs":60000,"cacheScope":"private"}}
        """
    case "tools/call":
      toolCallCount += 1
      if toolCallCount == 1 {
        json = """
          {"jsonrpc":"2.0","id":\(id),"result":{"resultType":"input_required","requestState":"wait-state"}}
          """
      } else {
        guard let params = rpcParams(body), params["requestState"] == .string("wait-state") else {
          throw MCPError.invalidResponse
        }
        json = """
          {"jsonrpc":"2.0","id":\(id),"result":{"resultType":"complete","content":[{"type":"text","text":"ready"}],"isError":false}}
          """
      }
    default:
      json = """
        {"jsonrpc":"2.0","id":\(id),"error":{"code":-32601,"message":"Method not found"}}
        """
    }
    return inputByteStream(json)
  }
}

private func waitForElicitation(
  _ center: MCPElicitationCenter,
  attempts: Int = 100
) async throws -> MCPElicitationRequest {
  for _ in 0..<attempts {
    if let request = await center.currentRequests().first { return request }
    try await Task.sleep(for: .milliseconds(5))
  }
  throw ProviderError.invalidRequest("Timed out waiting for MCP elicitation request.")
}

private func requestBody(_ request: URLRequest) throws -> JSONValue {
  guard let data = request.httpBody else { throw MCPError.invalidResponse }
  return try JSONDecoder.provider.decode(JSONValue.self, from: data)
}

private func requestMethodForInput(_ request: URLRequest) -> String? {
  guard let body = try? requestBody(request), case .object(let root) = body,
    case .string(let method)? = root["method"]
  else { return nil }
  return method
}

private func requestParams(_ request: URLRequest) -> [String: JSONValue]? {
  guard let body = try? requestBody(request) else { return nil }
  return rpcParams(body)
}

private func rpcID(_ body: JSONValue) -> Int? {
  guard case .object(let root) = body, case .number(let value)? = root["id"] else { return nil }
  return Int(value)
}

private func rpcParams(_ body: JSONValue) -> [String: JSONValue]? {
  guard case .object(let root) = body, case .object(let params)? = root["params"] else { return nil }
  return params
}

private func inputByteStream(_ json: String) -> ProviderHTTPByteStream {
  ProviderHTTPByteStream(
    statusCode: 200,
    headers: ["Content-Type": "application/json"],
    chunks: AsyncThrowingStream { continuation in
      continuation.yield(Data(json.utf8))
      continuation.finish()
    }
  )
}
