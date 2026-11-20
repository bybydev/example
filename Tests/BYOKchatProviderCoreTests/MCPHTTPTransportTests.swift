import Foundation
import Testing

@testable import BYOKchatProviderCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Test func slowModernDiscoveryFallsBackToLegacyInitialize() async throws {
  let base = SlowModernLegacyTransport()
  let transport = MCPHTTPTransport(base: base, discoverProbeTimeout: 0.02)
  let workspace = MCPWorkspaceStore(persistence: InMemoryMCPWorkspacePersistence())
  let runtime = MCPRemoteRuntime(
    workspace: workspace,
    vault: InMemoryMCPCredentialVault(),
    transport: transport
  )
  try await runtime.load()

  let server = MCPRemoteServer(
    id: "slow-legacy",
    name: "Slow Legacy",
    endpoint: URL(string: "https://legacy.example.com/mcp")!
  )
  try await runtime.saveServer(server, credential: nil)

  let snapshot = try await runtime.refreshServer(server.id, force: true)
  #expect(snapshot.era == .legacy)
  #expect(snapshot.protocolVersion == "2025-11-25")
  #expect(snapshot.tools.map(\.remoteName) == ["legacy_tool"])

  let methods = await base.methods
  #expect(methods.contains("server/discover"))
  #expect(methods.contains("initialize"))
  #expect(methods.contains("notifications/initialized"))
  #expect(methods.contains("tools/list"))
}

@Test func urlErrorTimedOutOnDiscoverFallsBackToLegacyInitialize() async throws {
  let base = SlowModernLegacyTransport(throwURLErrorTimeoutOnDiscover: true)
  let transport = MCPHTTPTransport(base: base, discoverProbeTimeout: 5)
  let workspace = MCPWorkspaceStore(persistence: InMemoryMCPWorkspacePersistence())
  let runtime = MCPRemoteRuntime(
    workspace: workspace,
    vault: InMemoryMCPCredentialVault(),
    transport: transport
  )
  try await runtime.load()

  let server = MCPRemoteServer(
    id: "timeout-legacy",
    name: "Timeout Legacy",
    endpoint: URL(string: "https://timeout-legacy.example.com/mcp")!
  )
  try await runtime.saveServer(server, credential: nil)

  let snapshot = try await runtime.refreshServer(server.id, force: true)
  #expect(snapshot.era == .legacy)
  #expect(snapshot.protocolVersion == "2025-11-25")
  #expect(snapshot.tools.map(\.remoteName) == ["legacy_tool"])
}

private actor SlowModernLegacyTransport: ProviderHTTPTransport {
  private(set) var methods: [String] = []
  private let throwURLErrorTimeoutOnDiscover: Bool

  init(throwURLErrorTimeoutOnDiscover: Bool = false) {
    self.throwURLErrorTimeoutOnDiscover = throwURLErrorTimeoutOnDiscover
  }

  func data(for request: URLRequest) async throws -> ProviderHTTPResponse {
    let stream = try await stream(for: request)
    var data = Data()
    for try await chunk in stream.chunks { data.append(chunk) }
    return ProviderHTTPResponse(
      statusCode: stream.statusCode,
      headers: stream.headers,
      data: data
    )
  }

  func stream(for request: URLRequest) async throws -> ProviderHTTPByteStream {
    let method = requestMethod(request)
    if let method { methods.append(method) }

    switch method {
    case "server/discover":
      if throwURLErrorTimeoutOnDiscover {
        throw URLError(.timedOut)
      }
      try await Task.sleep(for: .seconds(1))
      return streamResponse(
        """
        {"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}
        """,
        status: 404
      )
    case "initialize":
      return streamResponse(
        """
        {"jsonrpc":"2.0","id":2,"result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"Legacy","version":"1"}}}
        """,
        headers: [
          "Content-Type": "application/json",
          "Mcp-Session-Id": "legacy-session",
        ]
      )
    case "notifications/initialized":
      return ProviderHTTPByteStream(
        statusCode: 202,
        headers: [:],
        chunks: AsyncThrowingStream { $0.finish() }
      )
    case "tools/list":
      return streamResponse(
        """
        {"jsonrpc":"2.0","id":3,"result":{"tools":[{"name":"legacy_tool","description":"Legacy tool","inputSchema":{"type":"object"}}]}}
        """
      )
    default:
      return streamResponse(
        """
        {"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}
        """,
        status: 404
      )
    }
  }

  private func streamResponse(
    _ json: String,
    status: Int = 200,
    headers: [String: String] = ["Content-Type": "application/json"]
  ) -> ProviderHTTPByteStream {
    ProviderHTTPByteStream(
      statusCode: status,
      headers: headers,
      chunks: AsyncThrowingStream { continuation in
        continuation.yield(Data(json.utf8))
        continuation.finish()
      }
    )
  }
}

private func requestMethod(_ request: URLRequest) -> String? {
  guard let body = request.httpBody,
    let value = try? JSONDecoder.provider.decode(JSONValue.self, from: body),
    case .object(let root) = value,
    case .string(let method)? = root["method"]
  else { return nil }
  return method
}
