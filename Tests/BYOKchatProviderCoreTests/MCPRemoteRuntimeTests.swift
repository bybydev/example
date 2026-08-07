import Foundation
import Testing

@testable import BYOKchatProviderCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Test func mcpHeaderMapperValidatesAndEncodesAnnotatedParameters() throws {
  let schema: JSONValue = .object([
    "type": .string("object"),
    "properties": .object([
      "region": .object([
        "type": .string("string"),
        "x-mcp-header": .string("Region"),
      ]),
      "nested": .object([
        "type": .string("object"),
        "properties": .object([
          "enabled": .object([
            "type": .string("boolean"),
            "x-mcp-header": .string("Enabled"),
          ])
        ]),
      ]),
    ]),
  ])
  let bindings = try MCPToolHeaderMapper.bindings(from: schema)
  #expect(bindings.count == 2)
  let headers = try MCPToolHeaderMapper.headers(
    bindings: bindings,
    arguments: .object([
      "region": .string("Hello, 世界"),
      "nested": .object(["enabled": .bool(true)]),
    ])
  )
  #expect(headers["Mcp-Param-Region"] == "=?base64?SGVsbG8sIOS4lueVjA==?=")
  #expect(headers["Mcp-Param-Enabled"] == "true")
}

@Test func mcpHeaderMapperRejectsAnnotationsOutsideProperties() {
  let schema: JSONValue = .object([
    "type": .string("object"),
    "allOf": .array([
      .object([
        "type": .string("string"),
        "x-mcp-header": .string("Bad"),
      ])
    ]),
  ])
  #expect(throws: MCPError.self) {
    _ = try MCPToolHeaderMapper.bindings(from: schema)
  }
}

@Test func mcpToolNamesAreDeterministicAndServerScoped() {
  let first = MCPToolNamespace.exposedName(serverID: "server-a", remoteName: "search.web")
  let repeated = MCPToolNamespace.exposedName(serverID: "server-a", remoteName: "search.web")
  let other = MCPToolNamespace.exposedName(serverID: "server-b", remoteName: "search.web")
  #expect(first == repeated)
  #expect(first != other)
  #expect(first.count <= 128)
  #expect(first.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
}

@Test func modernMCPDiscoveryListsToolsAndCallsWithRequiredHeaders() async throws {
  let transport = ModernMCPTransport()
  let workspace = MCPWorkspaceStore(persistence: InMemoryMCPWorkspacePersistence())
  let vault = InMemoryMCPCredentialVault()
  let runtime = MCPRemoteRuntime(workspace: workspace, vault: vault, transport: transport)
  try await runtime.load()

  let server = MCPRemoteServer(
    id: "modern-server",
    name: "Modern",
    endpoint: URL(string: "https://mcp.example.com/mcp")!,
    authentication: MCPAuthentication(kind: .bearer)
  )
  try await runtime.saveServer(server, credential: "secret")

  let snapshot = try await runtime.refreshServer(server.id, force: true)
  #expect(snapshot.era == .modern)
  #expect(snapshot.protocolVersion == "2026-07-28")
  #expect(snapshot.serverInfo?.name == "Example MCP")
  #expect(snapshot.tools.count == 1)
  #expect(snapshot.tools.first?.headerBindings.count == 1)
  #expect(snapshot.expiresAt != nil)

  let output = try await runtime.callTool(
    serverID: server.id,
    remoteName: "get_weather",
    arguments: .object(["location": .string("Paris")])
  )
  #expect(output.isError == false)
  #expect(output.content == .string("21°C"))

  let requests = await transport.requests
  let discover = try #require(requests.first { requestMethod($0) == "server/discover" })
  #expect(discover.value(forHTTPHeaderField: "MCP-Protocol-Version") == "2026-07-28")
  #expect(discover.value(forHTTPHeaderField: "Mcp-Method") == "server/discover")
  #expect(discover.value(forHTTPHeaderField: "Authorization") == "Bearer secret")

  let call = try #require(requests.first { requestMethod($0) == "tools/call" })
  #expect(call.value(forHTTPHeaderField: "Mcp-Name") == "get_weather")
  #expect(call.value(forHTTPHeaderField: "Mcp-Param-Region") == "Paris")
  guard let body = call.httpBody,
    case .object(let root) = try JSONDecoder.provider.decode(JSONValue.self, from: body),
    case .object(let params)? = root["params"],
    case .object(let meta)? = params["_meta"]
  else {
    Issue.record("Missing modern MCP request metadata")
    return
  }
  #expect(meta["io.modelcontextprotocol/protocolVersion"] == .string("2026-07-28"))
}

@Test func mcpFallsBackToLegacyInitializeAndUsesSession() async throws {
  let transport = LegacyMCPTransport()
  let workspace = MCPWorkspaceStore(persistence: InMemoryMCPWorkspacePersistence())
  let runtime = MCPRemoteRuntime(
    workspace: workspace,
    vault: InMemoryMCPCredentialVault(),
    transport: transport
  )
  try await runtime.load()
  let server = MCPRemoteServer(
    id: "legacy-server",
    name: "Legacy",
    endpoint: URL(string: "https://legacy.example.com/mcp")!
  )
  try await runtime.saveServer(server, credential: nil)

  let snapshot = try await runtime.refreshServer(server.id, force: true)
  #expect(snapshot.era == .legacy)
  #expect(snapshot.protocolVersion == "2025-11-25")
  #expect(snapshot.tools.first?.remoteName == "legacy_search")

  let requests = await transport.requests
  #expect(requests.contains { requestMethod($0) == "server/discover" })
  #expect(requests.contains { requestMethod($0) == "initialize" })
  #expect(requests.contains { requestMethod($0) == "notifications/initialized" })
  let list = try #require(requests.first { requestMethod($0) == "tools/list" })
  #expect(list.value(forHTTPHeaderField: "Mcp-Session-Id") == "session-123")
  #expect(list.value(forHTTPHeaderField: "MCP-Protocol-Version") == "2025-11-25")
}

@Test func mcpWorkspaceNeverPersistsCredential() async throws {
  let persistence = InMemoryMCPWorkspacePersistence()
  let workspace = MCPWorkspaceStore(persistence: persistence)
  let vault = InMemoryMCPCredentialVault()
  let runtime = MCPRemoteRuntime(workspace: workspace, vault: vault)
  try await runtime.load()
  let server = MCPRemoteServer(
    id: "secret-server",
    name: "Secret",
    endpoint: URL(string: "https://example.com/mcp")!,
    authentication: MCPAuthentication(kind: .bearer)
  )
  try await runtime.saveServer(server, credential: "super-secret-token")
  let data = try #require(await persistence.loadData())
  let string = String(decoding: data, as: UTF8.self)
  #expect(!string.contains("super-secret-token"))
  #expect(try await vault.credential(serverID: server.id) == "super-secret-token")
}

private actor ModernMCPTransport: ProviderHTTPTransport {
  private(set) var requests: [URLRequest] = []

  func data(for request: URLRequest) async throws -> ProviderHTTPResponse {
    requests.append(request)
    return response(for: request)
  }

  func stream(for request: URLRequest) async throws -> ProviderHTTPByteStream {
    requests.append(request)
    let response = response(for: request)
    return ProviderHTTPByteStream(
      statusCode: response.statusCode,
      headers: response.headers,
      chunks: AsyncThrowingStream { continuation in
        if !response.data.isEmpty { continuation.yield(response.data) }
        continuation.finish()
      }
    )
  }

  private func response(for request: URLRequest) -> ProviderHTTPResponse {
    switch requestMethod(request) {
    case "server/discover":
      return jsonResponse(
        """
        {"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}},"_meta":{"io.modelcontextprotocol/serverInfo":{"name":"Example MCP","version":"2.0"}},"ttlMs":60000,"cacheScope":"private"}}
        """
      )
    case "tools/list":
      return jsonResponse(
        """
        {"jsonrpc":"2.0","id":2,"result":{"resultType":"complete","tools":[{"name":"get_weather","description":"Get weather","inputSchema":{"type":"object","properties":{"location":{"type":"string","x-mcp-header":"Region"}},"required":["location"]}}],"ttlMs":60000,"cacheScope":"private"}}
        """
      )
    case "tools/call":
      return jsonResponse(
        """
        {"jsonrpc":"2.0","id":3,"result":{"resultType":"complete","content":[{"type":"text","text":"21°C"}],"isError":false}}
        """
      )
    default:
      return jsonResponse(
        """{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}""",
        status: 404
      )
    }
  }
}

private actor LegacyMCPTransport: ProviderHTTPTransport {
  private(set) var requests: [URLRequest] = []

  func data(for request: URLRequest) async throws -> ProviderHTTPResponse {
    requests.append(request)
    return response(for: request)
  }

  func stream(for request: URLRequest) async throws -> ProviderHTTPByteStream {
    requests.append(request)
    let response = response(for: request)
    return ProviderHTTPByteStream(
      statusCode: response.statusCode,
      headers: response.headers,
      chunks: AsyncThrowingStream { continuation in
        if !response.data.isEmpty { continuation.yield(response.data) }
        continuation.finish()
      }
    )
  }

  private func response(for request: URLRequest) -> ProviderHTTPResponse {
    switch requestMethod(request) {
    case "server/discover":
      return ProviderHTTPResponse(
        statusCode: 400,
        headers: ["Content-Type": "text/plain"],
        data: Data("legacy".utf8)
      )
    case "initialize":
      return ProviderHTTPResponse(
        statusCode: 200,
        headers: [
          "Content-Type": "application/json",
          "Mcp-Session-Id": "session-123",
        ],
        data: Data(
          """
          {"jsonrpc":"2.0","id":2,"result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"Legacy MCP","version":"1.0"}}}
          """.utf8
        )
      )
    case "notifications/initialized":
      return ProviderHTTPResponse(statusCode: 202, headers: [:], data: Data())
    case "tools/list":
      return jsonResponse(
        """
        {"jsonrpc":"2.0","id":3,"result":{"tools":[{"name":"legacy_search","description":"Search","inputSchema":{"type":"object"}}]}}
        """
      )
    default:
      return jsonResponse(
        """{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}""",
        status: 404
      )
    }
  }
}

private func jsonResponse(_ json: String, status: Int = 200) -> ProviderHTTPResponse {
  ProviderHTTPResponse(
    statusCode: status,
    headers: ["Content-Type": "application/json"],
    data: Data(json.utf8)
  )
}

private func requestMethod(_ request: URLRequest) -> String? {
  guard let body = request.httpBody,
    let value = try? JSONDecoder.provider.decode(JSONValue.self, from: body),
    case .object(let root) = value,
    case .string(let method)? = root["method"]
  else { return nil }
  return method
}
