import BYOKchatProviderCore
import Foundation
import Testing

@testable import BYOKmac

@MainActor
@Suite("macOS analytics parity", .serialized)
struct MacAnalyticsTests {
  // MARK: - Provider & Model Display Name Resolution

  @Test("macUsageDisplayName resolves all 18 ProviderKinds, account labels, and UUID fallbacks")
  func usageDisplayNameCoversAllProviderKindsAndAccounts() {
    let expectedBuiltInNames: [(ProviderKind, String)] = [
      (.anthropic, "Anthropic"),
      (.openai, "OpenAI"),
      (.xAI, "xAI"),
      (.gemini, "Gemini"),
      (.deepSeek, "DeepSeek"),
      (.zAI, "Z.ai"),
      (.moonshot, "Moonshot AI"),
      (.minimax, "MiniMax"),
      (.qwen, "Alibaba Qwen"),
      (.mistral, "Mistral AI"),
      (.groq, "Groq"),
      (.together, "Together AI"),
      (.fireworks, "Fireworks AI"),
      (.openRouter, "OpenRouter"),
      (.nvidia, "NVIDIA"),
      (.ollama, "Ollama"),
      (.lmStudio, "LM Studio"),
    ]

    // Every built-in kind has a non-empty canonical display name and matches case-insensitively.
    #expect(expectedBuiltInNames.count == ProviderKind.allCases.count - 1)
    for (kind, expected) in expectedBuiltInNames {
      let providerID = kind.defaultProviderID!.rawValue
      #expect(macUsageDisplayName(providerID) == expected)
      #expect(macUsageDisplayName(providerID.uppercased()) == expected)
    }

    // Custom OpenAI-compatible provider UUID resolves via matching account label.
    let customProviderUUID = "550E8400-E29B-41D4-A716-446655440000"
    let customAccountID = "660E8400-E29B-41D4-A716-446655440001"
    let customAccount = ProviderAccount(
      kind: .openAICompatible,
      id: ProviderAccountID(rawValue: customAccountID),
      providerID: ProviderID(rawValue: customProviderUUID.lowercased()),
      label: "Corp vLLM Gateway"
    )

    #expect(macUsageDisplayName(customProviderUUID, accounts: [customAccount]) == "Corp vLLM Gateway")
    #expect(macUsageDisplayName(customAccountID, accounts: [customAccount]) == "Corp vLLM Gateway")

    // Unmatched UUID uses fallbackLabel when provided, otherwise "Custom Provider" (never raw UUID).
    let orphanUUID = "770e8400-e29b-41d4-a716-446655440002"
    #expect(macUsageDisplayName(orphanUUID, accounts: [customAccount], fallbackLabel: "Staging Server") == "Staging Server")
    #expect(macUsageDisplayName(orphanUUID, accounts: [customAccount]) == "Custom Provider")

    // Non-UUID unknown string falls back to raw value.
    #expect(macUsageDisplayName("my-local-proxy", accounts: []) == "my-local-proxy")
  }

  @Test("macUsageModelDisplayName prefers discovered record displayName and falls back gracefully")
  func usageModelDisplayNameResolvesRecordsAndFallback() {
    let accountA = ProviderAccountID(rawValue: "acct-a")
    let accountB = ProviderAccountID(rawValue: "acct-b")
    let manualRecord = AccountModelRecord(
      accountID: accountA,
      model: ProviderModel(
        providerID: "openai",
        id: "custom/model-x",
        displayName: "Manual Name"
      ),
      isManual: true
    )
    let discoveredRecord = AccountModelRecord(
      accountID: accountB,
      model: ProviderModel(
        providerID: "openai",
        id: "custom/model-x",
        displayName: "Discovered Model X"
      ),
      isManual: false
    )

    let modelsByAccount: [ProviderAccountID: [AccountModelRecord]] = [
      accountA: [manualRecord],
      accountB: [discoveredRecord],
    ]

    #expect(macUsageModelDisplayName("custom/model-x", modelsByAccount: modelsByAccount) == "Discovered Model X")
    #expect(macUsageModelDisplayName("unknown/raw-id", modelsByAccount: modelsByAccount) == "unknown/raw-id")
  }

  // MARK: - Acronym-Preserving Error & Category Titles

  @Test("macAnalyticsErrorTitle preserves technical acronyms and formats separators cleanly")
  func errorTitlePreservesAcronyms() {
    #expect(macAnalyticsErrorTitle("http_502_bad_gateway") == "HTTP 502 Bad Gateway")
    #expect(macAnalyticsErrorTitle("mcp_sse_eof") == "MCP SSE EOF")
    #expect(macAnalyticsErrorTitle("invalid_api_url") == "Invalid API URL")
    #expect(macAnalyticsErrorTitle("tls_ssl_handshake_failed") == "TLS SSL Handshake Failed")
    #expect(macAnalyticsErrorTitle("dns_lookup_timeout") == "DNS Lookup Timeout")
    #expect(macAnalyticsErrorTitle("malformed_json_id") == "Malformed JSON ID")
    #expect(macAnalyticsErrorTitle("https-oauth-token-expired") == "HTTPS OAuth Token Expired")

    #expect(macUsageCategoryTitle(.mcp) == "MCP")
    #expect(macUsageCategoryTitle(.provider) == "Provider")
    #expect(macUsageCategoryTitle(.tool) == "Tool")
  }

  // MARK: - Cost, Token, and Footnote Formatting Parity

  @Test("Cost formatting matches iOS parity for No requests, Unavailable, exact, estimated, and partial lower bounds")
  func costFormattingMatchesIOSParity() {
    // Empty aggregate -> No requests
    let empty = ChatUsageAggregate()
    #expect(macUsageAggregateCost(empty) == "No requests")

    // Requests without known pricing -> Unavailable
    var unavailable = ChatUsageAggregate()
    unavailable.assistantMessageCount = 2
    unavailable.incompleteCostMessageCount = 2
    #expect(macUsageAggregateCost(unavailable) == "Unavailable")

    // Exact complete provider-reported cost -> no ~ or ≥ prefix
    var exact = ChatUsageAggregate()
    exact.assistantMessageCount = 1
    exact.knownCostMessageCount = 1
    exact.costUSD = Decimal(string: "0.1234")!
    #expect(macUsageAggregateCost(exact) == "$0.1234")

    // Exact large cost -> 2 decimals
    var exactLarge = ChatUsageAggregate()
    exactLarge.assistantMessageCount = 3
    exactLarge.knownCostMessageCount = 3
    exactLarge.costUSD = Decimal(string: "12.5")!
    #expect(macUsageAggregateCost(exactLarge) == "$12.50")

    // Exact zero cost -> "$0.00" (not "$0.000000")
    var exactZero = ChatUsageAggregate()
    exactZero.assistantMessageCount = 1
    exactZero.knownCostMessageCount = 1
    exactZero.costUSD = .zero
    #expect(macUsageAggregateCost(exactZero) == "$0.00")

    // Calculated complete cost -> "~" prefix
    var calculated = ChatUsageAggregate()
    calculated.assistantMessageCount = 1
    calculated.knownCostMessageCount = 1
    calculated.estimatedCostMessageCount = 1
    calculated.costUSD = Decimal(string: "0.00045")!
    #expect(macUsageAggregateCost(calculated) == "~$0.000450")

    // Calculated partial cost -> "~" prefix + " (partial)"
    var calculatedPartial = calculated
    calculatedPartial.incompleteCostMessageCount = 1
    #expect(macUsageAggregateCost(calculatedPartial) == "~$0.000450 (partial)")

    // Provider-reported partial cost (lower bound, no calculated estimate) -> "≥" prefix + " (partial)"
    var lowerBound = ChatUsageAggregate()
    lowerBound.assistantMessageCount = 2
    lowerBound.knownCostMessageCount = 1
    lowerBound.incompleteCostMessageCount = 1
    lowerBound.costUSD = Decimal(string: "1.25")!
    #expect(macUsageAggregateCost(lowerBound) == "≥$1.25 (partial)")

    // OpenRouter BYOK footnote appears only when scopedProviderCostMessageCount > 0.
    let standardFootnote = macUsageHistoryFootnote(exact)
    #expect(!standardFootnote.contains("OpenRouter BYOK"))

    var openRouterScoped = exact
    openRouterScoped.scopedProviderCostMessageCount = 1
    let byokFootnote = macUsageHistoryFootnote(openRouterScoped)
    #expect(byokFootnote.contains("OpenRouter BYOK"))

    // Cached token hit-rate % & compact token boundaries
    #expect(macUsageCompactTokens(999_950) == "1.00M")
    #expect(macUsageCompactTokens(1_500) == "1.5K")
    #expect(macUsageCachedTokensWithRate(cached: 250, input: 1_000).contains("25%"))
    #expect(macUsageCachedTokensWithRate(cached: 0, input: 1_000) == "0")
  }

  // MARK: - Context Window Fill Calculation

  @Test("Context window usage resolves model context window, calculates fill fraction, and preserves omitted counts")
  func contextWindowFillAndOmittedMessages() {
    let accountID = ProviderAccountID(rawValue: "acct-openai")
    let modelID = ModelID(rawValue: "gpt-4o-custom")
    let account = ProviderAccount(
      kind: .openai,
      id: accountID,
      providerID: "openai",
      label: "OpenAI"
    )
    let record = AccountModelRecord(
      accountID: accountID,
      model: ProviderModel(
        providerID: "openai",
        id: modelID,
        displayName: "GPT-4o Custom",
        contextWindow: 128_000
      )
    )
    let assistantMessage = ChatMessage(
      id: "msg-latest",
      role: .assistant,
      content: "Done.",
      status: .complete,
      providerID: "openai",
      accountID: accountID,
      modelID: modelID,
      usage: ProviderUsage(inputTokens: 64_000, outputTokens: 1_200)
    )
    let conversation = ChatConversation(
      id: "chat-context",
      title: "Long Thread",
      providerID: "openai",
      accountID: accountID,
      modelID: modelID,
      messages: [assistantMessage],
      lastContextOmittedMessageCount: 3
    )

    // Even with empty telemetry (e.g. cleared/pruned), persisted lastContextOmittedMessageCount & model contextWindow work.
    let withoutTelemetry = macConversationContextUsage(
      conversation: conversation,
      telemetryEvents: [],
      accounts: [account],
      modelsByAccount: [accountID: [record]]
    )
    #expect(withoutTelemetry != nil)
    #expect(withoutTelemetry?.usedInputTokens == 64_000)
    #expect(withoutTelemetry?.contextWindow == 128_000)
    #expect(withoutTelemetry?.fillFraction == 0.5)
    #expect(withoutTelemetry?.omittedMessageCount == 3)
    #expect(withoutTelemetry?.isEstimated == false)

    // When .contextBuilt event reports higher omitted count on matching message, it is honored.
    let contextEvent = TelemetryEvent(
      dataClass: .analytics,
      category: .context,
      name: .contextBuilt,
      conversationID: conversation.id,
      messageID: assistantMessage.id,
      metadata: [
        "estimatedInputTokens": "62000",
        "contextWindow": "128000",
        "omittedMessageCount": "5",
      ]
    )
    let withTelemetry = macConversationContextUsage(
      conversation: conversation,
      telemetryEvents: [contextEvent],
      accounts: [account],
      modelsByAccount: [accountID: [record]]
    )
    #expect(withTelemetry?.omittedMessageCount == 5)
    #expect(withTelemetry?.fillFraction == 0.5)

    // Falls back to estimated input tokens when assistant message has no reported usage.
    let noUsageConversation = ChatConversation(
      id: "chat-estimated",
      title: "Estimated",
      providerID: "openai",
      accountID: accountID,
      modelID: modelID,
      messages: []
    )
    let estimatedEvent = TelemetryEvent(
      dataClass: .analytics,
      category: .context,
      name: .contextBuilt,
      conversationID: noUsageConversation.id,
      metadata: [
        "estimatedInputTokens": "102400",
        "contextWindow": "128000",
        "omittedMessageCount": "2",
      ]
    )
    let estimated = macConversationContextUsage(
      conversation: noUsageConversation,
      telemetryEvents: [estimatedEvent],
      accounts: [account],
      modelsByAccount: [accountID: [record]]
    )
    #expect(estimated?.usedInputTokens == 102_400)
    #expect(estimated?.fillFraction == 0.8)
    #expect(estimated?.omittedMessageCount == 2)
    #expect(estimated?.isEstimated == true)
  }

  // MARK: - Rollup-Backed Overview & Per-Conversation Loading

  @Test("MacAnalyticsModel loads daily rollups off-main-actor, clamps Free range, and loads per-conversation analytics")
  func rollupBackedOverviewAndPerConversationAnalytics() async throws {
    let context = try await makeMacAnalyticsTestContext()
    defer { context.cleanup() }

    let noonToday = Calendar.current
      .startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
      .addingTimeInterval(12 * 60 * 60)
    let now = noonToday
    let fortyDaysAgo = now.addingTimeInterval(-40 * 24 * 60 * 60)

    // Configure an Anthropic account with a model that has an explicit context window.
    let account = try await context.services.accountManager.createAccount(
      kind: .anthropic,
      label: "Anthropic Work",
      credential: "sk-ant-test",
      defaultModelID: "claude-sonnet-4-5"
    )
    try await context.services.providerWorkspace.mergeModels(
      [
        ProviderModel(
          providerID: account.providerID,
          id: "claude-sonnet-4-5",
          displayName: "Claude Sonnet 4.5",
          contextWindow: 200_000
        )
      ],
      for: account.id
    )

    // Create a conversation with cached + cache write + reasoning tokens, billing metadata, and omitted context count.
    let chat = try await context.services.conversationStore.createConversation(
      providerID: account.providerID,
      accountID: account.id,
      modelID: "claude-sonnet-4-5"
    )
    try await context.services.conversationStore.renameConversation(chat.id, title: "Architecture Review")
    let turn = try await context.services.conversationStore.beginTurn(
      conversationID: chat.id,
      userText: "Review this design",
      at: now.addingTimeInterval(-120)
    )
    let responseMetadata = ChatBilling.metadata(
      existing: ["costUSD": "0.25"],
      usage: ProviderUsage(
        inputTokens: 100_000,
        outputTokens: 2_500,
        cachedInputTokens: 40_000,
        reasoningTokens: 1_000,
        cacheWriteTokens: 10_000
      ),
      model: nil,
      modelRequestCount: 2,
      toolCallCount: 3
    )
    _ = try await context.services.conversationStore.completeMessage(
      conversationID: chat.id,
      messageID: turn.assistantMessage.id,
      response: ProviderResponse(
        text: "Looks solid.",
        providerID: account.providerID,
        accountID: account.id,
        modelID: "claude-sonnet-4-5",
        usage: ProviderUsage(
          inputTokens: 100_000,
          outputTokens: 2_500,
          cachedInputTokens: 40_000,
          reasoningTokens: 1_000,
          cacheWriteTokens: 10_000
        ),
        metadata: responseMetadata
      ),
      at: now.addingTimeInterval(-60)
    )
    try await context.services.conversationStore.setContextOmissionCount(4, conversationID: chat.id)

    // Record old (>30d) events that will be archived into daily rollups & error rollups during maintenance.
    await context.services.telemetryRecorder.record(
      TelemetryEvent(
        timestamp: fortyDaysAgo,
        dataClass: .analytics,
        category: .provider,
        name: .providerRequestCompleted,
        outcome: .success,
        providerID: account.providerID,
        accountID: account.id,
        modelID: "claude-sonnet-4-5",
        durationMilliseconds: 2_000,
        timeToFirstTokenMilliseconds: 300,
        metadata: ["outputTokensPerSecond": "40.0"]
      )
    )
    await context.services.telemetryRecorder.record(
      TelemetryEvent(
        timestamp: fortyDaysAgo.addingTimeInterval(30),
        dataClass: .analytics,
        category: .provider,
        name: .providerRequestFailed,
        outcome: .failure,
        providerID: account.providerID,
        accountID: account.id,
        modelID: "claude-sonnet-4-5",
        errorCode: "http_429_rate_limited",
        metadata: ["classification": "rate_limit"]
      )
    )
    await context.services.telemetryRecorder.record(
      TelemetryEvent(
        timestamp: fortyDaysAgo.addingTimeInterval(45),
        dataClass: .analytics,
        category: .tool,
        name: .toolCallCancelled,
        outcome: .cancelled
      )
    )

    // Record recent events scoped to this conversation (including tool failure, tool cancel, provider error, and contextBuilt).
    await context.services.telemetryRecorder.record(
      TelemetryEvent(
        timestamp: now.addingTimeInterval(-60),
        dataClass: .analytics,
        category: .provider,
        name: .providerRequestCompleted,
        outcome: .success,
        conversationID: chat.id,
        messageID: turn.assistantMessage.id,
        providerID: account.providerID,
        accountID: account.id,
        modelID: "claude-sonnet-4-5",
        durationMilliseconds: 1_000,
        timeToFirstTokenMilliseconds: 200,
        metadata: ["outputTokensPerSecond": "60.0"]
      )
    )
    await context.services.telemetryRecorder.record(
      TelemetryEvent(
        timestamp: now.addingTimeInterval(-55),
        dataClass: .analytics,
        category: .tool,
        name: .toolCallFailed,
        outcome: .failure,
        conversationID: chat.id,
        messageID: turn.assistantMessage.id,
        errorCode: "mcp_timeout",
        metadata: ["classification": "timeout"]
      )
    )
    await context.services.telemetryRecorder.record(
      TelemetryEvent(
        timestamp: now.addingTimeInterval(-50),
        dataClass: .analytics,
        category: .tool,
        name: .toolCallCancelled,
        outcome: .cancelled,
        conversationID: chat.id,
        messageID: turn.assistantMessage.id
      )
    )
    await context.services.telemetryRecorder.record(
      TelemetryEvent(
        timestamp: now.addingTimeInterval(-62),
        dataClass: .analytics,
        category: .context,
        name: .contextBuilt,
        conversationID: chat.id,
        messageID: turn.assistantMessage.id,
        metadata: [
          "estimatedInputTokens": "98000",
          "contextWindow": "200000",
          "omittedMessageCount": "4",
        ]
      )
    )

    // Prune >30d events into daily rollups.
    await context.services.telemetryRecorder.performMaintenance(referenceDate: now)

    let model = MacAnalyticsModel(services: context.services)
    await model.load(range: .all, hasPro: true, reference: now)

    #expect(model.hasLoaded)
    #expect(!model.overviewTelemetryUnavailable)
    #expect(!model.dailyRollups.isEmpty)
    #expect(!model.dailyErrorRollups.isEmpty)
    #expect(model.statistics.rollupRowCount >= 2)
    #expect(model.accounts.contains { $0.id == account.id })

    // Overview merges recent + rolled-up metrics.
    let overview = model.overviewSnapshot
    #expect(overview.activeConversationCount == 1)
    #expect(overview.conversationBreakdown.first?.id == chat.id)
    #expect(overview.conversationBreakdown.first?.title == "Architecture Review")
    #expect(overview.aggregate.totalTokens == 102_500)
    #expect(overview.aggregate.cachedInputTokens == 40_000)
    #expect(overview.aggregate.cacheWriteTokens == 10_000)
    #expect(overview.aggregate.reasoningTokens == 1_000)
    #expect(overview.performance.providerRequestCount == 3) // 1 recent + 2 rolled up
    #expect(overview.performance.providerSuccessCount == 2)
    #expect(overview.performance.providerFailureCount == 1)
    #expect(overview.performance.toolCancelledCount == 2) // 1 recent + 1 rolled up
    #expect(overview.failureBreakdown.contains { $0.errorCode == "http_429_rate_limited" && $0.count == 1 })
    #expect(overview.failureBreakdown.contains { $0.errorCode == "mcp_timeout" && $0.count == 1 })

    // Per-conversation analytics loads scoped events, context window fill, errors, tool counts, and breakdowns.
    let loadedChat = try #require(model.conversations.first { $0.id == chat.id })
    await model.loadConversation(loadedChat, reference: now)

    #expect(model.hasLoadedConversation)
    #expect(!model.conversationTelemetryUnavailable)
    #expect(model.selectedConversationIDLoaded == chat.id)

    let chatSnapshot = model.selectedConversationSnapshot
    #expect(chatSnapshot.aggregate.totalTokens == 102_500)
    #expect(chatSnapshot.performance.providerSuccessCount == 1)
    #expect(chatSnapshot.performance.toolFailureCount == 1)
    #expect(chatSnapshot.performance.toolCancelledCount == 1)
    #expect(chatSnapshot.failureBreakdown.contains { $0.errorCode == "mcp_timeout" && $0.count == 1 })
    #expect(chatSnapshot.providerBreakdown.first?.id == account.providerID.rawValue)
    #expect(chatSnapshot.modelBreakdown.first?.id == "claude-sonnet-4-5")

    let contextUsage = try #require(model.selectedConversationContextUsage)
    #expect(contextUsage.usedInputTokens == 100_000)
    #expect(contextUsage.contextWindow == 200_000)
    #expect(contextUsage.fillFraction == 0.5)
    #expect(contextUsage.omittedMessageCount == 4)

    // Free entitlement clamps historical ranges to .today.
    await model.load(range: .all, hasPro: false, reference: now)
    #expect(model.loadedRange == .today)
    #expect(model.overviewSnapshot.performance.providerRequestCount == 1)
  }

  // MARK: - Sheet Coordinator Deep-Link Routing

  @Test("MacUtilitySheetCoordinator routes Chat Usage & Analytics to a specific conversation and resets for Overview")
  func sheetCoordinatorAnalyticsRouting() {
    let coordinator = MacUtilitySheetCoordinator()
    let chatID = ConversationID(rawValue: "chat-deep-link")

    coordinator.presentAnalytics(conversationID: chatID)
    #expect(coordinator.destination == .analytics)
    #expect(coordinator.analyticsInitialConversationID == chatID)

    // Sidebar Overview entry clears the initial conversation ID.
    coordinator.present(.analytics)
    #expect(coordinator.destination == .analytics)
    #expect(coordinator.analyticsInitialConversationID == nil)

    coordinator.presentAnalytics(conversationID: chatID)
    coordinator.dismiss()
    #expect(coordinator.destination == nil)
    #expect(coordinator.analyticsInitialConversationID == nil)
  }
}

@MainActor
private struct MacAnalyticsTestContext {
  let parent: URL
  let suiteName: String
  let services: BYOKCoreServices

  func cleanup() {
    try? FileManager.default.removeItem(at: parent)
    UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
  }
}

@MainActor
private func makeMacAnalyticsTestContext() async throws -> MacAnalyticsTestContext {
  let parent = FileManager.default.temporaryDirectory
    .appendingPathComponent("byok-mac-analytics-tests-\(UUID().uuidString)", isDirectory: true)
  let root = parent.appendingPathComponent("Workspace", isDirectory: true)
  let telemetry = parent.appendingPathComponent("Telemetry", isDirectory: true)
  let suiteName = "byok-mac-analytics-tests-\(UUID().uuidString)"
  let storage = BYOKStorageEnvironment(
    rootDirectory: root,
    userDefaultsSuiteName: suiteName,
    credentialService: "tests.byok.mac.analytics.credentials.\(UUID().uuidString)",
    mcpCredentialService: "tests.byok.mac.analytics.mcp.\(UUID().uuidString)",
    telemetryDirectory: telemetry
  )

  try await BYOKStorageBootstrap.prepare(environment: storage)
  let services = try BYOKCoreServices(
    environment: storage,
    credentialVault: InMemoryCredentialVault(),
    mcpCredentialVault: InMemoryMCPCredentialVault()
  )
  try await services.loadStoredState()
  return MacAnalyticsTestContext(parent: parent, suiteName: suiteName, services: services)
}
