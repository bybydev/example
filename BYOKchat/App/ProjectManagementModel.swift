import BYOKchatProviderCore
import Foundation
import Observation

@MainActor
@Observable
final class ProjectManagementModel {
  private(set) var projects: [ChatProject] = []
  private(set) var conversationProjectIDs: [ConversationID: ProjectID] = [:]
  var isBusy = false
  struct OperationError: Identifiable, Equatable {
    let id = UUID()
    let message: String
  }

  private(set) var operationError: OperationError?
  var errorMessage: String? {
    get { operationError?.message }
    set { operationError = newValue.map { OperationError(message: $0) } }
  }
  var statusMessage: String?
  /// Installed by AppModel: Project writes and chat Tools writes share MCP's
  /// operation queue, including the derived-state refresh before releasing it.
  var coordinateMutation: @MainActor (@MainActor () async throws -> Void) async throws -> Void = { operation in
    try await operation()
  }
  var beginChatConfiguration: (ConversationID, String) -> Bool = { _, _ in true }
  var endChatConfiguration: (ConversationID, String, Bool) -> Void = { _, _, _ in }
  /// App-layer hook invoked after mutations that remove project file references.
  var onFileReferencesChanged: (() -> Void)?
  private var errorPresenterIDs: [UUID] = []

  func registerErrorPresenter(_ id: UUID) {
    errorPresenterIDs.removeAll { $0 == id }
    errorPresenterIDs.append(id)
  }

  func unregisterErrorPresenter(_ id: UUID) {
    errorPresenterIDs.removeAll { $0 == id }
  }

  func errorForPresenter(_ id: UUID? = nil) -> OperationError? {
    errorPresenterIDs.last == id ? operationError : nil
  }

  func acknowledgeError(_ error: OperationError, in presenterID: UUID? = nil) {
    guard errorForPresenter(presenterID)?.id == error.id else { return }
    operationError = nil
  }

  private let workspace: ProjectWorkspaceStore

  init(workspace: ProjectWorkspaceStore) {
    self.workspace = workspace
  }

  func load() async {
    await perform(nil) {
      try await workspace.load()
      await reloadSnapshot()
    }
  }

  func reloadFromStorage() async {
    // Snapshot-only refreshes must not acknowledge an unrelated pending error.
    await reloadSnapshot()
  }

  /// Authoritative reference-file IDs for the app-level orphan sweep.
  func referencedFileIDs() async -> Set<String> {
    await workspace.referencedFileIDs()
  }

  /// On-demand original bytes for a project reference file (composer attach,
  /// previews). nil when the blob is missing.
  func fileData(_ id: String) async -> Data? {
    await workspace.fileData(id)
  }

  func project(_ id: ProjectID?) -> ChatProject? {
    guard let id else { return nil }
    return projects.first { $0.id == id }
  }

  func projectID(for conversationID: ConversationID) -> ProjectID? {
    conversationProjectIDs[conversationID]
  }

  func project(for conversationID: ConversationID) -> ChatProject? {
    project(projectID(for: conversationID))
  }

  func conversationIDs(in projectID: ProjectID) -> Set<ConversationID> {
    Set(conversationProjectIDs.compactMap { $0.value == projectID ? $0.key : nil })
  }

  @discardableResult
  func createProject(
    name: String,
    symbolName: String,
    accentID: String,
    accountID: ProviderAccountID?,
    modelID: ModelID?,
    instructions: String,
    files: [ProjectFile] = [],
    mcpConfiguration: MCPChatToolConfiguration? = nil,
    promptPresets: [ProjectPromptPreset] = [],
    toolPresets: [ProjectToolPreset] = []
  ) async -> ProjectID? {
    var createdID: ProjectID?
    let succeeded = await performResult("Project created") {
      let project = try await workspace.createProject(
        name: name,
        symbolName: symbolName,
        accentID: accentID,
        accountID: accountID,
        modelID: modelID,
        instructions: instructions,
        files: files,
        mcpConfiguration: mcpConfiguration,
        promptPresets: promptPresets,
        toolPresets: toolPresets
      )
      createdID = project.id
      await reloadSnapshot()
    }
    if succeeded, createdID != nil {
      BYOKAppAnalytics.track(.projectCreated)
    }
    return succeeded ? createdID : nil
  }

  func updateProject(
    id: ProjectID,
    name: String,
    symbolName: String,
    accentID: String,
    accountID: ProviderAccountID?,
    modelID: ModelID?,
    instructions: String,
    files: [ProjectFile]? = nil,
    mcpConfiguration: MCPChatToolConfiguration? = nil,
    clearMCPConfiguration: Bool = false,
    promptPresets: [ProjectPromptPreset]? = nil,
    toolPresets: [ProjectToolPreset]? = nil
  ) async -> Bool {
    let succeeded = await performResult("Project updated") {
      _ = try await workspace.updateProject(
        id: id,
        name: name,
        symbolName: symbolName,
        accentID: accentID,
        accountID: accountID,
        modelID: modelID,
        instructions: instructions,
        files: files,
        mcpConfiguration: mcpConfiguration,
        clearMCPConfiguration: clearMCPConfiguration,
        promptPresets: promptPresets,
        toolPresets: toolPresets
      )
      await reloadSnapshot()
    }
    if succeeded, files != nil {
      onFileReferencesChanged?()
    }
    return succeeded
  }

  @discardableResult
  func removeProjectFile(_ fileID: String, from projectID: ProjectID) async -> Bool {
    let succeeded = await performResult("File removed") {
      _ = try await workspace.removeProjectFile(fileID, from: projectID)
      await reloadSnapshot()
    }
    if succeeded {
      onFileReferencesChanged?()
    }
    return succeeded
  }

  @discardableResult
  func deleteProject(_ id: ProjectID) async -> Bool {
    let succeeded = await performResult("Project deleted; its chats are now standalone") {
      try await workspace.deleteProject(id)
      await reloadSnapshot()
    }
    if succeeded {
      onFileReferencesChanged?()
    }
    return succeeded
  }

  @discardableResult
  func assignConversation(_ conversationID: ConversationID, to projectID: ProjectID?) async -> Bool {
    let key = "project.membership"
    guard beginChatConfiguration(conversationID, key) else {
      errorMessage = "This chat is no longer available or is preparing a message. Try the Project change again when it is ready."
      return false
    }
    var succeeded = false
    defer { endChatConfiguration(conversationID, key, succeeded) }
    succeeded = await performResult(nil) {
      try await workspace.assignConversation(conversationID, to: projectID)
      await reloadSnapshot()
    }
    return succeeded
  }

  @discardableResult
  func removeConversation(_ conversationID: ConversationID) async -> Bool {
    await assignConversation(conversationID, to: nil)
  }

  func reconcile(conversations: [ChatConversation]) async {
    await perform(nil, coordinatesMCP: true) {
      try await workspace.reconcileConversationIDs(Set(conversations.map(\.id)))
      await reloadSnapshot()
    }
  }

  private func reloadSnapshot() async {
    let snapshot = await workspace.snapshot()
    projects = snapshot.projects.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
    conversationProjectIDs = Dictionary(
      uniqueKeysWithValues: snapshot.conversationProjectIDs.compactMap { key, value in
        guard projects.contains(where: { $0.id.rawValue == value }) else { return nil }
        return (ConversationID(rawValue: key), ProjectID(rawValue: value))
      }
    )
  }

  private func perform(
    _ successMessage: String?,
    coordinatesMCP: Bool = false,
    operation: @MainActor () async throws -> Void
  ) async {
    _ = await performResult(successMessage, coordinatesMCP: coordinatesMCP, operation: operation)
  }

  private var operationCount = 0

  private func performResult(
    _ successMessage: String?,
    coordinatesMCP: Bool = true,
    operation: @MainActor () async throws -> Void
  ) async -> Bool {
    operationCount += 1
    isBusy = true
    errorMessage = nil
    statusMessage = nil
    defer {
      operationCount -= 1
      isBusy = operationCount > 0
    }
    do {
      if coordinatesMCP {
        try await coordinateMutation(operation)
      } else {
        try await operation()
      }
      if let successMessage { statusMessage = successMessage }
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }
}
