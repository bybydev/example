import BYOKchatProviderCore
import Foundation
import Observation

@MainActor
@Observable
final class MacMCPModel {
  private(set) var servers: [MCPRemoteServer] = []
  private(set) var snapshotsByServer: [MCPServerID: MCPServerSnapshot] = [:]
  private var toolsByServer: [MCPServerID: [MCPToolBinding]] = [:]
  private var toolDisplayNamesByExposedName: [String: String] = [:]
  private(set) var credentialServerIDs: Set<MCPServerID> = []
  private(set) var chatConfigurations: [ConversationID: MCPChatToolConfiguration] = [:]
  private(set) var inheritedChatConfigurations: [ConversationID: MCPChatToolConfiguration] = [:]
  private(set) var projectMCPConfigurations: [ProjectID: MCPChatToolConfiguration] = [:]
  private(set) var pendingApprovals: [MCPToolApprovalRequest] = []
  private(set) var pendingElicitations: [MCPElicitationRequest] = []
  private(set) var refreshingServerIDs: Set<MCPServerID> = []

  var isBusy = false
  var errorMessage: String?
  var statusMessage: String?
  var onProjectStateChanged: (@MainActor () async -> Void)?

  @ObservationIgnored private var activeOperationCount = 0

  private let runtime: MCPRemoteRuntime
  private let workspace: MCPWorkspaceStore
  private let credentialVault: any MCPCredentialVault
  private let projectWorkspace: ProjectWorkspaceStore
  private let approvals: MCPToolApprovalCenter
  private let elicitations: MCPElicitationCenter
  private var approvalObservationTask: Task<Void, Never>?
  private var elicitationObservationTask: Task<Void, Never>?

  convenience init(services: BYOKCoreServices) {
    self.init(
      runtime: services.mcpRuntime,
      workspace: services.mcpWorkspace,
      credentialVault: services.mcpCredentialVault,
      projectWorkspace: services.projectWorkspace,
      approvals: services.approvalCenter,
      elicitations: services.elicitationCenter
    )
  }

  init(
    runtime: MCPRemoteRuntime,
    workspace: MCPWorkspaceStore,
    credentialVault: any MCPCredentialVault,
    projectWorkspace: ProjectWorkspaceStore,
    approvals: MCPToolApprovalCenter,
    elicitations: MCPElicitationCenter
  ) {
    self.runtime = runtime
    self.workspace = workspace
    self.credentialVault = credentialVault
    self.projectWorkspace = projectWorkspace
    self.approvals = approvals
    self.elicitations = elicitations
  }

  func load(skipRuntimeLoad: Bool = false) async throws {
    startInteractionObserversIfNeeded()
    if !skipRuntimeLoad {
      try await runtime.load()
    }
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

  func isServerUsable(_ server: MCPRemoteServer) -> Bool {
    guard server.isEnabled else { return false }
    return server.authentication.kind == .none || hasCredential(server.id)
  }

  func activeToolCount(for configuration: MCPChatToolConfiguration) -> Int {
    let enabledIDs = Set(configuration.enabledServerIDs)
    var total = 0
    for server in servers where enabledIDs.contains(server.id) && isServerUsable(server) {
      total += tools(for: server.id).filter {
        configuration.policy(for: $0.exposedName) != .disabled
      }.count
    }
    return total
  }

  func activeServerCount(for configuration: MCPChatToolConfiguration) -> Int {
    let enabledIDs = Set(configuration.enabledServerIDs)
    return servers.filter { enabledIDs.contains($0.id) && isServerUsable($0) }.count
  }

  func consumeErrorMessage() -> String? {
    let message = errorMessage
    errorMessage = nil
    return message
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

  func projectConfiguration(for projectID: ProjectID?) -> MCPChatToolConfiguration? {
    guard let projectID else { return nil }
    return projectMCPConfigurations[projectID]
  }

  func effectiveDraftConfiguration(
    draft: MCPChatToolConfiguration?,
    projectID: ProjectID?
  ) -> MCPChatToolConfiguration {
    draft ?? projectConfiguration(for: projectID) ?? MCPChatToolConfiguration()
  }

  func inheritsProjectToolsForDraft(
    draft: MCPChatToolConfiguration?,
    projectID: ProjectID?
  ) -> Bool {
    draft == nil && projectConfiguration(for: projectID) != nil
  }

  func updatedDraftServerEnabled(
    _ enabled: Bool,
    serverID: MCPServerID,
    currentDraft: MCPChatToolConfiguration?,
    projectID: ProjectID?
  ) async -> (succeeded: Bool, configuration: MCPChatToolConfiguration?) {
    var updated = currentDraft
    let succeeded = await performResult(nil) {
      if enabled {
        guard servers.first(where: { $0.id == serverID })?.isEnabled == true else {
          throw MCPError.invalidServer("Enable this server in MCP Servers first.")
        }
        refreshingServerIDs.insert(serverID)
        defer { refreshingServerIDs.remove(serverID) }
        _ = try await runtime.refreshServer(serverID)
        try await reloadSnapshot()
      }
      var next = effectiveDraftConfiguration(draft: currentDraft, projectID: projectID)
      next.enabledServerIDs.removeAll { $0 == serverID }
      if enabled { next.enabledServerIDs.append(serverID) }
      updated = normalizedDraftConfiguration(next, projectID: projectID)
    }
    return (succeeded, updated)
  }

  func updatedDraftToolPolicy(
    _ policy: ChatToolPermissionPolicy,
    exposedToolName: String,
    currentDraft: MCPChatToolConfiguration?,
    projectID: ProjectID?
  ) -> (succeeded: Bool, configuration: MCPChatToolConfiguration?) {
    let normalizedName = exposedToolName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedName.isEmpty, normalizedName.count <= MCPToolNamespace.maximumExposedNameLength else {
      errorMessage = MCPError.invalidToolDefinition("Invalid MCP tool permission name.").localizedDescription
      return (false, currentDraft)
    }
    errorMessage = nil
    var next = effectiveDraftConfiguration(draft: currentDraft, projectID: projectID)
    if policy == .ask {
      next.toolPolicies.removeValue(forKey: normalizedName)
    } else {
      next.toolPolicies[normalizedName] = policy
    }
    return (true, normalizedDraftConfiguration(next, projectID: projectID))
  }

  func updatedDraftAllToolPolicies(
    _ policy: ChatToolPermissionPolicy,
    serverID: MCPServerID,
    currentDraft: MCPChatToolConfiguration?,
    projectID: ProjectID?
  ) -> (succeeded: Bool, configuration: MCPChatToolConfiguration?) {
    let bindings = tools(for: serverID)
    guard !bindings.isEmpty else { return (true, currentDraft) }
    errorMessage = nil
    var next = effectiveDraftConfiguration(draft: currentDraft, projectID: projectID)
    for binding in bindings {
      if policy == .ask {
        next.toolPolicies.removeValue(forKey: binding.exposedName)
      } else {
        next.toolPolicies[binding.exposedName] = policy
      }
    }
    return (true, normalizedDraftConfiguration(next, projectID: projectID))
  }

  func validatedDraftPresetConfiguration(
    _ configuration: MCPChatToolConfiguration,
    projectID: ProjectID?
  ) -> (succeeded: Bool, configuration: MCPChatToolConfiguration?) {
    errorMessage = nil
    statusMessage = "Tool configuration applied"
    return (true, normalizedDraftConfiguration(configuration, projectID: projectID))
  }

  private func normalizedDraftConfiguration(
    _ configuration: MCPChatToolConfiguration,
    projectID: ProjectID?
  ) -> MCPChatToolConfiguration? {
    let knownServerIDs = Set(servers.map(\.id))
    let enabledIDs = Array(Set(configuration.enabledServerIDs.filter(knownServerIDs.contains)))
      .sorted { $0.rawValue < $1.rawValue }
    let policies = configuration.toolPolicies.filter { $0.value != .ask }
    let normalized = MCPChatToolConfiguration(
      enabledServerIDs: enabledIDs,
      toolPolicies: policies
    )
    let hasProjectInheritance = projectConfiguration(for: projectID) != nil
    if !hasProjectInheritance && normalized.enabledServerIDs.isEmpty && normalized.toolPolicies.isEmpty {
      return nil
    }
    return normalized
  }

  func isServerEnabled(_ serverID: MCPServerID, for conversationID: ConversationID) -> Bool {
    chatConfiguration(for: conversationID).isServerEnabled(serverID)
  }

  func toolPolicy(_ exposedToolName: String, for conversationID: ConversationID) -> ChatToolPermissionPolicy {
    chatConfiguration(for: conversationID).policy(for: exposedToolName)
  }

  func tools(for serverID: MCPServerID) -> [MCPToolBinding] {
    toolsByServer[serverID] ?? []
  }

  func toolDisplayName(_ exposedToolName: String) -> String {
    toolDisplayNamesByExposedName[exposedToolName] ?? exposedToolName
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

    beginBusy()
    errorMessage = nil
    statusMessage = nil
    defer { endBusy() }

    do {
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
      try MCPWorkspaceStore.validateServer(server)

      let existingCredential = existing.map { credentialServerIDs.contains($0.id) } ?? false
      if authenticationKind != .none,
        credential?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
        !existingCredential
      {
        throw MCPError.missingCredential
      }

      try await commitServerConfiguration(server, credential: credential)
      if existing == nil {
        MacAppAnalytics.track(.mcpServerCreated)
      }

      var warnings: [String] = []
      if server.isEnabled {
        refreshingServerIDs.insert(server.id)
        defer { refreshingServerIDs.remove(server.id) }
        do {
          _ = try await runtime.refreshServer(server.id, force: true)
        } catch {
          MacAppAnalytics.track(.mcpDiscoveryFailed)
          warnings.append("Tool discovery failed: \(error.localizedDescription)")
        }
      }
      try await reloadSnapshot()

      if warnings.isEmpty {
        statusMessage = server.isEnabled
          ? "MCP server saved and tools discovered"
          : "MCP server saved"
      } else {
        statusMessage = "MCP server saved. \(warnings.joined(separator: " "))"
      }
      return true
    } catch {
      MacAppAnalytics.reportError("mcp_operation_failed", component: "mcp")
      errorMessage = error.localizedDescription
      return false
    }
  }

  func deleteServer(_ serverID: MCPServerID) async -> Bool {
    beginBusy()
    errorMessage = nil
    statusMessage = nil
    defer { endBusy() }

    do {
      let snapshot = await workspace.snapshot()
      let serverIDs = snapshot.servers.map(\.id)
        + snapshot.tombstones.keys.map { MCPServerID(rawValue: $0) }
      try await projectWorkspace.removeMCPServerReferences(serverID, knownServerIDs: serverIDs)
      await onProjectStateChanged?()
      try await workspace.deleteServer(serverID)

      var cleanupWarning: String?
      do {
        try await credentialVault.removeCredential(serverID: serverID)
      } catch {
        cleanupWarning = "Keychain cleanup failed: \(error.localizedDescription)"
      }

      try await reloadSnapshot()
      statusMessage = cleanupWarning.map { "MCP server deleted. \($0)" } ?? "MCP server deleted"
      return true
    } catch {
      await onProjectStateChanged?()
      try? await reloadSnapshot()
      MacAppAnalytics.reportError("mcp_operation_failed", component: "mcp")
      errorMessage = error.localizedDescription
      return false
    }
  }

  func setEnabled(_ enabled: Bool, serverID: MCPServerID) async -> Bool {
    beginBusy()
    errorMessage = nil
    statusMessage = nil
    defer { endBusy() }

    do {
      try await runtime.setEnabled(enabled, serverID: serverID)
      var discoveryWarning: String?
      if enabled {
        refreshingServerIDs.insert(serverID)
        defer { refreshingServerIDs.remove(serverID) }
        do {
          _ = try await runtime.refreshServer(serverID, force: true)
        } catch {
          discoveryWarning = "Tool discovery failed: \(error.localizedDescription)"
        }
      }
      try await reloadSnapshot()
      statusMessage = discoveryWarning
      return true
    } catch {
      MacAppAnalytics.reportError("mcp_operation_failed", component: "mcp")
      errorMessage = error.localizedDescription
      return false
    }
  }

  func refresh(_ serverID: MCPServerID) async -> Bool {
    return await performResult("MCP tools refreshed") {
      refreshingServerIDs.insert(serverID)
      defer { refreshingServerIDs.remove(serverID) }
      _ = try await runtime.refreshServer(serverID, force: true)
      try await reloadSnapshot()
    }
  }

  func setChatServerEnabled(
    _ enabled: Bool,
    serverID: MCPServerID,
    conversationID: ConversationID
  ) async -> Bool {
    return await performResult(nil) {
      if enabled {
        guard servers.first(where: { $0.id == serverID })?.isEnabled == true else {
          throw MCPError.invalidServer("Enable this server in MCP Servers first.")
        }
        refreshingServerIDs.insert(serverID)
        defer { refreshingServerIDs.remove(serverID) }
        _ = try await runtime.refreshServer(serverID)
      }
      try await persistChatServerEnabled(
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
    return await performResult(nil) {
      try await persistChatToolPolicy(
        policy,
        exposedToolName: exposedToolName,
        conversationID: conversationID
      )
      try await reloadSnapshot()
    }
  }

  func setAllChatToolPolicies(
    _ policy: ChatToolPermissionPolicy,
    serverID: MCPServerID,
    conversationID: ConversationID
  ) async -> Bool {
    let bindings = tools(for: serverID)
    guard !bindings.isEmpty else { return true }
    return await performResult("Updated permissions for \(bindings.count) \(bindings.count == 1 ? "tool" : "tools")") {
      let inherited = await projectWorkspace.mcpConfiguration(for: conversationID)
      var next = chatConfiguration(for: conversationID)
      for binding in bindings {
        if policy == .ask {
          next.toolPolicies.removeValue(forKey: binding.exposedName)
        } else {
          next.toolPolicies[binding.exposedName] = policy
        }
      }
      try await workspace.replaceChatConfiguration(
        next,
        conversationID: conversationID,
        preserveEmpty: inherited != nil
      )
      try await reloadSnapshot()
    }
  }

  func applyChatConfiguration(
    _ configuration: MCPChatToolConfiguration,
    conversationID: ConversationID
  ) async -> Bool {
    return await performResult("Tool configuration applied") {
      let inherited = await projectWorkspace.mcpConfiguration(for: conversationID)
      try await workspace.replaceChatConfiguration(
        configuration,
        conversationID: conversationID,
        preserveEmpty: inherited != nil
      )
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
        try await persistChatToolPolicy(
          .alwaysAllow,
          exposedToolName: request.exposedToolName,
          conversationID: request.conversationID
        )
        try await reloadSnapshot()
        await approvals.resolve(requestID, decision: .allowOnce)
      } catch {
        MacAppAnalytics.reportError("mcp_operation_failed", component: "mcp")
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

  private func commitServerConfiguration(
    _ server: MCPRemoteServer,
    credential: String?
  ) async throws {
    let previousCredential: String?
    if credential != nil {
      previousCredential = try await credentialVault.credential(serverID: server.id)
    } else {
      previousCredential = nil
    }

    if let credential {
      let normalized = credential.trimmingCharacters(in: .whitespacesAndNewlines)
      try await credentialVault.setCredential(
        normalized.isEmpty ? nil : credential,
        serverID: server.id
      )
    }

    do {
      try await workspace.upsertServer(
        server,
        invalidateSnapshot: credential != nil
      )
    } catch {
      let configurationError = error
      if credential != nil {
        do {
          try await credentialVault.setCredential(previousCredential, serverID: server.id)
        } catch {
          throw MCPError.transport(
            "MCP configuration was not saved and the previous Keychain credential could not be restored: \(error.localizedDescription)"
          )
        }
      }
      throw configurationError
    }
  }

  private func persistChatServerEnabled(
    _ enabled: Bool,
    serverID: MCPServerID,
    conversationID: ConversationID
  ) async throws {
    let inherited = await projectWorkspace.mcpConfiguration(for: conversationID)
    try await workspace.setChatServerEnabled(
      enabled,
      serverID: serverID,
      conversationID: conversationID,
      inheritedBase: inherited,
      preserveEmpty: inherited != nil
    )
  }

  private func persistChatToolPolicy(
    _ policy: ChatToolPermissionPolicy,
    exposedToolName: String,
    conversationID: ConversationID
  ) async throws {
    let inherited = await projectWorkspace.mcpConfiguration(for: conversationID)
    try await workspace.setChatToolPolicy(
      policy,
      exposedToolName: exposedToolName,
      conversationID: conversationID,
      inheritedBase: inherited,
      preserveEmpty: inherited != nil
    )
  }

  private func reloadSnapshot() async throws {
    let runtime = self.runtime
    let workspace = self.workspace
    let projectWorkspace = self.projectWorkspace

    async let serversTask = runtime.servers()
    async let snapshotsTask = runtime.snapshots()
    async let workspaceSnapshotTask = workspace.snapshot()
    async let projectSnapshotTask = projectWorkspace.snapshot()

    let loadedServers = await serversTask
    let snapshots = await snapshotsTask
    let workspaceSnapshot = await workspaceSnapshotTask
    let projectSnapshot = await projectSnapshotTask

    servers = loadedServers
    let snapshotMap = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.serverID, $0) })
    snapshotsByServer = snapshotMap

    var builtToolsByServer: [MCPServerID: [MCPToolBinding]] = [:]
    var builtDisplayNames: [String: String] = [:]
    builtToolsByServer.reserveCapacity(snapshotMap.count)

    for (serverID, snapshot) in snapshotMap {
      let bindings = snapshot.tools.map { tool in
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
      builtToolsByServer[serverID] = bindings
    }

    for server in loadedServers {
      for binding in builtToolsByServer[server.id] ?? [] {
        if builtDisplayNames[binding.exposedName] == nil {
          let toolName = binding.remoteTool.title ?? binding.remoteTool.remoteName
          builtDisplayNames[binding.exposedName] = "\(server.name) · \(toolName)"
        }
      }
    }

    toolsByServer = builtToolsByServer
    toolDisplayNamesByExposedName = builtDisplayNames

    chatConfigurations = Dictionary(
      uniqueKeysWithValues: (workspaceSnapshot.chatConfigurations ?? [:]).map {
        (ConversationID(rawValue: $0.key), $0.value)
      }
    )

    let projectsByID = Dictionary(uniqueKeysWithValues: projectSnapshot.projects.map { ($0.id.rawValue, $0) })
    projectMCPConfigurations = Dictionary(
      uniqueKeysWithValues: projectSnapshot.projects.compactMap { project in
        guard let configuration = project.mcpConfiguration else { return nil }
        return (project.id, configuration)
      }
    )
    inheritedChatConfigurations = Dictionary(
      uniqueKeysWithValues: projectSnapshot.conversationProjectIDs.compactMap { conversationID, projectID in
        guard let configuration = projectsByID[projectID]?.mcpConfiguration else { return nil }
        return (ConversationID(rawValue: conversationID), configuration)
      }
    )

    let credentials: Set<MCPServerID> = await withTaskGroup(of: MCPServerID?.self) { group in
      for server in loadedServers {
        let serverID = server.id
        group.addTask {
          (try? await runtime.hasCredential(serverID: serverID)) == true ? serverID : nil
        }
      }
      var result: Set<MCPServerID> = []
      for await serverID in group {
        if let serverID { result.insert(serverID) }
      }
      return result
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

  private func beginBusy() {
    activeOperationCount += 1
    isBusy = true
  }

  private func endBusy() {
    activeOperationCount = max(0, activeOperationCount - 1)
    isBusy = activeOperationCount > 0
  }

  private func perform(_ successMessage: String?, operation: () async throws -> Void) async {
    _ = await performResult(successMessage, operation: operation)
  }

  private func performResult(
    _ successMessage: String?,
    operation: () async throws -> Void
  ) async -> Bool {
    beginBusy()
    errorMessage = nil
    statusMessage = nil
    defer { endBusy() }
    do {
      try await operation()
      statusMessage = successMessage
      return true
    } catch {
      MacAppAnalytics.reportError("mcp_operation_failed", component: "mcp")
      errorMessage = error.localizedDescription
      return false
    }
  }
}
