import Foundation
import Testing

@testable import BYOKchatProviderCore

@Test func projectWorkspaceCreatesUpdatesAndKeepsChatsWhenProjectIsDeleted() async throws {
  let persistence = InMemoryProjectWorkspacePersistence()
  let workspace = ProjectWorkspaceStore(persistence: persistence)
  try await workspace.load()

  let created = try await workspace.createProject(
    name: "Work",
    symbolName: "briefcase.fill",
    accentID: "indigo",
    accountID: "anthropic-main",
    modelID: "claude-sonnet-5",
    instructions: "Act as my engineering copilot."
  )

  let conversationID = ConversationID(rawValue: "chat-1")
  try await workspace.assignConversation(conversationID, to: created.id)
  #expect(await workspace.projectID(for: conversationID) == created.id)

  let updated = try await workspace.updateProject(
    id: created.id,
    name: "Product",
    symbolName: "shippingbox.fill",
    accentID: "orange",
    accountID: nil,
    modelID: nil,
    instructions: "Keep answers concise."
  )
  #expect(updated.name == "Product")
  #expect(updated.accountID == nil)
  #expect(updated.modelID == nil)

  try await workspace.deleteProject(created.id)
  #expect(await workspace.projectID(for: conversationID) == nil)
  #expect(await workspace.allProjects().isEmpty)
}

@Test func projectWorkspaceRejectsDuplicateNamesCaseInsensitively() async throws {
  let workspace = ProjectWorkspaceStore(persistence: InMemoryProjectWorkspacePersistence())
  try await workspace.load()
  _ = try await workspace.createProject(
    name: "Research",
    symbolName: "folder.fill",
    accentID: "blue",
    accountID: nil,
    modelID: nil,
    instructions: ""
  )

  await #expect(throws: ProjectWorkspaceError.self) {
    _ = try await workspace.createProject(
      name: "research",
      symbolName: "folder.fill",
      accentID: "teal",
      accountID: nil,
      modelID: nil,
      instructions: ""
    )
  }
}

@Test func projectWorkspaceReconcilesStaleConversationMembership() async throws {
  let workspace = ProjectWorkspaceStore(persistence: InMemoryProjectWorkspacePersistence())
  try await workspace.load()
  let project = try await workspace.createProject(
    name: "Code",
    symbolName: "terminal.fill",
    accentID: "green",
    accountID: nil,
    modelID: nil,
    instructions: ""
  )
  let keep = ConversationID(rawValue: "keep")
  let stale = ConversationID(rawValue: "stale")
  try await workspace.assignConversation(keep, to: project.id)
  try await workspace.assignConversation(stale, to: project.id)

  try await workspace.reconcileConversationIDs([keep])
  #expect(await workspace.projectID(for: keep) == project.id)
  #expect(await workspace.projectID(for: stale) == nil)
}

@Test func projectWorkspacePersistsFilesToolsAndPresetsForConversation() async throws {
  let persistence = InMemoryProjectWorkspacePersistence()
  let workspace = ProjectWorkspaceStore(persistence: persistence)
  try await workspace.load()

  let file = ProjectFile(
    filename: "brief.txt",
    mimeType: "text/plain",
    data: Data("Project brief".utf8)
  )
  let configuration = MCPChatToolConfiguration(
    enabledServerIDs: [MCPServerID(rawValue: "github")],
    toolPolicies: ["github__read_file": .alwaysAllow]
  )
  let prompt = ProjectPromptPreset(name: "Review", prompt: "Review this carefully.")
  let toolPreset = ProjectToolPreset(name: "Read only", configuration: configuration)

  let project = try await workspace.createProject(
    name: "Launch",
    symbolName: "shippingbox.fill",
    accentID: "orange",
    accountID: nil,
    modelID: nil,
    instructions: "Use the project brief.",
    files: [file],
    mcpConfiguration: configuration,
    promptPresets: [prompt],
    toolPresets: [toolPreset]
  )
  let conversationID: ConversationID = "project-files-chat"
  try await workspace.assignConversation(conversationID, to: project.id)

  #expect(await workspace.files(for: conversationID) == [file])
  #expect(await workspace.mcpConfiguration(for: conversationID) == configuration)
  #expect(await workspace.promptPresets(for: conversationID) == [prompt])
  #expect(await workspace.toolPresets(for: conversationID) == [toolPreset])

  let reloaded = ProjectWorkspaceStore(persistence: persistence)
  try await reloaded.load()
  #expect(try await reloaded.project(id: project.id).projectFiles == [file])
  #expect(await reloaded.mcpConfiguration(for: conversationID) == configuration)
}

@Test func olderProjectWorkspaceStillDecodesWithoutOptionalFields() async throws {
  let json = """
  {
    "schemaVersion" : 1,
    "projects" : [
      {
        "id" : "legacy-project",
        "name" : "Legacy",
        "symbolName" : "folder.fill",
        "accentID" : "blue",
        "instructions" : "Legacy instructions",
        "createdAt" : "2026-08-07T00:00:00Z",
        "updatedAt" : "2026-08-07T00:00:00Z"
      }
    ],
    "conversationProjectIDs" : {
      "legacy-chat" : "legacy-project"
    }
  }
  """
  let persistence = InMemoryProjectWorkspacePersistence(data: Data(json.utf8))
  let workspace = ProjectWorkspaceStore(persistence: persistence)
  try await workspace.load()

  let project = try await workspace.project(id: "legacy-project")
  #expect(project.projectFiles.isEmpty)
  #expect(project.mcpConfiguration == nil)
  #expect(project.projectPromptPresets.isEmpty)
  #expect(project.projectToolPresets.isEmpty)
  #expect(await workspace.projectID(for: "legacy-chat") == ProjectID(rawValue: "legacy-project"))
}

@Test func projectWorkspaceRejectsOversizedReferenceFileSet() async throws {
  let workspace = ProjectWorkspaceStore(persistence: InMemoryProjectWorkspacePersistence())
  try await workspace.load()
  let files = (0..<9).map { index in
    ProjectFile(
      filename: "\(index).txt",
      mimeType: "text/plain",
      data: Data("x".utf8)
    )
  }

  await #expect(throws: ProjectWorkspaceError.self) {
    _ = try await workspace.createProject(
      name: "Too many files",
      symbolName: "folder.fill",
      accentID: "blue",
      accountID: nil,
      modelID: nil,
      instructions: "",
      files: files
    )
  }
}

@Test func projectWorkspaceQuarantinesUnreadableFileInsteadOfOverwritingIt() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("byokchat-project-workspace-\(UUID().uuidString)")
  let fileURL = directory.appendingPathComponent("projects-v1.json")
  let quarantineURL = fileURL.appendingPathExtension("corrupt")
  defer { try? FileManager.default.removeItem(at: directory) }

  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  try Data("definitely not json".utf8).write(to: fileURL)

  let workspace = ProjectWorkspaceStore(
    persistence: JSONFileProjectWorkspacePersistence(fileURL: fileURL)
  )
  var loadError: ProjectWorkspaceError?
  do {
    try await workspace.load()
  } catch let error as ProjectWorkspaceError {
    loadError = error
  }
  #expect(loadError == .loadFailurePreserved)

  #expect(!FileManager.default.fileExists(atPath: fileURL.path))
  #expect(FileManager.default.fileExists(atPath: quarantineURL.path))

  // The store starts fresh without destroying the preserved original.
  let created = try await workspace.createProject(
    name: "Fresh Start",
    symbolName: "folder.fill",
    accentID: "blue",
    accountID: nil,
    modelID: nil,
    instructions: ""
  )
  #expect(try await workspace.project(id: created.id).name == "Fresh Start")
  #expect(FileManager.default.fileExists(atPath: quarantineURL.path))
}

@Test func projectWorkspaceBlocksWritesWhenUnreadableFileCannotBeQuarantined() async throws {
  let workspace = ProjectWorkspaceStore(persistence: RefusingQuarantinePersistence())

  var loadError: ProjectWorkspaceError?
  do {
    try await workspace.load()
  } catch let error as ProjectWorkspaceError {
    loadError = error
  }
  #expect(loadError == .loadFailurePreserved)

  await #expect(throws: ProjectWorkspaceError.writesBlockedAfterLoadFailure) {
    _ = try await workspace.createProject(
      name: "Blocked",
      symbolName: "folder.fill",
      accentID: "blue",
      accountID: nil,
      modelID: nil,
      instructions: ""
    )
  }
}

/// Simulates storage that cannot move unreadable data aside (for example a read-only volume),
/// where overwriting would destroy the only copy of the user's projects.
private struct RefusingQuarantinePersistence: ProjectWorkspacePersistence {
  func loadData() async throws -> Data? { Data("unreadable payload".utf8) }
  func saveData(_ data: Data) async throws {}
  func quarantineData() async throws -> Bool { false }
}
