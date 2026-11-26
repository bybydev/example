import AppKit
import BYOKchatProviderCore
import Foundation
import MacAppFoundation
import Observation

enum MacStartupStage: String, Sendable, Equatable {
  case preparingStorage = "Preparing local data"
  case composingServices = "Preparing shared services"
  case preparingFiles = "Checking file storage"
  case loadingWorkspace = "Loading workspace"
  case loadingProviders = "Loading connections"
  case loadingProjects = "Loading projects"
  case loadingTools = "Loading tools"
  case loadingChats = "Loading chats"
  case loadingLibrary = "Loading library"
  case reconciling = "Checking references"
  case maintenance = "Finishing startup"
  case recovering = "Preparing a fresh workspace"
}

struct MacStartupFailure: Sendable, Equatable {
  let stage: MacStartupStage
  let message: String
  let details: String
  let occurredAt: Date
  let dataDirectoryPath: String

  init(
    stage: MacStartupStage,
    error: any Error,
    occurredAt: Date = .now,
    dataDirectoryPath: String = MacStorageEnvironment.current.rootDirectory.path
  ) {
    self.stage = stage
    message = error.localizedDescription
    details = String(describing: error)
    self.occurredAt = occurredAt
    self.dataDirectoryPath = dataDirectoryPath
  }

  var title: String {
    switch stage {
    case .preparingStorage, .composingServices, .preparingFiles, .recovering:
      "Couldn't Prepare BYOKchat"
    case .loadingWorkspace, .loadingProviders, .loadingProjects, .loadingTools, .loadingChats,
      .loadingLibrary, .reconciling, .maintenance:
      "Couldn't Start BYOKchat"
    }
  }

  var diagnosticText: String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    return """
    BYOKchat macOS startup failure
    App version: \(version) (\(build))
    Stage: \(stage.rawValue)
    Date: \(occurredAt.ISO8601Format())
    Message: \(message)
    Details: \(details)
    Data directory: \(dataDirectoryPath)
    """
  }
}

enum MacStartupState: Sendable, Equatable {
  case idle
  case loading(MacStartupStage)
  case ready
  case failed(MacStartupFailure)
}

private extension MacStartupStage {
  var analyticsErrorCode: String {
    switch self {
    case .preparingStorage:
      "startup_storage_failed"
    case .composingServices:
      "startup_services_failed"
    case .preparingFiles:
      "startup_files_failed"
    case .loadingWorkspace:
      "startup_workspace_failed"
    case .loadingProviders:
      "startup_providers_failed"
    case .loadingProjects:
      "startup_projects_failed"
    case .loadingTools:
      "startup_tools_failed"
    case .loadingChats:
      "startup_chats_failed"
    case .loadingLibrary:
      "startup_library_failed"
    case .reconciling:
      "startup_reconcile_failed"
    case .maintenance:
      "startup_maintenance_failed"
    case .recovering:
      "workspace_recovery_failed"
    }
  }
}

typealias MacCoreServicesFactory = @MainActor (BYOKStorageEnvironment) throws -> BYOKCoreServices

@MainActor
func resolveMacProjectTarget(
  project: ChatProject,
  providers: MacProviderModel
) -> MacChatTarget? {
  guard let accountID = project.accountID,
    let account = providers.account(accountID),
    providers.isReady(account)
  else { return nil }

  let modelID: ModelID?
  if let explicitModelID = project.modelID {
    guard providers.models(for: accountID).contains(where: {
      $0.model.id == explicitModelID && $0.isAvailable
    }) else { return nil }
    modelID = explicitModelID
  } else {
    modelID = providers.usableModelID(for: accountID)
  }

  guard let modelID else { return nil }
  return MacChatTarget(
    accountID: accountID,
    modelID: modelID,
    reasoning: nil
  )
}

@MainActor
@Observable
final class MacAppModel {
  let storageEnvironment: BYOKStorageEnvironment
  let preferences: MacPreferencesModel
  let themeStore: MacAppThemeStore

  private(set) var startupState: MacStartupState = .idle
  private(set) var coreServices: BYOKCoreServices?
  private(set) var providers: MacProviderModel?
  private(set) var chats: MacChatSessionModel?
  private(set) var workspace: MacWorkspaceModel?
  private(set) var mcp: MacMCPModel?
  private(set) var dataManagement: MacDataManagementModel?
  private(set) var diagnostics: MacDiagnosticsModel?
  private(set) var pendingAttachmentStore: MacPendingAttachmentStore?
  private(set) var lastRecoveryBackupURL: URL?

  private(set) var newChatRequestID = 0
  private(set) var conversationSearchRequestID = 0
  private(set) var inChatFindRequestID = 0
  private(set) var inChatFindNextRequestID = 0
  private(set) var inChatFindPreviousRequestID = 0
  private(set) var previousChatRequestID = 0
  private(set) var nextChatRequestID = 0
  private(set) var sidebarToggleRequestID = 0
  private(set) var exportMarkdownRequestID = 0
  private(set) var runtimeGeneration = 0
  var canExportActiveConversation = false

  private let coreServicesFactory: MacCoreServicesFactory
  @ObservationIgnored private var catalogRefreshTask: Task<Void, Never>?
  @ObservationIgnored private var postStartupMaintenanceTask: Task<Void, Never>?
  @ObservationIgnored private var orphanSweepTask: Task<Void, Never>?
  @ObservationIgnored private var isSweepingOrphans = false
  @ObservationIgnored private var isReloading = false
  @ObservationIgnored private var isFullTextSearchEnabled = false
  @ObservationIgnored private var lastReconciledEntitlement: MacProEntitlementAccess?
  @ObservationIgnored private var lastReconciledGeneration = -1

  private struct StagedStartupError: Error {
    let stage: MacStartupStage
    let underlying: any Error
  }

  init(
    storageEnvironment: BYOKStorageEnvironment = MacStorageEnvironment.current,
    coreServicesFactory: @escaping MacCoreServicesFactory = {
      try BYOKCoreServices.secure(environment: $0)
    }
  ) {
    self.storageEnvironment = storageEnvironment
    self.coreServicesFactory = coreServicesFactory
    preferences = MacPreferencesModel()
    themeStore = MacThemeFoundation.store
  }

  var isReady: Bool {
    if case .ready = startupState { return true }
    return false
  }

  var isLoading: Bool {
    if case .loading = startupState { return true }
    return false
  }

  var hasPendingWorkToFlush: Bool {
    chats?.hasPendingStateToFlush == true
  }

  func start() async {
    guard case .idle = startupState else { return }
    await performStart()
  }

  func retryStartup() async {
    guard !isLoading else { return }
    await performStart()
  }

  func startFreshKeepingBackup() async {
    guard !isLoading else { return }
    startupState = .loading(.recovering)

    do {
      lastRecoveryBackupURL = try await MacStorageRecovery.moveWorkspaceAside(
        environment: storageEnvironment
      )
      MacPurchaseStore.restrictions.clear()
      if storageEnvironment.userDefaultsSuiteName == nil {
        preferences.clearPinnedConversations()
      } else {
        MacSidebarPinStore.clear(in: storageEnvironment.makeUserDefaults())
      }
      ModelCatalogRegistry.resetToBundled()
      clearRuntimeModels()
      await performStart()
    } catch {
      MacAppAnalytics.reportError("workspace_recovery_failed", component: "startup")
      startupState = .failed(
        MacStartupFailure(
          stage: .recovering,
          error: error,
          dataDirectoryPath: storageEnvironment.rootDirectory.path
        )
      )
    }
  }

  func stopAllGenerations() async {
    guard let chats else { return }
    let activeIDs = Array(chats.activeConversationIDs)
    for id in activeIDs {
      await chats.stop(id)
    }
  }

  func flushPendingState() async {
    await chats?.flushPendingState()
  }

  func setFullTextSearchEnabled(_ enabled: Bool) async {
    isFullTextSearchEnabled = enabled
    if let chats {
      await chats.setFullTextSearchEnabled(enabled)
    } else if let store = coreServices?.conversationStore {
      await store.setFullTextSearchEnabled(enabled)
    }
  }

  func reconcileProEntitlement(
    _ access: MacProEntitlementAccess,
    forceTargetRefresh: Bool = false
  ) {
    if !forceTargetRefresh,
      lastReconciledEntitlement == access,
      lastReconciledGeneration == runtimeGeneration
    {
      return
    }
    lastReconciledEntitlement = access
    lastReconciledGeneration = runtimeGeneration

    if access == .pro {
      // Once the user legitimately unlocks Pro, restored resources become
      // normal existing resources and remain usable under downgrade semantics.
      MacPurchaseStore.restrictions.clear()
    }

    chats?.refreshNewChatTargetAfterProviderChanges()
  }

  func handleApplicationDidBecomeActive() {
    guard isReady, let providers else { return }
    scheduleBackgroundCatalogRefresh(for: providers)
  }

  /// Refreshes product models after an import or destructive data mutation while
  /// keeping the shared service graph and persistent Settings models alive.
  func reloadAfterDataMutation() async throws {
    guard !isReloading else { return }
    guard let services = coreServices else {
      await performStart()
      return
    }

    isReloading = true
    defer { isReloading = false }

    postStartupMaintenanceTask?.cancel()
    postStartupMaintenanceTask = nil
    catalogRefreshTask?.cancel()
    catalogRefreshTask = nil
    orphanSweepTask?.cancel()
    orphanSweepTask = nil

    let pendingStore = MacPendingAttachmentStore(
      environment: storageEnvironment,
      blobs: services.fileBlobStore
    )
    let providerModel = MacProviderModel(services: services)
    let projectWorkspace = services.projectWorkspace
    let mcpRuntime = services.mcpRuntime
    let conversationStore = services.conversationStore
    let libraryStore = services.libraryStore

    async let pendingLoad: Void = pendingStore.load()
    async let providersLoad: Void = providerModel.load()
    async let projectsLoad: Void = projectWorkspace.load()
    async let mcpRuntimeLoad: Void = mcpRuntime.load()
    async let chatsLoad: Void = conversationStore.load()
    async let libraryLoad: Void = libraryStore.load()

    await pendingLoad
    try await providersLoad
    try await projectsLoad
    try await mcpRuntimeLoad
    try await chatsLoad
    try await libraryLoad

    await conversationStore.setFullTextSearchEnabled(isFullTextSearchEnabled)

    pendingAttachmentStore = pendingStore
    providers = providerModel

    let conversations = await conversationStore.conversationSummaries()
    let chatModel = MacChatSessionModel(
      services: services,
      providers: providerModel,
      preferences: preferences,
      initialSummaries: conversations
    )
    chatModel.onFileReferencesChanged = { [weak self] in
      self?.scheduleOrphanFileSweep()
    }
    chats = chatModel

    try await projectWorkspace.reconcileConversationIDs(Set(conversations.map(\.id)))

    mcp?.stopInteractionObservers()
    let workspaceModel = MacWorkspaceModel(services: services)
    let mcpModel = MacMCPModel(services: services)
    async let workspaceReload: Void = workspaceModel.reload()
    async let mcpLoad: Void = mcpModel.load(skipRuntimeLoad: true)
    await workspaceReload
    try await mcpLoad

    workspaceModel.onFileReferencesChanged = { [weak self] in
      self?.scheduleOrphanFileSweep()
    }
    mcpModel.onProjectStateChanged = { [weak workspaceModel] in
      await workspaceModel?.reload()
    }
    workspace = workspaceModel
    mcp = mcpModel

    try await sweepOrphanFiles(services: services)
    await diagnostics?.load()

    canExportActiveConversation = false
    runtimeGeneration &+= 1
    startupState = .ready
    scheduleBackgroundCatalogRefresh(for: providerModel)
  }

  func recordRecoveryBackup(_ url: URL?) {
    lastRecoveryBackupURL = url
  }

  func restartAfterReset() async {
    await performStart()
  }

  func revealDataDirectory() {
    try? FileManager.default.createDirectory(
      at: storageEnvironment.rootDirectory,
      withIntermediateDirectories: true
    )
    NSWorkspace.shared.activateFileViewerSelecting([storageEnvironment.rootDirectory])
  }

  func revealRecoveryBackup() {
    guard let lastRecoveryBackupURL else { return }
    NSWorkspace.shared.activateFileViewerSelecting([lastRecoveryBackupURL])
  }

  @discardableResult
  func requestNewChat(projectID: ProjectID? = nil, initialDraft: String? = nil) -> Bool {
    guard isReady else { return false }

    if let projectID, workspace?.isProjectRestricted(projectID) == true {
      if MacProAccess.isCheckingEntitlement {
        workspace?.errorMessage = MacProAccess.restoredResourceBlockedMessage("project")
      }
      MacProAccess.requestUpgrade(.projects)
      return false
    }

    if let projectID, let project = workspace?.project(projectID), project.accountID != nil {
      guard let target = projectTarget(projectID) else {
        workspace?.errorMessage = project.modelID == nil
          ? "This project's provider account is unavailable. Edit the project defaults first."
          : "This project's provider account or default model is unavailable. Edit the project defaults first."
        return false
      }
      chats?.queueNewChat(projectID: projectID, initialDraft: initialDraft, target: target)
    } else {
      chats?.queueNewChat(
        projectID: projectID,
        initialDraft: initialDraft,
        target: projectTarget(projectID)
      )
    }
    newChatRequestID &+= 1
    return true
  }

  func requestConversationSearch() {
    guard isReady else { return }
    conversationSearchRequestID &+= 1
  }

  func requestInChatFind() {
    guard isReady else { return }
    inChatFindRequestID &+= 1
  }

  func requestInChatFindNext() {
    guard isReady else { return }
    inChatFindNextRequestID &+= 1
  }

  func requestInChatFindPrevious() {
    guard isReady else { return }
    inChatFindPreviousRequestID &+= 1
  }

  func requestPreviousChat() {
    guard isReady else { return }
    previousChatRequestID &+= 1
  }

  func requestNextChat() {
    guard isReady else { return }
    nextChatRequestID &+= 1
  }

  func requestSidebarToggle() {
    guard isReady else { return }
    sidebarToggleRequestID &+= 1
  }

  func requestExportMarkdown() {
    guard isReady else { return }
    exportMarkdownRequestID &+= 1
  }

  private func projectTarget(_ projectID: ProjectID?) -> MacChatTarget? {
    guard let project = workspace?.project(projectID), let providers else { return nil }
    return resolveMacProjectTarget(project: project, providers: providers)
  }

  private func performStart() async {
    var currentStage: MacStartupStage = .preparingStorage

    do {
      clearRuntimeModels()
      startupState = .loading(currentStage)

      // Overlap storage migration check with off-main-thread decoding of the
      // bundled model catalog so composing services never stalls the UI thread.
      let environment = storageEnvironment
      async let prepareStorage: Void = BYOKStorageBootstrap.prepare(environment: environment)
      async let warmCatalog: Void = Task.detached(priority: .userInitiated) {
        _ = ModelCatalogRegistry.bundled
        _ = BuiltInProviders.all
      }.value
      try await prepareStorage
      await warmCatalog

      currentStage = .composingServices
      startupState = .loading(currentStage)
      let services = try coreServicesFactory(storageEnvironment)
      coreServices = services

      currentStage = .loadingWorkspace
      startupState = .loading(currentStage)

      let pendingStore = MacPendingAttachmentStore(
        environment: storageEnvironment,
        blobs: services.fileBlobStore
      )
      let providerModel = MacProviderModel(services: services)
      let projectWorkspace = services.projectWorkspace
      let mcpRuntime = services.mcpRuntime
      let conversationStore = services.conversationStore
      let libraryStore = services.libraryStore

      async let pendingLoad: Void = pendingStore.load()
      async let providersLoad: Void = Self.runStage(.loadingProviders) {
        try await providerModel.load()
      }
      async let projectsLoad: Void = Self.runStage(.loadingProjects) {
        try await projectWorkspace.load()
      }
      async let mcpRuntimeLoad: Void = Self.runStage(.loadingTools) {
        try await mcpRuntime.load()
      }
      async let chatsLoad: Void = Self.runStage(.loadingChats) {
        try await conversationStore.load()
      }
      async let libraryLoad: Void = Self.runStage(.loadingLibrary) {
        try await libraryStore.load()
      }

      await pendingLoad
      try await providersLoad
      try await projectsLoad
      try await mcpRuntimeLoad
      try await chatsLoad
      try await libraryLoad

      await conversationStore.setFullTextSearchEnabled(isFullTextSearchEnabled)

      pendingAttachmentStore = pendingStore
      providers = providerModel

      let conversations = await conversationStore.conversationSummaries()
      let chatModel = MacChatSessionModel(
        services: services,
        providers: providerModel,
        preferences: preferences,
        initialSummaries: conversations
      )
      chatModel.onFileReferencesChanged = { [weak self] in
        self?.scheduleOrphanFileSweep()
      }
      chats = chatModel

      currentStage = .reconciling
      startupState = .loading(currentStage)
      try await projectWorkspace.reconcileConversationIDs(Set(conversations.map(\.id)))

      let workspaceModel = MacWorkspaceModel(services: services)
      let mcpModel = MacMCPModel(services: services)
      async let workspaceReload: Void = workspaceModel.reload()
      async let mcpLoad: Void = Self.runStage(.loadingTools) {
        try await mcpModel.load(skipRuntimeLoad: true)
      }
      await workspaceReload
      try await mcpLoad

      workspaceModel.onFileReferencesChanged = { [weak self] in
        self?.scheduleOrphanFileSweep()
      }
      mcpModel.onProjectStateChanged = { [weak workspaceModel] in
        await workspaceModel?.reload()
      }
      workspace = workspaceModel
      mcp = mcpModel

      dataManagement = MacDataManagementModel(app: self, services: services)
      diagnostics = MacDiagnosticsModel(recorder: services.telemetryRecorder)

      canExportActiveConversation = false
      runtimeGeneration &+= 1
      startupState = .ready
      schedulePostStartupMaintenance(services: services, providerModel: providerModel)
    } catch let staged as StagedStartupError {
      MacAppAnalytics.reportError(staged.stage.analyticsErrorCode, component: "startup")
      if lastRecoveryBackupURL == nil {
        lastRecoveryBackupURL = await MacStorageRecovery.latestRecoveryBackup(
          environment: storageEnvironment
        )
      }
      clearRuntimeModels()
      startupState = .failed(
        MacStartupFailure(
          stage: staged.stage,
          error: staged.underlying,
          dataDirectoryPath: storageEnvironment.rootDirectory.path
        )
      )
    } catch {
      MacAppAnalytics.reportError(currentStage.analyticsErrorCode, component: "startup")
      if lastRecoveryBackupURL == nil {
        lastRecoveryBackupURL = await MacStorageRecovery.latestRecoveryBackup(
          environment: storageEnvironment
        )
      }
      clearRuntimeModels()
      startupState = .failed(
        MacStartupFailure(
          stage: currentStage,
          error: error,
          dataDirectoryPath: storageEnvironment.rootDirectory.path
        )
      )
    }
  }

  private nonisolated static func runStage(
    _ stage: MacStartupStage,
    operation: @Sendable () async throws -> Void
  ) async throws {
    do {
      try await operation()
    } catch {
      throw StagedStartupError(stage: stage, underlying: error)
    }
  }

  /// Runs non-critical disk, SQLite maintenance, idle orphan blob sweeps, and
  /// staggered remote catalog refreshes at utility priority after the main window
  /// is interactive.
  private func schedulePostStartupMaintenance(
    services: BYOKCoreServices,
    providerModel: MacProviderModel
  ) {
    postStartupMaintenanceTask?.cancel()
    let environment = storageEnvironment
    let fileBlobStore = services.fileBlobStore
    let telemetryRecorder = services.telemetryRecorder
    postStartupMaintenanceTask = Task(priority: .utility) { @MainActor [weak self, weak providerModel] in
      try? await Task.sleep(for: .milliseconds(750))
      guard let self, !Task.isCancelled else { return }

      if self.lastRecoveryBackupURL == nil {
        self.lastRecoveryBackupURL = await MacStorageRecovery.latestRecoveryBackup(
          environment: environment
        )
      }
      guard !Task.isCancelled else { return }

      try? await fileBlobStore.rebuildIndexIfMissing()
      guard !Task.isCancelled else { return }
      try? await fileBlobStore.fillUnknownMetadata()
      guard !Task.isCancelled else { return }
      await self.sweepOrphanFilesIfIdle()
      guard !Task.isCancelled else { return }

      await telemetryRecorder.performMaintenance()
      guard !Task.isCancelled else { return }

      try? await Task.sleep(for: .seconds(1))
      guard !Task.isCancelled, let providerModel, self.providers === providerModel else { return }

      self.scheduleBackgroundCatalogRefresh(for: providerModel)
    }
  }

  private func scheduleBackgroundCatalogRefresh(for providerModel: MacProviderModel) {
    catalogRefreshTask?.cancel()
    catalogRefreshTask = Task(priority: .utility) { @MainActor [weak self, weak providerModel] in
      guard let providerModel else { return }
      await providerModel.refreshModelCatalogIfNeeded()
      guard !Task.isCancelled else { return }
      await providerModel.refreshReadyAccountsIfNeeded()
      guard !Task.isCancelled else { return }
      self?.chats?.refreshNewChatTargetAfterProviderChanges()
    }
  }

  /// Coalesces rapid file/chat/project deletions into one idle orphan sweep.
  private func scheduleOrphanFileSweep() {
    orphanSweepTask?.cancel()
    orphanSweepTask = Task(priority: .utility) { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled else { return }
      await self?.sweepOrphanFilesIfIdle()
    }
  }

  private var canSweepOrphanFiles: Bool {
    !isSweepingOrphans
      && !isReloading
      && (chats?.activeConversationIDs.isEmpty ?? true)
      && !(workspace?.isBusy ?? false)
      && !(dataManagement?.isBusy ?? false)
      && !(providers?.isBusy ?? false)
  }

  /// Reclaims unreferenced attachment blobs and orphaned thumbnails only when
  /// no reference-owning store or streaming generation has a live write in flight.
  func sweepOrphanFilesIfIdle() async {
    guard canSweepOrphanFiles, let services = coreServices else { return }
    try? await sweepOrphanFiles(services: services)
  }

  private func clearRuntimeModels() {
    postStartupMaintenanceTask?.cancel()
    postStartupMaintenanceTask = nil
    catalogRefreshTask?.cancel()
    catalogRefreshTask = nil
    orphanSweepTask?.cancel()
    orphanSweepTask = nil
    mcp?.stopInteractionObservers()
    coreServices = nil
    providers = nil
    chats = nil
    workspace = nil
    mcp = nil
    dataManagement = nil
    diagnostics = nil
    pendingAttachmentStore = nil
    canExportActiveConversation = false
  }

  private func sweepOrphanFiles(services: BYOKCoreServices) async throws {
    guard !isSweepingOrphans else { return }
    isSweepingOrphans = true
    defer { isSweepingOrphans = false }

    var referenced = await services.conversationStore.referencedAttachmentIDs()
    referenced.formUnion(await services.projectWorkspace.referencedFileIDs())
    referenced.formUnion(await services.libraryStore.referencedEntryIDs())
    if let pendingAttachmentStore {
      referenced.formUnion(await pendingAttachmentStore.referencedIDs())
    }

    let stored = try await services.fileBlobStore.storedIDs()
    let orphans = stored.subtracting(referenced)
    if !orphans.isEmpty {
      try await services.fileBlobStore.deleteIDs(orphans)
    }
    await services.fileBlobStore.sweepOrphanedDerivatives()
  }
}
