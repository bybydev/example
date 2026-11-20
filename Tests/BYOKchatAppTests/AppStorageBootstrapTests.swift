import BYOKchatProviderCore
import Foundation
import Testing

@testable import BYOKchat

@Suite("App storage bootstrap")
struct AppStorageBootstrapTests {
  @Test("Schema-less provider workspace migrates to schema one")
  func migratesLegacyProviderWorkspace() throws {
    let input = try JSONSerialization.data(withJSONObject: [:])
    let output = try AppStorageBootstrap.migrateDataForTesting(
      input,
      kind: .providers,
      currentSchemaVersion: 1
    )
    let object = try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
    #expect((object["schemaVersion"] as? NSNumber)?.intValue == 1)
    #expect((object["accounts"] as? [Any])?.isEmpty == true)
    #expect((object["modelRecords"] as? [Any])?.isEmpty == true)
    #expect((object["customProviders"] as? [Any])?.isEmpty == true)
  }

  @Test("Current workspace is left byte-for-byte unchanged")
  func currentDataIsUnchanged() throws {
    let input = Data("{\"schemaVersion\":1,\"conversations\":[]}".utf8)
    let output = try AppStorageBootstrap.migrateDataForTesting(
      input,
      kind: .conversations,
      currentSchemaVersion: 1
    )
    #expect(output == input)
  }

  @Test("Newer workspace is rejected without migration")
  func rejectsNewerWorkspace() throws {
    let input = Data("{\"schemaVersion\":2,\"projects\":[],\"conversationProjectIDs\":{}}".utf8)
    do {
      _ = try AppStorageBootstrap.migrateDataForTesting(
        input,
        kind: .projects,
        currentSchemaVersion: 1
      )
      Issue.record("Expected newer schema to be rejected")
    } catch let error as AppStorageMigrationError {
      #expect(error == .newerVersion(store: "projects", stored: 2, supported: 1))
    }
  }
}

@Suite("Library view support")
struct LibraryViewSupportTests {
  @Test("Date grouper classifies future dates as Upcoming and never emits duplicate section titles")
  func dateGrouperUniqueSections() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 14))!
    let future = calendar.date(byAdding: .day, value: 3, to: now)!
    let today = calendar.date(byAdding: .hour, value: -2, to: now)!
    let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
    let fourDaysAgo = calendar.date(byAdding: .day, value: -4, to: now)!
    let sixDaysAgo = calendar.date(byAdding: .day, value: -6, to: now)!
    let older = calendar.date(byAdding: .day, value: -45, to: now)!

    func makeEntry(_ name: String, createdAt: Date) -> LibraryEntry {
      LibraryEntry(
        filename: name,
        kind: .file,
        mimeType: "text/plain",
        byteCount: 16,
        createdAt: createdAt
      )
    }

    let entries = [
      makeEntry("future.txt", createdAt: future),
      makeEntry("today.txt", createdAt: today),
      makeEntry("yesterday.txt", createdAt: yesterday),
      makeEntry("four-days.txt", createdAt: fourDaysAgo),
      makeEntry("older.txt", createdAt: older),
      // Deliberately out-of-order entry in the same bucket to verify title deduplication.
      makeEntry("six-days.txt", createdAt: sixDaysAgo),
    ]

    let sections = LibraryDateGrouper.sections(for: entries, now: now, calendar: calendar)
    let titles = sections.map(\.title)
    #expect(Set(titles).count == titles.count)
    #expect(titles.prefix(4) == ["Upcoming", "Today", "Yesterday", "Previous 7 Days"])
    #expect(sections[3].entries.map(\.filename) == ["four-days.txt", "six-days.txt"])
  }

  @Test("Temp file support sanitizes path separators and cleans up materialized directories")
  func tempFileSanitizationAndCleanup() throws {
    #expect(LibraryTempFileSupport.safeFilename("2026/04:report.pdf") == "2026-04-report.pdf")
    #expect(LibraryTempFileSupport.safeFilename(".") == "file")
    #expect(LibraryTempFileSupport.safeFilename("..") == "file")
    #expect(LibraryTempFileSupport.safeFilename("   ") == "file")
    #expect(LibraryTempFileSupport.safeFilename(".env") == "file.env")

    let payload = Data("report bytes".utf8)
    let materialized = try LibraryTempFileSupport.materializeTempFile(
      directoryPrefix: "LibrarySupportTests",
      filename: "nested/dir/report.pdf",
      data: payload
    )
    defer { LibraryTempFileSupport.cleanupDirectory(materialized.directory) }

    #expect(materialized.fileURL.lastPathComponent == "nested-dir-report.pdf")
    #expect(try Data(contentsOf: materialized.fileURL) == payload)

    LibraryTempFileSupport.cleanupDirectory(materialized.directory)
    #expect(!FileManager.default.fileExists(atPath: materialized.directory.path))
  }

  @Test("Photo import support preserves PNG and JPEG payloads without lossy re-encoding")
  func photoImportPreservesSupportedFormats() {
    let pngHeader = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01])
    let png = LibraryImportSupport.preparedPhotoPayload(from: pngHeader)
    #expect(png?.mimeType == "image/png")
    #expect(png?.fileExtension == "png")
    #expect(png?.data == pngHeader)

    let jpegHeader = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
    let jpeg = LibraryImportSupport.preparedPhotoPayload(from: jpegHeader)
    #expect(jpeg?.mimeType == "image/jpeg")
    #expect(jpeg?.fileExtension == "jpg")
    #expect(jpeg?.data == jpegHeader)
  }

  @Test("Batch error formatter deduplicates and summarizes overflow errors")
  func batchErrorFormatting() {
    let formatted = LibraryImportSupport.formattedBatchErrors([
      "Error A",
      "Error A",
      "Error B",
      "Error C",
      "Error D",
      "Error E",
    ])
    #expect(formatted == "Error A\nError B\nError C\nAnd 2 more errors.")
  }
}

@Suite("Project view support")
struct ProjectViewSupportTests {
  @Test("File detail shows token estimates only for text-like files")
  func projectFileDetailRespectsMIMEType() {
    let textFile = ProjectFile(
      filename: "notes.md",
      mimeType: "text/markdown",
      data: Data(repeating: 0x61, count: 400)
    )
    #expect(projectFileDetail(textFile).contains("tokens"))

    let jsonFile = ProjectFile(
      filename: "config.json",
      mimeType: "application/json",
      data: Data(repeating: 0x7b, count: 400)
    )
    #expect(projectFileDetail(jsonFile).contains("tokens"))

    let imageFile = ProjectFile(
      filename: "diagram.jpg",
      mimeType: "IMAGE/JPEG",
      data: Data(repeating: 0xFF, count: 40_000)
    )
    #expect(ProjectFileImportSupport.isImageMIMEType(imageFile.mimeType))
    #expect(!projectFileDetail(imageFile).contains("tokens"))

    let pdfFile = ProjectFile(
      filename: "manual.pdf",
      mimeType: "application/pdf",
      data: Data(repeating: 0x25, count: 40_000)
    )
    #expect(!projectFileDetail(pdfFile).contains("tokens"))
  }

  @Test("Project tools summary formats singular, plural, and combined counts")
  func toolsSummaryFormatting() {
    let preset1 = ProjectToolPreset(name: "P1", configuration: MCPChatToolConfiguration())
    let preset2 = ProjectToolPreset(name: "P2", configuration: MCPChatToolConfiguration())
    let oneServer = MCPChatToolConfiguration(enabledServerIDs: [MCPServerID(rawValue: "a")])
    let twoServers = MCPChatToolConfiguration(
      enabledServerIDs: [MCPServerID(rawValue: "a"), MCPServerID(rawValue: "b")]
    )

    #expect(projectToolsSummary(configuration: nil, toolPresets: []) == "None")
    #expect(projectToolsSummary(configuration: nil, toolPresets: [preset1]) == "1 preset")
    #expect(projectToolsSummary(configuration: nil, toolPresets: [preset1, preset2]) == "2 presets")
    #expect(projectToolsSummary(configuration: oneServer, toolPresets: []) == "1 server")
    #expect(projectToolsSummary(configuration: twoServers, toolPresets: [preset1]) == "2 servers · 1 preset")
  }

  @Test("Project file import rejects empty files and loads non-empty text files")
  func importFilesValidation() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ProjectImportTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let emptyURL = dir.appendingPathComponent("empty.txt")
    try Data().write(to: emptyURL)
    #expect(throws: ProjectWorkspaceError.emptyFile("empty.txt")) {
      _ = try ProjectFileImportSupport.importFiles(from: [emptyURL], existingCount: 0, existingBytes: 0)
    }

    let validURL = dir.appendingPathComponent("brief.txt")
    let content = Data("Project brief".utf8)
    try content.write(to: validURL)
    let imported = try ProjectFileImportSupport.importFiles(
      from: [validURL],
      existingCount: 0,
      existingBytes: 0
    )
    #expect(imported.count == 1)
    #expect(imported[0].filename == "brief.txt")
    #expect(imported[0].mimeType == "text/plain")
    #expect(imported[0].data == content)
  }
}

@Suite("MCP UI support")
struct MCPUISupportTests {
  @Test("Tool count label uses singular and plural grammar")
  func toolCountLabelFormatting() {
    #expect(mcpToolCountLabel(0) == "0 tools")
    #expect(mcpToolCountLabel(1) == "1 tool")
    #expect(mcpToolCountLabel(3) == "3 tools")
  }

  @Test("Additional header parser rejects case-insensitive duplicates")
  func parseHeadersRejectsCaseInsensitiveDuplicates() throws {
    let parsed = try MCPServerFormSupport.parseHeaders("X-Tenant: alpha\nX-Region: eu-west\n")
    #expect(parsed == ["X-Tenant": "alpha", "X-Region": "eu-west"])

    #expect(throws: MCPError.self) {
      _ = try MCPServerFormSupport.parseHeaders("X-Tenant: alpha\nx-tenant: beta")
    }
  }

  @Test("Elicitation form handles integer defaults, trimmed numbers, optional enums, and array enums")
  func elicitationFormValidationAndPayload() {
    let fields: [MCPElicitationField] = [
      MCPElicitationField(
        name: "count",
        kind: .integer,
        isRequired: true,
        defaultValue: .number(5.0)
      ),
      MCPElicitationField(
        name: "ratio",
        kind: .number,
        isRequired: true
      ),
      MCPElicitationField(
        name: "mode",
        kind: .string,
        isRequired: false,
        allowedValues: ["fast", "safe"]
      ),
      MCPElicitationField(
        name: "tags",
        kind: .stringArray,
        isRequired: true,
        allowedValues: ["ios", "mcp", "core"]
      ),
    ]

    let initial = MCPElicitationFormSupport.initialValues(for: fields)
    // Integer default 5.0 formats cleanly as "5" (not "5.0")
    #expect(initial.text["count"] == "5")
    // Optional enum starts unset ("") rather than forcing the first value
    #expect(initial.text["mode"] == "")

    var text = initial.text
    text["count"] = " -12 "
    text["ratio"] = " 3.5\n"
    text["tags"] = ", , "
    // Comma-only input for a required stringArray must not be submittable
    #expect(!MCPElicitationFormSupport.canSubmit(mode: .form, url: nil, fields: fields, textValues: text))

    // Disallowed value in stringArray must not be submittable
    text["tags"] = "ios, invalid"
    #expect(!MCPElicitationFormSupport.canSubmit(mode: .form, url: nil, fields: fields, textValues: text))

    text["tags"] = "ios, mcp"
    #expect(MCPElicitationFormSupport.canSubmit(mode: .form, url: nil, fields: fields, textValues: text))

    let payload = MCPElicitationFormSupport.responseContent(
      fields: fields,
      textValues: text,
      boolValues: initial.bools
    )
    #expect(payload["count"] == .number(-12))
    #expect(payload["ratio"] == .number(3.5))
    #expect(payload["mode"] == nil)
    #expect(payload["tags"] == .array([.string("ios"), .string("mcp")]))
  }
}

@Suite("Local analytics formatting")
struct LocalAnalyticsFormattingTests {
  @Test("Provider display names cover OpenAI, xAI, custom accounts, and deleted UUIDs")
  func providerDisplayNames() {
    let customUUID = "7f8b9c21-3d4e-4567-89ab-0123456789ab"
    let deletedUUID = "11111111-2222-3333-4444-555555555555"
    let customAccount = ProviderAccount(
      kind: .openAICompatible,
      id: "custom-1",
      providerID: ProviderID(rawValue: customUUID),
      label: "My vLLM Server"
    )

    #expect(usageDisplayName("openai") == "OpenAI")
    #expect(usageDisplayName("xai") == "xAI")
    #expect(usageDisplayName(customUUID, accounts: [customAccount]) == "My vLLM Server")
    #expect(usageDisplayName(deletedUUID, accounts: [customAccount]) == "Custom Provider")
  }

  @Test("Currency, token, duration, request count, and error labels handle boundary values")
  func formattingEdgeCases() {
    #expect(usageFormatUSD(0) == "$0.00")
    #expect(usageFormatUSD(Decimal(string: "0.000021")!) == "$0.000021")
    #expect(usageFormatUSD(Decimal(string: "0.0009999")!) == "$0.0010")
    #expect(usageFormatUSD(Decimal(string: "0.99999")!) == "$1.00")
    #expect(usageFormatUSD(Decimal(string: "12.5")!) == "$12.50")

    #expect(usageCompactTokens(999) == "999")
    #expect(usageCompactTokens(999_949) == "999.9K")
    #expect(usageCompactTokens(999_950) == "1.00M")

    #expect(usageDuration(999.4) == "999 ms")
    #expect(usageDuration(999.6) == "1.00 s")
    #expect(usageDuration(9_999.9) == "10.0 s")

    #expect(usageRequestCountLabel(0) == "0 requests")
    #expect(usageRequestCountLabel(1) == "1 request")
    #expect(usageRequestCountLabel(2) == "2 requests")

    #expect(usageCategoryTitle(.mcp) == "MCP")
    #expect(usageCategoryTitle(.provider) == "Provider")
    #expect(usageErrorTitle("provider_http") == "Provider HTTP")
    #expect(usageErrorTitle("invalid_base_url") == "Invalid Base URL")
    #expect(usageErrorTitle("unsupported_api_family") == "Unsupported API Family")
  }
}

@Suite("Sidebar helpers")
struct SidebarHelperTests {
  @Test("SidebarPinStore toggles, removes, prunes orphans, and clears cleanly")
  func pinStoreLifecycle() throws {
    let first = ConversationID(rawValue: "chat-1")
    let second = ConversationID(rawValue: "chat-2")
    let third = ConversationID(rawValue: "chat-3")

    var raw = SidebarPinStore.toggled(second, in: "")
    raw = SidebarPinStore.toggled(first, in: raw)
    #expect(SidebarPinStore.parse(raw) == [first.rawValue, second.rawValue])

    raw = SidebarPinStore.toggled(first, in: raw)
    #expect(SidebarPinStore.parse(raw) == [second.rawValue])

    raw = SidebarPinStore.toggled(third, in: raw)
    let pruned = SidebarPinStore.pruned(raw, keeping: [second])
    #expect(SidebarPinStore.parse(pruned) == [second.rawValue])

    let suiteName = "byokchat.tests.sidebarPins.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.set(raw, forKey: SidebarPinStore.storageKey)
    SidebarPinStore.prune(keeping: [third], in: defaults)
    #expect(defaults.string(forKey: SidebarPinStore.storageKey) == third.rawValue)

    SidebarPinStore.clear(in: defaults)
    #expect(defaults.string(forKey: SidebarPinStore.storageKey) == nil)
  }

  @Test("Sidebar search subtitles avoid duplicating titles on title matches")
  func searchSubtitleDeduplicatesTitleMatches() {
    let conversationID = ConversationID(rawValue: "chat-pricing")
    let titleMatch = ConversationSearchResult(
      conversationID: conversationID,
      messageID: nil,
      role: .title,
      title: "Pricing Comparison",
      snippet: "Pricing Comparison",
      updatedAt: .now
    )
    let summaryWithPreview = ChatConversation(
      id: conversationID,
      title: "Pricing Comparison",
      providerID: "openai",
      accountID: "acct-1",
      modelID: "gpt-4o",
      indexedMessageCount: 2,
      indexedLastMessagePreview: "The new tier lowers input token cost by 30%."
    )
    let summaryWithoutPreview = ChatConversation(
      id: conversationID,
      title: "Pricing Comparison",
      providerID: "openai",
      accountID: "acct-1",
      modelID: "gpt-4o"
    )

    #expect(
      ChatSidebarView.searchSubtitle(for: titleMatch, summary: summaryWithPreview)
        == "The new tier lowers input token cost by 30%."
    )
    #expect(ChatSidebarView.searchSubtitle(for: titleMatch, summary: summaryWithoutPreview) == nil)
    #expect(ChatSidebarView.searchSubtitle(for: titleMatch, summary: nil) == nil)

    let messageMatch = ConversationSearchResult(
      conversationID: conversationID,
      messageID: ChatMessageID(rawValue: "msg-1"),
      role: .assistant,
      title: "Pricing Comparison",
      snippet: "…lowers input token cost by 30%…",
      updatedAt: .now
    )
    #expect(
      ChatSidebarView.searchSubtitle(for: messageMatch, summary: summaryWithPreview)
        == "…lowers input token cost by 30%…"
    )
  }
}

private actor PartiallyFailingCredentialVault: CredentialVault {
  private var values: [String: String] = [:]
  private var failingAccountIDs: Set<ProviderAccountID> = []

  func failRemoval(for accountID: ProviderAccountID) {
    failingAccountIDs.insert(accountID)
  }

  func secret(accountID: ProviderAccountID, field: String) -> String? {
    values["\(accountID.rawValue):\(field)"]
  }

  func setSecret(_ value: String?, accountID: ProviderAccountID, field: String) {
    let key = "\(accountID.rawValue):\(field)"
    if let value, !value.isEmpty { values[key] = value } else { values.removeValue(forKey: key) }
  }

  func removeAll(accountID: ProviderAccountID) throws {
    if failingAccountIDs.contains(accountID) {
      throw ProviderError.invalidRequest("Simulated Keychain delete failure for \(accountID.rawValue).")
    }
    let prefix = "\(accountID.rawValue):"
    for key in values.keys where key.hasPrefix(prefix) {
      values.removeValue(forKey: key)
    }
  }
}

@MainActor
private final class CallbackFlag {
  var called = false
}

@MainActor
@Suite("Data management")
struct DataManagementModelTests {
  private struct TestHarness {
    let model: DataPortabilityModel
    let providerWorkspace: ProviderWorkspaceStore
    let accountManager: ProviderAccountManager
    let providersModel: ProviderManagementModel
    let conversationStore: ConversationStore
    let chatsModel: ChatManagementModel
    let projectWorkspace: ProjectWorkspaceStore
    let projectsModel: ProjectManagementModel
    let mcpWorkspace: MCPWorkspaceStore
    let mcpVault: InMemoryMCPCredentialVault
    let mcpRuntime: MCPRemoteRuntime
    let mcpModel: MCPManagementModel
    let preferences: AppPreferencesModel
    let defaults: UserDefaults
    let defaultsSuiteName: String
  }

  private func makeHarness(
    providerVault: any CredentialVault = InMemoryCredentialVault()
  ) async throws -> TestHarness {
    let registry = try ProviderRegistry.builtIn()
    let providerWorkspace = ProviderWorkspaceStore(
      persistence: InMemoryProviderWorkspacePersistence()
    )
    let accountManager = ProviderAccountManager(
      registry: registry,
      workspace: providerWorkspace,
      vault: providerVault
    )
    let providerRuntime = ProviderRuntime(
      registry: registry,
      workspace: providerWorkspace,
      accounts: accountManager
    )
    let conversationStore = ConversationStore(
      persistence: InMemoryConversationWorkspacePersistence()
    )
    let projectWorkspace = ProjectWorkspaceStore(
      persistence: InMemoryProjectWorkspacePersistence()
    )
    let mcpWorkspace = MCPWorkspaceStore(
      persistence: InMemoryMCPWorkspacePersistence()
    )
    let mcpVault = InMemoryMCPCredentialVault()
    let mcpRuntime = MCPRemoteRuntime(workspace: mcpWorkspace, vault: mcpVault)
    let approvals = MCPToolApprovalCenter()
    let elicitations = MCPElicitationCenter()
    let toolRuntime = MCPConversationToolRuntime(
      localRuntime: ToolRuntime(),
      mcpRuntime: mcpRuntime,
      workspace: mcpWorkspace,
      projectWorkspace: projectWorkspace,
      approvals: approvals,
      elicitations: elicitations
    )
    let chatRuntime = ChatRuntime(
      providerRuntime: providerRuntime,
      providerWorkspace: providerWorkspace,
      conversations: conversationStore,
      toolRuntime: toolRuntime
    )

    let suiteName = "byokchat.tests.dataManagement.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    let preferences = AppPreferencesModel(defaults: defaults)

    let providersModel = ProviderManagementModel(
      registry: registry,
      workspace: providerWorkspace,
      accountManager: accountManager,
      runtime: providerRuntime
    )
    let projectsModel = ProjectManagementModel(workspace: projectWorkspace)
    let chatsModel = ChatManagementModel(
      providerWorkspace: providerWorkspace,
      conversations: conversationStore,
      runtime: chatRuntime,
      preferences: preferences,
      mcpWorkspace: mcpWorkspace,
      projectWorkspace: projectWorkspace
    )
    let mcpModel = MCPManagementModel(
      runtime: mcpRuntime,
      workspace: mcpWorkspace,
      projectWorkspace: projectWorkspace,
      approvals: approvals,
      elicitations: elicitations
    )
    let model = DataPortabilityModel(
      conversations: conversationStore,
      accountManager: accountManager,
      preferences: preferences,
      providersModel: providersModel,
      chatsModel: chatsModel,
      projectsModel: projectsModel,
      mcpModel: mcpModel
    )

    return TestHarness(
      model: model,
      providerWorkspace: providerWorkspace,
      accountManager: accountManager,
      providersModel: providersModel,
      conversationStore: conversationStore,
      chatsModel: chatsModel,
      projectWorkspace: projectWorkspace,
      projectsModel: projectsModel,
      mcpWorkspace: mcpWorkspace,
      mcpVault: mcpVault,
      mcpRuntime: mcpRuntime,
      mcpModel: mcpModel,
      preferences: preferences,
      defaults: defaults,
      defaultsSuiteName: suiteName
    )
  }

  @Test("Delete all conversations clears chats, pins, memberships, and MCP chat overrides while keeping configuration")
  func deleteAllConversationsCleansAllChatState() async throws {
    let harness = try await makeHarness()
    defer { harness.defaults.removePersistentDomain(forName: harness.defaultsSuiteName) }

    await harness.providersModel.load()
    await harness.projectsModel.load()
    await harness.mcpModel.load()
    await harness.chatsModel.load()

    let account = try await harness.accountManager.createAccount(
      kind: .openai,
      label: "OpenAI",
      credential: "sk-test",
      defaultModelID: "gpt-4o"
    )
    let project = try await harness.projectWorkspace.createProject(
      name: "Research",
      symbolName: "folder.fill",
      accentID: "blue",
      accountID: account.id,
      modelID: "gpt-4o",
      instructions: "Stay brief."
    )
    let server = MCPRemoteServer(
      id: "mcp-1",
      name: "Docs",
      endpoint: try #require(URL(string: "https://mcp.example.com/mcp")),
      authentication: MCPAuthentication(kind: .bearer)
    )
    try await harness.mcpRuntime.saveServer(server, credential: "mcp-secret")

    let conversation = try await harness.conversationStore.createConversation(
      providerID: account.providerID,
      accountID: account.id,
      modelID: "gpt-4o"
    )
    try await harness.projectWorkspace.assignConversation(conversation.id, to: project.id)
    try await harness.mcpWorkspace.setChatServerEnabled(
      true,
      serverID: server.id,
      conversationID: conversation.id
    )
    harness.defaults.set(conversation.id.rawValue, forKey: SidebarPinStore.storageKey)

    await harness.providersModel.reloadFromStorage()
    await harness.projectsModel.reloadFromStorage()
    await harness.mcpModel.reloadFromStorage()
    await harness.chatsModel.reloadFromStorage()

    let orphanSweepFlag = CallbackFlag()
    harness.model.onConversationsDeleted = {
      orphanSweepFlag.called = true
    }

    await harness.model.deleteAllConversations()

    #expect(harness.model.errorMessage == nil)
    #expect(harness.model.statusMessage == "All conversations deleted.")
    #expect(harness.chatsModel.conversations.isEmpty)
    #expect(harness.defaults.string(forKey: SidebarPinStore.storageKey) == nil)
    #expect(harness.projectsModel.projects.count == 1)
    #expect(harness.projectsModel.projectID(for: conversation.id) == nil)
    #expect(await harness.mcpWorkspace.snapshot().chatConfigurations == nil)
    #expect(harness.mcpModel.chatConfigurations.isEmpty)
    #expect(harness.providersModel.accounts.count == 1)
    #expect(harness.mcpModel.servers.count == 1)
    #expect(orphanSweepFlag.called)
  }

  @Test("Delete all credentials removes provider and MCP secrets while keeping configurations")
  func deleteAllCredentialsRemovesBothVaults() async throws {
    let harness = try await makeHarness()
    defer { harness.defaults.removePersistentDomain(forName: harness.defaultsSuiteName) }

    await harness.providersModel.load()
    await harness.projectsModel.load()
    await harness.mcpModel.load()
    await harness.chatsModel.load()

    let account = try await harness.accountManager.createAccount(
      kind: .openai,
      label: "OpenAI",
      credential: "sk-secret",
      defaultModelID: "gpt-4o"
    )
    let server = MCPRemoteServer(
      id: "mcp-1",
      name: "Docs",
      endpoint: try #require(URL(string: "https://mcp.example.com/mcp")),
      authentication: MCPAuthentication(kind: .bearer)
    )
    try await harness.mcpRuntime.saveServer(server, credential: "mcp-secret")

    await harness.providersModel.reloadFromStorage()
    await harness.mcpModel.reloadFromStorage()
    #expect(harness.providersModel.credentialAccountIDs.contains(account.id))
    #expect(harness.mcpModel.hasCredential(server.id))

    await harness.model.deleteAllCredentials()

    #expect(harness.model.errorMessage == nil)
    #expect(harness.model.statusMessage == "All credentials removed.")
    #expect(harness.providersModel.accounts.count == 1)
    #expect(harness.mcpModel.servers.count == 1)
    #expect(!harness.providersModel.credentialAccountIDs.contains(account.id))
    #expect(!harness.mcpModel.hasCredential(server.id))
    #expect(await harness.mcpVault.credential(serverID: server.id) == nil)
  }

  @Test("Partial credential deletion failure still wipes remaining credentials and reloads models")
  func deleteAllCredentialsPartialFailureStillCleansAndReloads() async throws {
    let vault = PartiallyFailingCredentialVault()
    let harness = try await makeHarness(providerVault: vault)
    defer { harness.defaults.removePersistentDomain(forName: harness.defaultsSuiteName) }

    await harness.providersModel.load()
    await harness.projectsModel.load()
    await harness.mcpModel.load()
    await harness.chatsModel.load()

    let healthyAccount = try await harness.accountManager.createAccount(
      kind: .openai,
      label: "Healthy",
      credential: "sk-healthy",
      defaultModelID: "gpt-4o"
    )
    let failingAccount = try await harness.accountManager.createAccount(
      kind: .anthropic,
      label: "Failing",
      credential: "sk-failing",
      defaultModelID: "claude-sonnet-4-5"
    )
    await vault.failRemoval(for: failingAccount.id)

    let server = MCPRemoteServer(
      id: "mcp-1",
      name: "Docs",
      endpoint: try #require(URL(string: "https://mcp.example.com/mcp")),
      authentication: MCPAuthentication(kind: .bearer)
    )
    try await harness.mcpRuntime.saveServer(server, credential: "mcp-secret")

    await harness.providersModel.reloadFromStorage()
    await harness.mcpModel.reloadFromStorage()
    #expect(harness.providersModel.credentialAccountIDs.contains(healthyAccount.id))
    #expect(harness.providersModel.credentialAccountIDs.contains(failingAccount.id))
    #expect(harness.mcpModel.hasCredential(server.id))

    await harness.model.deleteAllCredentials()

    // Error is surfaced and success toast is suppressed, yet all other keys were wiped and UI reloaded.
    #expect(harness.model.errorMessage != nil)
    #expect(harness.model.statusMessage == nil)
    #expect(!harness.providersModel.credentialAccountIDs.contains(healthyAccount.id))
    #expect(harness.providersModel.credentialAccountIDs.contains(failingAccount.id))
    #expect(!harness.mcpModel.hasCredential(server.id))
    #expect(await harness.mcpVault.credential(serverID: server.id) == nil)
  }
}
