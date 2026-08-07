import Foundation

public actor MCPConversationToolRuntime: ChatConversationToolExecuting {
  private let localRuntime: (any ChatToolExecuting)?
  private let mcpRuntime: MCPRemoteRuntime
  private let workspace: MCPWorkspaceStore
  private let approvals: MCPToolApprovalCenter
  private let elicitations: MCPElicitationCenter

  public init(
    localRuntime: (any ChatToolExecuting)? = nil,
    mcpRuntime: MCPRemoteRuntime,
    workspace: MCPWorkspaceStore,
    approvals: MCPToolApprovalCenter,
    elicitations: MCPElicitationCenter
  ) {
    self.localRuntime = localRuntime
    self.mcpRuntime = mcpRuntime
    self.workspace = workspace
    self.approvals = approvals
    self.elicitations = elicitations
  }

  public func availableTools(conversationID: ConversationID) async -> [ChatToolDefinition] {
    var definitions = await localRuntime?.availableTools() ?? []
    let configuration = await workspace.chatConfiguration(for: conversationID)
    guard !configuration.enabledServerIDs.isEmpty else {
      return definitions.sorted { $0.name < $1.name }
    }

    let globallyEnabled = Set(
      await mcpRuntime.servers().filter(\.isEnabled).map(\.id)
    )
    let selectedServerIDs = Set(configuration.enabledServerIDs).intersection(globallyEnabled)
    guard !selectedServerIDs.isEmpty else {
      return definitions.sorted { $0.name < $1.name }
    }

    // Refresh only selected servers. A stale cached catalog should not remain exposed to the model
    // indefinitely, but a temporary refresh failure should not erase the last known safe catalog.
    for serverID in selectedServerIDs {
      _ = try? await mcpRuntime.refreshServer(serverID)
    }

    let localNames = Set(definitions.map(\.name))
    let bindings = await mcpRuntime.toolBindings().filter { binding in
      selectedServerIDs.contains(binding.serverID)
        && configuration.policy(for: binding.exposedName) != .disabled
        && !localNames.contains(binding.exposedName)
    }
    definitions.append(contentsOf: bindings.map(\.chatDefinition))
    return definitions.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  public func execute(
    _ call: ChatToolCall,
    conversationID: ConversationID
  ) async -> ChatToolResult {
    if let localRuntime,
      await localRuntime.availableTools().contains(where: { $0.name == call.name })
    {
      return await localRuntime.execute(call)
    }

    let configuration = await workspace.chatConfiguration(for: conversationID)
    let bindings = await mcpRuntime.toolBindings()
    guard let binding = bindings.first(where: { $0.exposedName == call.name }) else {
      return failure(call, "MCP tool is no longer available. Refresh its server and try again.")
    }
    guard configuration.isServerEnabled(binding.serverID) else {
      return failure(call, "This MCP server is not enabled for this chat.")
    }
    guard let server = await mcpRuntime.servers().first(where: { $0.id == binding.serverID }),
      server.isEnabled
    else {
      return failure(call, "This MCP server is disabled in Settings.")
    }

    let policy = configuration.policy(for: binding.exposedName)
    guard policy != .disabled else {
      return failure(call, "This MCP tool is disabled for this chat.")
    }

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
        break
      case .alwaysAllow:
        do {
          try await workspace.setChatToolPolicy(
            .alwaysAllow,
            exposedToolName: binding.exposedName,
            conversationID: conversationID
          )
        } catch {
          return failure(call, error.localizedDescription)
        }
      case .deny:
        return failure(call, "The user denied this tool call.")
      }
    }

    if Task.isCancelled {
      return failure(call, "Tool execution was cancelled.")
    }

    do {
      let output = try await mcpRuntime.callTool(
        serverID: binding.serverID,
        remoteName: binding.remoteTool.remoteName,
        arguments: call.arguments
      )
      return ChatToolResult(
        callID: call.id,
        name: call.name,
        content: output.content,
        isError: output.isError
      )
    } catch MCPError.inputRequired {
      return failure(
        call,
        "This MCP tool requested additional interactive input that cannot be completed in this build."
      )
    } catch is CancellationError {
      return failure(call, "Tool execution was cancelled.")
    } catch {
      return failure(call, error.localizedDescription)
    }
  }

  public func cancelInteractions(conversationID: ConversationID) async {
    await approvals.cancelConversation(conversationID)
    await elicitations.cancelConversation(conversationID)
  }

  private func annotationBool(_ key: String, tool: MCPRemoteTool) -> Bool? {
    guard case .object(let annotations)? = tool.annotations,
      case .bool(let value)? = annotations[key]
    else { return nil }
    return value
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
