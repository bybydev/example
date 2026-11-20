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
  // Both store instances must see the same blobs: persisted JSON carries
  // metadata only, bytes rest in the shared blob store.
  let blobs = InMemoryAttachmentBlobStore()
  let workspace = ProjectWorkspaceStore(persistence: persistence, blobs: blobs)
  try await workspace.load()

  let file = ProjectFile(
    filename: "brief.txt",
    mimeType: "text/plain",
    data: Data("Project brief".utf8),
    createdAt: Date(timeIntervalSince1970: 1_700_000_000)
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

  // Rows are metadata-only after persist; the ID and declared size survive.
  var storedFile = file
  storedFile.data = Data()
  storedFile.declaredByteCount = file.data.count
  #expect(await workspace.files(for: conversationID) == [storedFile])
  #expect(await workspace.mcpConfiguration(for: conversationID) == configuration)
  #expect(await workspace.promptPresets(for: conversationID) == [prompt])
  #expect(await workspace.toolPresets(for: conversationID) == [toolPreset])

  let reloaded = ProjectWorkspaceStore(persistence: persistence, blobs: blobs)
  try await reloaded.load()
  #expect(try await reloaded.project(id: project.id).projectFiles == [storedFile])
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

@Test func createProjectReturnsOffloadedMetadataOnlyFiles() async throws {
  let blobs = InMemoryAttachmentBlobStore()
  let workspace = ProjectWorkspaceStore(
    persistence: InMemoryProjectWorkspacePersistence(),
    blobs: blobs
  )
  try await workspace.load()

  let payload = Data("spec".utf8)
  let file = ProjectFile(filename: "spec.txt", mimeType: "text/plain", data: payload)
  let created = try await workspace.createProject(
    name: "Spec",
    symbolName: "folder.fill",
    accentID: "blue",
    accountID: nil,
    modelID: nil,
    instructions: "",
    files: [file]
  )

  #expect(created.projectFiles.count == 1)
  #expect(created.projectFiles[0].data.isEmpty)
  #expect(created.projectFiles[0].declaredByteCount == payload.count)
  #expect(await workspace.fileData(file.id) == payload)
}

@Test func projectWorkspaceSurfacesSpecificValidationErrorsAndCanClearMCPConfig() async throws {
  let workspace = ProjectWorkspaceStore(persistence: InMemoryProjectWorkspacePersistence())
  try await workspace.load()

  await #expect(throws: ProjectWorkspaceError.nameTooLong) {
    _ = try await workspace.createProject(
      name: String(repeating: "a", count: 81),
      symbolName: "folder.fill",
      accentID: "blue",
      accountID: nil,
      modelID: nil,
      instructions: ""
    )
  }

  await #expect(throws: ProjectWorkspaceError.emptyFile("empty.txt")) {
    _ = try await workspace.createProject(
      name: "EmptyFile",
      symbolName: "folder.fill",
      accentID: "blue",
      accountID: nil,
      modelID: nil,
      instructions: "",
      files: [ProjectFile(filename: "empty.txt", mimeType: "text/plain", data: Data())]
    )
  }

  let duplicateFile = ProjectFile(id: "dup-id", filename: "a.txt", mimeType: "text/plain", data: Data("a".utf8))
  await #expect(throws: ProjectWorkspaceError.duplicateFileID) {
    _ = try await workspace.createProject(
      name: "DupFile",
      symbolName: "folder.fill",
      accentID: "blue",
      accountID: nil,
      modelID: nil,
      instructions: "",
      files: [duplicateFile, duplicateFile]
    )
  }

  await #expect(throws: ProjectWorkspaceError.presetNameTooLong) {
    _ = try await workspace.createProject(
      name: "LongPreset",
      symbolName: "folder.fill",
      accentID: "blue",
      accountID: nil,
      modelID: nil,
      instructions: "",
      promptPresets: [
        ProjectPromptPreset(name: String(repeating: "p", count: 61), prompt: "Run")
      ]
    )
  }

  let tooMany = (0..<25).map { ProjectPromptPreset(name: "Preset \($0)", prompt: "Body") }
  await #expect(throws: ProjectWorkspaceError.tooManyPresets) {
    _ = try await workspace.createProject(
      name: "TooManyPresets",
      symbolName: "folder.fill",
      accentID: "blue",
      accountID: nil,
      modelID: nil,
      instructions: "",
      promptPresets: tooMany
    )
  }

  let config = MCPChatToolConfiguration(enabledServerIDs: [MCPServerID(rawValue: "srv")])
  let project = try await workspace.createProject(
    name: "Tools",
    symbolName: "folder.fill",
    accentID: "blue",
    accountID: nil,
    modelID: nil,
    instructions: "",
    mcpConfiguration: config
  )
  #expect(project.mcpConfiguration == config)

  let cleared = try await workspace.updateProject(
    id: project.id,
    name: "Tools",
    symbolName: "folder.fill",
    accentID: "blue",
    accountID: nil,
    modelID: nil,
    instructions: "",
    mcpConfiguration: nil,
    clearMCPConfiguration: true
  )
  #expect(cleared.mcpConfiguration == nil)
}

@Test func projectWorkspaceLoadPreservesUnsupportedVersionAndAvoidsStatePollution() async throws {
  let unsupportedJSON = """
  {
    "schemaVersion": 99,
    "projects": [],
    "conversationProjectIDs": {}
  }
  """
  let unsupportedPersistence = InMemoryProjectWorkspacePersistence(data: Data(unsupportedJSON.utf8))
  let unsupportedStore = ProjectWorkspaceStore(persistence: unsupportedPersistence)

  await #expect(throws: ProjectWorkspaceError.unsupportedVersion(99)) {
    try await unsupportedStore.load()
  }
  // Future-version file stays intact (not quarantined/cleared) and writes are blocked.
  #expect(await unsupportedPersistence.loadData() != nil)
  await #expect(throws: ProjectWorkspaceError.writesBlockedAfterLoadFailure) {
    _ = try await unsupportedStore.createProject(
      name: "Blocked",
      symbolName: "folder.fill",
      accentID: "blue",
      accountID: nil,
      modelID: nil,
      instructions: ""
    )
  }

  // Invalid sanitized payload must not pollute live state after load fails.
  let invalidState = ProjectWorkspaceState(
    projects: [
      ChatProject(
        name: "Bad",
        promptPresets: [
          ProjectPromptPreset(name: "Dup", prompt: "A"),
          ProjectPromptPreset(name: "dup", prompt: "B"),
        ]
      )
    ]
  )
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .iso8601
  let invalidStore = ProjectWorkspaceStore(
    persistence: InMemoryProjectWorkspacePersistence(data: try encoder.encode(invalidState))
  )
  await #expect(throws: ProjectWorkspaceError.loadFailurePreserved) {
    try await invalidStore.load()
  }
  #expect(await invalidStore.allProjects().isEmpty)
}

@Test func projectPortabilityRoundTripsDiacriticsAndPreservesValidationErrors() async throws {
  let workspace = ProjectWorkspaceStore(persistence: InMemoryProjectWorkspacePersistence())
  try await workspace.load()
  _ = try await workspace.createProject(
    name: "Cafe",
    symbolName: "folder.fill",
    accentID: "blue",
    accountID: nil,
    modelID: nil,
    instructions: ""
  )
  _ = try await workspace.createProject(
    name: "Café",
    symbolName: "folder.fill",
    accentID: "teal",
    accountID: nil,
    modelID: nil,
    instructions: ""
  )

  let portability = ProjectPortabilityService(workspace: workspace)
  let exported = await portability.exportWorkspace()
  let validated = try await ProjectPortabilityService.validatedState(exported)
  #expect(validated.projects.count == 2)

  // Validation errors surface specifically instead of .loadFailurePreserved.
  let futureState = ProjectWorkspaceState(schemaVersion: 42)
  await #expect(throws: ProjectWorkspaceError.unsupportedVersion(42)) {
    _ = try await ProjectPortabilityService.validatedState(futureState)
  }

  let longNameState = ProjectWorkspaceState(
    projects: [ChatProject(name: String(repeating: "x", count: 81))]
  )
  await #expect(throws: ProjectWorkspaceError.nameTooLong) {
    _ = try await ProjectPortabilityService.validatedState(longNameState)
  }
}

/// Simulates storage that cannot move unreadable data aside (for example a read-only volume),
/// where overwriting would destroy the only copy of the user's projects.
private struct RefusingQuarantinePersistence: ProjectWorkspacePersistence {
  func loadData() async throws -> Data? { Data("unreadable payload".utf8) }
  func saveData(_ data: Data) async throws {}
  func quarantineData() async throws -> Bool { false }
}
