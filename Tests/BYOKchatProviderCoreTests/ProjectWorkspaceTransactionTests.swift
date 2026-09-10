import Foundation
import Testing

@testable import BYOKchatProviderCore

@Suite("Project workspace transactions")
struct ProjectWorkspaceTransactionTests {
  @Test("Failed create does not publish an unpersisted project")
  func failedCreateDoesNotMutateLiveState() async throws {
    let persistence = ToggleFailureProjectPersistence()
    let workspace = ProjectWorkspaceStore(persistence: persistence)
    try await workspace.load()
    await persistence.setFailSaves(true)

    var failed = false
    do {
      _ = try await workspace.createProject(
        name: "Uncommitted",
        symbolName: "folder.fill",
        accentID: "blue",
        accountID: nil,
        modelID: nil,
        instructions: ""
      )
    } catch {
      failed = true
    }

    #expect(failed)
    #expect(await workspace.allProjects().isEmpty)
  }

  @Test("Failed update keeps the last committed project state")
  func failedUpdateRollsBackCompletely() async throws {
    let persistence = ToggleFailureProjectPersistence()
    let workspace = ProjectWorkspaceStore(persistence: persistence)
    try await workspace.load()
    let project = try await workspace.createProject(
      name: "Original",
      symbolName: "folder.fill",
      accentID: "blue",
      accountID: nil,
      modelID: nil,
      instructions: "Original instructions"
    )

    await persistence.setFailSaves(true)
    var failed = false
    do {
      _ = try await workspace.updateProjectIdentity(
        id: project.id,
        name: "Changed",
        symbolName: "briefcase.fill",
        accentID: "orange"
      )
    } catch {
      failed = true
    }

    #expect(failed)
    let stored = try await workspace.project(id: project.id)
    #expect(stored.name == "Original")
    #expect(stored.symbolName == "folder.fill")
    #expect(stored.accentID == "blue")
    #expect(stored.instructions == "Original instructions")
  }

  @Test("Failed assignment and delete do not change runtime membership")
  func failedMembershipMutationsStayCommitted() async throws {
    let persistence = ToggleFailureProjectPersistence()
    let workspace = ProjectWorkspaceStore(persistence: persistence)
    try await workspace.load()
    let project = try await workspace.createProject(
      name: "Work",
      symbolName: "briefcase.fill",
      accentID: "indigo",
      accountID: nil,
      modelID: nil,
      instructions: ""
    )
    let conversationID: ConversationID = "project-transaction-chat"

    await persistence.setFailSaves(true)
    var assignmentFailed = false
    do {
      try await workspace.assignConversation(conversationID, to: project.id)
    } catch {
      assignmentFailed = true
    }
    #expect(assignmentFailed)
    #expect(await workspace.projectID(for: conversationID) == nil)

    await persistence.setFailSaves(false)
    try await workspace.assignConversation(conversationID, to: project.id)
    #expect(await workspace.projectID(for: conversationID) == project.id)

    await persistence.setFailSaves(true)
    var deleteFailed = false
    do {
      try await workspace.deleteProject(project.id)
    } catch {
      deleteFailed = true
    }
    #expect(deleteFailed)
    #expect(try await workspace.project(id: project.id).id == project.id)
    #expect(await workspace.projectID(for: conversationID) == project.id)
  }

  @Test("Focused mutations preserve unrelated project fields")
  func focusedMutationsDoNotClobberOtherProjectState() async throws {
    let persistence = ToggleFailureProjectPersistence()
    let blobs = InMemoryAttachmentBlobStore()
    let workspace = ProjectWorkspaceStore(persistence: persistence, blobs: blobs)
    try await workspace.load()

    let originalPrompt = ProjectPromptPreset(name: "Original prompt", prompt: "One")
    let originalFile = ProjectFile(
      filename: "brief.txt",
      mimeType: "text/plain",
      data: Data("brief".utf8)
    )
    let project = try await workspace.createProject(
      name: "Product",
      symbolName: "shippingbox.fill",
      accentID: "orange",
      accountID: "account-a",
      modelID: "model-a",
      instructions: "Original instructions",
      files: [originalFile],
      promptPresets: [originalPrompt]
    )

    _ = try await workspace.updateProjectIdentity(
      id: project.id,
      name: "Renamed",
      symbolName: "folder.fill",
      accentID: "teal"
    )
    _ = try await workspace.updateProjectInstructions(
      id: project.id,
      instructions: "Updated instructions"
    )
    let addedPrompt = ProjectPromptPreset(name: "Second prompt", prompt: "Two")
    _ = try await workspace.upsertProjectPromptPreset(addedPrompt, projectID: project.id)

    let stored = try await workspace.project(id: project.id)
    #expect(stored.name == "Renamed")
    #expect(stored.accountID == ProviderAccountID(rawValue: "account-a"))
    #expect(stored.modelID == ModelID(rawValue: "model-a"))
    #expect(stored.instructions == "Updated instructions")
    #expect(stored.projectFiles.map(\.id) == [originalFile.id])
    #expect(Set(stored.projectPromptPresets.map(\.id)) == Set([originalPrompt.id, addedPrompt.id]))
  }
}

private enum ProjectTransactionTestError: Error {
  case saveFailed
}

private actor ToggleFailureProjectPersistence: ProjectWorkspacePersistence {
  private var data: Data?
  private var failSaves = false

  func setFailSaves(_ value: Bool) {
    failSaves = value
  }

  func loadData() -> Data? {
    data
  }

  func saveData(_ data: Data) throws {
    if failSaves {
      throw ProjectTransactionTestError.saveFailed
    }
    self.data = data
  }

  func quarantineData() -> Bool {
    guard data != nil else { return false }
    data = nil
    return true
  }
}
