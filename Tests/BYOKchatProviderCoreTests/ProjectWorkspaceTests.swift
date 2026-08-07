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
