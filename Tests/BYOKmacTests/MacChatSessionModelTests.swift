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
