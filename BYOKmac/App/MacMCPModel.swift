import BYOKchatProviderCore
import Foundation
import Observation

@MainActor
@Observable
final class MacMCPModel {
  private(set) var servers: [MCPRemoteServer] = []
  private(set) var snapshotsByServer: [MCPServerID: MCPServerSnapshot] = [:]
  private(set) var credentialServerIDs: Set<MCPServerID> = []
  private(set) var chatConfigurations: [ConversationID: MCPChatToolConfiguration] = [:]
  private(set) var inheritedChatConfigurations: [ConversationID: MCPChatToolConfiguration] = [:]
  private(set) var pendingApprovals: [MCPToolApprovalRequest] = []
  private(set) var pendingElicitations: [MCPElicitationRequest] = []

  var isBusy = false
  var errorMessage: String?
  var statusMessage: String?

  private let runtime: MCPRemoteRuntime
  private let workspace: MCPWorkspaceStore
  private let projectWorkspace: ProjectWorkspaceStore
  private let approvals: MCPToolApprovalCenter
  private let elicitations: MCPElicitationCenter
  private var approvalObservationTask: Task<Void, Never>?
  private var elicitationObservationTask: Task<Void, Never>?

  init(services: BYOKCoreServices) {
    runtime = services.mcpRuntime
    workspace = services.mcpWorkspace
    projectWorkspace = services.projectWorkspace
    approvals = services.approvalCenter
    elicitations = services.elicitationCenter
  }

  func load() async throws {
    startInteractionObserversIfNeeded()
    try await runtime.load()
    try await reloadSnapshot()
  }

  func stopInteractionObservers() {
    approvalObservationTask?.cancel()
    approvalObservationTask = nil
    elicitationObservationTask?.cancel()
    elicitationObservationTask = nil
    pendingApprovals = []
    pendingElicitations = []
  }

  func reloadFromStorage() async {
    await perform(nil) {
      try await reloadSnapshot()
    }
  }

  func snapshot(for serverID: MCPServerID) -> MCPServerSnapshot? {
    snapshotsByServer[serverID]
  }

  func hasCredential(_ serverID: MCPServerID) -> Bool {
    credentialServerIDs.contains(serverID)
  }

  func chatConfiguration(for conversationID: ConversationID) -> MCPChatToolConfiguration {
    chatConfigurations[conversationID]
      ?? inheritedChatConfigurations[conversationID]
      ?? MCPChatToolConfiguration()
  }

  func hasChatOverride(_ conversationID: ConversationID) -> Bool {
    chatConfigurations[conversationID] != nil
  }

  func inheritsProjectTools(_ conversationID: ConversationID) -> Bool {
    chatConfigurations[conversationID] == nil && inheritedChatConfigurations[conversationID] != nil
  }

  func isServerEnabled(_ serverID: MCPServerID, for conversationID: ConversationID) -> Bool {
    chatConfiguration(for: conversationID).isServerEnabled(serverID)
  }

  func toolPolicy(_ exposedToolName: String, for conversationID: ConversationID) -> ChatToolPermissionPolicy {
    chatConfiguration(for: conversationID).policy(for: exposedToolName)
  }

  func tools(for serverID: MCPServerID) -> [MCPToolBinding] {
    guard let snapshot = snapshotsByServer[serverID] else { return [] }
    return snapshot.tools.map { tool in
      MCPToolBinding(
        serverID: serverID,
        remoteTool: tool,
        exposedName: MCPToolNamespace.exposedName(serverID: serverID, remoteName: tool.remoteName)
      )
    }
    .sorted {
      let lhs = $0.remoteTool.title ?? $0.remoteTool.remoteName
      let rhs = $1.remoteTool.title ?? $1.remoteTool.remoteName
      return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
    }
  }

  func toolDisplayName(_ exposedToolName: String) -> String {
    for server in servers {
      if let binding = tools(for: server.id).first(where: { $0.exposedName == exposedToolName }) {
        let toolName = binding.remoteTool.title ?? binding.remoteTool.remoteName
        return "\(server.name) · \(toolName)"
      }
    }
    return exposedToolName
  }

  func pendingApprovals(for conversationID: ConversationID) -> [MCPToolApprovalRequest] {
    pendingApprovals.filter { $0.conversationID == conversationID }
  }

  func pendingElicitations(for conversationID: ConversationID) -> [MCPElicitationRequest] {
    pendingElicitations.filter { $0.conversationID == conversationID }
  }

  func saveServer(
    existing: MCPRemoteServer?,
    name: String,
    endpoint: String,
    authenticationKind: MCPAuthenticationKind,
    authenticationHeader: String,
    credential: String?,
    additionalHeaders: [String: String],
    isEnabled: Bool
  ) async -> Bool {
    if existing == nil,
      !MacProAccess.requireMCPServerCapacity(currentCount: servers.count)
    {
      errorMessage = "Free includes 1 MCP server. Upgrade to BYOK Pro to add more."
      return false
    }

    return await performResult("MCP server saved and tools discovered") {
      let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
      let normalizedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let url = URL(string: normalizedEndpoint) else {
        throw MCPError.invalidServer("Enter a valid MCP endpoint URL.")
      }

      let authentication = MCPAuthentication(
        kind: authenticationKind,
        headerName: authenticationKind == .customHeader
          ? authenticationHeader.trimmingCharacters(in: .whitespacesAndNewlines)
          : nil
      )

      var server = existing ?? MCPRemoteServer(name: normalizedName, endpoint: url)
      server.name = normalizedName
      server.endpoint = url
      server.authentication = authentication
      server.additionalHeaders = additionalHeaders
      server.isEnabled = isEnabled

      let existingCredential = existing.map { credentialServerIDs.contains($0.id) } ?? false
      if authenticationKind != .none,
        credential?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
        !existingCredential
      {
        throw MCPError.missingCredential
      }

      try await runtime.saveServer(server, credential: credential)
      if server.isEnabled {
        _ = try await runtime.refreshServer(server.id, force: true)
      }
      try await reloadSnapshot()
    }
  }

  func deleteServer(_ serverID: MCPServerID) async -> Bool {
    await performResult("MCP server deleted") {
      try await runtime.deleteServer(serverID)
      try await reloadSnapshot()
    }
  }

  func setEnabled(_ enabled: Bool, serverID: MCPServerID) async -> Bool {
    await performResult(nil) {
      try await runtime.setEnabled(enabled, serverID: serverID)
      if enabled {
        _ = try await runtime.refreshServer(serverID, force: true)
      }
      try await reloadSnapshot()
    }
  }

  func refresh(_ serverID: MCPServerID) async -> Bool {
    await performResult("MCP tools refreshed") {
      _ = try await runtime.refreshServer(serverID, force: true)
      try await reloadSnapshot()
    }
  }

  func setChatServerEnabled(
    _ enabled: Bool,
    serverID: MCPServerID,
    conversationID: ConversationID
  ) async -> Bool {
    await performResult(nil) {
      if enabled {
        guard servers.first(where: { $0.id == serverID })?.isEnabled == true else {
          throw MCPError.invalidServer("Enable this MCP server in Settings first.")
        }
        _ = try await runtime.refreshServer(serverID)
      }
      try await materializeInheritedConfigurationIfNeeded(conversationID)
      try await workspace.setChatServerEnabled(
        enabled,
        serverID: serverID,
        conversationID: conversationID
      )
      try await reloadSnapshot()
    }
  }

  func setChatToolPolicy(
    _ policy: ChatToolPermissionPolicy,
    exposedToolName: String,
    conversationID: ConversationID
  ) async -> Bool {
    await performResult(nil) {
      try await materializeInheritedConfigurationIfNeeded(conversationID)
      try await workspace.setChatToolPolicy(
        policy,
        exposedToolName: exposedToolName,
        conversationID: conversationID
      )
      try await reloadSnapshot()
    }
  }

  func applyChatConfiguration(
    _ configuration: MCPChatToolConfiguration,
    conversationID: ConversationID
  ) async -> Bool {
    await performResult("Tool configuration applied") {
      try await workspace.replaceChatConfiguration(configuration, conversationID: conversationID)
      try await reloadSnapshot()
    }
  }

  func removeChatConfiguration(_ conversationID: ConversationID) async -> Bool {
    await performResult(nil) {
      try await workspace.removeChatConfiguration(conversationID: conversationID)
      try await reloadSnapshot()
    }
  }

  func resolveApproval(_ requestID: String, decision: MCPToolApprovalDecision) async {
    if decision == .alwaysAllow,
      let request = pendingApprovals.first(where: { $0.id == requestID })
    {
      do {
        try await materializeInheritedConfigurationIfNeeded(request.conversationID)
        try await workspace.setChatToolPolicy(
          .alwaysAllow,
          exposedToolName: request.exposedToolName,
          conversationID: request.conversationID
        )
        try await reloadSnapshot()
        await approvals.resolve(requestID, decision: .allowOnce)
      } catch {
        errorMessage = error.localizedDescription
        await approvals.resolve(requestID, decision: .deny)
      }
      return
    }
    await approvals.resolve(requestID, decision: decision)
  }

  func resolveElicitation(_ requestID: String, decision: MCPElicitationDecision) async {
    await elicitations.resolve(requestID, decision: decision)
  }

  private func materializeInheritedConfigurationIfNeeded(_ conversationID: ConversationID) async throws {
    guard chatConfigurations[conversationID] == nil,
      let inherited = inheritedChatConfigurations[conversationID]
    else { return }
    try await workspace.replaceChatConfiguration(inherited, conversationID: conversationID)
  }

  private func reloadSnapshot() async throws {
    servers = await runtime.servers()
    let snapshots = await runtime.snapshots()
    snapshotsByServer = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.serverID, $0) })

    let workspaceSnapshot = await workspace.snapshot()
    chatConfigurations = Dictionary(
      uniqueKeysWithValues: (workspaceSnapshot.chatConfigurations ?? [:]).map {
        (ConversationID(rawValue: $0.key), $0.value)
      }
    )

    let projectSnapshot = await projectWorkspace.snapshot()
    let projectsByID = Dictionary(uniqueKeysWithValues: projectSnapshot.projects.map { ($0.id.rawValue, $0) })
    inheritedChatConfigurations = Dictionary(
      uniqueKeysWithValues: projectSnapshot.conversationProjectIDs.compactMap { conversationID, projectID in
        guard let configuration = projectsByID[projectID]?.mcpConfiguration else { return nil }
        return (ConversationID(rawValue: conversationID), configuration)
      }
    )

    var credentials: Set<MCPServerID> = []
    for server in servers {
      if try await runtime.hasCredential(serverID: server.id) {
        credentials.insert(server.id)
      }
    }
    credentialServerIDs = credentials
  }

  private func startInteractionObserversIfNeeded() {
    if approvalObservationTask == nil {
      let center = approvals
      approvalObservationTask = Task { @MainActor [weak self] in
        let stream = await center.updates()
        for await requests in stream {
          guard let self, !Task.isCancelled else { return }
          pendingApprovals = requests
        }
      }
    }

    if elicitationObservationTask == nil {
      let center = elicitations
      elicitationObservationTask = Task { @MainActor [weak self] in
        let stream = await center.updates()
        for await requests in stream {
          guard let self, !Task.isCancelled else { return }
          pendingElicitations = requests
        }
      }
    }
  }

  private func perform(_ successMessage: String?, operation: () async throws -> Void) async {
    _ = await performResult(successMessage, operation: operation)
  }

  private func performResult(
    _ successMessage: String?,
    operation: () async throws -> Void
  ) async -> Bool {
    isBusy = true
    errorMessage = nil
    statusMessage = nil
    defer { isBusy = false }
    do {
      try await operation()
      statusMessage = successMessage
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }
}