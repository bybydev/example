#if DEBUG
import AppFoundation
import BYOKchatProviderCore
import Foundation
import UIKit

enum BYOKSeedPreset: String, CaseIterable, Identifiable, Sendable {
  case showcase
  case uiTest

  var id: String { rawValue }

  var title: String {
    switch self {
    case .showcase: "Showcase (App Store & Video)"
    case .uiTest: "UI Test (Minimal)"
    }
  }

  var subtitle: String {
    switch self {
    case .showcase:
      "5 providers, 4 projects, 3 MCP servers, 6 rich chats, Library images/PDFs, and 21 days of analytics."
    case .uiTest:
      "Minimal deterministic set with 2 providers, 1 project, 1 MCP server, and 2 chats."
    }
  }
}

struct BYOKSeedConfiguration: Sendable, Equatable {
  var preset: BYOKSeedPreset
  var themeID: String
  var proEnabled: Bool
  var openPaywallOnLaunch: Bool

  init(
    preset: BYOKSeedPreset = .showcase,
    themeID: String = "midnight",
    proEnabled: Bool = true,
    openPaywallOnLaunch: Bool = false
  ) {
    self.preset = preset
    self.themeID = themeID
    self.proEnabled = proEnabled
    self.openPaywallOnLaunch = openPaywallOnLaunch
  }
}

@MainActor
enum BYOKSeedLaunchOptions {
  static let presetArgument = "-BYOKSeedPreset"
  static let themeArgument = "-BYOKSeedTheme"
  static let proArgument = "-BYOKSeedPro"
  static let openPaywallArgument = "-BYOKOpenPaywall"
  static let disableAnimationsArgument = "-BYOKDisableAnimations"
  static let legacyScreenshotArgument = "UI_TEST_SCREENSHOTS"

  private static var pendingLaunchSeed: BYOKSeedConfiguration?
  private static var pendingOpenPaywall = false

  static func prepareLaunchIfNeeded(arguments: [String] = ProcessInfo.processInfo.arguments) {
    if arguments.contains(disableAnimationsArgument) {
      UIView.setAnimationsEnabled(false)
    }

    guard let configuration = parse(arguments: arguments) else {
      pendingLaunchSeed = nil
      pendingOpenPaywall = false
      return
    }

    pendingLaunchSeed = configuration
    pendingOpenPaywall = configuration.openPaywallOnLaunch
    BYOKSeedDataService.applyDefaults(
      configuration,
      defaults: AppStorageEnvironment.current.makeUserDefaults()
    )
  }

  static func consumePendingLaunchSeed() -> BYOKSeedConfiguration? {
    defer { pendingLaunchSeed = nil }
    return pendingLaunchSeed
  }

  static func consumePendingOpenPaywall() -> Bool {
    defer { pendingOpenPaywall = false }
    return pendingOpenPaywall
  }

  static func parse(arguments: [String]) -> BYOKSeedConfiguration? {
    let hasPresetFlag = arguments.contains(presetArgument)
    let hasLegacyFlag = arguments.contains(legacyScreenshotArgument)
    guard hasPresetFlag || hasLegacyFlag else { return nil }

    let preset: BYOKSeedPreset
    if let rawPreset = value(after: presetArgument, in: arguments),
      let parsed = BYOKSeedPreset(rawValue: rawPreset)
    {
      preset = parsed
    } else {
      preset = .showcase
    }

    let validThemeIDs = Set(BYOKchatThemes.catalog.themes.map(\.id))
    let rawTheme = value(after: themeArgument, in: arguments)?.lowercased()
    let themeID = rawTheme.flatMap { validThemeIDs.contains($0) ? $0 : nil }
      ?? BYOKchatThemes.midnight.id

    let proEnabled: Bool
    if let rawPro = value(after: proArgument, in: arguments)?.lowercased() {
      proEnabled = !(rawPro == "false" || rawPro == "0" || rawPro == "no")
    } else {
      proEnabled = true
    }

    let openPaywall = arguments.contains(openPaywallArgument)
    return BYOKSeedConfiguration(
      preset: preset,
      themeID: themeID,
      proEnabled: proEnabled,
      openPaywallOnLaunch: openPaywall
    )
  }

  private static func value(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
      return nil
    }
    let next = arguments[index + 1]
    return next.hasPrefix("-") ? nil : next
  }
}

enum BYOKSeedDataService {
  // MARK: - Stable Seed Identifiers

  static let heroConversationID: ConversationID = "seed-chat-hero"
  static let richRenderConversationID: ConversationID = "seed-chat-rich-render"
  static let reviewConversationID: ConversationID = "seed-chat-swift-audit"
  static let researchConversationID: ConversationID = "seed-chat-model-latency"
  static let travelConversationID: ConversationID = "seed-chat-tokyo-trip"
  static let designConversationID: ConversationID = "seed-chat-sidebar-polish"

  static let heroAssistantMessageID: ChatMessageID = "seed-msg-hero-assistant"
  static let richAssistantMessageID: ChatMessageID = "seed-msg-rich-assistant"

  static let anthropicAccountID: ProviderAccountID = "seed-account-anthropic"
  static let openAIAccountID: ProviderAccountID = "seed-account-openai"
  static let geminiAccountID: ProviderAccountID = "seed-account-gemini"
  static let openRouterAccountID: ProviderAccountID = "seed-account-openrouter"
  static let ollamaAccountID: ProviderAccountID = "seed-account-ollama"

  static let launchProjectID: ProjectID = "seed-project-launch"
  static let architectureProjectID: ProjectID = "seed-project-architecture"
  static let researchProjectID: ProjectID = "seed-project-research"
  static let travelProjectID: ProjectID = "seed-project-travel"

  static let githubServerID: MCPServerID = "seed-mcp-github"
  static let webServerID: MCPServerID = "seed-mcp-web"
  static let linearServerID: MCPServerID = "seed-mcp-linear"

  private static let launchChecklistAttachmentID = "seed-file-launch-checklist"
  private static let projectBriefAttachmentID = "seed-file-architecture-brief"
  private static let modelNotesAttachmentID = "seed-file-model-notes"

  private static let simulatedPurchasesKey = "byokchat.simulatedPurchases"
  private static let themeStorageKey = "byokchat.themeState.v1"
  private static let onboardingCompletedKey = "byokchat.onboarding.completed.v1"

  // MARK: - Public Entry Points

  @MainActor
  static func seedAll(
    _ configuration: BYOKSeedConfiguration,
    environment: BYOKStorageEnvironment = AppStorageEnvironment.current,
    telemetryRecorder: TelemetryRecorder? = nil
  ) async throws {
    try await seedStorage(
      configuration,
      environment: environment,
      telemetryRecorder: telemetryRecorder
    )
    applyDefaults(configuration, defaults: environment.makeUserDefaults())
  }

  @MainActor
  static func applyDefaults(
    _ configuration: BYOKSeedConfiguration,
    defaults: UserDefaults = .standard
  ) {
    defaults.set(true, forKey: onboardingCompletedKey)
    defaults.set(true, forKey: BYOKPurchaseStore.simulatedModeKey)

    if configuration.proEnabled {
      defaults.set([BYOKPurchaseStore.yearlyProductID], forKey: simulatedPurchasesKey)
    } else {
      defaults.removeObject(forKey: simulatedPurchasesKey)
    }

    let validThemeID = BYOKchatThemes.catalog.theme(id: configuration.themeID)?.id
      ?? BYOKchatThemes.midnight.id
    let committedID = configuration.proEnabled ? validThemeID : BYOKchatThemes.midnight.id
    let themeStore = UserDefaultsThemeStateStore(storageKey: themeStorageKey)
    themeStore.save(
      ThemeStoredState(
        selectedThemeID: validThemeID,
        lastKnownHasPro: configuration.proEnabled,
        committedThemeID: committedID
      )
    )

    let pinnedIDs: Set<String> = configuration.preset == .showcase
      ? [heroConversationID.rawValue, richRenderConversationID.rawValue]
      : [heroConversationID.rawValue]
    defaults.set(SidebarPinStore.serialize(pinnedIDs), forKey: SidebarPinStore.storageKey)
  }

  @MainActor
  static func seedStorage(
    _ configuration: BYOKSeedConfiguration,
    environment: BYOKStorageEnvironment = AppStorageEnvironment.current,
    telemetryRecorder: TelemetryRecorder? = nil
  ) async throws {
    let now = Date()
    let recorder = telemetryRecorder ?? environment.makeTelemetryRecorder()
    let layout = environment.layout

    try await AppStorageBootstrap.resetLocalData(
      environment: environment,
      telemetryRecorder: recorder,
      createBackup: false
    )

    // resetLocalData clears onboarding & pins; restore seeded defaults right away.
    applyDefaults(configuration, defaults: environment.makeUserDefaults())

    try FileManager.default.createDirectory(
      at: environment.rootDirectory,
      withIntermediateDirectories: true
    )

    let isShowcase = configuration.preset == .showcase
    let assets = SeedAssetGenerator.generate(isShowcase: isShowcase)

    // 1. Providers + Keychain credentials via real store & vault.
    let providerWorkspace = ProviderWorkspaceStore(
      persistence: JSONFileProviderWorkspacePersistence(fileURL: layout.providersFile)
    )
    let providerData = try encodeStandard(providerState(now: now, isShowcase: isShowcase))
    try await providerWorkspace.importConfiguration(providerData, strategy: .replaceExisting)

    let credentialVault = KeychainCredentialVault(service: environment.credentialService)
    let accountsNeedingKeys: [ProviderAccountID] = isShowcase
      ? [anthropicAccountID, openAIAccountID, geminiAccountID, openRouterAccountID]
      : [anthropicAccountID, openAIAccountID]
    for accountID in accountsNeedingKeys {
      try await credentialVault.setSecret(
        "sk-byok-seed-demo-key",
        accountID: accountID,
        field: ProviderAccountManager.apiKeyField
      )
    }

    // 2. MCP servers, discovery snapshots, and chat tool configurations via real store & vault.
    let mcpWorkspace = MCPWorkspaceStore(
      persistence: JSONFileMCPWorkspacePersistence(fileURL: layout.mcpServersFile)
    )
    let mcpData = try encodeStandard(mcpState(now: now, isShowcase: isShowcase))
    try await mcpWorkspace.importConfiguration(mcpData, strategy: .replaceExisting)

    let mcpVault = KeychainMCPCredentialVault(service: environment.mcpCredentialService)
    try await mcpVault.setCredential("byok-mcp-github-token", serverID: githubServerID)
    if isShowcase {
      try await mcpVault.setCredential("byok-mcp-linear-token", serverID: linearServerID)
    }

    // 3. Shared blob store for chat attachments, project files, and Library items.
    let fileBlobStore = FileAttachmentBlobStore(directory: layout.filesDirectory)

    // 4. Conversations written as versioned ConversationShardRecord v1 shards (with blobs offloaded).
    try await writeConversationShards(
      conversations(now: now, isShowcase: isShowcase, assets: assets),
      directory: layout.conversationsDirectory,
      blobs: fileBlobStore
    )

    // 5. Projects + project reference files (with blobs offloaded and ISO-8601 dates).
    try await writeProjects(
      projectState(now: now, isShowcase: isShowcase, assets: assets),
      fileURL: layout.projectsFile,
      blobs: fileBlobStore
    )

    // 6. Library entries via real LibraryStore.
    let libraryStore = LibraryStore(
      persistence: JSONFileLibraryWorkspacePersistence(fileURL: layout.libraryFile),
      blobs: fileBlobStore
    )
    try await libraryStore.load()
    try await libraryStore.restorePortableEntries(
      libraryEntries(now: now, isShowcase: isShowcase, assets: assets),
      strategy: .replaceExisting
    )

    // 7. Telemetry SQLite events for Analytics & Message Info.
    for event in telemetryEvents(now: now, isShowcase: isShowcase) {
      await recorder.record(event)
    }
    await recorder.performMaintenance(referenceDate: now)
  }

  // MARK: - Persistence Helpers

  private static func writeConversationShards(
    _ conversations: [ChatConversation],
    directory: URL,
    blobs: FileAttachmentBlobStore
  ) async throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    var blobItems: [AttachmentBlobWriteItem] = []
    var strippedConversations: [ChatConversation] = []

    for var conversation in conversations {
      for messageIndex in conversation.messages.indices {
        guard var attachments = conversation.messages[messageIndex].attachments,
          !attachments.isEmpty
        else { continue }

        for attachmentIndex in attachments.indices {
          let payload = attachments[attachmentIndex].data
          if !payload.isEmpty {
            blobItems.append(
              AttachmentBlobWriteItem(
                id: attachments[attachmentIndex].id,
                data: payload,
                metadata: AttachmentBlobMetadata(
                  filename: attachments[attachmentIndex].filename,
                  mimeType: attachments[attachmentIndex].mimeType,
                  byteCount: payload.count,
                  createdAt: conversation.messages[messageIndex].createdAt
                )
              )
            )
            attachments[attachmentIndex].declaredByteCount = payload.count
            attachments[attachmentIndex].data = Data()
          }
        }
        conversation.messages[messageIndex].attachments = attachments
      }
      strippedConversations.append(conversation)
    }

    if !blobItems.isEmpty {
      try await blobs.writeBatchIfAbsent(blobItems)
    }

    for conversation in strippedConversations {
      let record = ConversationShardRecord(conversation: conversation)
      let data = try encodeStandard(record)
      try data.write(
        to: directory.appendingPathComponent("\(conversation.id.rawValue).json"),
        options: .atomic
      )
    }
  }

  private static func writeProjects(
    _ state: ProjectWorkspaceState,
    fileURL: URL,
    blobs: FileAttachmentBlobStore
  ) async throws {
    var mutableState = state
    var blobItems: [AttachmentBlobWriteItem] = []

    for projectIndex in mutableState.projects.indices {
      guard var files = mutableState.projects[projectIndex].files, !files.isEmpty else {
        continue
      }
      for fileIndex in files.indices {
        let payload = files[fileIndex].data
        if !payload.isEmpty {
          blobItems.append(
            AttachmentBlobWriteItem(
              id: files[fileIndex].id,
              data: payload,
              metadata: AttachmentBlobMetadata(
                filename: files[fileIndex].filename,
                mimeType: files[fileIndex].mimeType,
                byteCount: payload.count,
                createdAt: files[fileIndex].createdAt
              )
            )
          )
          files[fileIndex].declaredByteCount = payload.count
          files[fileIndex].data = Data()
        }
      }
      mutableState.projects[projectIndex].files = files
    }

    if !blobItems.isEmpty {
      try await blobs.writeBatchIfAbsent(blobItems)
    }

    let data = try encodeISO8601(mutableState)
    try data.write(to: fileURL, options: .atomic)
  }

  private static func encodeStandard<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  private static func encodeISO8601<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  // MARK: - Providers

  private static func providerState(now: Date, isShowcase: Bool) -> ProviderWorkspaceState {
    let claudeSonnet = ProviderModel(
      providerID: BuiltInProviders.anthropicID,
      id: "claude-sonnet-4-5",
      displayName: "Claude Sonnet 4.5",
      contextWindow: 1_000_000,
      contextWindowKind: .inputOnly,
      maxOutputTokens: 64_000,
      supportedParameters: ["max_tokens", "thinking", "effort", "tools"],
      inputModalities: ["text", "image", "file"],
      promptPricePerToken: "0.000003",
      completionPricePerToken: "0.000015",
      cachedInputPricePerToken: "0.0000003"
    )
    let claudeOpus = ProviderModel(
      providerID: BuiltInProviders.anthropicID,
      id: "claude-opus-4-1",
      displayName: "Claude Opus 4.1",
      contextWindow: 200_000,
      contextWindowKind: .inputOnly,
      maxOutputTokens: 32_000,
      supportedParameters: ["max_tokens", "thinking", "effort", "tools"],
      inputModalities: ["text", "image", "file"],
      promptPricePerToken: "0.000015",
      completionPricePerToken: "0.000075",
      cachedInputPricePerToken: "0.0000015"
    )
    let gpt5 = ProviderModel(
      providerID: BuiltInProviders.openAIID,
      id: "gpt-5.2",
      displayName: "GPT-5.2",
      contextWindow: 400_000,
      contextWindowKind: .combined,
      maxOutputTokens: 128_000,
      supportedParameters: ["max_output_tokens", "reasoning", "tools"],
      inputModalities: ["text", "image", "file"],
      promptPricePerToken: "0.0000025",
      completionPricePerToken: "0.00001",
      cachedInputPricePerToken: "0.000000625"
    )
    let gpt5Mini = ProviderModel(
      providerID: BuiltInProviders.openAIID,
      id: "gpt-5-mini",
      displayName: "GPT-5 Mini",
      contextWindow: 400_000,
      contextWindowKind: .combined,
      maxOutputTokens: 64_000,
      supportedParameters: ["max_output_tokens", "reasoning", "tools"],
      inputModalities: ["text", "image", "file"],
      promptPricePerToken: "0.00000025",
      completionPricePerToken: "0.000002"
    )
    let geminiPro = ProviderModel(
      providerID: BuiltInProviders.geminiID,
      id: "gemini-2.5-pro",
      displayName: "Gemini 2.5 Pro",
      contextWindow: 1_048_576,
      contextWindowKind: .inputOnly,
      maxOutputTokens: 65_536,
      supportedParameters: ["maxOutputTokens", "thinkingConfig", "tools"],
      inputModalities: ["text", "image", "audio", "file"],
      promptPricePerToken: "0.00000125",
      completionPricePerToken: "0.00001"
    )
    let geminiFlash = ProviderModel(
      providerID: BuiltInProviders.geminiID,
      id: "gemini-2.5-flash",
      displayName: "Gemini 2.5 Flash",
      contextWindow: 1_048_576,
      contextWindowKind: .inputOnly,
      maxOutputTokens: 65_536,
      supportedParameters: ["maxOutputTokens", "thinkingConfig", "tools"],
      inputModalities: ["text", "image", "audio", "file"],
      promptPricePerToken: "0.0000003",
      completionPricePerToken: "0.0000025"
    )
    let openRouterClaude = ProviderModel(
      providerID: BuiltInProviders.openRouterID,
      id: "anthropic/claude-sonnet-4.5",
      displayName: "Claude Sonnet 4.5",
      contextWindow: 1_000_000,
      contextWindowKind: .combined,
      maxOutputTokens: 64_000,
      supportedParameters: ["temperature", "top_p", "max_tokens", "reasoning", "tools"],
      inputModalities: ["text", "image", "file"],
      promptPricePerToken: "0.000003",
      completionPricePerToken: "0.000015"
    )
    let qwenLocal = ProviderModel(
      providerID: BuiltInProviders.ollamaID,
      id: "qwen3:32b",
      displayName: "Qwen 3 32B",
      contextWindow: 131_072,
      contextWindowKind: .combined,
      maxOutputTokens: 16_384,
      supportedParameters: ["temperature", "top_p", "max_tokens", "tools"],
      inputModalities: ["text"]
    )

    var accounts = [
      ProviderAccount(
        kind: .anthropic,
        id: anthropicAccountID,
        label: "Personal",
        defaultModelID: claudeSonnet.id,
        createdAt: now.addingTimeInterval(-86_400 * 24),
        updatedAt: now.addingTimeInterval(-1_200)
      ),
      ProviderAccount(
        kind: .openai,
        id: openAIAccountID,
        label: "Work",
        defaultModelID: gpt5.id,
        createdAt: now.addingTimeInterval(-86_400 * 19),
        updatedAt: now.addingTimeInterval(-2_400)
      ),
    ]

    var records = [
      AccountModelRecord(
        accountID: anthropicAccountID,
        model: claudeSonnet,
        isFavorite: true,
        isManual: false,
        isAvailable: true
      ),
      AccountModelRecord(
        accountID: anthropicAccountID,
        model: claudeOpus,
        isFavorite: true,
        isManual: false,
        isAvailable: true
      ),
      AccountModelRecord(
        accountID: openAIAccountID,
        model: gpt5,
        isFavorite: true,
        isManual: false,
        isAvailable: true
      ),
      AccountModelRecord(
        accountID: openAIAccountID,
        model: gpt5Mini,
        isFavorite: false,
        isManual: false,
        isAvailable: true
      ),
    ]

    var providerDefaults: [String: String] = [
      BuiltInProviders.anthropicID.rawValue: anthropicAccountID.rawValue,
      BuiltInProviders.openAIID.rawValue: openAIAccountID.rawValue,
    ]
    var refreshTimes: [String: Date] = [
      anthropicAccountID.rawValue: now.addingTimeInterval(-1_200),
      openAIAccountID.rawValue: now.addingTimeInterval(-2_400),
    ]

    if isShowcase {
      accounts.append(contentsOf: [
        ProviderAccount(
          kind: .gemini,
          id: geminiAccountID,
          label: "Fast",
          defaultModelID: geminiFlash.id,
          createdAt: now.addingTimeInterval(-86_400 * 14),
          updatedAt: now.addingTimeInterval(-3_600)
        ),
        ProviderAccount(
          kind: .openRouter,
          id: openRouterAccountID,
          label: "Research",
          metadata: ["appTitle": "BYOK Chat"],
          defaultModelID: openRouterClaude.id,
          createdAt: now.addingTimeInterval(-86_400 * 11),
          updatedAt: now.addingTimeInterval(-5_400)
        ),
        ProviderAccount(
          kind: .ollama,
          id: ollamaAccountID,
          label: "Local Mac",
          defaultModelID: qwenLocal.id,
          createdAt: now.addingTimeInterval(-86_400 * 7),
          updatedAt: now.addingTimeInterval(-7_200)
        ),
      ])

      records.append(contentsOf: [
        AccountModelRecord(
          accountID: geminiAccountID,
          model: geminiPro,
          isFavorite: true,
          isManual: false,
          isAvailable: true
        ),
        AccountModelRecord(
          accountID: geminiAccountID,
          model: geminiFlash,
          isFavorite: true,
          isManual: false,
          isAvailable: true
        ),
        AccountModelRecord(
          accountID: openRouterAccountID,
          model: openRouterClaude,
          isFavorite: true,
          isManual: true,
          isAvailable: true
        ),
        AccountModelRecord(
          accountID: ollamaAccountID,
          model: qwenLocal,
          isFavorite: true,
          isManual: false,
          isAvailable: true
        ),
      ])

      providerDefaults[BuiltInProviders.geminiID.rawValue] = geminiAccountID.rawValue
      providerDefaults[BuiltInProviders.openRouterID.rawValue] = openRouterAccountID.rawValue
      providerDefaults[BuiltInProviders.ollamaID.rawValue] = ollamaAccountID.rawValue

      refreshTimes[geminiAccountID.rawValue] = now.addingTimeInterval(-3_600)
      refreshTimes[openRouterAccountID.rawValue] = now.addingTimeInterval(-5_400)
      refreshTimes[ollamaAccountID.rawValue] = now.addingTimeInterval(-7_200)
    }

    return ProviderWorkspaceState(
      accounts: accounts,
      modelRecords: records,
      defaultAccountID: anthropicAccountID,
      providerDefaultAccountIDs: providerDefaults,
      lastSuccessfulModelRefreshAt: refreshTimes
    )
  }

  // MARK: - Conversations

  private static func conversations(
    now: Date,
    isShowcase: Bool,
    assets: SeedAssets
  ) -> [ChatConversation] {
    var list = [
      heroConversation(now: now, assets: assets),
      richRenderConversation(now: now),
    ]

    if isShowcase {
      list.append(contentsOf: [
        reviewConversation(now: now),
        researchConversation(now: now),
        travelConversation(now: now),
        designConversation(now: now),
      ])
    }
    return list
  }

  private static func heroConversation(now: Date, assets: SeedAssets) -> ChatConversation {
    let userDate = now.addingTimeInterval(-1_500)
    let assistantDate = now.addingTimeInterval(-1_200)

    let checklistAttachment = ChatAttachment(
      id: launchChecklistAttachmentID,
      kind: .file,
      filename: "launch-checklist.md",
      mimeType: "text/markdown",
      data: assets.launchChecklistMarkdown
    )

    let searchToolName = MCPToolNamespace.exposedName(
      serverID: githubServerID,
      remoteName: "search_code"
    )
    let toolRound = ChatToolRound(
      id: "seed-hero-tool-round",
      calls: [
        ChatToolCall(
          id: "seed-hero-tool-call-1",
          name: searchToolName,
          arguments: .object([
            "query": .string("PrivacyInfo.xcprivacy ITSAppUsesNonExemptEncryption")
          ])
        )
      ],
      results: [
        ChatToolResult(
          callID: "seed-hero-tool-call-1",
          name: searchToolName,
          content: .object([
            "status": .string("complete"),
            "matches": .number(2),
            "summary": .string("Privacy manifest and export compliance verified in BYOKchat/Resources.")
          ])
        )
      ],
      assistantText: "I checked the repository compliance files before summarizing the release plan.",
      assistantReasoning: "Confirm privacy manifest and export flags in source control before listing final ship items.",
      usage: ProviderUsage(inputTokens: 640, outputTokens: 128, cachedInputTokens: 320),
      createdAt: assistantDate.addingTimeInterval(-35)
    )

    return ChatConversation(
      id: heroConversationID,
      title: "Ship a native iOS AI client",
      createdAt: now.addingTimeInterval(-86_400 * 3),
      updatedAt: assistantDate,
      providerID: BuiltInProviders.anthropicID,
      accountID: anthropicAccountID,
      modelID: "claude-sonnet-4-5",
      systemPrompt: "Be concise, practical, and release-focused.",
      options: ProviderRequestOptions(
        reasoning: ReasoningOptions(enabled: true, effort: .high)
      ),
      messages: [
        ChatMessage(
          id: "seed-msg-hero-user",
          role: .user,
          content: "Review our launch checklist and turn it into the smallest high-confidence release plan.",
          attachments: [checklistAttachment],
          createdAt: userDate,
          updatedAt: userDate,
          status: .complete,
          providerID: BuiltInProviders.anthropicID,
          accountID: anthropicAccountID,
          modelID: "claude-sonnet-4-5"
        ),
        ChatMessage(
          id: heroAssistantMessageID,
          role: .assistant,
          content: """
          ## Launch readiness

          Your privacy manifest and export-compliance flag are already verified. Focus on these three remaining steps:

          1. **Capture deterministic raw screenshots** across Dark and Light themes with clean `9:41` status bars.
          2. **Verify cold-start recovery** on a clean iPhone install before TestFlight external review.
          3. **Pin the default release model** so first-run chat latency stays under one second.

          ```swift
          let plan = ReleasePlan(
            screenshots: [.midnight, .paper],
            coldStartBudget: .milliseconds(450),
            directProvidersOnly: true
          )
          ```
          """,
          reasoning: """
          1. Checked `PrivacyInfo.xcprivacy` and `ITSAppUsesNonExemptEncryption` via GitHub MCP — both are present and valid.
          2. Filtered out already-shipped items from `launch-checklist.md` to keep the final checklist actionable.
          3. Prioritized visual App Store proof, clean-install reliability, and fast first-token latency.
          """,
          toolRounds: [toolRound],
          createdAt: assistantDate,
          updatedAt: assistantDate,
          status: .complete,
          providerID: BuiltInProviders.anthropicID,
          accountID: anthropicAccountID,
          modelID: "claude-sonnet-4-5",
          finishReason: "stop",
          usage: ProviderUsage(
            inputTokens: 4_820,
            outputTokens: 940,
            cachedInputTokens: 2_640,
            reasoningTokens: 368
          ),
          metadata: [
            ChatBilling.costKey: "0.064",
            ChatBilling.accuracyKey: ChatCostAccuracy.providerReported.rawValue,
            ChatBilling.modelRequestCountKey: "2",
            ChatBilling.toolCallCountKey: "1",
          ]
        ),
      ]
    )
  }

  private static func richRenderConversation(now: Date) -> ChatConversation {
    let userDate = now.addingTimeInterval(-3_600)
    let assistantDate = now.addingTimeInterval(-3_300)

    return ChatConversation(
      id: richRenderConversationID,
      title: "Sync architecture & cost model",
      createdAt: now.addingTimeInterval(-86_400 * 2),
      updatedAt: assistantDate,
      providerID: BuiltInProviders.openAIID,
      accountID: openAIAccountID,
      modelID: "gpt-5.2",
      options: ProviderRequestOptions(
        reasoning: ReasoningOptions(enabled: true, effort: .medium)
      ),
      messages: [
        ChatMessage(
          id: "seed-msg-rich-user",
          role: .user,
          content: "Diagram our direct BYOK request flow, compare provider latencies, and give the blended cost equation.",
          createdAt: userDate,
          updatedAt: userDate,
          status: .complete,
          providerID: BuiltInProviders.openAIID,
          accountID: openAIAccountID,
          modelID: "gpt-5.2"
        ),
        ChatMessage(
          id: richAssistantMessageID,
          role: .assistant,
          content: """
          ### Direct request flow

          ```mermaid
          flowchart LR
            A[iPhone App] -->|Keychain Key| B[Provider API]
            A -->|Local Policy| C[MCP Tools]
            B -->|SSE Stream| A
            C -->|Approved Result| A
          ```

          ### Provider benchmark

          | Provider | Median TTFT | Speed | Context |
          | :--- | ---: | ---: | ---: |
          | Anthropic | 0.78 s | 84 tok/s | 1M |
          | OpenAI | 0.92 s | 79 tok/s | 400K |
          | Gemini | 0.64 s | 112 tok/s | 1M |
          | Local Ollama | 0.31 s | 62 tok/s | 128K |

          ### Blended turn cost

          $$C_{\\text{turn}} = \\frac{T_{\\text{in}} \\cdot r_{\\text{in}} + T_{\\text{cache}} \\cdot r_{\\text{cache}} + T_{\\text{out}} \\cdot r_{\\text{out}}}{10^6}$$
          """,
          reasoning: "Combine a concise Mermaid diagram, aligned Markdown comparison table, and exact token-cost formula.",
          createdAt: assistantDate,
          updatedAt: assistantDate,
          status: .complete,
          providerID: BuiltInProviders.openAIID,
          accountID: openAIAccountID,
          modelID: "gpt-5.2",
          finishReason: "stop",
          usage: ProviderUsage(
            inputTokens: 2_310,
            outputTokens: 615,
            cachedInputTokens: 960,
            reasoningTokens: 210
          ),
          metadata: [
            ChatBilling.costKey: "0.038",
            ChatBilling.accuracyKey: ChatCostAccuracy.providerReported.rawValue,
            ChatBilling.modelRequestCountKey: "1",
            ChatBilling.toolCallCountKey: "0",
          ]
        ),
      ]
    )
  }

  private static func reviewConversation(now: Date) -> ChatConversation {
    let userDate = now.addingTimeInterval(-8_400)
    let assistantDate = now.addingTimeInterval(-8_100)

    return ChatConversation(
      id: reviewConversationID,
      title: "Swift 6 actor isolation audit",
      createdAt: now.addingTimeInterval(-86_400 * 4),
      updatedAt: assistantDate,
      providerID: BuiltInProviders.openAIID,
      accountID: openAIAccountID,
      modelID: "gpt-5.2",
      messages: [
        ChatMessage(
          id: "seed-msg-review-user",
          role: .user,
          content: "What is the safest pattern for serializing actor writes while awaiting disk I/O?",
          createdAt: userDate,
          updatedAt: userDate,
          status: .complete,
          providerID: BuiltInProviders.openAIID,
          accountID: openAIAccountID,
          modelID: "gpt-5.2"
        ),
        ChatMessage(
          id: "seed-msg-review-assistant",
          role: .assistant,
          content: "Queue mutations with a lightweight FIFO continuation gate inside the actor, compute the candidate snapshot after acquiring the gate, and publish in-memory state only after atomic persistence succeeds.",
          createdAt: assistantDate,
          updatedAt: assistantDate,
          status: .complete,
          providerID: BuiltInProviders.openAIID,
          accountID: openAIAccountID,
          modelID: "gpt-5.2",
          finishReason: "stop",
          usage: ProviderUsage(inputTokens: 1_840, outputTokens: 412, cachedInputTokens: 640),
          metadata: [
            ChatBilling.costKey: "0.029",
            ChatBilling.accuracyKey: ChatCostAccuracy.providerReported.rawValue,
            ChatBilling.modelRequestCountKey: "1",
            ChatBilling.toolCallCountKey: "0",
          ]
        ),
      ]
    )
  }

  private static func researchConversation(now: Date) -> ChatConversation {
    let userDate = now.addingTimeInterval(-86_400 * 1 - 1_800)
    let assistantDate = now.addingTimeInterval(-86_400 * 1 - 1_500)

    return ChatConversation(
      id: researchConversationID,
      title: "Local vs cloud model latency",
      createdAt: now.addingTimeInterval(-86_400 * 6),
      updatedAt: assistantDate,
      providerID: BuiltInProviders.openRouterID,
      accountID: openRouterAccountID,
      modelID: "anthropic/claude-sonnet-4.5",
      messages: [
        ChatMessage(
          id: "seed-msg-research-user",
          role: .user,
          content: "When should I route prompts to Ollama on LAN instead of a cloud model?",
          createdAt: userDate,
          updatedAt: userDate,
          status: .complete,
          providerID: BuiltInProviders.openRouterID,
          accountID: openRouterAccountID,
          modelID: "anthropic/claude-sonnet-4.5"
        ),
        ChatMessage(
          id: "seed-msg-research-assistant",
          role: .assistant,
          content: "Use local models over Wi-Fi for sensitive drafts, offline workflows, and zero-cost iteration. Switch to cloud frontier models when you need deep multi-step reasoning, long context, or complex MCP tool chains.",
          createdAt: assistantDate,
          updatedAt: assistantDate,
          status: .complete,
          providerID: BuiltInProviders.openRouterID,
          accountID: openRouterAccountID,
          modelID: "anthropic/claude-sonnet-4.5",
          finishReason: "stop",
          usage: ProviderUsage(inputTokens: 3_120, outputTokens: 780),
          metadata: [
            ChatBilling.costKey: "0.044",
            ChatBilling.accuracyKey: ChatCostAccuracy.providerReported.rawValue,
            ChatBilling.modelRequestCountKey: "1",
            ChatBilling.toolCallCountKey: "0",
          ]
        ),
      ]
    )
  }

  private static func travelConversation(now: Date) -> ChatConversation {
    let userDate = now.addingTimeInterval(-86_400 * 2 - 4_200)
    let assistantDate = now.addingTimeInterval(-86_400 * 2 - 3_900)

    return ChatConversation(
      id: travelConversationID,
      title: "Four-day Tokyo work trip",
      createdAt: now.addingTimeInterval(-86_400 * 5),
      updatedAt: assistantDate,
      providerID: BuiltInProviders.geminiID,
      accountID: geminiAccountID,
      modelID: "gemini-2.5-flash",
      messages: [
        ChatMessage(
          id: "seed-msg-travel-user",
          role: .user,
          content: "Plan a calm four-day Tokyo itinerary with mornings reserved for deep work.",
          createdAt: userDate,
          updatedAt: userDate,
          status: .complete,
          providerID: BuiltInProviders.geminiID,
          accountID: geminiAccountID,
          modelID: "gemini-2.5-flash"
        ),
        ChatMessage(
          id: "seed-msg-travel-assistant",
          role: .assistant,
          content: "Stay near Shibuya or Aoyama, block 8:00–12:00 for focused work, and pair each afternoon with one walkable neighborhood: Daikanyama, Yanaka, Ginza, and Kichijoji.",
          createdAt: assistantDate,
          updatedAt: assistantDate,
          status: .complete,
          providerID: BuiltInProviders.geminiID,
          accountID: geminiAccountID,
          modelID: "gemini-2.5-flash",
          finishReason: "stop",
          usage: ProviderUsage(inputTokens: 1_540, outputTokens: 390),
          metadata: [
            ChatBilling.costKey: "0.012",
            ChatBilling.accuracyKey: ChatCostAccuracy.providerReported.rawValue,
            ChatBilling.modelRequestCountKey: "1",
            ChatBilling.toolCallCountKey: "0",
          ]
        ),
      ]
    )
  }

  private static func designConversation(now: Date) -> ChatConversation {
    let userDate = now.addingTimeInterval(-86_400 * 4 - 2_000)
    let assistantDate = now.addingTimeInterval(-86_400 * 4 - 1_700)

    return ChatConversation(
      id: designConversationID,
      title: "Liquid Glass sidebar polish",
      createdAt: now.addingTimeInterval(-86_400 * 8),
      updatedAt: assistantDate,
      providerID: BuiltInProviders.anthropicID,
      accountID: anthropicAccountID,
      modelID: "claude-opus-4-1",
      messages: [
        ChatMessage(
          id: "seed-msg-design-user",
          role: .user,
          content: "Suggest spacing and contrast refinements for our iOS 26 navigation drawer.",
          createdAt: userDate,
          updatedAt: userDate,
          status: .complete,
          providerID: BuiltInProviders.anthropicID,
          accountID: anthropicAccountID,
          modelID: "claude-opus-4-1"
        ),
        ChatMessage(
          id: "seed-msg-design-assistant",
          role: .assistant,
          content: "Keep primary destinations at 42 pt minimum touch targets, cap unpinned history at 20 rows, and separate pinned workspaces with a subtle 12 pt top cadence so scanning stays effortless.",
          createdAt: assistantDate,
          updatedAt: assistantDate,
          status: .complete,
          providerID: BuiltInProviders.anthropicID,
          accountID: anthropicAccountID,
          modelID: "claude-opus-4-1",
          finishReason: "stop",
          usage: ProviderUsage(inputTokens: 2_980, outputTokens: 540, cachedInputTokens: 1_200),
          metadata: [
            ChatBilling.costKey: "0.092",
            ChatBilling.accuracyKey: ChatCostAccuracy.providerReported.rawValue,
            ChatBilling.modelRequestCountKey: "1",
            ChatBilling.toolCallCountKey: "0",
          ]
        ),
      ]
    )
  }

  // MARK: - Projects

  private static func projectState(
    now: Date,
    isShowcase: Bool,
    assets: SeedAssets
  ) -> ProjectWorkspaceState {
    let searchCodeTool = MCPToolNamespace.exposedName(
      serverID: githubServerID,
      remoteName: "search_code"
    )
    let openPRTool = MCPToolNamespace.exposedName(
      serverID: githubServerID,
      remoteName: "open_pull_request"
    )

    let launchProject = ChatProject(
      id: launchProjectID,
      name: "Product Launch",
      symbolName: "paperplane.fill",
      accentID: "blue",
      accountID: anthropicAccountID,
      modelID: "claude-sonnet-4-5",
      instructions: "Keep recommendations crisp, native to iOS 26, and focused on shipping a clean release.",
      createdAt: now.addingTimeInterval(-86_400 * 14),
      updatedAt: now.addingTimeInterval(-1_200),
      files: [
        ProjectFile(
          id: launchChecklistAttachmentID,
          filename: "launch-checklist.md",
          mimeType: "text/markdown",
          data: assets.launchChecklistMarkdown,
          createdAt: now.addingTimeInterval(-86_400 * 5)
        ),
        ProjectFile(
          id: projectBriefAttachmentID,
          filename: "q4-release-brief.pdf",
          mimeType: "application/pdf",
          data: assets.releaseBriefPDF,
          createdAt: now.addingTimeInterval(-86_400 * 3)
        ),
      ],
      mcpConfiguration: MCPChatToolConfiguration(
        enabledServerIDs: isShowcase ? [githubServerID, webServerID] : [githubServerID],
        toolPolicies: [
          searchCodeTool: .alwaysAllow,
          openPRTool: .disabled,
        ]
      ),
      promptPresets: [
        ProjectPromptPreset(
          id: "seed-preset-release-review",
          name: "Release Review",
          prompt: "Audit the current release checklist and call out any remaining ship blockers."
        ),
        ProjectPromptPreset(
          id: "seed-preset-changelog",
          name: "App Store Notes",
          prompt: "Draft concise What's New notes highlighting direct BYOK privacy and MCP tools."
        ),
      ]
    )

    var projects = [launchProject]
    var memberships: [String: String] = [
      heroConversationID.rawValue: launchProjectID.rawValue
    ]

    if isShowcase {
      projects.append(contentsOf: [
        ChatProject(
          id: architectureProjectID,
          name: "Core Architecture",
          symbolName: "cpu.fill",
          accentID: "indigo",
          accountID: openAIAccountID,
          modelID: "gpt-5.2",
          instructions: "Enforce Swift 6 strict concurrency, atomic persistence, and zero third-party proxies.",
          createdAt: now.addingTimeInterval(-86_400 * 12),
          updatedAt: now.addingTimeInterval(-3_300),
          files: [
            ProjectFile(
              id: modelNotesAttachmentID,
              filename: "provider-pricing-sheet.pdf",
              mimeType: "application/pdf",
              data: assets.pricingSheetPDF,
              createdAt: now.addingTimeInterval(-86_400 * 4)
            )
          ]
        ),
        ChatProject(
          id: researchProjectID,
          name: "Model Research",
          symbolName: "sparkles",
          accentID: "purple",
          accountID: openRouterAccountID,
          modelID: "anthropic/claude-sonnet-4.5",
          instructions: "Compare frontier cloud and local models on TTFT, reasoning accuracy, and token cost.",
          createdAt: now.addingTimeInterval(-86_400 * 9),
          updatedAt: now.addingTimeInterval(-86_400 * 1)
        ),
        ChatProject(
          id: travelProjectID,
          name: "Tokyo Work Trip",
          symbolName: "airplane",
          accentID: "orange",
          accountID: geminiAccountID,
          modelID: "gemini-2.5-flash",
          instructions: "Keep transit simple, protect morning focus blocks, and favor quiet neighborhoods.",
          createdAt: now.addingTimeInterval(-86_400 * 6),
          updatedAt: now.addingTimeInterval(-86_400 * 2)
        ),
      ])

      memberships[designConversationID.rawValue] = launchProjectID.rawValue
      memberships[richRenderConversationID.rawValue] = architectureProjectID.rawValue
      memberships[reviewConversationID.rawValue] = architectureProjectID.rawValue
      memberships[researchConversationID.rawValue] = researchProjectID.rawValue
      memberships[travelConversationID.rawValue] = travelProjectID.rawValue
    }

    return ProjectWorkspaceState(
      projects: projects,
      conversationProjectIDs: memberships
    )
  }

  // MARK: - MCP Servers

  private static func mcpState(now: Date, isShowcase: Bool) -> MCPWorkspaceState {
    let githubServer = MCPRemoteServer(
      id: githubServerID,
      name: "GitHub",
      endpoint: URL(string: "https://api.githubcopilot.com/mcp")!,
      authentication: MCPAuthentication(kind: .bearer),
      isEnabled: true,
      createdAt: now.addingTimeInterval(-86_400 * 16),
      updatedAt: now.addingTimeInterval(-900)
    )
    let githubSnapshot = MCPServerSnapshot(
      serverID: githubServerID,
      protocolVersion: "2025-06-18",
      era: .modern,
      serverInfo: MCPImplementationInfo(name: "github-mcp", version: "2.3.0", title: "GitHub"),
      capabilities: .object(["tools": .object([:])]),
      instructions: "Search code, inspect files, and manage pull requests across your repositories.",
      tools: [
        MCPRemoteTool(
          remoteName: "search_code",
          title: "Search Code",
          description: "Search source files across connected repositories.",
          inputSchema: objectSchema(properties: ["query": .object(["type": .string("string")])])
        ),
        MCPRemoteTool(
          remoteName: "read_file",
          title: "Read File",
          description: "Read a file at a specific branch or commit.",
          inputSchema: objectSchema(properties: ["path": .object(["type": .string("string")])])
        ),
        MCPRemoteTool(
          remoteName: "list_pull_requests",
          title: "List Pull Requests",
          description: "List open pull requests and review status.",
          inputSchema: objectSchema(properties: ["state": .object(["type": .string("string")])])
        ),
        MCPRemoteTool(
          remoteName: "open_pull_request",
          title: "Open Pull Request",
          description: "Create a new pull request from a branch.",
          inputSchema: objectSchema(properties: ["title": .object(["type": .string("string")])])
        ),
      ],
      refreshedAt: now.addingTimeInterval(-900),
      expiresAt: now.addingTimeInterval(86_400 * 7),
      cacheScope: "authenticated"
    )

    var servers = [githubServer]
    var snapshots = [githubSnapshot]

    if isShowcase {
      let webServer = MCPRemoteServer(
        id: webServerID,
        name: "Web Search",
        endpoint: URL(string: "https://mcp.brave.com/v1")!,
        authentication: MCPAuthentication(kind: .none),
        isEnabled: true,
        createdAt: now.addingTimeInterval(-86_400 * 12),
        updatedAt: now.addingTimeInterval(-1_500)
      )
      let webSnapshot = MCPServerSnapshot(
        serverID: webServerID,
        protocolVersion: "2025-06-18",
        era: .modern,
        serverInfo: MCPImplementationInfo(name: "web-search", version: "1.6.0", title: "Web Search"),
        capabilities: .object(["tools": .object([:])]),
        instructions: "Search current documentation and fetch clean article text.",
        tools: [
          MCPRemoteTool(
            remoteName: "search_web",
            title: "Search Web",
            description: "Search live web results with citations.",
            inputSchema: objectSchema(properties: ["query": .object(["type": .string("string")])])
          ),
          MCPRemoteTool(
            remoteName: "fetch_page",
            title: "Fetch Page",
            description: "Extract readable markdown from a web page.",
            inputSchema: objectSchema(properties: ["url": .object(["type": .string("string")])])
          ),
          MCPRemoteTool(
            remoteName: "extract_links",
            title: "Extract Links",
            description: "List relevant outgoing references from a URL.",
            inputSchema: objectSchema(properties: ["url": .object(["type": .string("string")])])
          ),
        ],
        refreshedAt: now.addingTimeInterval(-1_500),
        expiresAt: now.addingTimeInterval(86_400 * 7),
        cacheScope: "public"
      )

      let linearServer = MCPRemoteServer(
        id: linearServerID,
        name: "Linear",
        endpoint: URL(string: "https://mcp.linear.app/v1")!,
        authentication: MCPAuthentication(kind: .bearer),
        isEnabled: true,
        createdAt: now.addingTimeInterval(-86_400 * 8),
        updatedAt: now.addingTimeInterval(-2_400)
      )
      let linearSnapshot = MCPServerSnapshot(
        serverID: linearServerID,
        protocolVersion: "2025-06-18",
        era: .modern,
        serverInfo: MCPImplementationInfo(name: "linear-mcp", version: "1.2.0", title: "Linear"),
        capabilities: .object(["tools": .object([:])]),
        instructions: "Track sprint issues, milestones, and release blockers.",
        tools: [
          MCPRemoteTool(
            remoteName: "list_issues",
            title: "List Issues",
            description: "List active cycle issues for a team.",
            inputSchema: objectSchema(properties: ["team": .object(["type": .string("string")])])
          ),
          MCPRemoteTool(
            remoteName: "search_issues",
            title: "Search Issues",
            description: "Find issues matching keywords or labels.",
            inputSchema: objectSchema(properties: ["query": .object(["type": .string("string")])])
          ),
          MCPRemoteTool(
            remoteName: "create_issue",
            title: "Create Issue",
            description: "Open a new Linear issue in a project.",
            inputSchema: objectSchema(properties: ["title": .object(["type": .string("string")])])
          ),
        ],
        refreshedAt: now.addingTimeInterval(-2_400),
        expiresAt: now.addingTimeInterval(86_400 * 7),
        cacheScope: "authenticated"
      )

      servers.append(contentsOf: [webServer, linearServer])
      snapshots.append(contentsOf: [webSnapshot, linearSnapshot])
    }

    let searchCodeTool = MCPToolNamespace.exposedName(
      serverID: githubServerID,
      remoteName: "search_code"
    )
    let openPRTool = MCPToolNamespace.exposedName(
      serverID: githubServerID,
      remoteName: "open_pull_request"
    )
    let searchWebTool = MCPToolNamespace.exposedName(
      serverID: webServerID,
      remoteName: "search_web"
    )

    var policies: [String: ChatToolPermissionPolicy] = [
      searchCodeTool: .alwaysAllow,
      openPRTool: .disabled,
    ]
    if isShowcase {
      policies[searchWebTool] = .alwaysAllow
    }

    let heroChatTools = MCPChatToolConfiguration(
      enabledServerIDs: isShowcase ? [githubServerID, webServerID] : [githubServerID],
      toolPolicies: policies
    )

    return MCPWorkspaceState(
      servers: servers,
      snapshots: snapshots,
      chatConfigurations: [
        heroConversationID.rawValue: heroChatTools
      ]
    )
  }

  private static func objectSchema(properties: [String: JSONValue]) -> JSONValue {
    .object([
      "type": .string("object"),
      "properties": .object(properties),
    ])
  }

  // MARK: - Library

  private static func libraryEntries(
    now: Date,
    isShowcase: Bool,
    assets: SeedAssets
  ) -> [PortableLibraryEntry] {
    var items: [PortableLibraryEntry] = [
      PortableLibraryEntry(
        entry: LibraryEntry(
          id: "seed-lib-latency-chart",
          filename: "latency-benchmark.png",
          kind: .image,
          mimeType: "image/png",
          byteCount: assets.latencyChartPNG.count,
          createdAt: now.addingTimeInterval(-1_800),
          updatedAt: now.addingTimeInterval(-1_800),
          source: .chat(conversationID: richRenderConversationID, messageID: richAssistantMessageID)
        ),
        data: assets.latencyChartPNG
      ),
      PortableLibraryEntry(
        entry: LibraryEntry(
          id: LibraryEntryID(rawValue: launchChecklistAttachmentID),
          filename: "launch-checklist.md",
          kind: .file,
          mimeType: "text/markdown",
          byteCount: assets.launchChecklistMarkdown.count,
          createdAt: now.addingTimeInterval(-2_400),
          updatedAt: now.addingTimeInterval(-2_400),
          source: .chat(conversationID: heroConversationID, messageID: "seed-msg-hero-user")
        ),
        data: assets.launchChecklistMarkdown
      ),
    ]

    if isShowcase {
      items.append(contentsOf: [
        PortableLibraryEntry(
          entry: LibraryEntry(
            id: "seed-lib-sync-diagram",
            filename: "sync-architecture.png",
            kind: .image,
            mimeType: "image/png",
            byteCount: assets.architectureDiagramPNG.count,
            createdAt: now.addingTimeInterval(-86_400 * 1 - 1_200),
            updatedAt: now.addingTimeInterval(-86_400 * 1 - 1_200),
            source: .manual
          ),
          data: assets.architectureDiagramPNG
        ),
        PortableLibraryEntry(
          entry: LibraryEntry(
            id: "seed-lib-wireframe",
            filename: "iphone-wireframe.png",
            kind: .image,
            mimeType: "image/png",
            byteCount: assets.wireframePNG.count,
            createdAt: now.addingTimeInterval(-86_400 * 2 - 3_600),
            updatedAt: now.addingTimeInterval(-86_400 * 2 - 3_600),
            source: .project(launchProjectID)
          ),
          data: assets.wireframePNG
        ),
        PortableLibraryEntry(
          entry: LibraryEntry(
            id: LibraryEntryID(rawValue: projectBriefAttachmentID),
            filename: "q4-release-brief.pdf",
            kind: .file,
            mimeType: "application/pdf",
            byteCount: assets.releaseBriefPDF.count,
            createdAt: now.addingTimeInterval(-86_400 * 3),
            updatedAt: now.addingTimeInterval(-86_400 * 3),
            source: .project(launchProjectID)
          ),
          data: assets.releaseBriefPDF
        ),
        PortableLibraryEntry(
          entry: LibraryEntry(
            id: LibraryEntryID(rawValue: modelNotesAttachmentID),
            filename: "provider-pricing-sheet.pdf",
            kind: .file,
            mimeType: "application/pdf",
            byteCount: assets.pricingSheetPDF.count,
            createdAt: now.addingTimeInterval(-86_400 * 5),
            updatedAt: now.addingTimeInterval(-86_400 * 5),
            source: .project(architectureProjectID)
          ),
          data: assets.pricingSheetPDF
        ),
      ])
    }

    return items
  }

  // MARK: - Telemetry Events (Analytics + Message Info)

  private static func telemetryEvents(now: Date, isShowcase: Bool) -> [TelemetryEvent] {
    var events: [TelemetryEvent] = [
      // Linked directly to heroAssistantMessageID so Message Info shows full Performance metrics.
      TelemetryEvent(
        timestamp: now.addingTimeInterval(-1_240),
        dataClass: .analytics,
        category: .provider,
        name: .providerRequestCompleted,
        outcome: .success,
        conversationID: heroConversationID,
        messageID: heroAssistantMessageID,
        providerID: BuiltInProviders.anthropicID,
        accountID: anthropicAccountID,
        modelID: "claude-sonnet-4-5",
        durationMilliseconds: 1_940,
        timeToFirstTokenMilliseconds: 760,
        inputTokens: 1_980,
        outputTokens: 184,
        cachedInputTokens: 920,
        metadata: ["outputTokensPerSecond": "82.4"]
      ),
      TelemetryEvent(
        timestamp: now.addingTimeInterval(-1_220),
        dataClass: .analytics,
        category: .tool,
        name: .toolCallCompleted,
        outcome: .success,
        conversationID: heroConversationID,
        messageID: heroAssistantMessageID,
        providerID: BuiltInProviders.anthropicID,
        accountID: anthropicAccountID,
        modelID: "claude-sonnet-4-5",
        durationMilliseconds: 340
      ),
      TelemetryEvent(
        timestamp: now.addingTimeInterval(-1_215),
        dataClass: .analytics,
        category: .mcp,
        name: .mcpRequestCompleted,
        outcome: .success,
        conversationID: heroConversationID,
        messageID: heroAssistantMessageID,
        durationMilliseconds: 310
      ),
      TelemetryEvent(
        timestamp: now.addingTimeInterval(-1_200),
        dataClass: .analytics,
        category: .provider,
        name: .providerRequestCompleted,
        outcome: .success,
        conversationID: heroConversationID,
        messageID: heroAssistantMessageID,
        providerID: BuiltInProviders.anthropicID,
        accountID: anthropicAccountID,
        modelID: "claude-sonnet-4-5",
        durationMilliseconds: 3_120,
        timeToFirstTokenMilliseconds: 810,
        inputTokens: 2_840,
        outputTokens: 756,
        cachedInputTokens: 1_720,
        reasoningTokens: 368,
        metadata: ["outputTokensPerSecond": "86.2"]
      ),
      // Linked to richAssistantMessageID.
      TelemetryEvent(
        timestamp: now.addingTimeInterval(-3_300),
        dataClass: .analytics,
        category: .provider,
        name: .providerRequestCompleted,
        outcome: .success,
        conversationID: richRenderConversationID,
        messageID: richAssistantMessageID,
        providerID: BuiltInProviders.openAIID,
        accountID: openAIAccountID,
        modelID: "gpt-5.2",
        durationMilliseconds: 2_890,
        timeToFirstTokenMilliseconds: 910,
        inputTokens: 2_310,
        outputTokens: 615,
        cachedInputTokens: 960,
        reasoningTokens: 210,
        metadata: ["outputTokensPerSecond": "79.5"]
      ),
    ]

    guard isShowcase else { return events }

    struct SampleSpec {
      let daysAgo: Double
      let providerID: ProviderID
      let accountID: ProviderAccountID
      let modelID: ModelID
      let ttftMs: Double
      let durationMs: Double
      let speed: Double
      let inputTokens: Int
      let outputTokens: Int
      let hasTool: Bool
    }

    let samples: [SampleSpec] = [
      // Today
      .init(daysAgo: 0.08, providerID: BuiltInProviders.geminiID, accountID: geminiAccountID, modelID: "gemini-2.5-flash", ttftMs: 580, durationMs: 1_820, speed: 118.4, inputTokens: 1_420, outputTokens: 480, hasTool: false),
      .init(daysAgo: 0.14, providerID: BuiltInProviders.ollamaID, accountID: ollamaAccountID, modelID: "qwen3:32b", ttftMs: 310, durationMs: 2_150, speed: 64.0, inputTokens: 980, outputTokens: 390, hasTool: false),
      .init(daysAgo: 0.21, providerID: BuiltInProviders.openRouterID, accountID: openRouterAccountID, modelID: "anthropic/claude-sonnet-4.5", ttftMs: 1_040, durationMs: 3_420, speed: 74.8, inputTokens: 3_210, outputTokens: 810, hasTool: true),
      // Last 7 days
      .init(daysAgo: 1.1, providerID: BuiltInProviders.anthropicID, accountID: anthropicAccountID, modelID: "claude-sonnet-4-5", ttftMs: 790, durationMs: 2_760, speed: 83.2, inputTokens: 3_640, outputTokens: 740, hasTool: true),
      .init(daysAgo: 1.4, providerID: BuiltInProviders.openAIID, accountID: openAIAccountID, modelID: "gpt-5.2", ttftMs: 930, durationMs: 3_050, speed: 78.0, inputTokens: 2_890, outputTokens: 690, hasTool: false),
      .init(daysAgo: 2.2, providerID: BuiltInProviders.geminiID, accountID: geminiAccountID, modelID: "gemini-2.5-pro", ttftMs: 740, durationMs: 2_480, speed: 96.5, inputTokens: 4_120, outputTokens: 910, hasTool: false),
      .init(daysAgo: 2.6, providerID: BuiltInProviders.anthropicID, accountID: anthropicAccountID, modelID: "claude-opus-4-1", ttftMs: 1_180, durationMs: 4_210, speed: 62.4, inputTokens: 5_200, outputTokens: 1_040, hasTool: true),
      .init(daysAgo: 3.3, providerID: BuiltInProviders.openAIID, accountID: openAIAccountID, modelID: "gpt-5-mini", ttftMs: 520, durationMs: 1_640, speed: 109.0, inputTokens: 1_640, outputTokens: 420, hasTool: false),
      .init(daysAgo: 4.1, providerID: BuiltInProviders.openRouterID, accountID: openRouterAccountID, modelID: "anthropic/claude-sonnet-4.5", ttftMs: 1_120, durationMs: 3_680, speed: 72.1, inputTokens: 3_880, outputTokens: 860, hasTool: true),
      .init(daysAgo: 5.2, providerID: BuiltInProviders.geminiID, accountID: geminiAccountID, modelID: "gemini-2.5-flash", ttftMs: 610, durationMs: 1_790, speed: 115.2, inputTokens: 2_050, outputTokens: 540, hasTool: false),
      .init(daysAgo: 6.0, providerID: BuiltInProviders.ollamaID, accountID: ollamaAccountID, modelID: "qwen3:32b", ttftMs: 340, durationMs: 2_440, speed: 61.5, inputTokens: 1_240, outputTokens: 440, hasTool: false),
      // 8–21 days ago
      .init(daysAgo: 8.5, providerID: BuiltInProviders.anthropicID, accountID: anthropicAccountID, modelID: "claude-sonnet-4-5", ttftMs: 820, durationMs: 2_980, speed: 84.0, inputTokens: 4_400, outputTokens: 920, hasTool: true),
      .init(daysAgo: 10.2, providerID: BuiltInProviders.openAIID, accountID: openAIAccountID, modelID: "gpt-5.2", ttftMs: 890, durationMs: 2_940, speed: 80.1, inputTokens: 3_150, outputTokens: 760, hasTool: false),
      .init(daysAgo: 12.4, providerID: BuiltInProviders.geminiID, accountID: geminiAccountID, modelID: "gemini-2.5-pro", ttftMs: 770, durationMs: 2_610, speed: 94.0, inputTokens: 3_910, outputTokens: 830, hasTool: false),
      .init(daysAgo: 15.0, providerID: BuiltInProviders.anthropicID, accountID: anthropicAccountID, modelID: "claude-sonnet-4-5", ttftMs: 750, durationMs: 2_640, speed: 85.4, inputTokens: 3_560, outputTokens: 780, hasTool: true),
      .init(daysAgo: 18.3, providerID: BuiltInProviders.openRouterID, accountID: openRouterAccountID, modelID: "anthropic/claude-sonnet-4.5", ttftMs: 1_090, durationMs: 3_510, speed: 73.6, inputTokens: 2_920, outputTokens: 670, hasTool: false),
    ]

    for sample in samples {
      let timestamp = now.addingTimeInterval(-86_400 * sample.daysAgo)
      events.append(
        TelemetryEvent(
          timestamp: timestamp,
          dataClass: .analytics,
          category: .provider,
          name: .providerRequestCompleted,
          outcome: .success,
          providerID: sample.providerID,
          accountID: sample.accountID,
          modelID: sample.modelID,
          durationMilliseconds: sample.durationMs,
          timeToFirstTokenMilliseconds: sample.ttftMs,
          inputTokens: sample.inputTokens,
          outputTokens: sample.outputTokens,
          metadata: ["outputTokensPerSecond": String(format: "%.1f", sample.speed)]
        )
      )
      if sample.hasTool {
        events.append(
          TelemetryEvent(
            timestamp: timestamp.addingTimeInterval(-10),
            dataClass: .analytics,
            category: .tool,
            name: .toolCallCompleted,
            outcome: .success,
            providerID: sample.providerID,
            accountID: sample.accountID,
            modelID: sample.modelID,
            durationMilliseconds: 290
          )
        )
        events.append(
          TelemetryEvent(
            timestamp: timestamp.addingTimeInterval(-12),
            dataClass: .analytics,
            category: .mcp,
            name: .mcpRequestCompleted,
            outcome: .success,
            durationMilliseconds: 270
          )
        )
      }
    }

    return events
  }
}

// MARK: - Programmatic Debug Assets (Zero Release Binary Overhead)

private struct SeedAssets: Sendable {
  let launchChecklistMarkdown: Data
  let latencyChartPNG: Data
  let architectureDiagramPNG: Data
  let wireframePNG: Data
  let releaseBriefPDF: Data
  let pricingSheetPDF: Data
}

@MainActor
private enum SeedAssetGenerator {
  static func generate(isShowcase: Bool) -> SeedAssets {
    let checklist = Data(
      """
      # BYOK Chat 1.2 Launch Checklist
      - [x] PrivacyInfo.xcprivacy verified
      - [x] ITSAppUsesNonExemptEncryption set to false
      - [x] Direct provider transport & Keychain vault audit
      - [ ] Capture deterministic raw App Store screenshots
      - [ ] Clean-install TestFlight verification pass
      - [ ] Pin default release model configuration
      """.utf8
    )

    let latencyChart = renderLatencyChartPNG()
    let architectureDiagram = isShowcase ? renderArchitectureDiagramPNG() : latencyChart
    let wireframe = isShowcase ? renderWireframePNG() : latencyChart
    let releaseBrief = renderPDF(
      title: "BYOK Chat · Q4 Release Brief",
      lines: [
        "1. Direct-to-provider architecture with zero third-party proxy servers.",
        "2. API keys and MCP bearer tokens remain isolated in iOS Keychain.",
        "3. Remote MCP tools enforce explicit per-chat Always / Ask / Off policies.",
        "4. On-device SQLite analytics track spend, token usage, and TTFT locally.",
      ]
    )
    let pricingSheet = isShowcase
      ? renderPDF(
          title: "Provider Latency & Token Cost Notes",
          lines: [
            "Anthropic Claude Sonnet 4.5 — $3 / $15 per 1M tokens · 1M context.",
            "OpenAI GPT-5.2 — $2.50 / $10 per 1M tokens · 400K context.",
            "Google Gemini 2.5 Flash — $0.30 / $2.50 per 1M tokens · 1M context.",
            "Local Ollama (Qwen 3 32B) — $0 local inference on private LAN.",
          ]
        )
      : releaseBrief

    return SeedAssets(
      launchChecklistMarkdown: checklist,
      latencyChartPNG: latencyChart,
      architectureDiagramPNG: architectureDiagram,
      wireframePNG: wireframe,
      releaseBriefPDF: releaseBrief,
      pricingSheetPDF: pricingSheet
    )
  }

  private static func renderLatencyChartPNG() -> Data {
    let size = CGSize(width: 960, height: 680)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let renderer = UIGraphicsImageRenderer(size: size, format: format)
    let image = renderer.image { context in
      let cg = context.cgContext
      UIColor(red: 0.05, green: 0.09, blue: 0.16, alpha: 1).setFill()
      cg.fill(CGRect(origin: .zero, size: size))

      let cardRect = CGRect(x: 56, y: 56, width: size.width - 112, height: size.height - 112)
      let cardPath = UIBezierPath(roundedRect: cardRect, cornerRadius: 32)
      UIColor(red: 0.09, green: 0.15, blue: 0.25, alpha: 1).setFill()
      cardPath.fill()
      UIColor(red: 0.20, green: 0.31, blue: 0.48, alpha: 1).setStroke()
      cardPath.lineWidth = 2
      cardPath.stroke()

      let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 34, weight: .bold),
        .foregroundColor: UIColor(red: 0.92, green: 0.95, blue: 0.99, alpha: 1),
      ]
      let subtitleAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 22, weight: .medium),
        .foregroundColor: UIColor(red: 0.60, green: 0.68, blue: 0.80, alpha: 1),
      ]
      ("Provider TTFT Benchmark" as NSString).draw(at: CGPoint(x: 104, y: 102), withAttributes: titleAttrs)
      ("Median time to first token (lower is faster)" as NSString).draw(at: CGPoint(x: 104, y: 148), withAttributes: subtitleAttrs)

      let bars: [(String, CGFloat, String, UIColor)] = [
        ("Ollama Local", 0.34, "0.31 s", UIColor(red: 0.20, green: 0.83, blue: 0.60, alpha: 1)),
        ("Gemini 2.5", 0.56, "0.64 s", UIColor(red: 0.37, green: 0.66, blue: 1.00, alpha: 1)),
        ("Anthropic", 0.68, "0.78 s", UIColor(red: 0.66, green: 0.51, blue: 0.98, alpha: 1)),
        ("OpenAI", 0.80, "0.92 s", UIColor(red: 0.98, green: 0.62, blue: 0.29, alpha: 1)),
      ]

      let labelAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 24, weight: .semibold),
        .foregroundColor: UIColor(red: 0.88, green: 0.92, blue: 0.98, alpha: 1),
      ]
      let valueAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.monospacedDigitSystemFont(ofSize: 22, weight: .bold),
        .foregroundColor: UIColor(red: 0.72, green: 0.80, blue: 0.92, alpha: 1),
      ]

      for (index, item) in bars.enumerated() {
        let y = CGFloat(232 + index * 92)
        (item.0 as NSString).draw(at: CGPoint(x: 104, y: y), withAttributes: labelAttrs)
        (item.2 as NSString).draw(at: CGPoint(x: 760, y: y), withAttributes: valueAttrs)

        let track = UIBezierPath(roundedRect: CGRect(x: 104, y: y + 40, width: 736, height: 22), cornerRadius: 11)
        UIColor(red: 0.14, green: 0.22, blue: 0.35, alpha: 1).setFill()
        track.fill()

        let fill = UIBezierPath(roundedRect: CGRect(x: 104, y: y + 40, width: 736 * item.1, height: 22), cornerRadius: 11)
        item.3.setFill()
        fill.fill()
      }
    }
    return image.pngData() ?? Data()
  }

  private static func renderArchitectureDiagramPNG() -> Data {
    let size = CGSize(width: 960, height: 680)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let renderer = UIGraphicsImageRenderer(size: size, format: format)
    let image = renderer.image { context in
      let cg = context.cgContext
      UIColor(red: 0.08, green: 0.07, blue: 0.13, alpha: 1).setFill()
      cg.fill(CGRect(origin: .zero, size: size))

      let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 34, weight: .bold),
        .foregroundColor: UIColor(red: 0.96, green: 0.94, blue: 0.99, alpha: 1),
      ]
      ("Zero-Proxy BYOK Architecture" as NSString).draw(at: CGPoint(x: 72, y: 64), withAttributes: titleAttrs)

      let boxes: [(CGRect, String, String, UIColor)] = [
        (CGRect(x: 72, y: 240, width: 240, height: 180), "iPhone App", "Keychain + SQLite", UIColor(red: 0.45, green: 0.56, blue: 0.99, alpha: 1)),
        (CGRect(x: 380, y: 150, width: 250, height: 150), "AI Providers", "Anthropic · OpenAI · Gemini", UIColor(red: 0.72, green: 0.52, blue: 0.95, alpha: 1)),
        (CGRect(x: 380, y: 360, width: 250, height: 150), "Remote MCP", "GitHub · Web · Linear", UIColor(red: 0.20, green: 0.82, blue: 0.62, alpha: 1)),
        (CGRect(x: 690, y: 240, width: 200, height: 180), "Local LAN", "Ollama · LM Studio", UIColor(red: 0.98, green: 0.62, blue: 0.30, alpha: 1)),
      ]

      // Connecting lines
      UIColor(red: 0.58, green: 0.66, blue: 0.84, alpha: 0.65).setStroke()
      cg.setLineWidth(4)
      cg.move(to: CGPoint(x: 312, y: 310))
      cg.addLine(to: CGPoint(x: 380, y: 225))
      cg.move(to: CGPoint(x: 312, y: 350))
      cg.addLine(to: CGPoint(x: 380, y: 435))
      cg.move(to: CGPoint(x: 630, y: 225))
      cg.addLine(to: CGPoint(x: 690, y: 310))
      cg.strokePath()

      for (rect, title, detail, accent) in boxes {
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 24)
        UIColor(red: 0.14, green: 0.12, blue: 0.22, alpha: 1).setFill()
        path.fill()
        accent.setStroke()
        path.lineWidth = 3
        path.stroke()

        let hAttrs: [NSAttributedString.Key: Any] = [
          .font: UIFont.systemFont(ofSize: 25, weight: .bold),
          .foregroundColor: UIColor.white,
        ]
        let sAttrs: [NSAttributedString.Key: Any] = [
          .font: UIFont.systemFont(ofSize: 17, weight: .medium),
          .foregroundColor: UIColor(red: 0.78, green: 0.75, blue: 0.88, alpha: 1),
        ]
        (title as NSString).draw(at: CGPoint(x: rect.minX + 20, y: rect.minY + 34), withAttributes: hAttrs)
        (detail as NSString).draw(at: CGPoint(x: rect.minX + 20, y: rect.minY + 78), withAttributes: sAttrs)
      }
    }
    return image.pngData() ?? Data()
  }

  private static func renderWireframePNG() -> Data {
    let size = CGSize(width: 960, height: 680)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let renderer = UIGraphicsImageRenderer(size: size, format: format)
    let image = renderer.image { context in
      let cg = context.cgContext
      UIColor(red: 0.94, green: 0.92, blue: 0.88, alpha: 1).setFill()
      cg.fill(CGRect(origin: .zero, size: size))

      let phoneRect = CGRect(x: 320, y: 48, width: 320, height: 584)
      let phone = UIBezierPath(roundedRect: phoneRect, cornerRadius: 44)
      UIColor(red: 0.99, green: 0.98, blue: 0.96, alpha: 1).setFill()
      phone.fill()
      UIColor(red: 0.76, green: 0.70, blue: 0.62, alpha: 1).setStroke()
      phone.lineWidth = 4
      phone.stroke()

      let bubbleA = UIBezierPath(roundedRect: CGRect(x: 416, y: 132, width: 196, height: 68), cornerRadius: 20)
      UIColor(red: 0.76, green: 0.35, blue: 0.16, alpha: 1).setFill()
      bubbleA.fill()

      let cardB = UIBezierPath(roundedRect: CGRect(x: 348, y: 224, width: 264, height: 220), cornerRadius: 20)
      UIColor(red: 0.93, green: 0.89, blue: 0.83, alpha: 1).setFill()
      cardB.fill()

      let composer = UIBezierPath(roundedRect: CGRect(x: 348, y: 540, width: 264, height: 52), cornerRadius: 26)
      UIColor(red: 0.88, green: 0.83, blue: 0.76, alpha: 1).setFill()
      composer.fill()

      let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 22, weight: .bold),
        .foregroundColor: UIColor(red: 0.18, green: 0.14, blue: 0.11, alpha: 1),
      ]
      ("BYOK Chat · Wireframe" as NSString).draw(at: CGPoint(x: 48, y: 64), withAttributes: titleAttrs)
    }
    return image.pngData() ?? Data()
  }

  private static func renderPDF(title: String, lines: [String]) -> Data {
    let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
    let renderer = UIGraphicsPDFRenderer(bounds: bounds)
    return renderer.pdfData { context in
      context.beginPage()
      let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 22, weight: .bold),
        .foregroundColor: UIColor.label,
      ]
      let bodyAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 13, weight: .regular),
        .foregroundColor: UIColor.darkGray,
      ]
      (title as NSString).draw(at: CGPoint(x: 48, y: 56), withAttributes: titleAttrs)
      for (index, line) in lines.enumerated() {
        (line as NSString).draw(
          in: CGRect(x: 48, y: 112 + index * 34, width: 516, height: 30),
          withAttributes: bodyAttrs
        )
      }
    }
  }
}
#endif
