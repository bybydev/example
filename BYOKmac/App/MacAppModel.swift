import AppKit
import BYOKchatProviderCore
import Foundation
import MacAppFoundation
import Observation

enum MacStartupStage: String, Sendable, Equatable {
  case preparingStorage = "Preparing local data"
  case composingServices = "Preparing shared services"
  case preparingFiles = "Checking file storage"
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

  init(stage: MacStartupStage, error: any Error, occurredAt: Date = .now) {
    self.stage = stage
    message = error.localizedDescription
    details = String(describing: error)
    self.occurredAt = occurredAt
  }

  var title: String {
    switch stage {
    case .preparingStorage, .composingServices, .preparingFiles, .recovering:
      "Couldn't Prepare BYOKchat"
    case .loadingProviders, .loadingProjects, .loadingTools, .loadingChats,
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
    Data directory: \(MacStorageEnvironment.current.rootDirectory.path)
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
    reasoning: providers.supportsReasoning(accountID: accountID, modelID: modelID)
      ? providers.reasoningDefault(for: accountID)
      : nil
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
  private(set) var sidebarToggleRequestID = 0

  private let coreServicesFactory: MacCoreServicesFactory

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
      clearRuntimeModels()
      await performStart()
    } catch {
      MacAppAnalytics.reportError("workspace_recovery_failed", component: "startup")
      startupState = .failed(MacStartupFailure(stage: .recovering, error: error))
    }
  }

  func stopAllGenerations() async {
    guard let chats else { return }
    let activeIDs = Array(chats.activeConversationIDs)
    for id in activeIDs {
      await chats.stop(id)
    }
  }

  /// Refreshes product models after an import or destructive data mutation while
  /// keeping the shared service graph and persistent Settings models alive.
  func reloadAfterDataMutation() async throws {
    guard let services = coreServices else {
      await performStart()
      return
    }

    let pendingStore = MacPendingAttachmentStore(
      environment: storageEnvironment,
      blobs: services.fileBlobStore
    )
    await pendingStore.load()
    pendingAttachmentStore = pendingStore

    let providerModel = MacProviderModel(services: services)
    try await providerModel.load()
    providers = providerModel

    try await services.projectWorkspace.load()

    mcp?.stopInteractionObservers()
    let mcpModel = MacMCPModel(services: services)
    try await mcpModel.load()
    mcp = mcpModel

    try await services.conversationStore.load()
    let conversations = Self.sortedConversations(await services.conversationStore.conversationSummaries())
    chats = MacChatSessionModel(
      services: services,
      providers: providerModel,
      preferences: preferences,
      initialSummaries: conversations
    )

    try await services.libraryStore.load()
    let workspaceModel = MacWorkspaceModel(services: services)
    await workspaceModel.reload()
    workspaceModel.onFileReferencesChanged = { [weak self] in
      guard let self, let services = self.coreServices else { return }
      Task { @MainActor in
        try? await self.sweepOrphanFiles(services: services)
      }
    }
    workspace = workspaceModel

    try await services.projectWorkspace.reconcileConversationIDs(Set(conversations.map(\.id)))
    await workspaceModel.reload()
    await mcpModel.reloadFromStorage()
    try await sweepOrphanFiles(services: services)
    await diagnostics?.load()

    startupState = .ready
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

  func requestNewChat(projectID: ProjectID? = nil, initialDraft: String? = nil) {
    guard isReady else { return }

    if let projectID, workspace?.isProjectRestricted(projectID) == true {
      chats?.errorMessage = MacProAccess.restoredResourceBlockedMessage("project")
      MacProAccess.requestUpgrade(.projects)
      return
    }

    if let projectID, let project = workspace?.project(projectID), project.accountID != nil {
      guard let target = projectTarget(projectID) else {
        chats?.errorMessage = project.modelID == nil
          ? "This project's provider account is unavailable. Edit the project defaults first."
          : "This project's provider account or default model is unavailable. Edit the project defaults first."
        return
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
  }

  func requestConversationSearch() {
    guard isReady else { return }
    conversationSearchRequestID &+= 1
  }

  func requestSidebarToggle() {
    guard isReady else { return }
    sidebarToggleRequestID &+= 1
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
      try await BYOKStorageBootstrap.prepare(environment: storageEnvironment)
      lastRecoveryBackupURL = await MacStorageRecovery.latestRecoveryBackup(
        environment: storageEnvironment
      )

      currentStage = .composingServices
      startupState = .loading(currentStage)
      let services = try coreServicesFactory(storageEnvironment)
      coreServices = services

      currentStage = .preparingFiles
      startupState = .loading(currentStage)
      try await services.fileBlobStore.rebuildIndexIfMissing()
      try await services.fileBlobStore.fillUnknownMetadata()
      let pendingStore = MacPendingAttachmentStore(
        environment: storageEnvironment,
        blobs: services.fileBlobStore
      )
      await pendingStore.load()
      pendingAttachmentStore = pendingStore

      currentStage = .loadingProviders
      startupState = .loading(currentStage)
      let providerModel = MacProviderModel(services: services)
      try await providerModel.load()
      providers = providerModel

      currentStage = .loadingProjects
      startupState = .loading(currentStage)
      try await services.projectWorkspace.load()

      currentStage = .loadingTools
      startupState = .loading(currentStage)
      let mcpModel = MacMCPModel(services: services)
      try await mcpModel.load()
      mcp = mcpModel

      currentStage = .loadingChats
      startupState = .loading(currentStage)
      try await services.conversationStore.load()
      let conversations = Self.sortedConversations(await services.conversationStore.conversationSummaries())
      chats = MacChatSessionModel(
        services: services,
        providers: providerModel,
        preferences: preferences,
        initialSummaries: conversations
      )

      currentStage = .loadingLibrary
      startupState = .loading(currentStage)
      try await services.libraryStore.load()
      let workspaceModel = MacWorkspaceModel(services: services)
      await workspaceModel.reload()
      workspaceModel.onFileReferencesChanged = { [weak self] in
        guard let self, let services = self.coreServices else { return }
        Task { @MainActor in
          try? await self.sweepOrphanFiles(services: services)
        }
      }
      workspace = workspaceModel

      currentStage = .reconciling
      startupState = .loading(currentStage)
      try await services.projectWorkspace.reconcileConversationIDs(Set(conversations.map(\.id)))
      await workspaceModel.reload()
      await mcpModel.reloadFromStorage()
      try await sweepOrphanFiles(services: services)

      currentStage = .maintenance
      startupState = .loading(currentStage)
      await services.telemetryRecorder.performMaintenance()

      dataManagement = MacDataManagementModel(app: self, services: services)
      let diagnosticsModel = MacDiagnosticsModel(recorder: services.telemetryRecorder)
      await diagnosticsModel.load()
      diagnostics = diagnosticsModel

      startupState = .ready
    } catch {
      MacAppAnalytics.reportError(currentStage.analyticsErrorCode, component: "startup")
      clearRuntimeModels()
      startupState = .failed(MacStartupFailure(stage: currentStage, error: error))
    }
  }

  private func clearRuntimeModels() {
    mcp?.stopInteractionObservers()
    coreServices = nil
    providers = nil
    chats = nil
    workspace = nil
    mcp = nil
    dataManagement = nil
    diagnostics = nil
    pendingAttachmentStore = nil
  }

  private func sweepOrphanFiles(services: BYOKCoreServices) async throws {
    var referenced = await services.conversationStore.referencedAttachmentIDs()
    referenced.formUnion(await services.projectWorkspace.referencedFileIDs())
    referenced.formUnion(await services.libraryStore.referencedEntryIDs())
    if let pendingAttachmentStore {
      referenced.formUnion(await pendingAttachmentStore.referencedIDs())
    }

    let stored = try await services.fileBlobStore.storedIDs()
    let orphans = stored.subtracting(referenced)
    guard !orphans.isEmpty else { return }
    try await services.fileBlobStore.deleteIDs(orphans)
  }

  private static func sortedConversations(_ values: [ChatConversation]) -> [ChatConversation] {
    values.sorted { lhs, rhs in
      if lhs.updatedAt == rhs.updatedAt { return lhs.id.rawValue > rhs.id.rawValue }
      return lhs.updatedAt > rhs.updatedAt
    }
  }
}