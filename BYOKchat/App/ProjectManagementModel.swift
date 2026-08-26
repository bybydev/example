import BYOKchatProviderCore
import Foundation
import Observation

@MainActor
@Observable
final class ProjectManagementModel {
  private(set) var projects: [ChatProject] = []
  private(set) var conversationProjectIDs: [ConversationID: ProjectID] = [:]
  var isBusy = false
  var errorMessage: String?
  var statusMessage: String?
  /// App-layer hook fired after snapshot refreshes; AppModel runs the
  /// orphan-file sweep in response (project file pointers may have shrunk).
  var onFileReferencesChanged: (() -> Void)?

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
    await perform(nil) {
      await reloadSnapshot()
    }
  }

  /// Authoritative reference-file IDs for the app-level orphan sweep.
  func referencedFileIDs() async -> Set<String> {
    await workspace.referencedFileIDs()
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
    promptPresets: [ProjectPromptPreset]? = nil,
    toolPresets: [ProjectToolPreset]? = nil
  ) async -> Bool {
    await performResult("Project updated") {
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
        promptPresets: promptPresets,
        toolPresets: toolPresets
      )
      await reloadSnapshot()
    }
  }

  func deleteProject(_ id: ProjectID) async {
    await perform("Project deleted; its chats are now standalone") {
      try await workspace.deleteProject(id)
      await reloadSnapshot()
    }
  }

  func assignConversation(_ conversationID: ConversationID, to projectID: ProjectID?) async -> Bool {
    await performResult(nil) {
      try await workspace.assignConversation(conversationID, to: projectID)
      await reloadSnapshot()
    }
  }

  func removeConversation(_ conversationID: ConversationID) async {
    await perform(nil) {
      try await workspace.removeConversation(conversationID)
      await reloadSnapshot()
    }
  }

  func reconcile(conversations: [ChatConversation]) async {
    await perform(nil) {
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
    onFileReferencesChanged?()
  }

  private func perform(_ successMessage: String?, operation: () async throws -> Void) async {
    isBusy = true
    errorMessage = nil
    defer { isBusy = false }
    do {
      try await operation()
      if let successMessage { statusMessage = successMessage }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func performResult(_ successMessage: String?, operation: () async throws -> Void) async -> Bool {
    isBusy = true
    errorMessage = nil
    defer { isBusy = false }
    do {
      try await operation()
      if let successMessage { statusMessage = successMessage }
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }
}
