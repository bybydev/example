import BYOKchatProviderCore
import Foundation
import Testing

@testable import BYOKmac

@MainActor
@Suite("macOS chat session core correctness")
struct MacChatSessionModelTests {
  @Test("Conversation delete commits primary mutation and treats cleanup failures as warnings")
  func deletionCleanupIsBestEffort() async throws {
    var primaryDeleted = false
    var projectCleanupAttempted = false

    let warnings = try await performMacConversationDeletion(
      deleteConversation: {
        primaryDeleted = true
      },
      removeMCPConfiguration: {
        throw MacChatSessionTestError.injectedCleanup
      },
      removeProjectReference: {
        projectCleanupAttempted = true
        throw MacChatSessionTestError.injectedCleanup
      }
    )

    #expect(primaryDeleted)
    #expect(projectCleanupAttempted)
    #expect(warnings.count == 2)
    #expect(warnings[0].contains("Tool configuration cleanup failed"))
    #expect(warnings[1].contains("Project reference cleanup failed"))
  }

  @Test("Conversation delete never runs secondary cleanup when primary delete fails")
  func deletionStopsOnPrimaryFailure() async {
    var cleanupAttempted = false

    await #expect(throws: MacChatSessionTestError.self) {
      _ = try await performMacConversationDeletion(
        deleteConversation: {
          throw MacChatSessionTestError.injectedPrimary
        },
        removeMCPConfiguration: {
          cleanupAttempted = true
        },
        removeProjectReference: {
          cleanupAttempted = true
        }
      )
    }

    #expect(!cleanupAttempted)
  }

  @Test("Successful model delete removes persisted and presentation state")
  func modelDeleteRemovesConversation() async throws {
    let context = try await makeMacCoreTestContext()
    defer { context.cleanup() }

    let conversation = try await context.services.conversationStore.createConversation(
      providerID: "deepseek",
      accountID: "test-account",
      modelID: "deepseek-v4-flash"
    )
    let providers = MacProviderModel(services: context.services)
    let session = MacChatSessionModel(
      services: context.services,
      providers: providers,
      preferences: context.preferences,
      initialSummaries: await context.services.conversationStore.conversationSummaries()
    )
    await session.loadConversation(conversation.id)
    session.setDraft("pending text", conversationID: conversation.id)

    #expect(await session.deleteConversation(conversation.id))
    #expect(!(await context.services.conversationStore.containsConversation(conversation.id)))
    #expect(session.summary(conversation.id) == nil)
    #expect(session.conversation(conversation.id) == nil)
    #expect(session.errorMessage == nil)
  }

  @Test("Preparing a cached chat does not republish unchanged sidebar summaries")
  func preparationPreservesSummaryIdentity() async throws {
    let context = try await makeMacCoreTestContext()
    defer { context.cleanup() }
    let conversation = try await context.services.conversationStore.createConversation(
      providerID: "deepseek", accountID: "test-account", modelID: "deepseek-v4-flash"
    )
    let session = MacChatSessionModel(
      services: context.services,
      providers: MacProviderModel(services: context.services),
      preferences: context.preferences,
      initialSummaries: await context.services.conversationStore.conversationSummaries()
    )
    var summaryPublications = 0
    session.onSummariesChanged = { _ in summaryPublications += 1 }
    async let first = session.prepareConversation(conversation.id)
    async let second = session.prepareConversation(conversation.id)
    let prepared = try await [first, second]
    #expect(prepared.allSatisfy { $0.id == conversation.id })
    #expect(session.conversation(conversation.id) != nil)
    #expect(summaryPublications == 0)
  }

  @Test("Pending draft survives a conversation reload and persists latest value")
  func pendingDraftSurvivesReload() async throws {
    let context = try await makeMacCoreTestContext()
    defer { context.cleanup() }

    let conversation = try await context.services.conversationStore.createConversation(
      providerID: "deepseek",
      accountID: "test-account",
      modelID: "deepseek-v4-flash"
    )
    let session = MacChatSessionModel(
      services: context.services,
      providers: MacProviderModel(services: context.services),
      preferences: context.preferences,
      initialSummaries: await context.services.conversationStore.conversationSummaries()
    )
    await session.loadConversation(conversation.id)

    session.setDraft("still typing", conversationID: conversation.id)
    #expect(await session.renameConversation(conversation.id, title: "Renamed"))
    #expect(session.draft(for: conversation.id) == "still typing")

    try await Task.sleep(for: .milliseconds(350))
    let persisted = try await context.services.conversationStore.conversation(id: conversation.id)
    #expect(persisted.draftText == "still typing")
  }

  @Test("Rapid draft changes persist the newest value")
  func rapidDraftChangesPersistLatestValue() async throws {
    let context = try await makeMacCoreTestContext()
    defer { context.cleanup() }

    let conversation = try await context.services.conversationStore.createConversation(
      providerID: "deepseek",
      accountID: "test-account",
      modelID: "deepseek-v4-flash"
    )
    let session = MacChatSessionModel(
      services: context.services,
      providers: MacProviderModel(services: context.services),
      preferences: context.preferences,
      initialSummaries: await context.services.conversationStore.conversationSummaries()
    )
    await session.loadConversation(conversation.id)

    session.setDraft("one", conversationID: conversation.id)
    session.setDraft("two", conversationID: conversation.id)
    session.setDraft("three", conversationID: conversation.id)

    try await Task.sleep(for: .milliseconds(350))
    let persisted = try await context.services.conversationStore.conversation(id: conversation.id)
    #expect(persisted.draftText == "three")
    #expect(session.draft(for: conversation.id) == "three")
  }

  @Test("Failed first-chat project assignment rolls back the empty conversation")
  func failedProjectAssignmentRollsBackNewConversation() async throws {
    let context = try await makeMacCoreTestContext()
    defer { context.cleanup() }

    let account = try await context.services.accountManager.createAccount(
      kind: .deepSeek,
      label: "Test DeepSeek",
      credential: "test-key",
      defaultModelID: "deepseek-v4-flash"
    )
    try await context.services.providerWorkspace.mergeModels(
      ProviderKind.deepSeek.seedModels,
      for: account.id
    )

    let providers = MacProviderModel(services: context.services)
    try await providers.load()
    let target = try #require(providers.preferredTarget())
    let session = MacChatSessionModel(
      services: context.services,
      providers: providers,
      preferences: context.preferences,
      initialSummaries: await context.services.conversationStore.conversationSummaries()
    )

    let missingProjectID = ProjectID(rawValue: "missing-project")
    session.queueNewChat(
      projectID: missingProjectID,
      initialDraft: "hello",
      target: target
    )
    session.resetNewChat()

    let result = await session.send(conversationID: nil, text: "hello")

    #expect(result == nil)
    #expect((await context.services.conversationStore.conversationSummaries()).isEmpty)
    let projectSnapshot = await context.services.projectWorkspace.snapshot()
    #expect(projectSnapshot.conversationProjectIDs.isEmpty)
    #expect(session.draft(for: nil) == "hello")
    #expect(session.errorMessage != nil)
  }

  @Test("Search deduplication preserves matched messageID when a message matches")
  func searchItemsPreservesMatchedMessageIDDuringDeduplication() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let results = [
      ConversationSearchResult(
        conversationID: "conv-both",
        messageID: nil,
        role: .title,
        title: "Swift Concurrency",
        snippet: "Swift Concurrency",
        updatedAt: now
      ),
      ConversationSearchResult(
        conversationID: "conv-title-only",
        messageID: nil,
        role: .title,
        title: "Swift Notes",
        snippet: "Swift Notes",
        updatedAt: now.addingTimeInterval(-10)
      ),
      ConversationSearchResult(
        conversationID: "conv-both",
        messageID: "msg-match-1",
        role: .assistant,
        title: "Swift Concurrency",
        snippet: "Use actors for Swift Concurrency isolation.",
        updatedAt: now.addingTimeInterval(-20)
      ),
      ConversationSearchResult(
        conversationID: "conv-both",
        messageID: "msg-match-2",
        role: .user,
        title: "Swift Concurrency",
        snippet: "Second match should not replace first message match.",
        updatedAt: now.addingTimeInterval(-30)
      ),
      ConversationSearchResult(
        conversationID: "conv-message-only",
        messageID: "msg-only",
        role: .user,
        title: "Unrelated Title",
        snippet: "Question about Swift actors",
        updatedAt: now.addingTimeInterval(-40)
      ),
    ]

    let items = MacChatSessionModel.searchItems(from: results)

    #expect(items.map(\.conversationID) == ["conv-both", "conv-title-only", "conv-message-only"])
    #expect(items[0].messageID == "msg-match-1")
    #expect(items[0].role == .assistant)
    #expect(items[0].snippet == "Use actors for Swift Concurrency isolation.")
    #expect(items[1].messageID == nil)
    #expect(items[1].role == .title)
    #expect(items[2].messageID == "msg-only")
    #expect(items[2].role == .user)
  }

  @Test("Session search retains messageID for deep-linking to matched content")
  func updateSearchRetainsMessageIDForContentMatches() async throws {
    let context = try await makeMacCoreTestContext()
    defer { context.cleanup() }

    let conversation = try await context.services.conversationStore.createConversation(
      providerID: "deepseek",
      accountID: "test-account",
      modelID: "deepseek-v4-flash"
    )
    try await context.services.conversationStore.renameConversation(
      conversation.id,
      title: "Architecture Notes"
    )
    let turn = try await context.services.conversationStore.beginTurn(
      conversationID: conversation.id,
      userText: "Explain deterministic xylophone indexing in detail"
    )

    let session = MacChatSessionModel(
      services: context.services,
      providers: MacProviderModel(services: context.services),
      preferences: context.preferences,
      initialSummaries: await context.services.conversationStore.conversationSummaries()
    )

    session.updateSearch("xylophone")
    try await Task.sleep(for: .milliseconds(300))

    let item = try #require(session.searchItems.first)
    #expect(item.conversationID == conversation.id)
    #expect(item.messageID == turn.userMessage.id)
    #expect(item.role == .user)
    #expect(!session.isSearching)
  }

  @Test("Per-chat settings persist on existing conversations and respect OpenRouter routing scope")
  func updateChatSettingsPersistsOnExistingConversation() async throws {
    let context = try await makeMacCoreTestContext()
    defer { context.cleanup() }

    let openRouter = try await context.services.accountManager.createAccount(
      kind: .openRouter,
      label: "OpenRouter",
      credential: "or-key",
      defaultModelID: "openai/gpt-4o"
    )
    try await context.services.providerWorkspace.addManualModel(
      ProviderModel(providerID: openRouter.providerID, id: "openai/gpt-4o", displayName: "GPT-4o"),
      for: openRouter.id
    )
    let deepSeek = try await context.services.accountManager.createAccount(
      kind: .deepSeek,
      label: "DeepSeek",
      credential: "ds-key",
      defaultModelID: "deepseek-v4-flash"
    )
    try await context.services.providerWorkspace.mergeModels(
      ProviderKind.deepSeek.seedModels,
      for: deepSeek.id
    )

    let providers = MacProviderModel(services: context.services)
    try await providers.load()

    let orConversation = try await context.services.conversationStore.createConversation(
      providerID: openRouter.providerID,
      accountID: openRouter.id,
      modelID: "openai/gpt-4o"
    )
    let dsConversation = try await context.services.conversationStore.createConversation(
      providerID: deepSeek.providerID,
      accountID: deepSeek.id,
      modelID: "deepseek-v4-flash"
    )

    let session = MacChatSessionModel(
      services: context.services,
      providers: providers,
      preferences: context.preferences,
      initialSummaries: await context.services.conversationStore.conversationSummaries()
    )

    let routing = OpenRouterRoutingOptions(
      providerOrder: ["anthropic", "openai"],
      allowFallbacks: false,
      requireParameters: true,
      dataCollection: .deny,
      zeroDataRetention: true,
      sort: .latency
    )
    let options = ProviderRequestOptions(
      temperature: 0.45,
      topP: 0.9,
      maxOutputTokens: 2_048,
      openRouterRouting: routing
    )

    #expect(
      await session.updateChatSettings(
        conversationID: orConversation.id,
        systemPrompt: "  Be concise.  ",
        options: options
      )
    )
    let persistedOR = try await context.services.conversationStore.conversation(id: orConversation.id)
    #expect(persistedOR.systemPrompt == "Be concise.")
    #expect(persistedOR.options.temperature == 0.45)
    #expect(persistedOR.options.topP == 0.9)
    #expect(persistedOR.options.maxOutputTokens == 2_048)
    #expect(persistedOR.options.openRouterRouting == routing)

    // Non-OpenRouter conversations strip OpenRouter routing automatically.
    #expect(
      await session.updateChatSettings(
        conversationID: dsConversation.id,
        systemPrompt: "Answer with bullets.",
        options: options
      )
    )
    let persistedDS = try await context.services.conversationStore.conversation(id: dsConversation.id)
    #expect(persistedDS.systemPrompt == "Answer with bullets.")
    #expect(persistedDS.options.temperature == 0.45)
    #expect(persistedDS.options.maxOutputTokens == 2_048)
    #expect(persistedDS.options.openRouterRouting == nil)
  }

  @Test("Pre-send chat settings and MCP configuration apply on createConversation and clear on resetNewChat")
  func preSendSettingsAndMCPPersistAndReset() async throws {
    let context = try await makeMacCoreTestContext()
    defer { context.cleanup() }

    let account = try await context.services.accountManager.createAccount(
      kind: .openRouter,
      label: "OpenRouter",
      credential: "or-key",
      defaultModelID: "openai/gpt-4o"
    )
    try await context.services.providerWorkspace.addManualModel(
      ProviderModel(providerID: account.providerID, id: "openai/gpt-4o", displayName: "GPT-4o"),
      for: account.id
    )

    let server = MCPRemoteServer(
      id: "pre-send-server",
      name: "Docs MCP",
      endpoint: URL(string: "https://docs.example.com/mcp")!,
      isEnabled: true
    )
    try await context.services.mcpWorkspace.upsertServer(server)

    let providers = MacProviderModel(services: context.services)
    try await providers.load()
    let session = MacChatSessionModel(
      services: context.services,
      providers: providers,
      preferences: context.preferences,
      initialSummaries: await context.services.conversationStore.conversationSummaries()
    )

    let routing = OpenRouterRoutingOptions(
      providerOrder: ["openai"],
      zeroDataRetention: true,
      sort: .price
    )
    let draftOptions = ProviderRequestOptions(
      temperature: 0.3,
      topP: 0.85,
      maxOutputTokens: 1_500,
      openRouterRouting: routing
    )
    let draftMCP = MCPChatToolConfiguration(
      enabledServerIDs: [server.id],
      toolPolicies: ["mcp_docs_search": .alwaysAllow]
    )

    // Stage pre-send settings, then verify resetNewChat clears them.
    #expect(
      await session.updateChatSettings(
        conversationID: nil,
        systemPrompt: "Temporary prompt",
        options: draftOptions
      )
    )
    session.setNewChatMCPConfiguration(draftMCP)
    #expect(session.newChatSystemPromptOverride == "Temporary prompt")
    #expect(session.newChatOptions.temperature == 0.3)
    #expect(session.newChatMCPConfiguration == draftMCP)

    session.resetNewChat()
    #expect(session.newChatSystemPromptOverride == nil)
    #expect(session.newChatOptions == ProviderRequestOptions())
    #expect(session.newChatMCPConfiguration == nil)

    // Re-stage settings and send the first message to verify persistence on createConversation.
    #expect(
      await session.updateChatSettings(
        conversationID: nil,
        systemPrompt: "Custom pre-send prompt",
        options: draftOptions
      )
    )
    session.setNewChatMCPConfiguration(draftMCP)

    let createdID = try #require(await session.send(conversationID: nil, text: "Hello"))
    await session.stop(createdID)

    let persisted = try await context.services.conversationStore.conversation(id: createdID)
    #expect(persisted.systemPrompt == "Custom pre-send prompt")
    #expect(persisted.options.temperature == 0.3)
    #expect(persisted.options.topP == 0.85)
    #expect(persisted.options.maxOutputTokens == 1_500)
    #expect(persisted.options.openRouterRouting == routing)

    let persistedMCP = await context.services.mcpWorkspace.explicitChatConfiguration(for: createdID)
    #expect(persistedMCP == draftMCP)

    // Staging state resets once the conversation has been created.
    #expect(session.newChatSystemPromptOverride == nil)
    #expect(session.newChatOptions == ProviderRequestOptions())
    #expect(session.newChatMCPConfiguration == nil)
  }

  @Test("Configuration issue detection reports broken provider, account, credential, model, and Pro restrictions")
  func configurationIssueDetection() async throws {
    let context = try await makeMacCoreTestContext()
    defer { context.cleanup() }

    let account = try await context.services.accountManager.createAccount(
      kind: .deepSeek,
      label: "Primary DeepSeek",
      credential: "ds-key",
      defaultModelID: "deepseek-v4-flash"
    )
    try await context.services.providerWorkspace.mergeModels(
      ProviderKind.deepSeek.seedModels,
      for: account.id
    )
    let localAccount = try await context.services.accountManager.createAccount(
      kind: .ollama,
      label: "Local Ollama",
      credential: nil,
      defaultModelID: "llama3.2"
    )
    try await context.services.providerWorkspace.addManualModel(
      ProviderModel(providerID: localAccount.providerID, id: "llama3.2", displayName: "Llama 3.2"),
      for: localAccount.id
    )

    let providers = MacProviderModel(services: context.services)
    try await providers.load()
    let session = MacChatSessionModel(
      services: context.services,
      providers: providers,
      preferences: context.preferences,
      initialSummaries: []
    )

    // Healthy cloud conversation and credential-less local Ollama conversation.
    let healthyCloud = ChatConversation(
      providerID: account.providerID,
      accountID: account.id,
      modelID: "deepseek-v4-flash"
    )
    #expect(session.configurationIssue(for: healthyCloud) == nil)

    let healthyLocal = ChatConversation(
      providerID: localAccount.providerID,
      accountID: localAccount.id,
      modelID: "llama3.2"
    )
    #expect(session.configurationIssue(for: healthyLocal) == nil)
    #expect(session.newChatSetupReadiness(project: nil) == .ready)

    // Missing provider definition.
    let missingProvider = ChatConversation(
      providerID: "nonexistent-provider",
      accountID: account.id,
      modelID: "deepseek-v4-flash"
    )
    #expect(session.configurationIssue(for: missingProvider) == .providerMissing)

    // Deleted account.
    let missingAccount = ChatConversation(
      providerID: account.providerID,
      accountID: "deleted-account",
      modelID: "deepseek-v4-flash"
    )
    #expect(session.configurationIssue(for: missingAccount) == .accountMissing)

    // Missing model.
    let missingModel = ChatConversation(
      providerID: account.providerID,
      accountID: account.id,
      modelID: "unknown-model"
    )
    #expect(session.configurationIssue(for: missingModel) == .modelMissing(modelID: "unknown-model"))

    // Missing credential on cloud account.
    try await context.services.accountManager.setCredential(nil, accountID: account.id)
    await providers.reload()
    #expect(
      session.configurationIssue(for: healthyCloud)
        == .missingCredential(label: "Primary DeepSeek")
    )

    // Disabled account.
    #expect(await providers.setAccountEnabled(false, accountID: account.id))
    #expect(
      session.configurationIssue(for: healthyCloud)
        == .accountDisabled(label: "Primary DeepSeek")
    )

    // Pro-restricted restored account.
    let suiteName = "byok-mac-config-issue-restrictions-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let restrictions = MacProResourceRestrictions(defaults: defaults, keyPrefix: "test")
    restrictions.recordFullBackupImport(
      before: MacProResourceSnapshot(),
      after: MacProResourceSnapshot(
        providerAccountIDs: [localAccount.id.rawValue, account.id.rawValue]
      ),
      strategy: .replaceExisting,
      entitlement: .free
    )
    let restrictedProviders = MacProviderModel(
      services: context.services,
      restrictions: restrictions,
      entitlementAccessOverride: .free
    )
    try await restrictedProviders.load()
    let restrictedSession = MacChatSessionModel(
      services: context.services,
      providers: restrictedProviders,
      preferences: context.preferences,
      initialSummaries: [],
      restrictions: restrictions
    )
    #expect(
      restrictedSession.configurationIssue(for: healthyCloud)
        == .accountRestricted(label: "Primary DeepSeek")
    )
  }

  @Test("Chat settings validation helpers and Markdown filename sanitization match rules")
  func chatSettingsAndExportHelpers() {
    #expect(MacChatSettingsSupport.temperatureRange(for: .minimax) == 0.01...1.0)
    #expect(MacChatSettingsSupport.temperatureRange(for: .openai) == 0.0...2.0)
    #expect(MacChatSettingsSupport.clampedTemperature(1.8, for: .minimax) == 1.0)
    #expect(MacChatSettingsSupport.clampedTopP(0.01) == 0.05)

    #expect(
      MacChatSettingsSupport.parseMaxOutputTokens("", maxAllowed: 4_096, anthropicReasoningBudget: nil).error
        == nil
    )
    #expect(
      MacChatSettingsSupport.parseMaxOutputTokens("0", maxAllowed: 4_096, anthropicReasoningBudget: nil).error
        != nil
    )
    #expect(
      MacChatSettingsSupport.parseMaxOutputTokens("8192", maxAllowed: 4_096, anthropicReasoningBudget: nil).error
        != nil
    )
    #expect(
      MacChatSettingsSupport.parseMaxOutputTokens("1024", maxAllowed: 8_192, anthropicReasoningBudget: 1_024).error
        != nil
    )
    #expect(
      MacChatSettingsSupport.parseMaxOutputTokens("2048", maxAllowed: 8_192, anthropicReasoningBudget: 1_024).value
        == 2_048
    )

    #expect(
      MacChatSettingsSupport.parseProviderOrder("anthropic, openai, anthropic\ngoogle")
        == ["anthropic", "openai", "google"]
    )
    #expect(MacChatSettingsSupport.normalizedOpenRouterRouting(OpenRouterRoutingOptions()) == nil)
    #expect(
      MacChatSettingsSupport.normalizedOpenRouterRouting(
        OpenRouterRoutingOptions(zeroDataRetention: true)
      )?.zeroDataRetention == true
    )

    #expect(
      MacConversationExportSupport.markdownFilename(for: "Swift 6: Strict Concurrency?!")
        == "Swift-6-Strict-Concurrency"
    )
    #expect(
      MacConversationExportSupport.markdownFilename(for: "   ") == "BYOKchat-conversation"
    )
  }
}

private enum MacChatSessionTestError: Error {
  case injectedPrimary
  case injectedCleanup
}

@MainActor
private struct MacCoreTestContext {
  let parent: URL
  let suiteName: String
  let storage: BYOKStorageEnvironment
  let services: BYOKCoreServices
  let preferences: MacPreferencesModel

  func cleanup() {
    try? FileManager.default.removeItem(at: parent)
    UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
  }
}

@MainActor
private func makeMacCoreTestContext() async throws -> MacCoreTestContext {
  let parent = FileManager.default.temporaryDirectory
    .appendingPathComponent("byok-mac-chat-tests-\(UUID().uuidString)", isDirectory: true)
  let root = parent.appendingPathComponent("Workspace", isDirectory: true)
  let telemetry = parent.appendingPathComponent("Telemetry", isDirectory: true)
  let suiteName = "byok-mac-chat-tests-\(UUID().uuidString)"
  let storage = BYOKStorageEnvironment(
    rootDirectory: root,
    userDefaultsSuiteName: suiteName,
    credentialService: "tests.byok.mac.credentials.\(UUID().uuidString)",
    mcpCredentialService: "tests.byok.mac.mcp.\(UUID().uuidString)",
    telemetryDirectory: telemetry
  )

  try await BYOKStorageBootstrap.prepare(environment: storage)
  let services = try BYOKCoreServices(
    environment: storage,
    credentialVault: InMemoryCredentialVault(),
    mcpCredentialVault: InMemoryMCPCredentialVault()
  )
  try await services.loadStoredState()

  let defaults = try #require(UserDefaults(suiteName: suiteName))
  return MacCoreTestContext(
    parent: parent,
    suiteName: suiteName,
    storage: storage,
    services: services,
    preferences: MacPreferencesModel(defaults: defaults)
  )
}

@MainActor
@Suite("Prepared macOS chat navigation")
struct MacChatNavigationTests {
  private func prepared(_ id: ConversationID) -> MacPreparedConversation {
    MacPreparedConversation(id: id, conversation: nil, answers: [:])
  }

  @Test("A slow earlier selection cannot replace a later selected chat")
  func latestSelectionWins() async {
    let navigation = MacChatNavigation()
    navigation.requestedID = "a"
    await navigation.prepareSelection(using: prepared)
    let gate = MacChatPreparationGate()
    navigation.requestedID = "b"
    let slow = Task { await navigation.prepareSelection { _ in try await gate.wait() } }
    await gate.waitUntilStarted()
    #expect(navigation.displayedID == "a")
    #expect(navigation.isPreparing)
    #expect(!navigation.canFollowSend(from: "a"))

    navigation.requestedID = "c"
    await navigation.prepareSelection(using: prepared)
    gate.finish(with: prepared("b"))
    await slow.value
    #expect(navigation.displayedID == "c")
    #expect(!navigation.isPreparing)
    #expect(!navigation.retainedConversations.contains { $0.id == "b" })
  }

  @Test("New chat supersedes a pending load")
  func newChatWinsOverPendingLoad() async {
    let navigation = MacChatNavigation()
    let gate = MacChatPreparationGate()
    navigation.requestedID = "pending"
    let slow = Task { await navigation.prepareSelection { _ in try await gate.wait() } }
    await gate.waitUntilStarted()
    navigation.requestedID = nil
    await navigation.prepareSelection(using: prepared)
    gate.finish(with: prepared("pending"))
    await slow.value
    #expect(navigation.displayedID == nil)
    #expect(navigation.requestedID == nil)
    #expect(navigation.canFollowSend(from: nil))
  }

  @Test("Failed preparation keeps the displayed chat and restores sidebar selection")
  func failureKeepsDisplayedChat() async {
    let navigation = MacChatNavigation()
    navigation.requestedID = "a"
    await navigation.prepareSelection(using: prepared)
    navigation.requestedID = "b"
    await navigation.prepareSelection { _ in throw MacChatSessionTestError.injectedPrimary }
    #expect(navigation.displayedID == "a")
    #expect(navigation.requestedID == "a")
    #expect(navigation.errorMessage != nil)
    #expect(!navigation.isPreparing)
  }

  @Test("Recent transcripts are reused and retention is bounded to three")
  func boundedRetention() async {
    let navigation = MacChatNavigation()
    var preparations = 0
    for id: ConversationID in ["a", "b", "c", "a", "d"] {
      navigation.requestedID = id
      await navigation.prepareSelection { id in
        preparations += 1
        return prepared(id)
      }
      #expect(navigation.retainedConversations.count <= 3)
    }
    #expect(preparations == 4)
    #expect(navigation.retainedConversations.map(\.id) == ["c", "a", "d"])
    navigation.removeDeletedConversations(validIDs: ["a", "c"])
    #expect(navigation.displayedID == nil)
    #expect(navigation.requestedID == "a")
    #expect(!navigation.retainedConversations.contains { $0.id == "d" })
  }

  @Test("Source-message navigation survives preparation and is cleared by another selection")
  func sourceNavigationSurvivesPreparation() async {
    let navigation = MacChatNavigation()
    let gate = MacChatPreparationGate()
    navigation.requestedID = "a"
    let slow = Task { await navigation.prepareSelection { _ in try await gate.wait() } }
    await gate.waitUntilStarted()
    let request = MacConversationNavigationRequest(conversationID: "a", messageID: "message")
    navigation.navigateToMessage(request)
    gate.finish(with: prepared("a"))
    await slow.value
    #expect(navigation.messageTarget?.request == request)
    navigation.requestedID = "b"
    #expect(navigation.messageTarget == nil)
  }
}

@MainActor
private final class MacChatPreparationGate {
  private var continuation: CheckedContinuation<MacPreparedConversation, Error>?
  private var started: CheckedContinuation<Void, Never>?

  func wait() async throws -> MacPreparedConversation {
    try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      started?.resume()
      started = nil
    }
  }

  func waitUntilStarted() async {
    if continuation != nil { return }
    await withCheckedContinuation { started = $0 }
  }

  func finish(with value: MacPreparedConversation) {
    continuation?.resume(returning: value)
    continuation = nil
  }
}

@Suite("Prepared Markdown cache")
struct MacPreparedAnswerCacheTests {
  @Test("Prepared Markdown trees are reused across row lifetimes")
  func reusesParsedMarkdown() async throws {
    let cache = MacAnswerContentParseCache()
    let source = "| Name | Value |\n| --- | ---: |\n| One | **2** |"
    let first = try await cache.answer(for: source)
    let second = try await cache.answer(for: source)
    #expect(first === second)
    #expect(cache.cachedAnswer(for: source) === first)
    let markdown = try #require(first.markdown[source])
    #expect(markdown.renderPlainText().contains("One"))
    let changed = try await cache.answer(for: source + "\n\nUpdated")
    #expect(changed !== first)
  }

  @Test("Least recently used entries are evicted and pinned results stay valid")
  func evictsOldEntries() async throws {
    let cache = MacAnswerContentParseCache(limit: 2)
    let pinned = try await cache.answer(for: "one")
    _ = try await cache.answer(for: "two")
    _ = cache.cachedAnswer(for: "one")
    _ = try await cache.answer(for: "three")
    #expect(cache.cachedAnswer(for: "two") == nil)
    #expect(cache.cachedAnswer(for: "one") === pinned)
    #expect(pinned.blocks == [.markdown("one")])
  }

  @Test("Source-byte budget bounds shared cache retention")
  func sourceBudget() async throws {
    let cache = MacAnswerContentParseCache(limit: 10, byteLimit: 6)
    _ = try await cache.answer(for: "one")
    _ = try await cache.answer(for: "four")
    #expect(cache.cachedAnswer(for: "one") == nil)
    let oversized = try await cache.answer(for: "a longer answer")
    #expect(cache.cachedAnswer(for: oversized.source) == nil)
    #expect(!oversized.blocks.isEmpty)
  }
}

@Suite("macOS sidebar date grouping and search subtitles")
struct MacSidebarGroupingTests {
  private func makeConversation(
    id: ConversationID,
    title: String = "Chat",
    updatedAt: Date,
    preview: String? = nil
  ) -> ChatConversation {
    ChatConversation(
      id: id,
      title: title,
      createdAt: updatedAt,
      updatedAt: updatedAt,
      providerID: "deepseek",
      accountID: "account-1",
      modelID: "deepseek-v4-flash",
      indexedMessageCount: preview == nil ? 0 : 2,
      indexedLastMessagePreview: preview
    )
  }

  @Test("Groups pinned conversations first and unpinned conversations into date buckets")
  func groupsPinnedAndDateBuckets() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let locale = Locale(identifier: "en_US_POSIX")
    let now = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 4, day: 15, hour: 15, minute: 0))
    )

    let pinnedOld = makeConversation(
      id: "pinned-old",
      updatedAt: try #require(calendar.date(byAdding: .day, value: -90, to: now))
    )
    let todayChat = makeConversation(
      id: "today",
      updatedAt: try #require(calendar.date(byAdding: .hour, value: -2, to: now))
    )
    let yesterdayChat = makeConversation(
      id: "yesterday",
      updatedAt: try #require(calendar.date(byAdding: .day, value: -1, to: now))
    )
    let last7Chat = makeConversation(
      id: "last7",
      updatedAt: try #require(calendar.date(byAdding: .day, value: -5, to: now))
    )
    let last30Chat = makeConversation(
      id: "last30",
      updatedAt: try #require(calendar.date(byAdding: .day, value: -20, to: now))
    )
    let febChat = makeConversation(
      id: "feb",
      updatedAt: try #require(calendar.date(from: DateComponents(year: 2026, month: 2, day: 10, hour: 12)))
    )
    let janChat = makeConversation(
      id: "jan",
      updatedAt: try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 20, hour: 12)))
    )

    let sections = MacChatListGrouping.sections(
      from: [janChat, last30Chat, pinnedOld, yesterdayChat, febChat, todayChat, last7Chat],
      pinnedIDs: [pinnedOld.id.rawValue],
      now: now,
      calendar: calendar,
      locale: locale
    )

    #expect(sections.map(\.id) == [
      "pinned",
      "today",
      "yesterday",
      "last7days",
      "last30days",
      "month-2026-2",
      "month-2026-1",
    ])
    #expect(sections.map(\.title) == [
      "Pinned",
      "Today",
      "Yesterday",
      "Previous 7 Days",
      "Previous 30 Days",
      "February 2026",
      "January 2026",
    ])
    #expect(sections[0].isPinned)
    #expect(sections[0].conversations.map(\.id) == ["pinned-old"])
    #expect(sections[1].conversations.map(\.id) == ["today"])
    #expect(sections[2].conversations.map(\.id) == ["yesterday"])
    #expect(sections[3].conversations.map(\.id) == ["last7"])
    #expect(sections[4].conversations.map(\.id) == ["last30"])
    #expect(sections[5].conversations.map(\.id) == ["feb"])
    #expect(sections[6].conversations.map(\.id) == ["jan"])
  }

  @Test("Title-match search results fall back to the conversation's last message preview")
  func searchSubtitleFallsBackToPreviewOnTitleMatch() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let summary = makeConversation(
      id: "conv-1",
      title: "SwiftUI Tips",
      updatedAt: now,
      preview: "Use LazyVStack inside ScrollView."
    )

    let titleItem = MacChatSessionModel.SearchItem(
      conversationID: "conv-1",
      messageID: nil,
      title: "SwiftUI Tips",
      snippet: "SwiftUI Tips",
      role: .title,
      updatedAt: now
    )
    #expect(
      MacSidebarSearchSupport.subtitle(for: titleItem, summary: summary)
        == "Use LazyVStack inside ScrollView."
    )

    let messageItem = MacChatSessionModel.SearchItem(
      conversationID: "conv-1",
      messageID: "msg-1",
      title: "SwiftUI Tips",
      snippet: "Matched message snippet",
      role: .assistant,
      updatedAt: now
    )
    #expect(
      MacSidebarSearchSupport.subtitle(for: messageItem, summary: summary)
        == "Matched message snippet"
    )
  }

  @Test("Sidebar conversation buckets separate pinned and recent with cap and overflow metadata")
  func sidebarConversationBucketsCapRecentAndTrackOverflow() {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let conversations = (0..<25).map { index in
      makeConversation(
        id: String(format: "conv-%02d", index),
        title: "Chat \(index)",
        updatedAt: base.addingTimeInterval(TimeInterval(index * 60))
      )
    }

    let pinnedRaw = MacSidebarPinStore.serialize(["conv-01", "conv-05"])
    let buckets = MacSidebarConversationBuckets.make(
      from: conversations,
      pinnedRaw: pinnedRaw
    )

    #expect(MacSidebarConversationBuckets.recentDisplayLimit == 20)
    #expect(buckets.pinned.map(\.id) == ["conv-05", "conv-01"])
    #expect(buckets.recent.count == 20)
    #expect(buckets.recent.first?.id == "conv-24")
    #expect(buckets.recent.last?.id == "conv-04")
    #expect(buckets.totalHistoryCount == 25)
    #expect(buckets.hiddenRecentCount == 3)
    #expect(buckets.hasMoreRecent)

    let uncapped = MacSidebarConversationBuckets.make(
      from: Array(conversations.prefix(10)),
      pinnedRaw: pinnedRaw
    )
    #expect(uncapped.pinned.map(\.id) == ["conv-05", "conv-01"])
    #expect(uncapped.recent.count == 8)
    #expect(uncapped.hiddenRecentCount == 0)
    #expect(!uncapped.hasMoreRecent)
  }

  @Test("Sidebar pin store toggles and removes pinned IDs deterministically")
  func sidebarPinStoreToggleAndRemove() {
    var raw = ""
    raw = MacSidebarPinStore.toggled("conv-b", in: raw)
    raw = MacSidebarPinStore.toggled("conv-a", in: raw)
    #expect(raw == "conv-a\nconv-b")

    raw = MacSidebarPinStore.toggled("conv-a", in: raw)
    #expect(raw == "conv-b")

    let unchanged = MacSidebarPinStore.removing("conv-missing", from: raw)
    #expect(unchanged == "conv-b")

    raw = MacSidebarPinStore.removing("conv-b", from: raw)
    #expect(raw.isEmpty)
  }
}

@Suite("macOS user message collapsing and link detection")
struct MacUserMessageTextSupportTests {
  @Test("Short messages are not collapsed")
  func shortMessageStaysUncollapsed() {
    let text = "Hello\nworld"
    let preview = MacUserMessageTextSupport.preview(for: text, isExpanded: false)
    #expect(!preview.isLong)
    #expect(preview.displayedText == text)
    #expect(preview.toggleLabel == "Show more")
  }

  @Test("Messages exceeding 12 lines or 900 characters collapse with Show more / Show less")
  func longMessagesCollapseAndExpand() {
    let manyLines = (1...15).map { "Line \($0)" }.joined(separator: "\n")
    let collapsedLines = MacUserMessageTextSupport.preview(for: manyLines, isExpanded: false)
    #expect(collapsedLines.isLong)
    #expect(collapsedLines.toggleLabel == "Show more")
    #expect(collapsedLines.displayedText.hasSuffix("…"))
    #expect(!collapsedLines.displayedText.contains("Line 13"))

    let expandedLines = MacUserMessageTextSupport.preview(for: manyLines, isExpanded: true)
    #expect(expandedLines.isLong)
    #expect(expandedLines.toggleLabel == "Show less")
    #expect(expandedLines.displayedText == manyLines)

    let longSingleLine = String(repeating: "a", count: 950)
    let collapsedChars = MacUserMessageTextSupport.preview(for: longSingleLine, isExpanded: false)
    #expect(collapsedChars.isLong)
    #expect(collapsedChars.displayedText.count == 901)
    #expect(collapsedChars.displayedText.hasSuffix("…"))
  }

  @Test("Auto-linking detects HTTP(S) URLs and ignores non-browsable schemes")
  func detectsValidHTTPAndHTTPSLinks() throws {
    let text = "Visit https://example.com/docs and http://swift.org or email test@example.com"
    let matches = MacUserMessageTextSupport.linkMatches(in: text)

    #expect(matches.count == 2)
    #expect(matches[0].url.absoluteString == "https://example.com/docs")
    #expect(matches[1].url.absoluteString == "http://swift.org")

    let firstStart = text.index(text.startIndex, offsetBy: matches[0].startOffset)
    let firstEnd = text.index(text.startIndex, offsetBy: matches[0].endOffset)
    #expect(String(text[firstStart..<firstEnd]) == "https://example.com/docs")

    #expect(MacUserMessageTextSupport.isValidBrowsableURL(try #require(URL(string: "https://example.com"))))
    #expect(!MacUserMessageTextSupport.isValidBrowsableURL(try #require(URL(string: "mailto:test@example.com"))))
    #expect(!MacUserMessageTextSupport.isValidBrowsableURL(try #require(URL(string: "javascript:alert(1)"))))
  }
}

@Suite("macOS transcript windowing policy")
struct MacChatMessageWindowPolicyTests {
  @Test("Mounts latest 30 messages by default and handles small or empty transcripts")
  func defaultWindowRanges() {
    #expect(
      MacChatMessageWindowPolicy.visibleRange(
        totalCount: 0,
        visibleCount: MacChatMessageWindowPolicy.initialVisibleCount,
        targetMessageIndex: nil
      ) == 0..<0
    )
    #expect(
      MacChatMessageWindowPolicy.visibleRange(
        totalCount: 12,
        visibleCount: MacChatMessageWindowPolicy.initialVisibleCount,
        targetMessageIndex: nil
      ) == 0..<12
    )
    #expect(
      MacChatMessageWindowPolicy.visibleRange(
        totalCount: 100,
        visibleCount: MacChatMessageWindowPolicy.initialVisibleCount,
        targetMessageIndex: nil
      ) == 70..<100
    )
  }

  @Test("Automatically expands window with context when targeting an earlier message")
  func expandsForEarlierNavigationTarget() {
    #expect(
      MacChatMessageWindowPolicy.visibleRange(
        totalCount: 100,
        visibleCount: MacChatMessageWindowPolicy.initialVisibleCount,
        targetMessageIndex: 25
      ) == 10..<100
    )
    #expect(
      MacChatMessageWindowPolicy.visibleRange(
        totalCount: 100,
        visibleCount: MacChatMessageWindowPolicy.initialVisibleCount,
        targetMessageIndex: 5
      ) == 0..<100
    )
    #expect(
      MacChatMessageWindowPolicy.visibleRange(
        totalCount: 100,
        visibleCount: MacChatMessageWindowPolicy.initialVisibleCount,
        targetMessageIndex: 90
      ) == 70..<100
    )
  }
}
