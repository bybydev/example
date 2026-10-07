import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public actor MCPRemoteRuntime {
  public static let modernProtocolVersion = "2026-07-28"
  public static let supportedLegacyProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]

  private struct ConnectionState: Sendable {
    var era: MCPProtocolEra
    var protocolVersion: String
    var sessionID: String?
    var serverInfo: MCPImplementationInfo?
    var capabilities: JSONValue
    var instructions: String?
  }

  private struct HTTPReply: Sendable {
    var statusCode: Int
    var headers: [String: String]
    var payload: JSONValue?
  }

  private let workspace: MCPWorkspaceStore
  private let vault: any MCPCredentialVault
  private let transport: any ProviderHTTPTransport
  private var connections: [MCPServerID: ConnectionState] = [:]
  private var nextRequestID: UInt64 = 1

  public init(
    workspace: MCPWorkspaceStore,
    vault: any MCPCredentialVault,
    transport: any ProviderHTTPTransport = URLSessionProviderHTTPTransport()
  ) {
    self.workspace = workspace
    self.vault = vault
    self.transport = transport
  }

  public func load() async throws {
    try await workspace.load()
  }

  public func servers() async -> [MCPRemoteServer] {
    await workspace.allServers()
  }

  public func snapshots() async -> [MCPServerSnapshot] {
    await workspace.snapshot().snapshots.sorted {
      $0.refreshedAt > $1.refreshedAt
    }
  }

  public func snapshot(serverID: MCPServerID) async -> MCPServerSnapshot? {
    await workspace.snapshot(for: serverID)
  }

  public func hasCredential(serverID: MCPServerID) async throws -> Bool {
    let credential = try await vault.credential(serverID: serverID)
    return credential?.isEmpty == false
  }

  public func saveServer(_ server: MCPRemoteServer, credential: String?) async throws {
    try MCPWorkspaceStore.validateServer(server)
    let previous = try? await workspace.server(id: server.id)
    let previousCredential: String?
    if credential != nil {
      previousCredential = try await vault.credential(serverID: server.id)
    } else {
      previousCredential = nil
    }

    let invalidatesConnection = previous?.endpoint != server.endpoint
      || previous?.authentication != server.authentication
      || previous?.additionalHeaders != server.additionalHeaders
      || credential != nil
    if invalidatesConnection {
      connections.removeValue(forKey: server.id)
    }

    // Update Keychain first so a credential failure cannot leave a newly saved
    // configuration behind. Restore it if the single workspace commit fails.
    if let credential {
      try await vault.setCredential(
        credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : credential,
        serverID: server.id
      )
    }

    do {
      try await workspace.upsertServer(server, invalidateSnapshot: credential != nil)
    } catch {
      let configurationError = error
      if credential != nil {
        do {
          try await vault.setCredential(previousCredential, serverID: server.id)
        } catch {
          throw MCPError.transport(
            "MCP configuration was not saved and the previous Keychain credential could not be restored: \(error.localizedDescription)"
          )
        }
      }
      throw configurationError
    }
  }

  public func setEnabled(_ enabled: Bool, serverID: MCPServerID) async throws {
    try await workspace.setEnabled(enabled, serverID: serverID)
  }

  public func deleteServer(_ id: MCPServerID) async throws {
    // Keep the server visible when Keychain cleanup fails. If the subsequent
    // workspace commit fails, restore its credential so retry does not leave
    // a retained authenticated server silently broken.
    let previousCredential = try await vault.credential(serverID: id)
    try await vault.removeCredential(serverID: id)
    do {
      try await workspace.deleteServer(id)
    } catch {
      let deletionError = error
      do {
        try await vault.setCredential(previousCredential, serverID: id)
      } catch {
        connections.removeValue(forKey: id)
        throw MCPError.transport(
          "MCP server deletion failed and its Keychain credential could not be restored. The server remains available for deletion retry. Restore its credential to use it: \(error.localizedDescription)"
        )
      }
      throw deletionError
    }
    connections.removeValue(forKey: id)
  }

  @discardableResult
  public func refreshServer(
    _ serverID: MCPServerID,
    force: Bool = false
  ) async throws -> MCPServerSnapshot {
    let server = try await workspace.server(id: serverID)
    if !force,
      let cached = await workspace.snapshot(for: serverID),
      cached.isFresh
    {
      return cached
    }

    let connection = try await connection(for: server, forceProbe: force)
    let listing = try await listTools(server: server, connection: connection)
    let refreshedAt = Date.now
    let expiresAt: Date?
    if connection.era == .modern {
      expiresAt = listing.ttlMilliseconds > 0
        ? refreshedAt.addingTimeInterval(Double(listing.ttlMilliseconds) / 1_000)
        : nil
    } else {
      expiresAt = refreshedAt.addingTimeInterval(300)
    }

    let snapshot = MCPServerSnapshot(
      serverID: server.id,
      protocolVersion: connection.protocolVersion,
      era: connection.era,
      serverInfo: connection.serverInfo,
      capabilities: connection.capabilities,
      instructions: connection.instructions,
      tools: listing.tools,
      refreshedAt: refreshedAt,
      expiresAt: expiresAt,
      cacheScope: listing.cacheScope,
      warnings: listing.warnings
    )
    try await workspace.storeSnapshot(snapshot)
    return snapshot
  }

  public func toolBindings(includeDisabled: Bool = false) async -> [MCPToolBinding] {
    let servers = await workspace.allServers()
    let enabledIDs = Set(servers.filter { includeDisabled || $0.isEnabled }.map(\.id))
    return await workspace.snapshot().snapshots
      .filter { enabledIDs.contains($0.serverID) }
      .flatMap { snapshot in
        snapshot.tools.map { tool in
          MCPToolBinding(
            serverID: snapshot.serverID,
            remoteTool: tool,
            exposedName: MCPToolNamespace.exposedName(
              serverID: snapshot.serverID,
              remoteName: tool.remoteName
            )
          )
        }
      }
      .sorted { $0.exposedName < $1.exposedName }
  }

  public func callTool(
    serverID: MCPServerID,
    remoteName: String,
    arguments: JSONValue
  ) async throws -> MCPToolCallOutput {
    switch try await callToolRound(
      serverID: serverID,
      remoteName: remoteName,
      arguments: arguments
    ) {
    case .complete(let output):
      return output
    case .inputRequired:
      throw MCPError.inputRequired
    }
  }

  public func callToolRound(
    serverID: MCPServerID,
    remoteName: String,
    arguments: JSONValue,
    inputResponses: [String: JSONValue]? = nil,
    requestState: String? = nil
  ) async throws -> MCPToolCallRoundResult {
    let server = try await workspace.server(id: serverID)
    var snapshot = try await refreshServer(serverID)
    var tool: MCPRemoteTool
    if let cachedTool = snapshot.tools.first(where: { $0.remoteName == remoteName }) {
      tool = cachedTool
    } else {
      snapshot = try await refreshServer(serverID, force: true)
      guard let refreshedTool = snapshot.tools.first(where: { $0.remoteName == remoteName }) else {
        throw MCPError.toolNotFound(remoteName)
      }
      tool = refreshedTool
    }

    var connectionState = try await connection(for: server, forceProbe: false)
    do {
      return try await callToolRound(
        server: server,
        connection: connectionState,
        tool: tool,
        arguments: arguments,
        inputResponses: inputResponses,
        requestState: requestState
      )
    } catch MCPError.protocolError(let code, _) where code == -32_020 && connectionState.era == .modern {
      snapshot = try await refreshServer(serverID, force: true)
      guard let refreshedTool = snapshot.tools.first(where: { $0.remoteName == remoteName }) else {
        throw MCPError.toolNotFound(remoteName)
      }
      connectionState = try await connection(for: server, forceProbe: false)
      return try await callToolRound(
        server: server,
        connection: connectionState,
        tool: refreshedTool,
        arguments: arguments,
        inputResponses: inputResponses,
        requestState: requestState
      )
    }
  }

  private func connection(
    for server: MCPRemoteServer,
    forceProbe: Bool
  ) async throws -> ConnectionState {
    if !forceProbe, let existing = connections[server.id] { return existing }
    connections.removeValue(forKey: server.id)

    let modern = await modernDiscover(server: server)
    switch modern {
    case .success(let connection):
      connections[server.id] = connection
      return connection
    case .failure(let error):
      if case .unsupportedProtocol(let versions) = error,
        versions.contains(where: Self.supportedLegacyProtocolVersions.contains)
      {
        let legacy = try await initializeLegacy(server: server)
        connections[server.id] = legacy
        return legacy
      }
      if shouldFallbackToLegacy(error) {
        let legacy = try await initializeLegacy(server: server)
        connections[server.id] = legacy
        return legacy
      }
      throw error
    }
  }

  private func modernDiscover(server: MCPRemoteServer) async -> Result<ConnectionState, MCPError> {
    do {
      let reply = try await post(
        server: server,
        method: "server/discover",
        params: [:],
        era: .modern,
        protocolVersion: Self.modernProtocolVersion,
        sessionID: nil,
        name: nil,
        parameterHeaders: [:]
      )

      if (200..<300).contains(reply.statusCode) {
        guard let payload = reply.payload else { return .failure(.invalidResponse) }
        if let error = rpcError(payload) {
          if error.code == -32_022 {
            return .failure(.unsupportedProtocol(error.supportedVersions))
          }
          return .failure(.protocolError(code: error.code, message: error.message))
        }
        guard let result = rpcResult(payload),
          case .object(let object) = result
        else {
          return .failure(.invalidResponse)
        }
        let versions = stringArray(object["supportedVersions"])
        guard versions.contains(Self.modernProtocolVersion) else {
          return .failure(.unsupportedProtocol(versions))
        }
        let capabilities = object["capabilities"] ?? .object([:])
        let info = implementationInfo(from: object["_meta"])
        let instructions = stringValue(object["instructions"])
        return .success(
          ConnectionState(
            era: .modern,
            protocolVersion: Self.modernProtocolVersion,
            sessionID: nil,
            serverInfo: info,
            capabilities: capabilities,
            instructions: instructions
          )
        )
      }

      if let payload = reply.payload, let error = rpcError(payload) {
        if error.code == -32_022 {
          return .failure(.unsupportedProtocol(error.supportedVersions))
        }
        if error.code == -32_020 || error.code == -32_021 {
          return .failure(.protocolError(code: error.code, message: error.message))
        }
      }
      if [400, 404, 405].contains(reply.statusCode) {
        return .failure(.transport("Legacy MCP probe required."))
      }
      return .failure(httpError(status: reply.statusCode, payload: reply.payload))
    } catch let error as MCPError {
      return .failure(error)
    } catch {
      return .failure(.transport(error.localizedDescription))
    }
  }

  private func shouldFallbackToLegacy(_ error: MCPError) -> Bool {
    switch error {
    case .transport(let message):
      return message == "Legacy MCP probe required."
    case .protocolError(let code, _):
      return code == -32_601
    default:
      return false
    }
  }

  private func initializeLegacy(server: MCPRemoteServer) async throws -> ConnectionState {
    let reply = try await post(
      server: server,
      method: "initialize",
      params: [
        "protocolVersion": .string(Self.supportedLegacyProtocolVersions[0]),
        "capabilities": .object([:]),
        "clientInfo": .object([
          "name": .string("BYOKchat"),
          "version": .string("1.0"),
        ]),
      ],
      era: .legacy,
      protocolVersion: nil,
      sessionID: nil,
      name: nil,
      parameterHeaders: [:]
    )
    guard (200..<300).contains(reply.statusCode), let payload = reply.payload else {
      if [404, 405].contains(reply.statusCode) { throw MCPError.unsupportedLegacyTransport }
      throw httpError(status: reply.statusCode, payload: reply.payload)
    }
    if let error = rpcError(payload) {
      throw MCPError.protocolError(code: error.code, message: error.message)
    }
    guard let result = rpcResult(payload), case .object(let object) = result,
      let version = stringValue(object["protocolVersion"]),
      Self.supportedLegacyProtocolVersions.contains(version)
    else {
      throw MCPError.invalidResponse
    }

    let sessionID = header("Mcp-Session-Id", in: reply.headers)
    let capabilities = object["capabilities"] ?? .object([:])
    let info = implementationInfoDirect(from: object["serverInfo"])
    let instructions = stringValue(object["instructions"])

    let initialized = try await postNotification(
      server: server,
      method: "notifications/initialized",
      params: nil,
      protocolVersion: version,
      sessionID: sessionID
    )
    guard (200..<300).contains(initialized.statusCode) else {
      throw httpError(status: initialized.statusCode, payload: initialized.payload)
    }

    return ConnectionState(
      era: .legacy,
      protocolVersion: version,
      sessionID: sessionID,
      serverInfo: info,
      capabilities: capabilities,
      instructions: instructions
    )
  }

  private struct ToolListing: Sendable {
    var tools: [MCPRemoteTool]
    var ttlMilliseconds: Int
    var cacheScope: String?
    var warnings: [String]
  }

  private func listTools(
    server: MCPRemoteServer,
    connection: ConnectionState
  ) async throws -> ToolListing {
    guard supportsTools(connection.capabilities) else {
      return ToolListing(tools: [], ttlMilliseconds: 0, cacheScope: nil, warnings: [])
    }

    var tools: [MCPRemoteTool] = []
    var warnings: [String] = []
    var cursor: String?
    var seenCursors: Set<String> = []
    var ttlMilliseconds: Int? = connection.era == .modern ? nil : 300_000
    var cacheScope: String?

    for _ in 0..<100 {
      var params: [String: JSONValue] = [:]
      if let cursor { params["cursor"] = .string(cursor) }

      let reply = try await postWithLegacyRecovery(
        server: server,
        connection: connection,
        method: "tools/list",
        params: params,
        name: nil,
        parameterHeaders: [:]
      )
      guard (200..<300).contains(reply.statusCode), let payload = reply.payload else {
        throw httpError(status: reply.statusCode, payload: reply.payload)
      }
      if let error = rpcError(payload) {
        throw MCPError.protocolError(code: error.code, message: error.message)
      }
      guard let result = rpcResult(payload), case .object(let object) = result,
        case .array(let values)? = object["tools"]
      else {
        throw MCPError.invalidResponse
      }

      for value in values {
        do {
          let tool = try decodeTool(value)
          if tools.contains(where: { $0.remoteName == tool.remoteName }) {
            warnings.append("Duplicate tool name \(tool.remoteName) was ignored.")
          } else {
            tools.append(tool)
          }
        } catch {
          warnings.append(error.localizedDescription)
        }
      }

      if connection.era == .modern {
        let pageTTL = integerValue(object["ttlMs"]) ?? 0
        ttlMilliseconds = min(ttlMilliseconds ?? pageTTL, pageTTL)
        let pageScope = stringValue(object["cacheScope"]) == "public" ? "public" : "private"
        if let existingScope = cacheScope {
          cacheScope = existingScope == "public" && pageScope == "public" ? "public" : "private"
        } else {
          cacheScope = pageScope
        }
      }

      guard let next = stringValue(object["nextCursor"]), !next.isEmpty else { break }
      guard seenCursors.insert(next).inserted else {
        throw MCPError.invalidResponse
      }
      cursor = next
    }

    return ToolListing(
      tools: tools,
      ttlMilliseconds: ttlMilliseconds ?? 0,
      cacheScope: cacheScope,
      warnings: warnings
    )
  }

  private func callToolRound(
    server: MCPRemoteServer,
    connection: ConnectionState,
    tool: MCPRemoteTool,
    arguments: JSONValue,
    inputResponses: [String: JSONValue]?,
    requestState: String?
  ) async throws -> MCPToolCallRoundResult {
    if (inputResponses != nil || requestState != nil), connection.era != .modern {
      throw MCPError.inputRequired
    }

    let parameterHeaders = connection.era == .modern
      ? try MCPToolHeaderMapper.headers(bindings: tool.headerBindings, arguments: arguments)
      : [:]
    var params: [String: JSONValue] = [
      "name": .string(tool.remoteName),
      "arguments": arguments,
    ]
    if let inputResponses {
      params["inputResponses"] = .object(inputResponses)
    }
    if let requestState {
      params["requestState"] = .string(requestState)
    }

    let reply = try await postWithLegacyRecovery(
      server: server,
      connection: connection,
      method: "tools/call",
      params: params,
      name: tool.remoteName,
      parameterHeaders: parameterHeaders
    )
    guard (200..<300).contains(reply.statusCode), let payload = reply.payload else {
      throw httpError(status: reply.statusCode, payload: reply.payload)
    }
    if let error = rpcError(payload) {
      throw MCPError.protocolError(code: error.code, message: error.message)
    }
    guard let result = rpcResult(payload), case .object(let object) = result else {
      throw MCPError.invalidResponse
    }

    if stringValue(object["resultType"]) == "input_required" {
      guard connection.era == .modern else { throw MCPError.inputRequired }
      let inputRequests: [String: JSONValue]
      if case .object(let values)? = object["inputRequests"] {
        inputRequests = values
      } else {
        inputRequests = [:]
      }
      let state = stringValue(object["requestState"])
      guard !inputRequests.isEmpty || state != nil else {
        throw MCPError.invalidResponse
      }
      return .inputRequired(
        MCPInputRequiredRound(inputRequests: inputRequests, requestState: state)
      )
    }

    let isError = boolValue(object["isError"]) ?? false
    return .complete(
      MCPToolCallOutput(content: normalizedToolContent(object), isError: isError)
    )
  }

  private func postWithLegacyRecovery(
    server: MCPRemoteServer,
    connection: ConnectionState,
    method: String,
    params: [String: JSONValue],
    name: String?,
    parameterHeaders: [String: String]
  ) async throws -> HTTPReply {
    var reply = try await post(
      server: server,
      method: method,
      params: params,
      era: connection.era,
      protocolVersion: connection.protocolVersion,
      sessionID: connection.sessionID,
      name: name,
      parameterHeaders: parameterHeaders
    )
    if connection.era == .legacy,
      connection.sessionID != nil,
      reply.statusCode == 404
    {
      connections.removeValue(forKey: server.id)
      let refreshed = try await initializeLegacy(server: server)
      connections[server.id] = refreshed
      reply = try await post(
        server: server,
        method: method,
        params: params,
        era: refreshed.era,
        protocolVersion: refreshed.protocolVersion,
        sessionID: refreshed.sessionID,
        name: name,
        parameterHeaders: parameterHeaders
      )
    }
    return reply
  }

  private func post(
    server: MCPRemoteServer,
    method: String,
    params: [String: JSONValue],
    era: MCPProtocolEra,
    protocolVersion: String?,
    sessionID: String?,
    name: String?,
    parameterHeaders: [String: String]
  ) async throws -> HTTPReply {
    let id = nextID()
    var bodyParams = params
    if era == .modern {
      bodyParams["_meta"] = modernMetadata()
    }
    let body: JSONValue = .object([
      "jsonrpc": .string("2.0"),
      "id": .number(Double(id)),
      "method": .string(method),
      "params": .object(bodyParams),
    ])
    let request = try await makeRequest(
      server: server,
      body: body,
      methodName: method,
      era: era,
      protocolVersion: protocolVersion,
      sessionID: sessionID,
      name: name,
      parameterHeaders: parameterHeaders
    )
    return try await send(request, expectedID: id)
  }

  private func postNotification(
    server: MCPRemoteServer,
    method: String,
    params: [String: JSONValue]?,
    protocolVersion: String,
    sessionID: String?
  ) async throws -> HTTPReply {
    var object: [String: JSONValue] = [
      "jsonrpc": .string("2.0"),
      "method": .string(method),
    ]
    if let params { object["params"] = .object(params) }
    let request = try await makeRequest(
      server: server,
      body: .object(object),
      methodName: method,
      era: .legacy,
      protocolVersion: protocolVersion,
      sessionID: sessionID,
      name: nil,
      parameterHeaders: [:]
    )
    return try await send(request, expectedID: nil)
  }

  private func makeRequest(
    server: MCPRemoteServer,
    body: JSONValue,
    methodName: String,
    era: MCPProtocolEra,
    protocolVersion: String?,
    sessionID: String?,
    name: String?,
    parameterHeaders: [String: String]
  ) async throws -> URLRequest {
    var request = URLRequest(url: server.endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")

    for (header, value) in server.additionalHeaders {
      request.setValue(value, forHTTPHeaderField: header)
    }
    let credential = try await vault.credential(serverID: server.id)
    switch server.authentication.kind {
    case .none:
      break
    case .bearer:
      guard let credential, !credential.isEmpty else { throw MCPError.missingCredential }
      request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
    case .customHeader:
      guard let header = server.authentication.headerName, !header.isEmpty else {
        throw MCPError.invalidServer("Custom authentication header name is missing.")
      }
      guard let credential, !credential.isEmpty else { throw MCPError.missingCredential }
      request.setValue(credential, forHTTPHeaderField: header)
    }

    if era == .modern {
      guard let protocolVersion else { throw MCPError.invalidResponse }
      request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
      request.setValue(methodName, forHTTPHeaderField: "Mcp-Method")
      if let name {
        request.setValue(MCPToolHeaderMapper.encodeHeaderValue(name), forHTTPHeaderField: "Mcp-Name")
      }
      for (header, value) in parameterHeaders {
        request.setValue(value, forHTTPHeaderField: header)
      }
    } else {
      if let protocolVersion,
        protocolVersion != "2025-03-26"
      {
        request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
      }
      if let sessionID {
        request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
      }
    }

    request.httpBody = try JSONEncoder.providerEncoder.encode(body)
    return request
  }

  private func send(_ request: URLRequest, expectedID: UInt64?) async throws -> HTTPReply {
    do {
      let response = try await transport.stream(for: request)
      let contentType = header("Content-Type", in: response.headers)?.lowercased() ?? ""
      if contentType.contains("text/event-stream") {
        var decoder = SSEDecoder()
        var finalPayload: JSONValue?
        for try await chunk in response.chunks {
          try Task.checkCancellation()
          for event in try decoder.append(chunk) {
            if let value = try? decodeJSON(event.data),
              matchesExpectedResponse(value, expectedID: expectedID)
            {
              finalPayload = value
            }
          }
        }
        for event in try decoder.finish() {
          if let value = try? decodeJSON(event.data),
            matchesExpectedResponse(value, expectedID: expectedID)
          {
            finalPayload = value
          }
        }
        return HTTPReply(
          statusCode: response.statusCode,
          headers: response.headers,
          payload: finalPayload
        )
      }

      var data = Data()
      for try await chunk in response.chunks {
        try Task.checkCancellation()
        data.append(chunk)
      }
      let payload: JSONValue?
      if data.isEmpty {
        payload = nil
      } else {
        let decoded = try? JSONDecoder.provider.decode(JSONValue.self, from: data)
        if let decoded, expectedID != nil, isRPCResponse(decoded),
          !matchesExpectedResponse(decoded, expectedID: expectedID)
        {
          throw MCPError.invalidResponse
        }
        payload = decoded
      }
      return HTTPReply(
        statusCode: response.statusCode,
        headers: response.headers,
        payload: payload
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as MCPError {
      throw error
    } catch {
      throw MCPError.transport(error.localizedDescription)
    }
  }

  private func modernMetadata() -> JSONValue {
    .object([
      "io.modelcontextprotocol/protocolVersion": .string(Self.modernProtocolVersion),
      "io.modelcontextprotocol/clientInfo": .object([
        "name": .string("BYOKchat"),
        "version": .string("1.0"),
      ]),
      "io.modelcontextprotocol/clientCapabilities": .object([
        "elicitation": .object([
          "form": .object([:]),
          "url": .object([:]),
        ])
      ]),
    ])
  }

  private func decodeTool(_ value: JSONValue) throws -> MCPRemoteTool {
    guard case .object(let object) = value,
      let name = stringValue(object["name"]),
      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let inputSchema = object["inputSchema"],
      case .object = inputSchema
    else {
      throw MCPError.invalidToolDefinition("MCP server returned a tool with an invalid name or inputSchema.")
    }
    let bindings = try MCPToolHeaderMapper.bindings(from: inputSchema)
    return MCPRemoteTool(
      remoteName: name,
      title: stringValue(object["title"]),
      description: stringValue(object["description"]) ?? "MCP tool \(name)",
      inputSchema: inputSchema,
      outputSchema: object["outputSchema"],
      annotations: object["annotations"],
      headerBindings: bindings
    )
  }

  private func normalizedToolContent(_ object: [String: JSONValue]) -> JSONValue {
    if let structured = object["structuredContent"] {
      if let content = object["content"] {
        return .object([
          "structuredContent": structured,
          "content": content,
        ])
      }
      return structured
    }

    guard case .array(let content)? = object["content"] else {
      return .object(object)
    }
    var text: [String] = []
    var hasNonText = false
    for item in content {
      guard case .object(let block) = item,
        stringValue(block["type"]) == "text",
        let value = stringValue(block["text"])
      else {
        hasNonText = true
        continue
      }
      text.append(value)
    }
    if !hasNonText, !text.isEmpty {
      return .string(text.joined(separator: "\n\n"))
    }
    return .object(["content": .array(content)])
  }

  private func supportsTools(_ capabilities: JSONValue) -> Bool {
    guard case .object(let object) = capabilities else { return false }
    return object["tools"] != nil
  }

  private struct RPCErrorValue: Sendable {
    var code: Int
    var message: String
    var supportedVersions: [String]
  }

  private func rpcError(_ payload: JSONValue) -> RPCErrorValue? {
    guard case .object(let root) = payload,
      case .object(let error)? = root["error"],
      let code = integerValue(error["code"]),
      let message = stringValue(error["message"])
    else { return nil }
    var supported: [String] = []
    if case .object(let data)? = error["data"] {
      supported = stringArray(data["supported"])
    }
    return RPCErrorValue(code: code, message: message, supportedVersions: supported)
  }

  private func rpcResult(_ payload: JSONValue) -> JSONValue? {
    guard case .object(let root) = payload else { return nil }
    return root["result"]
  }

  private func isRPCResponse(_ value: JSONValue) -> Bool {
    guard case .object(let object) = value else { return false }
    return object["id"] != nil && (object["result"] != nil || object["error"] != nil)
  }

  private func matchesExpectedResponse(_ value: JSONValue, expectedID: UInt64?) -> Bool {
    guard let expectedID else { return false }
    guard case .object(let object) = value,
      object["result"] != nil || object["error"] != nil,
      case .number(let rawID)? = object["id"],
      rawID.isFinite,
      rawID >= 0,
      rawID.rounded(.towardZero) == rawID,
      rawID <= Double(UInt64.max)
    else {
      return false
    }
    return UInt64(rawID) == expectedID
  }

  private func decodeJSON(_ string: String) throws -> JSONValue {
    guard let data = string.data(using: .utf8) else { throw MCPError.invalidResponse }
    do {
      return try JSONDecoder.provider.decode(JSONValue.self, from: data)
    } catch {
      throw MCPError.invalidResponse
    }
  }

  private func implementationInfo(from metadata: JSONValue?) -> MCPImplementationInfo? {
    guard case .object(let meta)? = metadata else { return nil }
    return implementationInfoDirect(from: meta["io.modelcontextprotocol/serverInfo"])
  }

  private func implementationInfoDirect(from value: JSONValue?) -> MCPImplementationInfo? {
    guard case .object(let object)? = value,
      let name = stringValue(object["name"]),
      let version = stringValue(object["version"])
    else { return nil }
    return MCPImplementationInfo(
      name: name,
      version: version,
      title: stringValue(object["title"])
    )
  }

  private func httpError(status: Int, payload: JSONValue?) -> MCPError {
    if let payload, let error = rpcError(payload) {
      if error.code == -32_022 { return .unsupportedProtocol(error.supportedVersions) }
      return .protocolError(code: error.code, message: error.message)
    }
    switch status {
    case 401: return .authenticationFailed
    case 403: return .permissionDenied
    case 429: return .rateLimited
    default: return .transport("MCP server returned HTTP \(status).")
    }
  }

  private func header(_ name: String, in headers: [String: String]) -> String? {
    headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
  }

  private func stringValue(_ value: JSONValue?) -> String? {
    guard case .string(let value)? = value else { return nil }
    return value
  }

  private func boolValue(_ value: JSONValue?) -> Bool? {
    guard case .bool(let value)? = value else { return nil }
    return value
  }

  private func integerValue(_ value: JSONValue?) -> Int? {
    guard case .number(let value)? = value, value.isFinite,
      value.rounded(.towardZero) == value,
      value >= Double(Int.min), value <= Double(Int.max)
    else { return nil }
    return Int(value)
  }

  private func stringArray(_ value: JSONValue?) -> [String] {
    guard case .array(let values)? = value else { return [] }
    return values.compactMap { stringValue($0) }
  }

  private func nextID() -> UInt64 {
    defer { nextRequestID &+= 1 }
    return nextRequestID
  }
}