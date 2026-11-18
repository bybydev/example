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
  let storageEnvironment: BYOKStorageEnvironment
  let telemetryRecorder: TelemetryRecorder
  let startupCompositionFailure: AppBootstrapFailure?
  /// Shared byte store behind chat attachments, library entries, and project
  /// reference files; startup cleanup garbage-collects unused bytes.
  let fileBlobStore: FileAttachmentBlobStore
  private let coreServices: BYOKCoreServices

  private(set) var hasLoaded = false

  init() {
    let storageEnvironment = AppStorageEnvironment.current
    let coreServices: BYOKCoreServices
    let startupCompositionFailure: AppBootstrapFailure?
    do {
      coreServices = try BYOKCoreServices.secure(environment: storageEnvironment)
      startupCompositionFailure = nil
    } catch {
      BYOKAppAnalytics.reportError("credential_store_failed", component: "storage")
      // AppModel exists before AppBootstrapController, so composition must not
      // trap here. Build a recovery-only empty-provider graph and let startup
      // present the normal failure/recovery UI without touching user stores.
      coreServices = BYOKCoreServices.secureRecoveryFallback(environment: storageEnvironment)
      startupCompositionFailure = AppBootstrapFailure(
        stage: .preparingStorage,
        error: error
      )
    }

    self.coreServices = coreServices
    self.storageEnvironment = coreServices.environment
    self.startupCompositionFailure = startupCompositionFailure
    telemetryRecorder = coreServices.telemetryRecorder
    toolRuntime = coreServices.toolRuntime
    fileBlobStore = coreServices.fileBlobStore

    let preferences = AppPreferencesModel(defaults: storageEnvironment.makeUserDefaults())
    self.preferences = preferences
    // Preserve the committed Free theme while StoreKit resolves entitlement.
    // The purchase-aware binding in BYOKchatApp authorizes Pro selections.
    themeManager = ThemeManager(
      catalog: BYOKchatThemes.catalog,
      stateStore: UserDefaultsThemeStateStore(storageKey: "byokchat.themeState.v1")
    )

    let providerModel = ProviderManagementModel(
      registry: coreServices.providerRegistry,
      workspace: coreServices.providerWorkspace,
      accountManager: coreServices.accountManager,
      runtime: coreServices.providerRuntime
    )
    let projectModel = ProjectManagementModel(workspace: coreServices.projectWorkspace)
    let chatModel = ChatManagementModel(
      providerWorkspace: coreServices.providerWorkspace,
      conversations: coreServices.conversationStore,
      runtime: coreServices.chatRuntime,
      preferences: preferences,
      mcpWorkspace: coreServices.mcpWorkspace,
      projectWorkspace: coreServices.projectWorkspace,
      resolveDefaultAccountID: { [weak providerModel] in providerModel?.defaultAccountID }
    )
    let libraryModel = LibraryManagementModel(store: coreServices.libraryStore)
    let mcpModel = MCPManagementModel(
      runtime: coreServices.mcpRuntime,
      workspace: coreServices.mcpWorkspace,
      projectWorkspace: coreServices.projectWorkspace,
      approvals: coreServices.approvalCenter,
      elicitations: coreServices.elicitationCenter
    )

    providers = providerModel
    projects = projectModel
    chats = chatModel
    let backgroundKeeper = BackgroundActivityKeeper { [weak chatModel] in
      Task { await chatModel?.handleBackgroundExpiration() }
    }
    chatModel.backgroundKeeper = backgroundKeeper
    library = libraryModel
    mcp = mcpModel
    mcpModel.beginChatConfiguration = { [weak chatModel] id, key in
      chatModel?.beginConfiguration(id, key: key) ?? false
    }
    mcpModel.endChatConfiguration = { [weak chatModel] id, key, succeeded in
      chatModel?.endConfiguration(id, key: key, succeeded: succeeded)
    }
    projectModel.beginChatConfiguration = mcpModel.beginChatConfiguration
    projectModel.endChatConfiguration = mcpModel.endChatConfiguration
    projectModel.coordinateMutation = { [weak mcpModel] operation in
      guard let mcpModel else {
        throw ProviderError.invalidRequest("Project coordination is unavailable. Please try again.")
      }
      try await mcpModel.coordinateProjectMutation(operation)
    }
    mcpModel.onProjectStateChanged = { [weak projectModel] in
      await projectModel?.reloadFromStorage()
    }
    chatModel.onNewChatDiscarded = { [weak projectModel, weak mcpModel] in
      await projectModel?.reloadFromStorage()
      await mcpModel?.reloadFromStorage()
    }
    dataPortability = DataPortabilityModel(
      service: coreServices.dataPortability,
      providerWorkspace: coreServices.providerWorkspace,
      conversations: coreServices.conversationStore,
      accountManager: coreServices.accountManager,
      preferences: preferences,
      providersModel: providerModel,
      chatsModel: chatModel,
      projectsModel: projectModel,
      mcpModel: mcpModel
    )
  }

  /// Startup-only cleanup, after every reference-owning store has loaded and
  /// before interactive use. Live saves write blobs before committing their
  /// references, so sweeping during a mutation can delete an in-flight file.
  /// Removed files are reclaimed on the next launch.
  func sweepOrphanFilesAtStartup() async {
    var referenced = await chats.referencedAttachmentIDs()
    referenced.formUnion(await projects.referencedFileIDs())
    referenced.formUnion(await library.referencedEntryIDs())

    let stored = (try? await fileBlobStore.storedIDs()) ?? []
    let orphans = stored.subtracting(referenced)
    guard !orphans.isEmpty else { return }
    try? await fileBlobStore.deleteIDs(orphans)
  }

  func load() async {
    guard !hasLoaded, startupCompositionFailure == nil else { return }
    await providers.load()
    guard providers.errorMessage == nil else { return }
    await projects.load()
    guard projects.errorMessage == nil else { return }
    await mcp.load()
    guard mcp.errorMessage == nil else { return }
    await chats.load()
    guard chats.errorMessage == nil else { return }
    await library.load()
    guard library.errorMessage == nil else { return }
    await chats.recoverUnsentNewChats()
    guard chats.errorMessage == nil else { return }
    await projects.reconcile(conversations: chats.conversations)
    guard projects.errorMessage == nil else { return }
    await mcp.reloadFromStorage()
    guard mcp.errorMessage == nil else { return }
    await sweepOrphanFilesAtStartup()
    hasLoaded = true
  }
}

@MainActor
@Observable
final class MCPManagementModel {
  var beginChatConfiguration: (ConversationID, String) -> Bool = { _, _ in true }
  var endChatConfiguration: (ConversationID, String, Bool) -> Void = { _, _, _ in }
  var onProjectStateChanged: @MainActor () async -> Void = {}
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
  var warningMessage: String?

  // The most recently presented MCP screen owns its alert. The root remains
  // the fallback when no local presenter is visible.
  private var errorPresenterIDs: [UUID] = []

  func registerErrorPresenter(_ id: UUID) {
    errorPresenterIDs.removeAll { $0 == id }
    errorPresenterIDs.append(id)
  }

  func unregisterErrorPresenter(_ id: UUID) {
    errorPresenterIDs.removeAll { $0 == id }
  }

  func shouldPresentError(in presenterID: UUID? = nil) -> Bool {
    errorMessage != nil && errorPresenterIDs.last == presenterID
  }

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

  /// Hold the existing MCP queue across a Project commit and cache refresh.
  /// Do not call perform()/reloadFromStorage() inside this operation: they
  /// acquire the same queue. Project failures retain Project error ownership.
  func coordinateProjectMutation(_ operation: @MainActor () async throws -> Void) async throws {
    operationCount += 1
    isBusy = true
    await acquireOperation()
    defer {
      releaseOperation()
      operationCount -= 1
      isBusy = operationCount > 0
    }
    try await operation()
    await reloadProjectInheritance()
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
  ) async -> MCPRemoteServer? {
    guard !isBusy else { return nil }
    isBusy = true
    errorMessage = nil
    statusMessage = nil
    warningMessage = nil
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
      if authenticationKind != .none,
        credential?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
      {
        // A nil credential preserves an existing Keychain value; an explicit
        // empty value removes it and cannot satisfy an authenticated server.
        guard credential == nil, try await runtime.hasCredential(serverID: server.id) else {
          throw MCPError.missingCredential
        }
      }

      try await runtime.saveServer(server, credential: credential)
      if existing == nil {
        BYOKAppAnalytics.track(.mcpServerCreated)
      }
      statusMessage = "MCP server saved"
      do {
        try await reloadSnapshot()
      } catch {
        warningMessage = "Server saved, but local state could not be fully refreshed: \(error.localizedDescription)"
      }
      return server
    } catch {
      BYOKAppAnalytics.reportError("mcp_operation_failed", component: "mcp")
      errorMessage = error.localizedDescription
      return nil
    }
  }

  /// Called by the editor after requesting dismissal. Warnings stay in the
  /// server list rather than attempting an alert during the sheet transition.
  func discoverSavedServer(_ server: MCPRemoteServer) async {
    guard server.isEnabled else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      _ = try await runtime.refreshServer(server.id, force: true)
      statusMessage = "MCP server saved and tools discovered"
    } catch {
      BYOKAppAnalytics.track(.mcpDiscoveryFailed)
      appendSaveWarning("Server saved, but tool discovery failed: \(error.localizedDescription)")
    }
    do {
      try await reloadSnapshot()
    } catch {
      appendSaveWarning("Server saved, but local state could not be fully refreshed: \(error.localizedDescription)")
    }
  }

  private func appendSaveWarning(_ message: String) {
    guard warningMessage != message else { return }
    warningMessage = warningMessage.map { "\($0)\n\(message)" } ?? message
  }

  func deleteServer(_ serverID: MCPServerID) async {
    await perform("MCP server deleted") {
      do {
        let snapshot = await workspace.snapshot()
        let serverIDs = snapshot.servers.map(\.id)
          + snapshot.tombstones.keys.map { MCPServerID(rawValue: $0) }
        // Project persistence must succeed while the server is still visible
        // for retry. This is one serialized Project JSON commit, not a series
        // of independent per-project updates.
        try await projectWorkspace.removeMCPServerReferences(serverID, knownServerIDs: serverIDs)
        await onProjectStateChanged()
        try await runtime.deleteServer(serverID)
      } catch {
        // An earlier store may have committed. Publish its real state while
        // preserving the original error and leaving deletion retryable.
        await onProjectStateChanged()
        try? await reloadSnapshot()
        throw error
      }
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
    await perform(nil, conversationID: conversationID, configurationKey: "mcp.server.\(serverID.rawValue)") {
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
    await perform(nil, conversationID: conversationID, configurationKey: "mcp.policy.\(exposedToolName)") {
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
    await perform("Tool preset applied", conversationID: conversationID, configurationKey: "mcp.replace") {
      try await workspace.replaceChatConfiguration(configuration, conversationID: conversationID)
      try await reloadSnapshot()
    }
  }

  func removeChatConfiguration(_ conversationID: ConversationID) async {
    await perform(nil, conversationID: conversationID, configurationKey: "mcp.reset") {
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
      var persisted = false
      await perform(nil, conversationID: request.conversationID, configurationKey: "mcp.policy.\(request.exposedToolName)") {
        try await materializeInheritedConfigurationIfNeeded(request.conversationID)
        try await workspace.setChatToolPolicy(
          .alwaysAllow,
          exposedToolName: request.exposedToolName,
          conversationID: request.conversationID
        )
        try await reloadSnapshot()
        persisted = true
        await approvals.resolve(requestID, decision: .allowOnce)
      }
      if !persisted {
        // Persistence failed or the chat was retired before the write began.
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
    guard await workspace.explicitChatConfiguration(for: conversationID) == nil,
      let inherited = await projectWorkspace.mcpConfiguration(for: conversationID)
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

    await reloadProjectInheritance()

    var credentials: Set<MCPServerID> = []
    for server in servers {
      if try await runtime.hasCredential(serverID: server.id) {
        credentials.insert(server.id)
      }
    }
    credentialServerIDs = credentials
  }

  /// Project writes do not change credentials or explicit chat overrides.
  /// Refreshing inheritance is nonthrowing, so an unrelated Keychain read
  /// cannot turn a durably saved Project into an apparent failed save.
  private func reloadProjectInheritance() async {
    let projectSnapshot = await projectWorkspace.snapshot()
    let projectsByID = Dictionary(uniqueKeysWithValues: projectSnapshot.projects.map { ($0.id.rawValue, $0) })
    inheritedChatConfigurations = Dictionary(
      uniqueKeysWithValues: projectSnapshot.conversationProjectIDs.compactMap { conversationID, projectID in
        guard let configuration = projectsByID[projectID]?.mcpConfiguration else { return nil }
        return (ConversationID(rawValue: conversationID), configuration)
      }
    )
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

  private var operationCount = 0
  private var operationInProgress = false
  private var operationWaiters: [CheckedContinuation<Void, Never>] = []

  private func acquireOperation() async {
    if !operationInProgress {
      operationInProgress = true
      return
    }
    await withCheckedContinuation { operationWaiters.append($0) }
  }

  private func releaseOperation() {
    if operationWaiters.isEmpty {
      operationInProgress = false
    } else {
      operationWaiters.removeFirst().resume()
    }
  }

  private func perform(
    _ success: String?,
    conversationID: ConversationID? = nil,
    configurationKey: String = "",
    operation: () async throws -> Void
  ) async {
    if let conversationID {
      guard beginChatConfiguration(conversationID, configurationKey) else { return }
    }
    var succeeded = false
    operationCount += 1
    isBusy = true
    await acquireOperation()
    errorMessage = nil
    statusMessage = nil
    warningMessage = nil
    isBusy = true
    defer {
      releaseOperation()
      operationCount -= 1
      isBusy = operationCount > 0
      if let conversationID {
        endChatConfiguration(conversationID, configurationKey, succeeded)
      }
    }
    do {
      try await operation()
      statusMessage = success
      succeeded = true
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
