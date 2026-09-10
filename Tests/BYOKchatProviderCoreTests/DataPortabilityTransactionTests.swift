import Foundation
import Testing

@testable import BYOKchatProviderCore

@Suite("Full backup transactions")
struct DataPortabilityTransactionTests {
  @Test("Full backup hydrates chat and Project blob payloads")
  func fullBackupIsSelfContained() async throws {
    let fixture = try await makePortabilityFixture()
    let account = try await installAccount(
      in: fixture,
      accountID: "portable-account",
      modelID: "portable-model"
    )

    let chatBytes = Data("chat attachment bytes".utf8)
    let attachment = ChatAttachment(
      id: "chat-file",
      kind: .file,
      filename: "chat.txt",
      mimeType: "text/plain",
      data: chatBytes
    )
    _ = try await createCompletedConversation(
      in: fixture,
      account: account,
      modelID: "portable-model",
      userText: "Chat with file",
      attachments: [attachment]
    )

    let projectBytes = Data("project reference bytes".utf8)
    _ = try await fixture.projects.createProject(
      name: "Portable Project",
      symbolName: "folder.fill",
      accentID: "blue",
      accountID: account.id,
      modelID: "portable-model",
      instructions: "",
      files: [
        ProjectFile(
          id: "project-file",
          filename: "reference.txt",
          mimeType: "text/plain",
          data: projectBytes
        )
      ]
    )

    let libraryBytes = Data("library bytes".utf8)
    _ = try await fixture.library.add(
      filename: "library.txt",
      mimeType: "text/plain",
      data: libraryBytes
    )

    let data = try await fixture.service.exportBackup(defaultSystemPrompt: "Portable")
    let backup = try JSONDecoder.provider.decode(ProjectAwareBYOKchatBackup.self, from: data)

    let exportedAttachment = try #require(
      backup.conversationWorkspace.conversations
        .flatMap(\.messages)
        .flatMap { $0.attachments ?? [] }
        .first(where: { $0.id == attachment.id })
    )
    #expect(exportedAttachment.data == chatBytes)

    let projectWorkspace = try #require(backup.projectWorkspace)
    let exportedProjectFile = try #require(
      projectWorkspace.projects
        .flatMap(\.projectFiles)
        .first(where: { $0.id == "project-file" })
    )
    #expect(exportedProjectFile.data == projectBytes)

    let exportedLibrary = try #require(
      backup.libraryEntries?.first(where: { $0.filename == "library.txt" })
    )
    #expect(exportedLibrary.data == libraryBytes)
  }

  @Test("Project replace import preserves IDs and publishes in one save")
  func projectReplaceIsOneAtomicCommit() async throws {
    let persistence = CountingProjectPersistence()
    let workspace = ProjectWorkspaceStore(persistence: persistence)
    try await workspace.load()
    let portability = ProjectPortabilityService(workspace: workspace)

    let first = ChatProject(id: "project-a", name: "A")
    let second = ChatProject(id: "project-b", name: "B")
    let imported = ProjectWorkspaceState(
      projects: [first, second],
      conversationProjectIDs: ["source-chat": first.id.rawValue]
    )
    await persistence.resetSaveCount()

    let mapping: [ConversationID: ConversationID] = ["source-chat": "local-chat"]
    let result = try await portability.importWorkspace(
      imported,
      strategy: .replaceExisting,
      conversationIDMapping: mapping
    )

    #expect(await persistence.saveCount() == 1)
    #expect(result.projectIDMapping[first.id] == first.id)
    #expect(result.projectIDMapping[second.id] == second.id)
    #expect(Set(await workspace.allProjects().map(\.id)) == Set([first.id, second.id]))
    #expect(await workspace.projectID(for: "local-chat") == first.id)
  }

  @Test("Failed Project restore rolls back core data before credentials are cleaned")
  func projectFailureRollsBackCoreAndPreservesCredentials() async throws {
    let source = try await makePortabilityFixture()
    let sourceAccount = try await installAccount(
      in: source,
      accountID: "imported-account",
      modelID: "imported-model"
    )
    let sourceConversation = try await createCompletedConversation(
      in: source,
      account: sourceAccount,
      modelID: "imported-model",
      userText: "Imported conversation"
    )
    let importedProject = try await source.projects.createProject(
      name: "Imported Project",
      symbolName: "shippingbox.fill",
      accentID: "orange",
      accountID: sourceAccount.id,
      modelID: "imported-model",
      instructions: "Imported"
    )
    try await source.projects.assignConversation(sourceConversation, to: importedProject.id)
    let backup = try await source.service.exportBackup(defaultSystemPrompt: "Imported prompt")

    let projectPersistence = OneShotFailureProjectPersistence()
    let destination = try await makePortabilityFixture(projectPersistence: projectPersistence)
    let existingAccount = try await installAccount(
      in: destination,
      accountID: "existing-account",
      modelID: "existing-model"
    )
    try await destination.accountManager.setCredential("keep-me", accountID: existingAccount.id)
    let existingConversation = try await createCompletedConversation(
      in: destination,
      account: existingAccount,
      modelID: "existing-model",
      userText: "Existing conversation"
    )
    let existingProject = try await destination.projects.createProject(
      name: "Existing Project",
      symbolName: "folder.fill",
      accentID: "blue",
      accountID: existingAccount.id,
      modelID: "existing-model",
      instructions: "Existing"
    )
    try await destination.projects.assignConversation(existingConversation, to: existingProject.id)

    await projectPersistence.failNextSave()
    var failed = false
    do {
      _ = try await destination.service.importBackup(backup, strategy: .replaceExisting)
    } catch {
      failed = true
    }
    #expect(failed)

    let accounts = await destination.providers.allAccounts()
    #expect(accounts.map(\.id) == [existingAccount.id])
    #expect(try await destination.accountManager.hasCredential(accountID: existingAccount.id))

    let restoredConversation = try #require(await destination.conversations.allConversations().first)
    #expect(restoredConversation.messages.first(where: { $0.role == .user })?.content == "Existing conversation")
    let restoredProject = try #require(await destination.projects.allProjects().first)
    #expect(restoredProject.id == existingProject.id)
    #expect(restoredProject.name == "Existing Project")
    #expect(await destination.projects.projectID(for: restoredConversation.id) == existingProject.id)
  }

  @Test("Failed Library restore rolls back already-committed Project and core workspaces")
  func libraryFailureRollsBackCoreAndProjects() async throws {
    let source = try await makePortabilityFixture()
    let sourceAccount = try await installAccount(
      in: source,
      accountID: "library-import-account",
      modelID: "library-import-model"
    )
    let sourceConversation = try await createCompletedConversation(
      in: source,
      account: sourceAccount,
      modelID: "library-import-model",
      userText: "Imported library conversation"
    )
    let sourceProject = try await source.projects.createProject(
      name: "Imported Library Project",
      symbolName: "folder.fill",
      accentID: "orange",
      accountID: sourceAccount.id,
      modelID: "library-import-model",
      instructions: "Imported"
    )
    try await source.projects.assignConversation(sourceConversation, to: sourceProject.id)
    _ = try await source.library.add(
      filename: "imported.txt",
      mimeType: "text/plain",
      data: Data("imported library".utf8)
    )
    let backup = try await source.service.exportBackup(defaultSystemPrompt: "")

    let libraryPersistence = OneShotFailureLibraryPersistence()
    let destination = try await makePortabilityFixture(libraryPersistence: libraryPersistence)
    let existingAccount = try await installAccount(
      in: destination,
      accountID: "library-existing-account",
      modelID: "library-existing-model"
    )
    try await destination.accountManager.setCredential("keep-library-key", accountID: existingAccount.id)
    let existingConversation = try await createCompletedConversation(
      in: destination,
      account: existingAccount,
      modelID: "library-existing-model",
      userText: "Existing library conversation"
    )
    let existingProject = try await destination.projects.createProject(
      name: "Existing Library Project",
      symbolName: "folder.fill",
      accentID: "blue",
      accountID: existingAccount.id,
      modelID: "library-existing-model",
      instructions: "Existing"
    )
    try await destination.projects.assignConversation(existingConversation, to: existingProject.id)

    await libraryPersistence.failNextSave()
    var failed = false
    do {
      _ = try await destination.service.importBackup(backup, strategy: .replaceExisting)
    } catch {
      failed = true
    }
    #expect(failed)

    #expect(await destination.providers.allAccounts().map(\.id) == [existingAccount.id])
    #expect(try await destination.accountManager.hasCredential(accountID: existingAccount.id))
    #expect(await destination.library.entries().isEmpty)

    let restoredConversation = try #require(await destination.conversations.allConversations().first)
    #expect(
      restoredConversation.messages.first(where: { $0.role == .user })?.content
        == "Existing library conversation"
    )
    let restoredProject = try #require(await destination.projects.allProjects().first)
    #expect(restoredProject.id == existingProject.id)
    #expect(restoredProject.name == "Existing Library Project")
    #expect(await destination.projects.projectID(for: restoredConversation.id) == existingProject.id)
  }

  @Test("Merge uses one authoritative conversation mapping for MCP and Projects")
  func mergeSharesConversationMappingAcrossWorkspaces() async throws {
    let source = try await makePortabilityFixture()
    let sourceAccount = try await installAccount(
      in: source,
      accountID: "shared-account",
      modelID: "shared-model"
    )
    let sourceConversation = try await createCompletedConversation(
      in: source,
      account: sourceAccount,
      modelID: "shared-model",
      userText: "Equivalent conversation"
    )
    let sourceProject = try await source.projects.createProject(
      name: "Mapped Project",
      symbolName: "folder.fill",
      accentID: "blue",
      accountID: sourceAccount.id,
      modelID: "shared-model",
      instructions: ""
    )
    try await source.projects.assignConversation(sourceConversation, to: sourceProject.id)

    let server = MCPRemoteServer(
      id: "mapping-server",
      name: "Mapping Server",
      endpoint: URL(string: "https://mapping.example.com/mcp")!
    )
    try await source.mcp.upsertServer(server)
    try await source.mcp.setChatServerEnabled(
      true,
      serverID: server.id,
      conversationID: sourceConversation
    )
    let backup = try await source.service.exportBackup(defaultSystemPrompt: "")

    let destination = try await makePortabilityFixture()
    let destinationAccount = try await installAccount(
      in: destination,
      accountID: "shared-account",
      modelID: "shared-model"
    )
    let first = try await createCompletedConversation(
      in: destination,
      account: destinationAccount,
      modelID: "shared-model",
      userText: "Equivalent conversation"
    )
    let second = try await createCompletedConversation(
      in: destination,
      account: destinationAccount,
      modelID: "shared-model",
      userText: "Equivalent conversation"
    )

    _ = try await destination.service.importBackup(backup, strategy: .keepExisting)

    var mcpMappedConversation: ConversationID?
    for id in [first, second] {
      let config = await destination.mcp.chatConfiguration(for: id)
      if config.enabledServerIDs.contains(server.id) {
        mcpMappedConversation = id
      }
    }
    let mappedConversation = try #require(mcpMappedConversation)
    #expect(await destination.projects.projectID(for: mappedConversation) != nil)
  }
}

private struct PortabilityFixture {
  let providers: ProviderWorkspaceStore
  let conversations: ConversationStore
  let projects: ProjectWorkspaceStore
  let library: LibraryStore
  let mcp: MCPWorkspaceStore
  let accountManager: ProviderAccountManager
  let credentialVault: InMemoryCredentialVault
  let service: ProjectAwareDataPortabilityService
}

private func makePortabilityFixture(
  projectPersistence: any ProjectWorkspacePersistence = InMemoryProjectWorkspacePersistence(),
  libraryPersistence: any LibraryWorkspacePersistence = InMemoryLibraryWorkspacePersistence()
) async throws -> PortabilityFixture {
  let blobs = InMemoryAttachmentBlobStore()

  let providers = ProviderWorkspaceStore(persistence: InMemoryProviderWorkspacePersistence())
  try await providers.load()

  let conversations = ConversationStore(
    persistence: InMemoryConversationWorkspacePersistence(),
    blobs: blobs
  )
  try await conversations.load()

  let projects = ProjectWorkspaceStore(persistence: projectPersistence, blobs: blobs)
  try await projects.load()

  let library = LibraryStore(persistence: libraryPersistence, blobs: blobs)
  try await library.load()

  let mcp = MCPWorkspaceStore(persistence: InMemoryMCPWorkspacePersistence())
  try await mcp.load()

  let credentialVault = InMemoryCredentialVault()
  let accountManager = ProviderAccountManager(
    registry: try ProviderRegistry.builtIn(),
    workspace: providers,
    vault: credentialVault
  )
  let base = DataPortabilityService(
    providers: providers,
    conversations: conversations,
    accounts: accountManager,
    mcp: mcp,
    mcpCredentials: InMemoryMCPCredentialVault()
  )
  let service = ProjectAwareDataPortabilityService(
    base: base,
    projects: projects,
    conversations: conversations,
    library: library
  )

  return PortabilityFixture(
    providers: providers,
    conversations: conversations,
    projects: projects,
    library: library,
    mcp: mcp,
    accountManager: accountManager,
    credentialVault: credentialVault,
    service: service
  )
}

private func installAccount(
  in fixture: PortabilityFixture,
  accountID: ProviderAccountID,
  modelID: ModelID
) async throws -> ProviderAccount {
  let account = ProviderAccount(
    kind: ProviderKind(providerID: "deepseek"),
    id: accountID,
    providerID: "deepseek",
    label: accountID.rawValue,
    defaultModelID: modelID
  )
  try await fixture.providers.upsertAccount(account)
  try await fixture.providers.addManualModel(
    ProviderModel(
      providerID: account.providerID,
      id: modelID,
      displayName: modelID.rawValue
    ),
    for: account.id
  )
  return account
}

private func createCompletedConversation(
  in fixture: PortabilityFixture,
  account: ProviderAccount,
  modelID: ModelID,
  userText: String,
  attachments: [ChatAttachment] = []
) async throws -> ConversationID {
  let conversation = try await fixture.conversations.createConversation(
    providerID: account.providerID,
    accountID: account.id,
    modelID: modelID
  )
  let turn = try await fixture.conversations.beginTurn(
    conversationID: conversation.id,
    userText: userText,
    attachments: attachments
  )
  _ = try await fixture.conversations.completeMessage(
    conversationID: conversation.id,
    messageID: turn.assistantMessage.id,
    response: ProviderResponse(
      text: "Response",
      providerID: account.providerID,
      accountID: account.id,
      modelID: modelID
    )
  )
  return conversation.id
}

private enum PortabilityTransactionTestError: Error {
  case injectedSaveFailure
}

private actor CountingProjectPersistence: ProjectWorkspacePersistence {
  private var data: Data?
  private var saves = 0

  func loadData() -> Data? { data }

  func saveData(_ data: Data) {
    self.data = data
    saves += 1
  }

  func quarantineData() -> Bool {
    guard data != nil else { return false }
    data = nil
    return true
  }

  func resetSaveCount() {
    saves = 0
  }

  func saveCount() -> Int {
    saves
  }
}

private actor OneShotFailureProjectPersistence: ProjectWorkspacePersistence {
  private var data: Data?
  private var shouldFailNextSave = false

  func failNextSave() {
    shouldFailNextSave = true
  }

  func loadData() -> Data? { data }

  func saveData(_ data: Data) throws {
    if shouldFailNextSave {
      shouldFailNextSave = false
      throw PortabilityTransactionTestError.injectedSaveFailure
    }
    self.data = data
  }

  func quarantineData() -> Bool {
    guard data != nil else { return false }
    data = nil
    return true
  }
}

private actor OneShotFailureLibraryPersistence: LibraryWorkspacePersistence {
  private var data: Data?
  private var shouldFailNextSave = false

  func failNextSave() {
    shouldFailNextSave = true
  }

  func loadData() -> Data? { data }

  func saveData(_ data: Data) throws {
    if shouldFailNextSave {
      shouldFailNextSave = false
      throw PortabilityTransactionTestError.injectedSaveFailure
    }
    self.data = data
  }
}
