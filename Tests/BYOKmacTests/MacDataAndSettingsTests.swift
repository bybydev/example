import BYOKchatProviderCore
import Foundation
import MacAppFoundation
import Testing

@testable import BYOKmac

@MainActor
@Suite("macOS storage usage, cache cleanup, analytics privacy, and preferences sync")
struct MacDataAndSettingsTests {
  @Test("Storage usage report measures categories and cleanup actions refresh usage")
  func storageUsageAndCleanupActions() async throws {
    let context = makeTestContext()
    defer { context.cleanup() }

    let app = MacAppModel(
      storageEnvironment: context.storage,
      coreServicesFactory: { try makeIsolatedServices(environment: $0) }
    )
    await app.start()

    let services = try #require(app.coreServices)
    let dataManagement = try #require(app.dataManagement)

    let conversation = try await services.conversationStore.createConversation(
      providerID: BuiltInProviders.openAIID,
      accountID: ProviderAccountID(rawValue: "acct-storage"),
      modelID: ModelID(rawValue: "gpt-4o")
    )
    _ = try await services.conversationStore.beginTurn(
      conversationID: conversation.id,
      userText: "Storage breakdown verification message"
    )
    try await services.conversationStore.rebuildSearchIndex()

    // Write an original attachment blob plus a derived cached thumbnail.
    let blobData = Data(repeating: 0xAB, count: 4_096)
    try await services.fileBlobStore.writeIfAbsent("blob-1", data: blobData, metadata: nil)
    let derivedDir = context.storage.layout.derivedThumbnailsDirectory
    try FileManager.default.createDirectory(at: derivedDir, withIntermediateDirectories: true)
    let thumbnailFile = derivedDir.appendingPathComponent("blob-1_256.jpg", isDirectory: false)
    try Data(repeating: 0xCD, count: 2_048).write(to: thumbnailFile)

    // Write a quarantined unreadable shard alongside the healthy conversation.
    let corruptFile = context.storage.layout.conversationsDirectory
      .appendingPathComponent("corrupt-shard.json.corrupt", isDirectory: false)
    try Data("{ invalid json".utf8).write(to: corruptFile)

    await dataManagement.refreshStorageUsage()

    let initialReport = try #require(dataManagement.storageReport)
    #expect(initialReport.conversationsBytes > 0)
    #expect(initialReport.attachmentsBytes > 0)
    #expect(initialReport.thumbnailCacheBytes > 0)
    #expect(initialReport.searchIndexBytes > 0)
    #expect(initialReport.quarantinedCount == 1)
    #expect(initialReport.quarantinedBytes > 0)
    #expect(initialReport.hasCleanupWarning)
    #expect(dataManagement.quarantinedShardCount == 1)

    // Clear cached thumbnails: derived cache disappears, original attachment stays intact.
    await dataManagement.clearThumbnailCache()
    let afterThumbnails = try #require(dataManagement.storageReport)
    #expect(afterThumbnails.thumbnailCacheBytes == 0)
    #expect(afterThumbnails.attachmentsBytes > 0)
    #expect(try await services.fileBlobStore.loadData("blob-1") == blobData)

    // Clear search index: FTS database files are removed and report refreshes.
    await dataManagement.clearSearchIndex()
    let afterSearch = try #require(dataManagement.storageReport)
    #expect(afterSearch.searchIndexBytes == 0)

    // Purge unreadable shards: corrupt shard removed, healthy conversation preserved.
    await dataManagement.purgeQuarantinedConversations()
    let afterPurge = try #require(dataManagement.storageReport)
    #expect(afterPurge.quarantinedCount == 0)
    #expect(afterPurge.quarantinedBytes == 0)
    #expect(dataManagement.quarantinedShardCount == 0)
    #expect(!FileManager.default.fileExists(atPath: corruptFile.path))
    #expect(await services.conversationStore.containsConversation(conversation.id))
  }

  @Test("Delete all conversations clears pinned conversation IDs")
  func deleteAllConversationsClearsPinnedIDs() async throws {
    let context = makeTestContext()
    defer { context.cleanup() }

    let previousStandardPins = UserDefaults.standard.string(forKey: MacSidebarPinStore.storageKey)
    defer {
      if let previousStandardPins {
        UserDefaults.standard.set(previousStandardPins, forKey: MacSidebarPinStore.storageKey)
      } else {
        UserDefaults.standard.removeObject(forKey: MacSidebarPinStore.storageKey)
      }
    }

    let app = MacAppModel(
      storageEnvironment: context.storage,
      coreServicesFactory: { try makeIsolatedServices(environment: $0) }
    )
    await app.start()

    let services = try #require(app.coreServices)
    let dataManagement = try #require(app.dataManagement)
    let conversation = try await services.conversationStore.createConversation(
      providerID: BuiltInProviders.openAIID,
      accountID: ProviderAccountID(rawValue: "acct-pin"),
      modelID: ModelID(rawValue: "gpt-4o")
    )

    UserDefaults.standard.set(conversation.id.rawValue, forKey: MacSidebarPinStore.storageKey)
    let suiteDefaults = context.storage.makeUserDefaults()
    suiteDefaults.set(conversation.id.rawValue, forKey: MacSidebarPinStore.storageKey)

    await dataManagement.deleteAllConversations()

    #expect((await services.conversationStore.conversationSummaries()).isEmpty)
    #expect(UserDefaults.standard.string(forKey: MacSidebarPinStore.storageKey) == nil)
    #expect(suiteDefaults.string(forKey: MacSidebarPinStore.storageKey) == nil)
  }

  @Test("Reset application data clears pinned conversation IDs and default system prompt")
  func resetClearsPinnedIDsAndDefaultPrompt() async throws {
    let context = makeTestContext()
    defer { context.cleanup() }

    let previousStandardPins = UserDefaults.standard.string(forKey: MacSidebarPinStore.storageKey)
    let previousStandardPrompt = UserDefaults.standard.string(forKey: "defaultSystemPrompt")
    defer {
      if let previousStandardPins {
        UserDefaults.standard.set(previousStandardPins, forKey: MacSidebarPinStore.storageKey)
      } else {
        UserDefaults.standard.removeObject(forKey: MacSidebarPinStore.storageKey)
      }
      if let previousStandardPrompt {
        UserDefaults.standard.set(previousStandardPrompt, forKey: "defaultSystemPrompt")
      } else {
        UserDefaults.standard.removeObject(forKey: "defaultSystemPrompt")
      }
    }

    let app = MacAppModel(
      storageEnvironment: context.storage,
      coreServicesFactory: { try makeIsolatedServices(environment: $0) }
    )
    await app.start()

    app.preferences.defaultSystemPrompt = "Be concise."
    UserDefaults.standard.set("conv-pinned", forKey: MacSidebarPinStore.storageKey)
    let suiteDefaults = context.storage.makeUserDefaults()
    suiteDefaults.set("conv-pinned", forKey: MacSidebarPinStore.storageKey)

    let dataManagement = try #require(app.dataManagement)
    await dataManagement.resetApplicationDataKeepingBackup()

    #expect(app.isReady)
    #expect(app.preferences.defaultSystemPrompt.isEmpty)
    #expect(UserDefaults.standard.string(forKey: MacSidebarPinStore.storageKey) == nil)
    #expect(suiteDefaults.string(forKey: MacSidebarPinStore.storageKey) == nil)
  }

  @Test("Anonymous usage uses in-memory storage, persists opt-out preference, and toggles runtime collection")
  func analyticsOptOutPersistenceAndInMemoryRuntimeToggle() async throws {
    let suiteName = "byokchat.mac.tests.analytics.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    // Default opt-in preference when unset, while test process still suppresses production sends.
    #expect(MacAppAnalytics.shareUsageDataPreference(in: defaults))
    #expect(MacAppAnalytics.isCollectionAllowed(in: defaults, ignoreTestSuppression: true))
    #expect(MacAppAnalytics.isSuppressedForTesting)
    #expect(!MacAppAnalytics.isEnabled)
    #expect(MacAppAnalytics.configuration.storageMode == .inMemory)
    #expect(
      MacAppAnalytics.configuration.uploadInterval == AppAnalyticsConfiguration.defaultUploadInterval
    )

    await MacAppAnalytics.setEnabled(false, defaults: defaults)
    #expect(!MacAppAnalytics.shareUsageDataPreference(in: defaults))
    #expect(!MacAppAnalytics.isCollectionAllowed(in: defaults, ignoreTestSuppression: true))

    // Preferences model reads and persists the same key.
    let reloadedPrefs = MacPreferencesModel(defaults: defaults)
    #expect(!reloadedPrefs.shareUsageData)
    reloadedPrefs.shareUsageData = true
    #expect(MacAppAnalytics.shareUsageDataPreference(in: defaults))
    #expect(MacAppAnalytics.isCollectionAllowed(in: defaults, ignoreTestSuppression: true))

    // In-memory runtime client respects setEnabled(false/true) and never writes UserDefaults state.
    let spyTransport = SpyAnalyticsTransport()
    let config = MacAppAnalytics.makeConfiguration(enabled: false)
    let client = AppAnalyticsClient(configuration: config, transport: spyTransport)

    #expect(!(await client.isEnabled))
    try await client.track(MacAppAnalytics.Event.messageEdited.rawValue)
    try await client.flush()
    #expect(await spyTransport.requestCount() == 0)

    await client.setEnabled(true)
    #expect(await client.isEnabled)
    try await client.track(MacAppAnalytics.Event.messageEdited.rawValue)
    try await client.flush()
    #expect(await spyTransport.requestCount() == 1)
    #expect(UserDefaults.standard.data(forKey: config.stateStorageKey) == nil)

    // Disabling at runtime clears pending in-memory data and sends no final upload.
    try await client.track(MacAppAnalytics.Event.projectCreated.rawValue)
    await client.setEnabled(false)
    #expect(!(await client.isEnabled))
    try await client.flush()
    #expect(await spyTransport.requestCount() == 1)
  }

  @Test("Paywall URLs and simulated product prices match iOS parity")
  func paywallURLsAndSimulatedPrices() {
    #expect(MacPurchaseStore.websiteURL.absoluteString == "https://spokiostudio.com/byokchat")
    #expect(MacPurchaseStore.contactURL.absoluteString == "https://spokiostudio.com/byokchat/contact")
    #expect(MacPurchaseStore.privacyURL.absoluteString == "https://spokiostudio.com/byokchat/privacy")
    #expect(MacPurchaseStore.termsURL.absoluteString == "https://spokiostudio.com/byokchat/terms")
    #expect(MacPurchaseStore.paywallConfiguration.privacyURL == MacPurchaseStore.privacyURL)
    #expect(MacPurchaseStore.paywallConfiguration.termsURL == MacPurchaseStore.termsURL)

    let productsByID = Dictionary(
      uniqueKeysWithValues: MacPurchaseStore.simulatedProducts.map { ($0.id, $0) }
    )
    #expect(productsByID[MacPurchaseStore.monthlyProductID]?.displayPrice == "$6.99")
    #expect(productsByID[MacPurchaseStore.monthlyProductID]?.price == 6.99)
    #expect(productsByID[MacPurchaseStore.yearlyProductID]?.displayPrice == "$29.99")
    #expect(productsByID[MacPurchaseStore.yearlyProductID]?.price == 29.99)
    #expect(productsByID[MacPurchaseStore.lifetimeProductID]?.displayPrice == "$49.99")
    #expect(productsByID[MacPurchaseStore.lifetimeProductID]?.price == 49.99)
  }

  @Test("Default system prompt normalization trims outer whitespace while preserving internal newlines")
  func defaultSystemPromptNormalization() throws {
    let suiteName = "byokchat.mac.tests.defaultPrompt.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.set("   \n\t  ", forKey: "defaultSystemPrompt")
    let preferences = MacPreferencesModel(defaults: defaults)
    #expect(preferences.defaultSystemPrompt.isEmpty)
    #expect(!preferences.hasDefaultSystemPrompt)

    #expect(
      MacPreferencesModel.normalizedSystemPrompt("  Line 1\n\nLine 2  \n") == "Line 1\n\nLine 2"
    )

    preferences.defaultSystemPrompt = "   \n  "
    #expect(preferences.defaultSystemPrompt.isEmpty)
    #expect(!preferences.hasDefaultSystemPrompt)
    #expect(defaults.string(forKey: "defaultSystemPrompt") == "")

    preferences.defaultSystemPrompt = "  Be direct.\nExplain trade-offs.  "
    #expect(preferences.defaultSystemPrompt == "Be direct.\nExplain trade-offs.")
    #expect(preferences.hasDefaultSystemPrompt)
    #expect(defaults.string(forKey: "defaultSystemPrompt") == "Be direct.\nExplain trade-offs.")
  }

  @Test("Syncing default system prompt updates only untouched empty chats and matching new-chat drafts")
  func syncDefaultSystemPromptUpdatesOnlyEligibleChats() async throws {
    let context = makeTestContext()
    defer { context.cleanup() }

    let services = try makeIsolatedServices(environment: context.storage)
    try await services.loadStoredState()

    let account = try await services.accountManager.createAccount(
      kind: .openai,
      label: "OpenAI",
      credential: "sk-test",
      defaultModelID: "gpt-4o"
    )
    let model = ProviderModel(
      providerID: BuiltInProviders.openAIID,
      id: "gpt-4o",
      displayName: "GPT-4o"
    )
    try await services.providerWorkspace.mergeModels([model], for: account.id)

    let projectWithInstructions = try await services.projectWorkspace.createProject(
      name: "Docs",
      symbolName: "folder.fill",
      accentID: "blue",
      accountID: account.id,
      modelID: "gpt-4o",
      instructions: "Always reply in JSON."
    )
    let projectWithoutInstructions = try await services.projectWorkspace.createProject(
      name: "Scratch",
      symbolName: "folder.fill",
      accentID: "green",
      accountID: account.id,
      modelID: "gpt-4o",
      instructions: "   "
    )

    let defaults = context.storage.makeUserDefaults()
    let preferences = MacPreferencesModel(defaults: defaults)
    preferences.defaultSystemPrompt = "Old default"

    // 1. Untouched empty standalone chat -> should update.
    let emptyStandalone = try await services.conversationStore.createConversation(
      providerID: account.providerID,
      accountID: account.id,
      modelID: "gpt-4o",
      systemPrompt: "Old default"
    )
    // 2. Untouched empty chat in project without instructions -> should update.
    let emptyBlankProject = try await services.conversationStore.createConversation(
      providerID: account.providerID,
      accountID: account.id,
      modelID: "gpt-4o",
      systemPrompt: "Old default"
    )
    try await services.projectWorkspace.assignConversation(
      emptyBlankProject.id,
      to: projectWithoutInstructions.id
    )
    // 3. Empty chat in project WITH instructions -> must stay unchanged.
    let emptyInstructedProject = try await services.conversationStore.createConversation(
      providerID: account.providerID,
      accountID: account.id,
      modelID: "gpt-4o",
      systemPrompt: "Always reply in JSON."
    )
    try await services.projectWorkspace.assignConversation(
      emptyInstructedProject.id,
      to: projectWithInstructions.id
    )
    // 4. Empty chat with custom system prompt -> must stay unchanged.
    let emptyCustomPrompt = try await services.conversationStore.createConversation(
      providerID: account.providerID,
      accountID: account.id,
      modelID: "gpt-4o",
      systemPrompt: "Custom standalone prompt"
    )
    // 5. Chat with existing messages -> must stay unchanged.
    let sentChat = try await services.conversationStore.createConversation(
      providerID: account.providerID,
      accountID: account.id,
      modelID: "gpt-4o",
      systemPrompt: "Old default"
    )
    _ = try await services.conversationStore.beginTurn(
      conversationID: sentChat.id,
      userText: "Hello"
    )

    let providers = MacProviderModel(services: services)
    try await providers.load()
    let session = MacChatSessionModel(
      services: services,
      providers: providers,
      preferences: preferences,
      initialSummaries: await services.conversationStore.conversationSummaries()
    )

    // Draft new chat matching old default should also sync.
    _ = await session.updateChatSettings(
      conversationID: nil,
      systemPrompt: "Old default",
      options: ProviderRequestOptions()
    )

    preferences.defaultSystemPrompt = "New default"
    await session.syncDefaultSystemPrompt(from: "Old default", to: "New default")

    #expect(
      (try await services.conversationStore.conversation(id: emptyStandalone.id)).systemPrompt
        == "New default"
    )
    #expect(
      (try await services.conversationStore.conversation(id: emptyBlankProject.id)).systemPrompt
        == "New default"
    )
    #expect(
      (try await services.conversationStore.conversation(id: emptyInstructedProject.id)).systemPrompt
        == "Always reply in JSON."
    )
    #expect(
      (try await services.conversationStore.conversation(id: emptyCustomPrompt.id)).systemPrompt
        == "Custom standalone prompt"
    )
    #expect(
      (try await services.conversationStore.conversation(id: sentChat.id)).systemPrompt
        == "Old default"
    )
    #expect(session.effectiveSystemPrompt(for: nil, project: nil) == "New default")

    // Custom draft override must NOT be overwritten when default is cleared.
    _ = await session.updateChatSettings(
      conversationID: nil,
      systemPrompt: "Custom draft prompt",
      options: ProviderRequestOptions()
    )
    preferences.defaultSystemPrompt = ""
    await session.syncDefaultSystemPrompt(from: "New default", to: "")

    #expect(
      (try await services.conversationStore.conversation(id: emptyStandalone.id)).systemPrompt
        == ""
    )
    #expect(session.effectiveSystemPrompt(for: nil, project: nil) == "Custom draft prompt")
  }
}

private struct MacDataAndSettingsTestContext {
  let parent: URL
  let suiteName: String
  let storage: BYOKStorageEnvironment

  func cleanup() {
    try? FileManager.default.removeItem(at: parent)
    UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
  }
}

private func makeTestContext() -> MacDataAndSettingsTestContext {
  let parent = FileManager.default.temporaryDirectory
    .appendingPathComponent("byok-mac-data-settings-tests-\(UUID().uuidString)", isDirectory: true)
  let suiteName = "byok-mac-data-settings-tests-\(UUID().uuidString)"
  let storage = BYOKStorageEnvironment(
    rootDirectory: parent.appendingPathComponent("Workspace", isDirectory: true),
    userDefaultsSuiteName: suiteName,
    credentialService: "tests.byok.mac.data-settings.credentials.\(UUID().uuidString)",
    mcpCredentialService: "tests.byok.mac.data-settings.mcp.\(UUID().uuidString)",
    telemetryDirectory: parent.appendingPathComponent("Telemetry", isDirectory: true)
  )
  return MacDataAndSettingsTestContext(parent: parent, suiteName: suiteName, storage: storage)
}

private func makeIsolatedServices(environment: BYOKStorageEnvironment) throws -> BYOKCoreServices {
  try BYOKCoreServices(
    environment: environment,
    credentialVault: InMemoryCredentialVault(),
    mcpCredentialVault: InMemoryMCPCredentialVault()
  )
}

private actor SpyAnalyticsTransport: AppAnalyticsTransport {
  private var count = 0

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    count += 1
    let response = HTTPURLResponse(
      url: request.url ?? URL(string: "https://analytics.133043.xyz")!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: nil
    )!
    return (Data("{\"ok\":true}".utf8), response)
  }

  func requestCount() -> Int {
    count
  }
}
