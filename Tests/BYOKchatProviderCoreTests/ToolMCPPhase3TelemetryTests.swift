import Foundation
import Testing

@testable import BYOKchatProviderCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Test func mcpHTTPTransportRecordsLifecycleWithoutPayloadOrCredentials() async throws {
  let location = phase3TelemetryLocation()
  defer { try? FileManager.default.removeItem(at: location.directory) }
  let recorder = TelemetryRecorder(
    databaseURL: location.database,
    configuration: phase3TelemetryConfiguration(),
    deviceID: "phase3-device",
    sessionID: "phase3-session"
  )
  let transport = MCPHTTPTransport(
    base: Phase3TelemetryBaseTransport(mode: .success),
    telemetryRecorder: recorder
  )

  var request = URLRequest(url: URL(string: "https://private.example.test/mcp")!)
  request.httpMethod = "POST"
  request.setValue("2026-07-28", forHTTPHeaderField: "MCP-Protocol-Version")
  request.setValue("tools/call", forHTTPHeaderField: "Mcp-Method")
  request.setValue("change_value", forHTTPHeaderField: "Mcp-Name")
  request.setValue("Bearer should-never-be-logged", forHTTPHeaderField: "Authorization")
  request.httpBody = Data(
    """
    {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"change_value","arguments":{"secret":"super-secret-argument"}}}
    """.utf8
  )

  let response = try await transport.stream(for: request)
  var data = Data()
  for try await chunk in response.chunks { data.append(chunk) }
  #expect(!data.isEmpty)

  let events = await waitForPhase3Telemetry(
    recorder,
    requiredNames: [.mcpRequestStarted, .mcpRequestCompleted]
  )
  let completed = try #require(events.first(where: { $0.name == .mcpRequestCompleted }))
  #expect(completed.outcome == .success)
  #expect(completed.httpStatus == 200)
  #expect(completed.durationMilliseconds != nil)
  #expect(completed.metadata["method"] == "tools/call")
  #expect(completed.metadata["protocolEra"] == MCPProtocolEra.modern.rawValue)
  #expect(completed.metadata["protocolVersion"] == "2026-07-28")
  #expect(completed.metadata["toolName"] == "change_value")
  #expect(completed.metadata["responseMode"] == "json")

  let persistedText = events.flatMap(\.metadata.values).joined(separator: " ")
  #expect(!persistedText.contains("super-secret-argument"))
  #expect(!persistedText.contains("should-never-be-logged"))
  #expect(!persistedText.contains("private.example.test"))
}

@Test func mcpHTTPTransportClassifiesFailureWithoutErrorText() async throws {
  let location = phase3TelemetryLocation()
  defer { try? FileManager.default.removeItem(at: location.directory) }
  let recorder = TelemetryRecorder(
    databaseURL: location.database,
    configuration: phase3TelemetryConfiguration(),
    deviceID: "phase3-device",
    sessionID: "phase3-session"
  )
  let transport = MCPHTTPTransport(
    base: Phase3TelemetryBaseTransport(mode: .failure),
    telemetryRecorder: recorder
  )

  var request = URLRequest(url: URL(string: "https://private.example.test/mcp")!)
  request.httpMethod = "POST"
  request.setValue("tools/list", forHTTPHeaderField: "Mcp-Method")
  request.setValue("2026-07-28", forHTTPHeaderField: "MCP-Protocol-Version")
  request.httpBody = Data(
    """{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}""".utf8
  )

  do {
    _ = try await transport.stream(for: request)
    Issue.record("Expected transport failure")
  } catch {}

  let events = await waitForPhase3Telemetry(
    recorder,
    requiredNames: [.mcpRequestFailed]
  )
  let failed = try #require(events.first(where: { $0.name == .mcpRequestFailed }))
  #expect(failed.errorCode == "transport")
  #expect(failed.metadata["classification"] == "transport")
  #expect(failed.metadata["completionUnknown"] == "true")
  #expect(failed.metadata.values.allSatisfy { !$0.contains("PRIVATE MCP TRANSPORT FAILURE") })
}

@Test func mcpConversationToolTelemetryTracksServerAndRoundsWithoutArgumentsOrResults() async throws {
  let location = phase3TelemetryLocation()
  defer { try? FileManager.default.removeItem(at: location.directory) }
  let recorder = TelemetryRecorder(
    databaseURL: location.database,
    configuration: phase3TelemetryConfiguration(),
    deviceID: "phase3-device",
    sessionID: "phase3-session"
  )
  let fixture = try await Phase3TelemetryMCPFixture.make(recorder: recorder)
  let conversationID: ConversationID = "phase3-telemetry-chat"
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

  let result = await fixture.coordinator.execute(
    ChatToolCall(
      id: "phase3-call",
      name: fixture.exposedToolName,
      arguments: .object(["secret": .string("super-secret-tool-argument")])
    ),
    conversationID: conversationID
  )
  #expect(result.isError == false)
  #expect(result.content == .string("private-tool-result"))

  let events = await waitForPhase3Telemetry(
    recorder,
    requiredNames: [.toolCallStarted, .toolCallCompleted]
  )
  let completed = try #require(events.first(where: { $0.name == .toolCallCompleted }))
  #expect(completed.outcome == .success)
  #expect(completed.conversationID == conversationID)
  #expect(completed.durationMilliseconds != nil)
  #expect(completed.toolCallCount == 1)
  #expect(completed.metadata["source"] == "mcp")
  #expect(completed.metadata["serverID"] == fixture.server.id.rawValue)
  #expect(completed.metadata["remoteToolName"] == "change_value")
  #expect(completed.metadata["policy"] == ChatToolPermissionPolicy.alwaysAllow.rawValue)
  #expect(completed.metadata["interactiveRoundCount"] == "1")
  #expect(completed.metadata["elicitationCount"] == "0")

  let persistedText = events.flatMap(\.metadata.values).joined(separator: " ")
  #expect(!persistedText.contains("super-secret-tool-argument"))
  #expect(!persistedText.contains("private-tool-result"))
}

@Test func deniedMCPToolRecordsStableFailureWithoutCallingServer() async throws {
  let location = phase3TelemetryLocation()
  defer { try? FileManager.default.removeItem(at: location.directory) }
  let recorder = TelemetryRecorder(
    databaseURL: location.database,
    configuration: phase3TelemetryConfiguration(),
    deviceID: "phase3-device",
    sessionID: "phase3-session"
  )
  let fixture = try await Phase3TelemetryMCPFixture.make(recorder: recorder)
  let conversationID: ConversationID = "phase3-denied-chat"
  try await fixture.workspace.setChatServerEnabled(
    true,
    serverID: fixture.server.id,
    conversationID: conversationID
  )

  let execution = Task {
    await fixture.coordinator.execute(
      ChatToolCall(
        id: "phase3-denied-call",
        name: fixture.exposedToolName,
        arguments: .object(["secret": .string("denied-private-argument")])
      ),
      conversationID: conversationID
    )
  }
  let approval = try await waitForPhase3Approval(fixture.approvals)
  await fixture.approvals.resolve(approval.id, decision: .deny)
  let result = await execution.value
  #expect(result.isError)
  #expect(await fixture.transport.toolCallCount == 0)

  let events = await waitForPhase3Telemetry(
    recorder,
    requiredNames: [.toolCallFailed]
  )
  let failed = try #require(events.first(where: { $0.name == .toolCallFailed }))
  #expect(failed.errorCode == "approval_denied")
  #expect(failed.metadata["classification"] == "user_decision")
  #expect(failed.metadata["approvalDecision"] == MCPToolApprovalDecision.deny.rawValue)
  #expect(failed.metadata.values.allSatisfy { !$0.contains("denied-private-argument") })
}

@Test func localToolExecutionSurvivesUnavailableTelemetryStore() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("BYOKchatPhase3Blocked-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let blockingFile = root.appendingPathComponent("not-a-directory")
  try Data("blocked".utf8).write(to: blockingFile)
  let recorder = TelemetryRecorder(
    databaseURL: blockingFile.appendingPathComponent("telemetry.sqlite"),
    configuration: phase3TelemetryConfiguration(),
    deviceID: "phase3-device",
    sessionID: "phase3-session"
  )

  let local = ToolRuntime()
  try await local.register(
    ChatToolDefinition(name: "local_echo", description: "Echo locally")
  ) { _ in
    .string("local-success")
  }

  let workspace = MCPWorkspaceStore(persistence: InMemoryMCPWorkspacePersistence())
  let remote = MCPRemoteRuntime(
    workspace: workspace,
    vault: InMemoryMCPCredentialVault(),
    transport: Phase3TelemetryRemoteTransport()
  )
  try await remote.load()
  let coordinator = MCPConversationToolRuntime(
    localRuntime: local,
    mcpRuntime: remote,
    workspace: workspace,
    approvals: MCPToolApprovalCenter(),
    elicitations: MCPElicitationCenter(),
    telemetryRecorder: recorder
  )

  let result = await coordinator.execute(
    ChatToolCall(
      id: "local-call",
      name: "local_echo",
      arguments: .object(["secret": .string("private-local-input")])
    ),
    conversationID: "local-chat"
  )
  #expect(result.isError == false)
  #expect(result.content == .string("local-success"))
}

private actor Phase3TelemetryBaseTransport: ProviderHTTPTransport {
  enum Mode: Sendable {
    case success
    case failure
  }

  let mode: Mode

  init(mode: Mode) {
    self.mode = mode
  }

  func data(for request: URLRequest) async throws -> ProviderHTTPResponse {
    let stream = try await stream(for: request)
    var data = Data()
    for try await chunk in stream.chunks { data.append(chunk) }
    return ProviderHTTPResponse(statusCode: stream.statusCode, headers: stream.headers, data: data)
  }

  func stream(for request: URLRequest) async throws -> ProviderHTTPByteStream {
    switch mode {
    case .failure:
      throw ProviderError.transport(
        message: "PRIVATE MCP TRANSPORT FAILURE",
        completionUnknown: true
      )
    case .success:
      let data = Data(
        """{"jsonrpc":"2.0","id":1,"result":{"ok":true,"private":"response-body-is-not-telemetry"}}""".utf8
      )
      return ProviderHTTPByteStream(
        statusCode: 200,
        headers: ["Content-Type": "application/json"],
        chunks: AsyncThrowingStream { continuation in
          continuation.yield(data)
          continuation.finish()
        }
      )
    }
  }
}

private struct Phase3TelemetryMCPFixture: Sendable {
  let workspace: MCPWorkspaceStore
  let coordinator: MCPConversationToolRuntime
  let approvals: MCPToolApprovalCenter
  let transport: Phase3TelemetryRemoteTransport
  let server: MCPRemoteServer
  let exposedToolName: String

  static func make(recorder: TelemetryRecorder) async throws -> Self {
    let transport = Phase3TelemetryRemoteTransport()
    let workspace = MCPWorkspaceStore(persistence: InMemoryMCPWorkspacePersistence())
    let remote = MCPRemoteRuntime(
      workspace: workspace,
      vault: InMemoryMCPCredentialVault(),
      transport: transport
    )
    try await remote.load()

    let server = MCPRemoteServer(
      id: "phase3-telemetry-server",
      name: "Telemetry Test Server",
      endpoint: URL(string: "https://telemetry.example.test/mcp")!
    )
    try await remote.saveServer(server, credential: nil)
    _ = try await remote.refreshServer(server.id, force: true)

    let approvals = MCPToolApprovalCenter()
    let coordinator = MCPConversationToolRuntime(
      mcpRuntime: remote,
      workspace: workspace,
      approvals: approvals,
      elicitations: MCPElicitationCenter(),
      telemetryRecorder: recorder
    )
    return Self(
      workspace: workspace,
      coordinator: coordinator,
      approvals: approvals,
      transport: transport,
      server: server,
      exposedToolName: MCPToolNamespace.exposedName(
        serverID: server.id,
        remoteName: "change_value"
      )
    )
  }
}

private actor Phase3TelemetryRemoteTransport: ProviderHTTPTransport {
  private(set) var toolCallCount = 0

  func data(for request: URLRequest) async throws -> ProviderHTTPResponse {
    let stream = try await stream(for: request)
    var data = Data()
    for try await chunk in stream.chunks { data.append(chunk) }
    return ProviderHTTPResponse(statusCode: stream.statusCode, headers: stream.headers, data: data)
  }

  func stream(for request: URLRequest) async throws -> ProviderHTTPByteStream {
    let method = phase3RequestMethod(request)
    let id = phase3RequestID(request) ?? 1
    let json: String
    switch method {
    case "server/discover":
      json = """
        {"jsonrpc":"2.0","id":\(id),"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}},"_meta":{"io.modelcontextprotocol/serverInfo":{"name":"Telemetry MCP","version":"1.0"}}}}
        """
    case "tools/list":
      json = """
        {"jsonrpc":"2.0","id":\(id),"result":{"resultType":"complete","tools":[{"name":"change_value","description":"Change a value","inputSchema":{"type":"object"}}],"ttlMs":60000,"cacheScope":"private"}}
        """
    case "tools/call":
      toolCallCount += 1
      json = """
        {"jsonrpc":"2.0","id":\(id),"result":{"resultType":"complete","content":[{"type":"text","text":"private-tool-result"}],"isError":false}}
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

private func waitForPhase3Telemetry(
  _ recorder: TelemetryRecorder,
  requiredNames: Set<TelemetryEventName>
) async -> [TelemetryEvent] {
  for _ in 0..<100 {
    let events = await recorder.recentEvents(limit: 200)
    if requiredNames.isSubset(of: Set(events.map(\.name))) {
      return events
    }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return await recorder.recentEvents(limit: 200)
}

private func waitForPhase3Approval(
  _ center: MCPToolApprovalCenter,
  attempts: Int = 100
) async throws -> MCPToolApprovalRequest {
  for _ in 0..<attempts {
    if let request = await center.currentRequests().first { return request }
    try await Task.sleep(for: .milliseconds(5))
  }
  throw ProviderError.invalidRequest("Timed out waiting for MCP approval request.")
}

private func phase3RequestMethod(_ request: URLRequest) -> String? {
  guard let body = request.httpBody,
    let value = try? JSONDecoder.provider.decode(JSONValue.self, from: body),
    case .object(let root) = value,
    case .string(let method)? = root["method"]
  else { return nil }
  return method
}

private func phase3RequestID(_ request: URLRequest) -> Int? {
  guard let body = request.httpBody,
    let value = try? JSONDecoder.provider.decode(JSONValue.self, from: body),
    case .object(let root) = value,
    case .number(let id)? = root["id"]
  else { return nil }
  return Int(id)
}

private func phase3TelemetryConfiguration() -> TelemetryStoreConfiguration {
  TelemetryStoreConfiguration(
    maximumAge: 30 * 24 * 60 * 60,
    maximumEventCount: 10_000,
    maximumDatabaseBytes: 10 * 1024 * 1024,
    maintenanceInsertInterval: 1_000,
    pruneBatchSize: 100
  )
}

private func phase3TelemetryLocation() -> (directory: URL, database: URL) {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("BYOKchatPhase3Telemetry-\(UUID().uuidString)", isDirectory: true)
  return (
    directory,
    directory.appendingPathComponent("telemetry.sqlite", isDirectory: false)
  )
}
