import AppFoundation
import BYOKchatProviderCore
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
  let providers: ProviderManagementModel
  let chats: ChatManagementModel
  let library: LibraryManagementModel
  let projects: ProjectManagementModel
  let mcp: MCPManagementModel
  let preferences: AppPreferencesModel
  let dataPortability: DataPortabilityModel
  let themeManager: ThemeManager
  let toolRuntime: ToolRuntime
  /// Shared byte store behind chat attachments, library entries, and project
  /// reference files; `sweepOrphanFiles` garbage-collects it.
  let fileBlobStore: FileAttachmentBlobStore

  private(set) var hasLoaded = false

  init() {
    let preferences = AppPreferencesModel()
    self.preferences = preferences
    themeManager = ThemeManager(
      catalog: BYOKchatThemes.catalog,
      stateStore: UserDefaultsThemeStateStore(storageKey: "byokchat.themeState.v1"),
      hasPro: false
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
    // One shared file-byte store backs chat attachments, library entries, and
    // project reference files; everything else stores metadata only.
    fileBlobStore = FileAttachmentBlobStore(
      directory: supportDirectory.appendingPathComponent("files-v1", isDirectory: true)
    )
    let conversationStore = ConversationStore(
      persistence: JSONFileConversationWorkspacePersistence(
        directory: supportDirectory.appendingPathComponent("conversations-v1", isDirectory: true)
      ),
      blobs: fileBlobStore
    )
    let libraryStore = LibraryStore(
      persistence: JSONFileLibraryWorkspacePersistence(
        fileURL: supportDirectory.appendingPathComponent("library-v1.json")
      ),
      blobs: fileBlobStore
    )
    let projectWorkspace = ProjectWorkspaceStore(
      persistence: JSONFileProjectWorkspacePersistence(
        fileURL: supportDirectory.appendingPathComponent("projects-v1.json")
      ),
      blobs: fileBlobStore
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
      projectWorkspace: projectWorkspace,
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
    let projectModel = ProjectManagementModel(workspace: projectWorkspace)
    let chatModel = ChatManagementModel(
      providerWorkspace: providerWorkspace,
      conversations: conversationStore,
      runtime: chatRuntime,
      preferences: preferences,
      mcpWorkspace: mcpWorkspace,
      projectWorkspace: projectWorkspace
    )
    let libraryModel = LibraryManagementModel(store: libraryStore)
    let mcpModel = MCPManagementModel(
      runtime: mcpRuntime,
      workspace: mcpWorkspace,
      projectWorkspace: projectWorkspace,
      approvals: approvalCenter,
      elicitations: elicitationCenter
    )
    let baseDataPortability = DataPortabilityService(
      providers: providerWorkspace,
      conversations: conversationStore,
      accounts: accountManager,
      mcp: mcpWorkspace,
      mcpCredentials: mcpVault
    )
    let projectAwareDataPortability = ProjectAwareDataPortabilityService(
      base: baseDataPortability,
      projects: projectWorkspace,
      conversations: conversationStore,
      library: libraryStore
    )

    providers = providerModel
    projects = projectModel
    chats = chatModel
    library = libraryModel
    mcp = mcpModel
    dataPortability = DataPortabilityModel(
      service: projectAwareDataPortability,
      providerWorkspace: providerWorkspace,
      conversations: conversationStore,
      accountManager: accountManager,
      preferences: preferences,
      providersModel: providerModel,
      chatsModel: chatModel,
      projectsModel: projectModel,
      mcpModel: mcpModel
    )

    // Reference counting: every mutation that can drop file edges funnels
    // through a model's snapshot refresh; respond by sweeping orphan bytes.
    let sweep: () -> Void = { [weak self] in
      _ = Task { await self?.sweepOrphanFiles() }
    }
    chats.onFileReferencesChanged = sweep
    projects.onFileReferencesChanged = sweep
    library.onFileReferencesChanged = sweep
  }

  /// Derived reference counting, exact because every edge lives in queryable
  /// state: a blob survives while any chat message attachment, project file
  /// pointer, or library entry references its ID.
  func sweepOrphanFiles() async {
    var referenced = Set<String>()
    for conversation in chats.conversations {
      for message in conversation.messages {
        for attachment in message.attachments ?? [] {
          referenced.insert(attachment.id)
        }
      }
    }
    for project in projects.projects {
      for file in project.projectFiles {
        referenced.insert(file.id)
      }
    }
    for entry in library.entries {
      referenced.insert(entry.id.rawValue)
    }

    let stored = (try? await fileBlobStore.storedIDs()) ?? []
    let orphans = stored.subtracting(referenced)
    guard !orphans.isEmpty else { return }
    try? await fileBlobStore.deleteIDs(orphans)
  }

  func load() async {
    guard !hasLoaded else { return }
    await providers.load()
    await projects.load()
    await mcp.load()
    await chats.load()
    await library.load()
    await projects.reconcile(conversations: chats.conversations)
    await mcp.reloadFromStorage()
    await sweepOrphanFiles()
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

  init(
    runtime: MCPRemoteRuntime,
    workspace: MCPWorkspaceStore,
    projectWorkspace: ProjectWorkspaceStore,
    approvals: MCPToolApprovalCenter,
    elicitations: MCPElicitationCenter
  ) {
    self.runtime = runtime
    self.workspace = workspace
    self.projectWorkspace = projectWorkspace
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
  ) async {
    await perform(nil) {
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
  ) async {
    await perform("Tool preset applied") {
      try await workspace.replaceChatConfiguration(configuration, conversationID: conversationID)
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

  func deleteAllCredentials() async throws {
    let values = await runtime.servers()
    for server in values {
      try await runtime.saveServer(server, credential: "")
    }
    try await reloadSnapshot()
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
