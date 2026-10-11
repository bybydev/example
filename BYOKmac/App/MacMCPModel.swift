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
  private let credentialVault: any MCPCredentialVault
  private let projectWorkspace: ProjectWorkspaceStore
  private let approvals: MCPToolApprovalCenter
  private let elicitations: MCPElicitationCenter
  private let restrictions: MacProResourceRestrictions
  private let entitlementAccessOverride: MacProEntitlementAccess?
  private var approvalObservationTask: Task<Void, Never>?
  private var elicitationObservationTask: Task<Void, Never>?

  convenience init(
    services: BYOKCoreServices,
    restrictions: MacProResourceRestrictions = MacPurchaseStore.restrictions,
    entitlementAccessOverride: MacProEntitlementAccess? = nil
  ) {
    self.init(
      runtime: services.mcpRuntime,
      workspace: services.mcpWorkspace,
      credentialVault: services.mcpCredentialVault,
      projectWorkspace: services.projectWorkspace,
      approvals: services.approvalCenter,
      elicitations: services.elicitationCenter,
      restrictions: restrictions,
      entitlementAccessOverride: entitlementAccessOverride
    )
  }

  init(
    runtime: MCPRemoteRuntime,
    workspace: MCPWorkspaceStore,
    credentialVault: any MCPCredentialVault,
    projectWorkspace: ProjectWorkspaceStore,
    approvals: MCPToolApprovalCenter,
    elicitations: MCPElicitationCenter,
    restrictions: MacProResourceRestrictions = MacPurchaseStore.restrictions,
    entitlementAccessOverride: MacProEntitlementAccess? = nil
  ) {
    self.runtime = runtime
    self.workspace = workspace
    self.credentialVault = credentialVault
    self.projectWorkspace = projectWorkspace
    self.approvals = approvals
    self.elicitations = elicitations
    self.restrictions = restrictions
    self.entitlementAccessOverride = entitlementAccessOverride
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

  func isServerRestricted(_ serverID: MCPServerID) -> Bool {
    restrictions.isMCPServerRestricted(
      serverID,
      currentIDs: servers.map(\.id),
      entitlement: effectiveEntitlementAccess
    )
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
    if let existing, !requireServerAccess(existing.id) {
      return false
    }
    if existing == nil,
      !MacProAccess.requireMCPServerCapacity(currentCount: servers.count)
    {
      errorMessage = "Free includes 1 MCP server. Upgrade to BYOK Pro to add more."
      return false
    }

    isBusy = true
    errorMessage = nil
    statusMessage = nil
    defer { isBusy = false }

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
        do {
          _ = try await runtime.refreshServer(server.id, force: true)
          MacAppAnalytics.track(.mcpDiscoverySucceeded)
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
    isBusy = true
    errorMessage = nil
    statusMessage = nil
    defer { isBusy = false }

    do {
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
      MacAppAnalytics.reportError("mcp_operation_failed", component: "mcp")
      errorMessage = error.localizedDescription
      return false
    }
  }

  func setEnabled(_ enabled: Bool, serverID: MCPServerID) async -> Bool {
    if enabled, !requireServerAccess(serverID) { return false }

    isBusy = true
    errorMessage = nil
    statusMessage = nil
    defer { isBusy = false }

    do {
      try await runtime.setEnabled(enabled, serverID: serverID)
      var discoveryWarning: String?
      if enabled {
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
    guard requireServerAccess(serverID) else { return false }
    return await performResult("MCP tools refreshed") {
      _ = try await runtime.refreshServer(serverID, force: true)
      try await reloadSnapshot()
    }
  }

  func setChatServerEnabled(
    _ enabled: Bool,
    serverID: MCPServerID,
    conversationID: ConversationID
  ) async -> Bool {
    if enabled, !requireServerAccess(serverID) { return false }
    return await performResult(nil) {
      if enabled {
        guard servers.first(where: { $0.id == serverID })?.isEnabled == true else {
          throw MCPError.invalidServer("Enable this MCP server in Settings first.")
        }
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
    if policy != .disabled,
      let serverID = serverID(forExposedToolName: exposedToolName),
      !requireServerAccess(serverID)
    {
      return false
    }
    return await performResult(nil) {
      try await persistChatToolPolicy(
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
    guard requireConfigurationAccess(configuration) else { return false }
    return await performResult("Tool configuration applied") {
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
      guard requireServerAccess(request.serverID) else {
        await approvals.resolve(requestID, decision: .deny)
        return
      }
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

  private var effectiveEntitlementAccess: MacProEntitlementAccess {
    entitlementAccessOverride ?? MacProAccess.entitlementAccess
  }

  @discardableResult
  private func requireServerAccess(_ serverID: MCPServerID) -> Bool {
    guard !isServerRestricted(serverID) else {
      errorMessage = MacProAccess.restoredResourceBlockedMessage("MCP server")
      if effectiveEntitlementAccess == .free {
        MacProGateCenter.shared.request(.mcpServers)
      }
      return false
    }
    return true
  }

  private func requireConfigurationAccess(_ configuration: MCPChatToolConfiguration) -> Bool {
    for serverID in configuration.enabledServerIDs where isServerRestricted(serverID) {
      return requireServerAccess(serverID)
    }
    return true
  }

  private func serverID(forExposedToolName exposedToolName: String) -> MCPServerID? {
    for server in servers {
      if tools(for: server.id).contains(where: { $0.exposedName == exposedToolName }) {
        return server.id
      }
    }
    return nil
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
    if await workspace.explicitChatConfiguration(for: conversationID) != nil {
      try await workspace.setChatServerEnabled(
        enabled,
        serverID: serverID,
        conversationID: conversationID
      )
      return
    }

    if var inherited = await projectWorkspace.mcpConfiguration(for: conversationID) {
      inherited.enabledServerIDs.removeAll { $0 == serverID }
      if enabled { inherited.enabledServerIDs.append(serverID) }
      inherited.enabledServerIDs.sort { $0.rawValue < $1.rawValue }
      try await workspace.replaceChatConfiguration(inherited, conversationID: conversationID)
      return
    }

    try await workspace.setChatServerEnabled(
      enabled,
      serverID: serverID,
      conversationID: conversationID
    )
  }

  private func persistChatToolPolicy(
    _ policy: ChatToolPermissionPolicy,
    exposedToolName: String,
    conversationID: ConversationID
  ) async throws {
    if await workspace.explicitChatConfiguration(for: conversationID) != nil {
      try await workspace.setChatToolPolicy(
        policy,
        exposedToolName: exposedToolName,
        conversationID: conversationID
      )
      return
    }

    if var inherited = await projectWorkspace.mcpConfiguration(for: conversationID) {
      let normalized = exposedToolName.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !normalized.isEmpty, normalized.count <= MCPToolNamespace.maximumExposedNameLength else {
        throw MCPError.invalidToolDefinition("Invalid MCP tool permission name.")
      }
      if policy == .ask {
        inherited.toolPolicies.removeValue(forKey: normalized)
      } else {
        inherited.toolPolicies[normalized] = policy
      }
      try await workspace.replaceChatConfiguration(inherited, conversationID: conversationID)
      return
    }

    try await workspace.setChatToolPolicy(
      policy,
      exposedToolName: exposedToolName,
      conversationID: conversationID
    )
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
      if (try? await runtime.hasCredential(serverID: server.id)) == true {
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
      MacAppAnalytics.reportError("mcp_operation_failed", component: "mcp")
      errorMessage = error.localizedDescription
      return false
    }
  }
}
