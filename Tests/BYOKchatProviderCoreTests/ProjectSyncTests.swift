import Foundation
import Testing

@testable import BYOKchatProviderCore

@Test func projectSyncDownloadsWorkspaceWithoutCopyingConversationMembership() async throws {
  let remote = InMemoryProjectSyncRemoteStorage()

  let workspaceA = ProjectWorkspaceStore(persistence: InMemoryProjectWorkspacePersistence())
  try await workspaceA.load()
  let projectA = try await workspaceA.createProject(
    name: "Research",
    symbolName: "folder.fill",
    accentID: "indigo",
    accountID: "anthropic-main",
    modelID: "claude-sonnet-5",
    instructions: "Use project context.",
    files: [
      ProjectFile(filename: "brief.txt", mimeType: "text/plain", data: Data("hello".utf8))
    ],
    promptPresets: [ProjectPromptPreset(name: "Summarize", prompt: "Summarize the project.")]
  )
  try await workspaceA.assignConversation("chat-a", to: projectA.id)

  let serviceA = ProjectSyncService(
    workspace: workspaceA,
    remote: remote,
    localPersistence: InMemoryProjectSyncLocalPersistence()
  )
  _ = try await serviceA.synchronize(at: Date(timeIntervalSince1970: 100))

  let workspaceB = ProjectWorkspaceStore(persistence: InMemoryProjectWorkspacePersistence())
  try await workspaceB.load()
  let serviceB = ProjectSyncService(
    workspace: workspaceB,
    remote: remote,
    localPersistence: InMemoryProjectSyncLocalPersistence()
  )
  _ = try await serviceB.synchronize(at: Date(timeIntervalSince1970: 200))

  let projectsB = await workspaceB.allProjects()
  #expect(projectsB.count == 1)
  #expect(projectsB[0].name == "Research")
  #expect(projectsB[0].instructions == "Use project context.")
  #expect(projectsB[0].projectFiles.first?.filename == "brief.txt")
  #expect(projectsB[0].projectPromptPresets.first?.name == "Summarize")
  #expect(await workspaceB.projectID(for: "chat-a") == nil)
}

@Test func projectSyncPropagatesNewerEditsAndDeletionTombstones() async throws {
  let remote = InMemoryProjectSyncRemoteStorage()

  let workspaceA = ProjectWorkspaceStore(persistence: InMemoryProjectWorkspacePersistence())
  try await workspaceA.load()
  let projectA = try await workspaceA.createProject(
    name: "Code",
    symbolName: "terminal.fill",
    accentID: "green",
    accountID: nil,
    modelID: nil,
    instructions: "Initial",
    at: Date(timeIntervalSince1970: 100)
  )
  let serviceA = ProjectSyncService(
    workspace: workspaceA,
    remote: remote,
    localPersistence: InMemoryProjectSyncLocalPersistence()
  )
  _ = try await serviceA.synchronize(at: Date(timeIntervalSince1970: 110))

  let workspaceB = ProjectWorkspaceStore(persistence: InMemoryProjectWorkspacePersistence())
  try await workspaceB.load()
  let serviceB = ProjectSyncService(
    workspace: workspaceB,
    remote: remote,
    localPersistence: InMemoryProjectSyncLocalPersistence()
  )
  _ = try await serviceB.synchronize(at: Date(timeIntervalSince1970: 120))

  let projectB = try #require(await workspaceB.allProjects().first)
  _ = try await workspaceB.updateProject(
    id: projectB.id,
    name: projectB.name,
    symbolName: projectB.symbolName,
    accentID: projectB.accentID,
    accountID: nil,
    modelID: nil,
    instructions: "Updated on B",
    at: Date(timeIntervalSince1970: 200)
  )
  _ = try await serviceB.synchronize(at: Date(timeIntervalSince1970: 210))
  _ = try await serviceA.synchronize(at: Date(timeIntervalSince1970: 220))

  #expect(await workspaceA.allProjects().first?.instructions == "Updated on B")

  try await workspaceA.deleteProject(projectA.id)
  _ = try await serviceA.synchronize(at: Date(timeIntervalSince1970: 300))
  _ = try await serviceB.synchronize(at: Date(timeIntervalSince1970: 310))

  #expect(await workspaceB.allProjects().isEmpty)
}

@Test func projectPortabilityRemapsConversationMembership() async throws {
  let destination = ProjectWorkspaceStore(persistence: InMemoryProjectWorkspacePersistence())
  try await destination.load()
  let service = ProjectPortabilityService(workspace: destination)

  let sourceProjectID = ProjectID(rawValue: "source-project")
  let sourceConversationID = ConversationID(rawValue: "source-chat")
  let destinationConversationID = ConversationID(rawValue: "restored-chat")
  let source = ProjectWorkspaceState(
    projects: [
      ChatProject(
        id: sourceProjectID,
        name: "Product",
        symbolName: "shippingbox.fill",
        accentID: "orange",
        instructions: "Ship carefully.",
        files: [
          ProjectFile(filename: "notes.txt", mimeType: "text/plain", data: Data("notes".utf8))
        ]
      )
    ],
    conversationProjectIDs: [sourceConversationID.rawValue: sourceProjectID.rawValue]
  )

  let result = try await service.importWorkspace(
    source,
    strategy: .replaceExisting,
    conversationIDMapping: [sourceConversationID: destinationConversationID]
  )

  let restoredProjectID = try #require(result.projectIDMapping[sourceProjectID])
  #expect(await destination.projectID(for: destinationConversationID) == restoredProjectID)
  #expect(try await destination.project(id: restoredProjectID).projectFiles.first?.filename == "notes.txt")
}
