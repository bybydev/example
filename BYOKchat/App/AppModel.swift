import AppFoundation
import BYOKchatProviderCore
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
  let providers: ProviderManagementModel
  let chats: ChatManagementModel
  let mcp: MCPManagementModel
  let preferences: AppPreferencesModel
  let dataPortability: DataPortabilityModel
  let themeManager: ThemeManager
  let toolRuntime: ToolRuntime

  private(set) var hasLoaded = false

  init() {
    let preferences = AppPreferencesModel()
    self.preferences = preferences
    themeManager = ThemeManager(
      catalog: BYOKchatThemes.catalog,
      stateStore: UserDefaultsThemeStateStore(storageKey: "byokchat.themeState.v1"),
      hasPro: false,
      previewBehavior: .disabled
    )

    let registry = try! ProviderRegistry.builtIn()
    let supportDirectory = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first!
    .appendingPathComponent("BYOKchat", isDirectory: true)

    let providerWorkspace = ProviderWorkspaceStore(
      persistence: JSONFileProviderWorkspacePersistence(
        fileURL: supportDirectory.appendingPathComponent("providers-v1.json")
      )
    )
    let vault = KeychainCredentialVault()
    let accountManager = ProviderAccountManager(
      registry: registry,
      workspace: providerWorkspace,
      vault: vault
    )
    let providerRuntime = ProviderRuntime(
      registry: registry,
      workspace: providerWorkspace,
      accounts: accountManager
    )
    let conversationStore = ConversationStore(
      persistence: JSONFileConversationWorkspacePersistence(
        fileURL: supportDirectory.appendingPathComponent("conversations-v1.json")
      )
    )

    let mcpWorkspace = MCPWorkspaceStore(
      persistence: JSONFileMCPWorkspacePersistence(
        fileURL: supportDirectory.appendingPathComponent("mcp-servers-v1.json")
      )
    )
    let mcpVault = KeychainMCPCredentialVault()
    let mcpRuntime = MCPRemoteRuntime(
      workspace: mcpWorkspace,
      vault: mcpVault,
      transport: MCPHTTPTransport()
    )
    let approvalCenter = MCPToolApprovalCenter()
    let elicitationCenter = MCPElicitationCenter()

    let toolRuntime = ToolRuntime()
    self.toolRuntime = toolRuntime
    let conversationToolRuntime = MCPConversationToolRuntime(
      localRuntime: toolRuntime,
      mcpRuntime: mcpRuntime,
      workspace: mcpWorkspace,
      approvals: approvalCenter,
      elicitations: elicitationCenter
    )
    let chatRuntime = ChatRuntime(
      providerRuntime: providerRuntime,
      providerWorkspace: providerWorkspace,
      conversations: conversationStore,
      toolRuntime: conversationToolRuntime
    )

    let providerModel = ProviderManagementModel(
      registry: registry,
      workspace: providerWorkspace,
      vault: vault,
      accountManager: accountManager,
      runtime: providerRuntime
    )
    let chatModel = ChatManagementModel(
      providerWorkspace: providerWorkspace,
      conversations: conversationStore,
      runtime: chatRuntime,
      preferences: preferences,
      mcpWorkspace: mcpWorkspace
    )
    let mcpModel = MCPManagementModel(
      runtime: mcpRuntime,
      workspace: mcpWorkspace,
      approvals: approvalCenter,
      elicitations: elicitationCenter
    )

    providers = providerModel
    chats = chatModel
    mcp = mcpModel
    dataPortability = DataPortabilityModel(
      service: DataPortabilityService(
        providers: providerWorkspace,
        conversations: conversationStore,
        accounts: accountManager,
        mcp: mcpWorkspace,
        mcpCredentials: mcpVault
      ),
      providerWorkspace: providerWorkspace,
      conversations: conversationStore,
      accountManager: accountManager,
      preferences: preferences,
      providersModel: providerModel,
      chatsModel: chatModel,
      mcpModel: mcpModel
    )
  }

  func load() async {
    guard !hasLoaded else { return }
    await providers.load()
    await mcp.load()
    await chats.load()
    hasLoaded = true
  }
}

@MainActor
@Observable
final class MCPManagementModel {
  private(set) var servers: [MCPRemoteServer] = []
  private(set) var snapshotsByServer: [MCPServerID: MCPServerSnapshot] = [:]
  private(set) var credentialServerIDs: Set<MCPServerID> = []
  private(set) var chatConfigurations: [ConversationID: MCPChatToolConfiguration] = [:]
  private(set) var pendingApprovals: [MCPToolApprovalRequest] = []
  private(set) var pendingElicitations: [MCPElicitationRequest] = []
  var isBusy = false
  var errorMessage: String?
  var statusMessage: String?

  private let runtime: MCPRemoteRuntime
  private let workspace: MCPWorkspaceStore
  private let approvals: MCPToolApprovalCenter
  private let elicitations: MCPElicitationCenter
  private var approvalObservationTask: Task<Void, Never>?
  private var elicitationObservationTask: Task<Void, Never>?

  init(
    runtime: MCPRemoteRuntime,
    workspace: MCPWorkspaceStore,
    approvals: MCPToolApprovalCenter,
    elicitations: MCPElicitationCenter
  ) {
    self.runtime = runtime
    self.workspace = workspace
    self.approvals = approvals
    self.elicitations = elicitations
  }

  func load() async {
    startInteractionObserversIfNeeded()
    await perform(nil) {
      try await runtime.load()
      try await reloadSnapshot()
    }
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
    chatConfigurations[conversationID] ?? MCPChatToolConfiguration()
  }

  func isServerEnabled(_ serverID: MCPServerID, for conversationID: ConversationID) -> Bool {
    chatConfiguration(for: conversationID).isServerEnabled(serverID)
  }

  func toolPolicy(_ exposedToolName: String, for conversationID: ConversationID)
    -> ChatToolPermissionPolicy
  {
    chatConfiguration(for: conversationID).policy(for: exposedToolName)
  }

  func tools(for serverID: MCPServerID) -> [MCPToolBinding] {
    guard let snapshot = snapshotsByServer[serverID] else { return [] }
    return snapshot.tools.map { tool in
      MCPToolBinding(
        serverID: serverID,
        remoteTool: tool,
        exposedName: MCPToolNamespace.exposedName(
          serverID: serverID,
          remoteName: tool.remoteName
        )
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
    await performResult("MCP server saved and tools discovered") {
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

      if existing == nil,
        authenticationKind != .none,
        credential?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
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

  func deleteServer(_ serverID: MCPServerID) async {
    await perform("MCP server deleted") {
      try await runtime.deleteServer(serverID)
      try await reloadSnapshot()
    }
  }

  func setEnabled(_ enabled: Bool, serverID: MCPServerID) async {
    await perform(nil) {
      try await runtime.setEnabled(enabled, serverID: serverID)
      if enabled {
        _ = try await runtime.refreshServer(serverID, force: true)
      }
      try await reloadSnapshot()
    }
  }

  func setChatServerEnabled(
    _ enabled: Bool,
    serverID: MCPServerID,
    conversationID: ConversationID
  ) async {
    await perform(nil) {
      if enabled {
        guard servers.first(where: { $0.id == serverID })?.isEnabled == true else {
          throw MCPError.invalidServer("Enable this MCP server in Settings first.")
        }
        _ = try await runtime.refreshServer(serverID)
      }
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
  ) async {
    await perform(nil) {
      try await workspace.setChatToolPolicy(
        policy,
        exposedToolName: exposedToolName,
        conversationID: conversationID
      )
      try await reloadSnapshot()
    }
  }

  func removeChatConfiguration(_ conversationID: ConversationID) async {
    await perform(nil) {
      try await workspace.removeChatConfiguration(conversationID: conversationID)
      try await reloadSnapshot()
    }
  }

  func refresh(_ serverID: MCPServerID) async {
    await perform("MCP tools refreshed") {
      _ = try await runtime.refreshServer(serverID, force: true)
      try await reloadSnapshot()
    }
  }

  func resolveApproval(_ requestID: String, decision: MCPToolApprovalDecision) async {
    if decision == .alwaysAllow,
      let request = pendingApprovals.first(where: { $0.id == requestID })
    {
      do {
        try await workspace.setChatToolPolicy(
          .alwaysAllow,
          exposedToolName: request.exposedToolName,
          conversationID: request.conversationID
        )
        try await reloadSnapshot()
        // Persistence already happened here, so the executor only needs a one-shot allow.
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

  func deleteAllCredentials() async throws {
    let values = await runtime.servers()
    for server in values {
      try await runtime.saveServer(server, credential: "")
    }
    try await reloadSnapshot()
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
      let approvalCenter = approvals
      approvalObservationTask = Task { @MainActor [weak self] in
        let stream = await approvalCenter.updates()
        for await requests in stream {
          guard let self, !Task.isCancelled else { return }
          pendingApprovals = requests
        }
      }
    }

    if elicitationObservationTask == nil {
      let elicitationCenter = elicitations
      elicitationObservationTask = Task { @MainActor [weak self] in
        let stream = await elicitationCenter.updates()
        for await requests in stream {
          guard let self, !Task.isCancelled else { return }
          pendingElicitations = requests
        }
      }
    }
  }

  private func perform(_ success: String?, operation: () async throws -> Void) async {
    isBusy = true
    defer { isBusy = false }
    do {
      try await operation()
      statusMessage = success
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func performResult(_ success: String?, operation: () async throws -> Void) async -> Bool {
    isBusy = true
    defer { isBusy = false }
    do {
      try await operation()
      statusMessage = success
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }
}
