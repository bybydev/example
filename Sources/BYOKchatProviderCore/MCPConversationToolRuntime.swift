import Foundation

public actor MCPConversationToolRuntime: ChatConversationToolExecuting {
  private struct RemoteExecutionOutcome: Sendable {
    var result: ChatToolResult
    var interactiveRoundCount: Int
    var elicitationCount: Int
  }

  private let localRuntime: (any ChatToolExecuting)?
  private let mcpRuntime: MCPRemoteRuntime
  private let workspace: MCPWorkspaceStore
  private let projectWorkspace: ProjectWorkspaceStore?
  private let approvals: MCPToolApprovalCenter
  private let elicitations: MCPElicitationCenter
  private let maxInputRequiredRounds: Int
  private let telemetry: ChatToolTelemetry

  public init(
    localRuntime: (any ChatToolExecuting)? = nil,
    mcpRuntime: MCPRemoteRuntime,
    workspace: MCPWorkspaceStore,
    projectWorkspace: ProjectWorkspaceStore? = nil,
    approvals: MCPToolApprovalCenter,
    elicitations: MCPElicitationCenter,
    maxInputRequiredRounds: Int = 10,
    telemetryRecorder: TelemetryRecorder? = nil
  ) {
    self.localRuntime = localRuntime
    self.mcpRuntime = mcpRuntime
    self.workspace = workspace
    self.projectWorkspace = projectWorkspace
    self.approvals = approvals
    self.elicitations = elicitations
    self.maxInputRequiredRounds = max(1, maxInputRequiredRounds)
    telemetry = ChatToolTelemetry(recorder: telemetryRecorder)
  }

  public func availableTools(conversationID: ConversationID) async -> [ChatToolDefinition] {
    var definitions: [ChatToolDefinition]
    if let localRuntime {
      definitions = await localRuntime.availableTools()
    } else {
      definitions = []
    }

    let configuration = await effectiveConfiguration(for: conversationID)
    guard !configuration.enabledServerIDs.isEmpty else {
      return sorted(definitions)
    }

    let servers = await mcpRuntime.servers()
    let globallyEnabled = Set(servers.filter(\.isEnabled).map(\.id))
    let selectedServerIDs = Set(configuration.enabledServerIDs).intersection(globallyEnabled)
    guard !selectedServerIDs.isEmpty else {
      return sorted(definitions)
    }

    for serverID in selectedServerIDs {
      _ = try? await mcpRuntime.refreshServer(serverID)
    }

    let localNames = Set(definitions.map(\.name))
    let allBindings = await mcpRuntime.toolBindings()
    let bindings = allBindings.filter { binding in
      selectedServerIDs.contains(binding.serverID)
        && configuration.policy(for: binding.exposedName) != .disabled
        && !localNames.contains(binding.exposedName)
    }
    definitions.append(contentsOf: bindings.map(\.chatDefinition))
    return sorted(definitions)
  }

  public func execute(
    _ call: ChatToolCall,
    conversationID: ConversationID
  ) async -> ChatToolResult {
    let clock = ContinuousClock()
    let startedAt = clock.now

    if let localRuntime {
      let localTools = await localRuntime.availableTools()
      if localTools.contains(where: { $0.name == call.name }) {
        telemetry.started(
          call: call,
          conversationID: conversationID,
          source: "local"
        )
        let result = await localRuntime.execute(call)
        telemetry.completed(
          call: call,
          conversationID: conversationID,
          source: "local",
          durationMilliseconds: durationMilliseconds(startedAt, clock: clock),
          resultIsError: result.isError
        )
        return result
      }
    }

    let configuration = await effectiveConfiguration(for: conversationID)
    let bindings = await mcpRuntime.toolBindings()
    guard let binding = bindings.first(where: { $0.exposedName == call.name }) else {
      telemetry.started(
        call: call,
        conversationID: conversationID,
        source: "mcp"
      )
      telemetry.failed(
        call: call,
        conversationID: conversationID,
        source: "mcp",
        durationMilliseconds: durationMilliseconds(startedAt, clock: clock),
        errorCode: "tool_unavailable",
        classification: "configuration"
      )
      return failure(call, "MCP tool is no longer available. Refresh its server and try again.")
    }

    let policy = configuration.policy(for: binding.exposedName)
    telemetry.started(
      call: call,
      conversationID: conversationID,
      source: "mcp",
      serverID: binding.serverID,
      remoteToolName: binding.remoteTool.remoteName,
      policy: policy
    )

    guard configuration.isServerEnabled(binding.serverID) else {
      telemetry.failed(
        call: call,
        conversationID: conversationID,
        source: "mcp",
        serverID: binding.serverID,
        remoteToolName: binding.remoteTool.remoteName,
        policy: policy,
        durationMilliseconds: durationMilliseconds(startedAt, clock: clock),
        errorCode: "server_not_enabled_for_chat",
        classification: "configuration"
      )
      return failure(call, "This MCP server is not enabled for this chat.")
    }

    let servers = await mcpRuntime.servers()
    guard let server = servers.first(where: { $0.id == binding.serverID }), server.isEnabled else {
      telemetry.failed(
        call: call,
        conversationID: conversationID,
        source: "mcp",
        serverID: binding.serverID,
        remoteToolName: binding.remoteTool.remoteName,
        policy: policy,
        durationMilliseconds: durationMilliseconds(startedAt, clock: clock),
        errorCode: "server_disabled",
        classification: "configuration"
      )
      return failure(call, "This MCP server is disabled in Settings.")
    }

    guard policy != .disabled else {
      telemetry.failed(
        call: call,
        conversationID: conversationID,
        source: "mcp",
        serverID: binding.serverID,
        remoteToolName: binding.remoteTool.remoteName,
        policy: policy,
        durationMilliseconds: durationMilliseconds(startedAt, clock: clock),
        errorCode: "tool_disabled",
        classification: "configuration"
      )
      return failure(call, "This MCP tool is disabled for this chat.")
    }

    var approvalDecision: String?
    if policy == .ask {
      let request = MCPToolApprovalRequest(
        conversationID: conversationID,
        callID: call.id,
        serverID: binding.serverID,
        serverName: server.name,
        exposedToolName: binding.exposedName,
        remoteToolName: binding.remoteTool.remoteName,
        toolTitle: binding.remoteTool.title,
        toolDescription: binding.remoteTool.description,
        arguments: call.arguments,
        readOnlyHint: annotationBool("readOnlyHint", tool: binding.remoteTool),
        destructiveHint: annotationBool("destructiveHint", tool: binding.remoteTool)
      )
      switch await approvals.requestApproval(request) {
      case .allowOnce:
        approvalDecision = MCPToolApprovalDecision.allowOnce.rawValue
      case .alwaysAllow:
        approvalDecision = MCPToolApprovalDecision.alwaysAllow.rawValue
        do {
          try await materializeInheritedConfigurationIfNeeded(conversationID)
          try await workspace.setChatToolPolicy(
            .alwaysAllow,
            exposedToolName: binding.exposedName,
            conversationID: conversationID
          )
        } catch {
          telemetry.failed(
            call: call,
            conversationID: conversationID,
            source: "mcp",
            serverID: binding.serverID,
            remoteToolName: binding.remoteTool.remoteName,
            policy: policy,
            durationMilliseconds: durationMilliseconds(startedAt, clock: clock),
            errorCode: "approval_persistence_failed",
            classification: "storage",
            approvalDecision: approvalDecision
          )
          return failure(call, error.localizedDescription)
        }
      case .deny:
        approvalDecision = MCPToolApprovalDecision.deny.rawValue
        telemetry.failed(
          call: call,
          conversationID: conversationID,
          source: "mcp",
          serverID: binding.serverID,
          remoteToolName: binding.remoteTool.remoteName,
          policy: policy,
          durationMilliseconds: durationMilliseconds(startedAt, clock: clock),
          errorCode: "approval_denied",
          classification: "user_decision",
          approvalDecision: approvalDecision
        )
        return failure(call, "The user denied this tool call.")
      }
    }

    if Task.isCancelled {
      telemetry.cancelled(
        call: call,
        conversationID: conversationID,
        source: "mcp",
        serverID: binding.serverID,
        remoteToolName: binding.remoteTool.remoteName,
        policy: policy,
        durationMilliseconds: durationMilliseconds(startedAt, clock: clock)
      )
      return failure(call, "Tool execution was cancelled.")
    }

    do {
      let outcome = try await executeRemoteTool(
        call,
        conversationID: conversationID,
        server: server,
        binding: binding
      )
      telemetry.completed(
        call: call,
        conversationID: conversationID,
        source: "mcp",
        serverID: binding.serverID,
        remoteToolName: binding.remoteTool.remoteName,
        policy: policy,
        durationMilliseconds: durationMilliseconds(startedAt, clock: clock),
        resultIsError: outcome.result.isError,
        interactiveRoundCount: outcome.interactiveRoundCount,
        elicitationCount: outcome.elicitationCount,
        approvalDecision: approvalDecision
      )
      return outcome.result
    } catch is CancellationError {
      telemetry.cancelled(
        call: call,
        conversationID: conversationID,
        source: "mcp",
        serverID: binding.serverID,
        remoteToolName: binding.remoteTool.remoteName,
        policy: policy,
        durationMilliseconds: durationMilliseconds(startedAt, clock: clock)
      )
      return failure(call, "Tool execution was cancelled.")
    } catch {
      let failure = ChatToolTelemetry.failureDescriptor(for: error)
      telemetry.failed(
        call: call,
        conversationID: conversationID,
        source: "mcp",
        serverID: binding.serverID,
        remoteToolName: binding.remoteTool.remoteName,
        policy: policy,
        durationMilliseconds: durationMilliseconds(startedAt, clock: clock),
        errorCode: failure.errorCode,
        classification: failure.classification,
        approvalDecision: approvalDecision
      )
      return failure(call, error.localizedDescription)
    }
  }

  public func cancelInteractions(conversationID: ConversationID) async {
    await approvals.cancelConversation(conversationID)
    await elicitations.cancelConversation(conversationID)
  }

  private func effectiveConfiguration(for conversationID: ConversationID) async
    -> MCPChatToolConfiguration
  {
    if let explicit = await workspace.explicitChatConfiguration(for: conversationID) {
      return explicit
    }
    if let inherited = await projectWorkspace?.mcpConfiguration(for: conversationID) {
      return inherited
    }
    return MCPChatToolConfiguration()
  }

  private func materializeInheritedConfigurationIfNeeded(_ conversationID: ConversationID) async throws {
    guard await workspace.explicitChatConfiguration(for: conversationID) == nil,
      let inherited = await projectWorkspace?.mcpConfiguration(for: conversationID)
    else { return }
    try await workspace.replaceChatConfiguration(inherited, conversationID: conversationID)
  }

  private func executeRemoteTool(
    _ call: ChatToolCall,
    conversationID: ConversationID,
    server: MCPRemoteServer,
    binding: MCPToolBinding
  ) async throws -> RemoteExecutionOutcome {
    var inputResponses: [String: JSONValue]?
    var requestState: String?
    var elicitationCount = 0

    for roundIndex in 0..<maxInputRequiredRounds {
      try Task.checkCancellation()
      let round = try await mcpRuntime.callToolRound(
        serverID: binding.serverID,
        remoteName: binding.remoteTool.remoteName,
        arguments: call.arguments,
        inputResponses: inputResponses,
        requestState: requestState
      )

      switch round {
      case .complete(let output):
        return RemoteExecutionOutcome(
          result: ChatToolResult(
            callID: call.id,
            name: call.name,
            content: output.content,
            isError: output.isError
          ),
          interactiveRoundCount: roundIndex + 1,
          elicitationCount: elicitationCount
        )

      case .inputRequired(let required):
        guard roundIndex + 1 < maxInputRequiredRounds else {
          throw MCPError.transport(
            "The MCP tool exceeded \(maxInputRequiredRounds) interactive input rounds."
          )
        }

        requestState = required.requestState
        guard !required.inputRequests.isEmpty else {
          try await Task.sleep(for: .milliseconds(250))
          inputResponses = nil
          continue
        }

        elicitationCount += required.inputRequests.count
        var responses: [String: JSONValue] = [:]
        for key in required.inputRequests.keys.sorted() {
          guard let inputRequest = required.inputRequests[key] else { continue }
          let request = try parseElicitationRequest(
            inputRequest,
            interactionKey: key,
            conversationID: conversationID,
            server: server,
            binding: binding
          )
          let decision = await elicitations.requestInput(request)
          try Task.checkCancellation()
          responses[key] = elicitationResponse(decision)
        }
        inputResponses = responses
      }
    }

    throw MCPError.transport(
      "The MCP tool exceeded \(maxInputRequiredRounds) interactive input rounds."
    )
  }

  private func parseElicitationRequest(
    _ value: JSONValue,
    interactionKey: String,
    conversationID: ConversationID,
    server: MCPRemoteServer,
    binding: MCPToolBinding
  ) throws -> MCPElicitationRequest {
    guard case .object(let requestObject) = value,
      stringValue(requestObject["method"]) == "elicitation/create",
      case .object(let params)? = requestObject["params"],
      let message = stringValue(params["message"]),
      !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw MCPError.invalidResponse
    }

    let modeValue = stringValue(params["mode"]) ?? "form"
    switch modeValue {
    case "form":
      guard let schema = params["requestedSchema"] else { throw MCPError.invalidResponse }
      return MCPElicitationRequest(
        interactionKey: interactionKey,
        conversationID: conversationID,
        serverID: binding.serverID,
        serverName: server.name,
        exposedToolName: binding.exposedName,
        remoteToolName: binding.remoteTool.remoteName,
        message: message,
        mode: .form,
        fields: try parseElicitationFields(schema)
      )

    case "url":
      guard let rawURL = stringValue(params["url"]),
        let url = URL(string: rawURL),
        url.scheme?.lowercased() == "https",
        url.host?.isEmpty == false,
        url.user == nil,
        url.password == nil
      else {
        throw MCPError.invalidResponse
      }
      return MCPElicitationRequest(
        interactionKey: interactionKey,
        conversationID: conversationID,
        serverID: binding.serverID,
        serverName: server.name,
        exposedToolName: binding.exposedName,
        remoteToolName: binding.remoteTool.remoteName,
        message: message,
        mode: .url,
        url: url
      )

    default:
      throw MCPError.invalidResponse
    }
  }

  private func parseElicitationFields(_ schema: JSONValue) throws -> [MCPElicitationField] {
    guard case .object(let root) = schema,
      stringValue(root["type"]) == "object"
    else {
      throw MCPError.invalidResponse
    }

    let required = Set(stringArray(root["required"]))
    let properties: [String: JSONValue]
    if case .object(let values)? = root["properties"] {
      properties = values
    } else {
      properties = [:]
    }
    guard properties.count <= 32 else {
      throw MCPError.invalidResponse
    }

    return try properties.keys.sorted().map { name in
      guard !name.isEmpty,
        let value = properties[name],
        case .object(let property) = value,
        let type = stringValue(property["type"])
      else {
        throw MCPError.invalidResponse
      }

      let kind: MCPElicitationFieldKind
      let allowedValues: [String]
      switch type {
      case "string":
        kind = .string
        allowedValues = stringArray(property["enum"])
      case "integer":
        kind = .integer
        allowedValues = []
      case "number":
        kind = .number
        allowedValues = []
      case "boolean":
        kind = .boolean
        allowedValues = []
      case "array":
        guard case .object(let items)? = property["items"],
          stringValue(items["type"]) == "string"
        else {
          throw MCPError.invalidResponse
        }
        kind = .stringArray
        allowedValues = stringArray(items["enum"])
      default:
        throw MCPError.invalidResponse
      }

      return MCPElicitationField(
        name: name,
        title: stringValue(property["title"]),
        description: stringValue(property["description"]),
        kind: kind,
        isRequired: required.contains(name),
        allowedValues: allowedValues,
        defaultValue: property["default"]
      )
    }
  }

  private func elicitationResponse(_ decision: MCPElicitationDecision) -> JSONValue {
    switch decision {
    case .accept(let content):
      var value: [String: JSONValue] = ["action": .string("accept")]
      if !content.isEmpty { value["content"] = .object(content) }
      return .object(value)
    case .decline:
      return .object(["action": .string("decline")])
    case .cancel:
      return .object(["action": .string("cancel")])
    }
  }

  private func annotationBool(_ key: String, tool: MCPRemoteTool) -> Bool? {
    guard case .object(let annotations)? = tool.annotations,
      case .bool(let value)? = annotations[key]
    else { return nil }
    return value
  }

  private func stringValue(_ value: JSONValue?) -> String? {
    guard case .string(let value)? = value else { return nil }
    return value
  }

  private func stringArray(_ value: JSONValue?) -> [String] {
    guard case .array(let values)? = value else { return [] }
    return values.compactMap { stringValue($0) }
  }

  private func sorted(_ definitions: [ChatToolDefinition]) -> [ChatToolDefinition] {
    definitions.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  private func durationMilliseconds(
    _ startedAt: ContinuousClock.Instant,
    clock: ContinuousClock
  ) -> Double {
    ChatToolTelemetry.milliseconds(startedAt.duration(to: clock.now))
  }

  private func failure(_ call: ChatToolCall, _ message: String) -> ChatToolResult {
    ChatToolResult(
      callID: call.id,
      name: call.name,
      content: .string(message),
      isError: true
    )
  }
}
