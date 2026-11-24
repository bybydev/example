import Foundation
import Testing

@testable import BYOKmac
import BYOKchatProviderCore

@Suite("macOS message details formatting")
struct MacMessageDetailsTests {
  private let enUS = Locale(identifier: "en_US")

  // MARK: - Provider, Account & Model Resolution

  @Test("Resolves built-in provider, account label, and model display name with distinct raw ID")
  func resolvesBuiltInProviderAccountAndModel() {
    let accountID = ProviderAccountID(rawValue: "acct-anthropic-1")
    let account = ProviderAccount(
      kind: .anthropic,
      id: accountID,
      label: "Work Anthropic"
    )
    let model = ProviderModel(
      providerID: BuiltInProviders.anthropicID,
      id: "claude-sonnet-4-5",
      displayName: "Claude Sonnet 4.5"
    )
    let record = AccountModelRecord(accountID: accountID, model: model)

    let target = MacMessageDetailsFormatter.resolveTarget(
      providerID: BuiltInProviders.anthropicID,
      accountID: accountID,
      modelID: "claude-sonnet-4-5",
      accounts: [account],
      definitions: [],
      modelsByAccount: [accountID: [record]]
    )

    #expect(target.providerName == "Anthropic")
    #expect(target.accountName == "Work Anthropic")
    #expect(target.isAccountDeleted == false)
    #expect(target.modelDisplayName == "Claude Sonnet 4.5")
    #expect(target.modelRawID == "claude-sonnet-4-5")
    #expect(target.distinctModelRawID == "claude-sonnet-4-5")
    #expect(target.hasAnyMetadata == true)
  }

  @Test("Handles deleted account gracefully without leaking raw UUIDs")
  func resolvesDeletedAccountAndCustomProviderUUID() {
    let deletedAccountID = ProviderAccountID(rawValue: "00000000-1111-2222-3333-444444444444")
    let customProviderUUID = ProviderID(rawValue: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")

    let customTarget = MacMessageDetailsFormatter.resolveTarget(
      providerID: customProviderUUID,
      accountID: deletedAccountID,
      modelID: "my-local-model",
      accounts: [],
      definitions: [],
      modelsByAccount: [:]
    )

    #expect(customTarget.providerName == "Custom Provider")
    #expect(customTarget.accountName == "Deleted connection")
    #expect(customTarget.isAccountDeleted == true)
    #expect(customTarget.modelDisplayName == "my-local-model")
    #expect(customTarget.distinctModelRawID == nil)

    let builtInTarget = MacMessageDetailsFormatter.resolveTarget(
      providerID: BuiltInProviders.openRouterID,
      accountID: deletedAccountID,
      modelID: "openai/gpt-5",
      accounts: [],
      definitions: [],
      modelsByAccount: [:]
    )

    #expect(builtInTarget.providerName == "OpenRouter")
    #expect(builtInTarget.accountName == "Deleted connection")
    #expect(builtInTarget.isAccountDeleted == true)
  }

  @Test("Resolves custom OpenAI-compatible provider name from definition or account label")
  func resolvesCustomProviderNameFromDefinitionAndAccount() {
    let customProviderID = ProviderID(rawValue: "11111111-2222-3333-4444-555555555555")
    let accountID = ProviderAccountID(rawValue: "acct-custom")
    let account = ProviderAccount(
      kind: .openAICompatible,
      id: accountID,
      providerID: customProviderID,
      label: "Lab Gateway"
    )
    let definition = ProviderDefinition(
      id: customProviderID,
      displayName: "Lab Gateway",
      behavior: .genericOpenAICompatible,
      defaultBaseURL: URL(string: "https://gateway.example.com/v1")!
    )

    let resolved = MacMessageDetailsFormatter.resolveTarget(
      providerID: customProviderID,
      accountID: accountID,
      modelID: "llama-3.3-70b",
      accounts: [account],
      definitions: [definition],
      modelsByAccount: [:]
    )

    #expect(resolved.providerName == "Lab Gateway")
    #expect(resolved.accountName == "Lab Gateway")
    #expect(resolved.isAccountDeleted == false)
  }

  // MARK: - Cache Hit-Rate & Token Metrics

  @Test("Calculates cache hit-rate percentage and handles zero and overflow edge cases")
  func cacheHitRateCalculationAndFormatting() {
    #expect(MacMessageDetailsFormatter.cacheHitRate(cached: 0, input: 1_000) == nil)
    #expect(MacMessageDetailsFormatter.cacheHitRate(cached: 500, input: 0) == nil)
    #expect(MacMessageDetailsFormatter.cacheHitRate(cached: -10, input: 100) == nil)

    #expect(MacMessageDetailsFormatter.cacheHitRate(cached: 500, input: 2_000) == 0.25)
    #expect(MacMessageDetailsFormatter.cacheHitRate(cached: 1_500, input: 1_000) == 1.0)

    #expect(
      MacMessageDetailsFormatter.cachedTokensWithRate(cached: 2_500, input: 10_000, locale: enUS)
        == "2,500 (25%)"
    )
    #expect(
      MacMessageDetailsFormatter.cachedTokensWithRate(cached: 125, input: 1_000, locale: enUS)
        == "125 (12.5%)"
    )
    #expect(
      MacMessageDetailsFormatter.cachedTokensWithRate(cached: 300, input: 0, locale: enUS)
        == "300"
    )
  }

  // MARK: - Performance Metrics

  @Test("Formats duration and output throughput across millisecond and second thresholds")
  func formatsDurationAndThroughput() {
    #expect(MacMessageDetailsFormatter.duration(nil) == "—")
    #expect(MacMessageDetailsFormatter.duration(-1) == "—")
    #expect(MacMessageDetailsFormatter.duration(.nan) == "—")
    #expect(MacMessageDetailsFormatter.duration(.infinity) == "—")
    #expect(MacMessageDetailsFormatter.duration(420.4) == "420 ms")
    #expect(MacMessageDetailsFormatter.duration(999.5) == "1.00 s")
    #expect(MacMessageDetailsFormatter.duration(2_345) == "2.35 s")
    #expect(MacMessageDetailsFormatter.duration(14_280) == "14.3 s")

    #expect(MacMessageDetailsFormatter.throughput(nil) == "—")
    #expect(MacMessageDetailsFormatter.throughput(-5) == "—")
    #expect(MacMessageDetailsFormatter.throughput(.nan) == "—")
    #expect(MacMessageDetailsFormatter.throughput(84.26) == "84.3 tok/s")
  }

  @Test("Builds single-request and multi-request performance rows matching iOS labels")
  func buildsPerformanceRows() {
    let single = TelemetryPerformanceAggregate(
      providerRequestCount: 1,
      medianTTFTMilliseconds: 310,
      medianDurationMilliseconds: 1_850,
      medianOutputTokensPerSecond: 62.4,
      totalDurationMilliseconds: 1_850
    )
    let singleRows = MacMessageDetailsFormatter.performanceRows(for: single)
    #expect(singleRows.map(\.label) == ["TTFT", "Duration", "Output speed"])
    #expect(singleRows.map(\.value) == ["310 ms", "1.85 s", "62.4 tok/s"])

    let multi = TelemetryPerformanceAggregate(
      providerRequestCount: 3,
      medianTTFTMilliseconds: 450,
      medianDurationMilliseconds: 2_200,
      medianOutputTokensPerSecond: 51.0,
      totalDurationMilliseconds: 12_400
    )
    let multiRows = MacMessageDetailsFormatter.performanceRows(for: multi)
    #expect(multiRows.map(\.label) == ["Total duration", "Median TTFT", "Median request", "Median speed"])
    #expect(multiRows.map(\.value) == ["12.4 s", "450 ms", "2.20 s", "51.0 tok/s"])
  }

  // MARK: - Finish Reason, Status & Context Trimming

  @Test("Formats finish reasons and error titles while preserving technical acronyms")
  func formatsFinishReasonsAndErrorCodes() {
    #expect(MacMessageDetailsFormatter.finishReasonTitle("stop") == "Completed")
    #expect(MacMessageDetailsFormatter.finishReasonTitle("end_turn") == "Completed")
    #expect(MacMessageDetailsFormatter.finishReasonTitle("max_output_tokens") == "Max tokens reached")
    #expect(MacMessageDetailsFormatter.finishReasonTitle("tool_use") == "Tool calls")
    #expect(MacMessageDetailsFormatter.finishReasonTitle("content_filter") == "Filtered by safety")
    #expect(MacMessageDetailsFormatter.finishReasonTitle("pause_turn") == "Paused")
    #expect(MacMessageDetailsFormatter.finishReasonTitle("stop_sequence") == "Stop sequence")
    #expect(MacMessageDetailsFormatter.finishReasonTitle("canceled") == "Stopped")
    #expect(MacMessageDetailsFormatter.finishReasonTitle("http_sse_timeout") == "HTTP SSE Timeout")

    #expect(MacMessageDetailsFormatter.errorTitle("mcp_json_api_error") == "MCP JSON API Error")
    #expect(MacMessageDetailsFormatter.errorTitle("invalid_url_id") == "Invalid URL ID")
    #expect(MacMessageDetailsFormatter.statusLabel(for: .cancelled) == "Stopped")
    #expect(MacMessageDetailsFormatter.statusLabel(for: .interrupted) == "Interrupted")
  }

  @Test("Resolves omitted context count from telemetry first and latest-assistant fallback only")
  func resolvesOmittedContextCount() {
    let earlierAssistant = ChatMessage(role: .assistant, content: "Earlier", status: .complete)
    let latestAssistant = ChatMessage(role: .assistant, content: "Latest", status: .complete)
    let conversation = ChatConversation(
      providerID: BuiltInProviders.openaiID,
      accountID: "acct-1",
      modelID: "gpt-5",
      messages: [earlierAssistant, latestAssistant],
      lastContextOmittedMessageCount: 4
    )

    #expect(
      MacMessageDetailsFormatter.resolvedOmittedContextCount(
        telemetryCount: 7,
        message: earlierAssistant,
        conversation: conversation
      ) == 7
    )
    #expect(
      MacMessageDetailsFormatter.resolvedOmittedContextCount(
        telemetryCount: 0,
        message: earlierAssistant,
        conversation: conversation
      ) == 0
    )
    #expect(
      MacMessageDetailsFormatter.resolvedOmittedContextCount(
        telemetryCount: 0,
        message: latestAssistant,
        conversation: conversation
      ) == 4
    )
    #expect(
      MacMessageDetailsFormatter.contextTrimmedLabel(omittedCount: 1, locale: enUS)
        == "1 earlier message"
    )
    #expect(
      MacMessageDetailsFormatter.contextTrimmedLabel(omittedCount: 4, locale: enUS)
        == "4 earlier messages"
    )
    #expect(MacMessageDetailsFormatter.contextTrimmedLabel(omittedCount: 0, locale: enUS) == nil)
  }

  // MARK: - Billing Snapshot & Pricing Rates

  @Test("Formats USD amounts and per-million pricing rates across precision tiers")
  func formatsUSDAndPerMillionRates() {
    #expect(MacMessageDetailsFormatter.formatUSD(0) == "$0.00")
    #expect(MacMessageDetailsFormatter.formatUSD(Decimal(string: "0.000125")!) == "$0.000125")
    #expect(MacMessageDetailsFormatter.formatUSD(Decimal(string: "0.01234")!) == "$0.0123")
    #expect(MacMessageDetailsFormatter.formatUSD(Decimal(string: "3.5")!) == "$3.50")

    #expect(
      MacMessageDetailsFormatter.pricePerMillion(fromPerToken: Decimal(string: "0.000003")!)
        == "$3.00"
    )
    #expect(
      MacMessageDetailsFormatter.pricePerMillion(fromPerMillionString: "0.15")
        == "$0.1500"
    )
    #expect(MacMessageDetailsFormatter.pricePerMillion(fromPerMillionString: "invalid") == nil)
  }

  @Test("Builds cost presentations for reported, estimated, OpenRouter BYOK partial, and unavailable billing")
  func buildsCostPresentations() {
    let reportedReceipt = ChatBilling.requestBilling(
      metadata: ["costUSD": "0.025"],
      usage: nil,
      pricing: nil
    )
    let reportedMessage = ChatMessage(
      role: .assistant,
      content: "Done",
      status: .complete,
      metadata: ChatBilling.metadata(existing: [:], requests: [reportedReceipt], toolCallCount: 0)
    )
    let reportedCost = MacMessageDetailsFormatter.costPresentation(
      billing: ChatBilling.snapshot(for: reportedMessage),
      messageMetadata: reportedMessage.metadata
    )
    #expect(reportedCost.label == "Cost")
    #expect(reportedCost.value == "$0.0250")
    #expect(reportedCost.badgeKind == .exact)
    #expect(reportedCost.badgeTitle == "Reported")
    #expect(reportedCost.footnote.contains("reported by the provider"))

    let byokReceipt = ChatBilling.requestBilling(
      metadata: [
        "openrouter.costUSD": "0.004",
        ChatBilling.reportedCostCompleteKey: "false",
      ],
      usage: nil,
      pricing: nil
    )
    let byokMessage = ChatMessage(
      role: .assistant,
      content: "Done",
      status: .complete,
      metadata: ChatBilling.metadata(existing: [:], requests: [byokReceipt], toolCallCount: 0)
    )
    let byokCost = MacMessageDetailsFormatter.costPresentation(
      billing: ChatBilling.snapshot(for: byokMessage),
      messageMetadata: byokMessage.metadata
    )
    #expect(byokCost.value == "≥$0.0040 (partial)")
    #expect(byokCost.badgeKind == .partial)
    #expect(byokCost.badgeTitle == "BYOK Partial")
    #expect(byokCost.footnote.contains("OpenRouter account charge"))

    let unpricedReceipt = ChatBilling.requestBilling(
      metadata: [:],
      usage: ProviderUsage(inputTokens: 1_000, outputTokens: 200),
      pricing: nil
    )
    let unpricedMessage = ChatMessage(
      role: .assistant,
      content: "Done",
      status: .complete,
      metadata: ChatBilling.metadata(existing: [:], requests: [unpricedReceipt], toolCallCount: 0)
    )
    let unpricedCost = MacMessageDetailsFormatter.costPresentation(
      billing: ChatBilling.snapshot(for: unpricedMessage),
      messageMetadata: unpricedMessage.metadata
    )
    #expect(unpricedCost.value == "Unavailable")
    #expect(unpricedCost.badgeKind == .unavailable)
    #expect(unpricedCost.footnote.contains("No supported price was available"))
  }

  @Test("Builds pricing snapshot presentation with cached/write rates, HTTPS URL validation, and catalog metadata")
  func buildsPricingSnapshotPresentation() throws {
    let snapshotJSON = """
    {
      "source": "remoteCatalog",
      "version": "2026-04-01",
      "sourceURL": "https://www.anthropic.com/pricing",
      "verifiedAt": "2026-04-01",
      "modelID": "claude-sonnet-4-5",
      "rates": {
        "input": "3",
        "output": "15",
        "cachedInput": "0.30",
        "cacheWrite": "3.75",
        "longCacheWrite": "6.00"
      },
      "longContextThreshold": 200000,
      "longContextInputMultiplier": "2",
      "longContextOutputMultiplier": "1.5",
      "contextNote": "Standard Anthropic direct pricing.",
      "supportsCacheWriteDuration": true
    }
    """
    let snapshot = try JSONDecoder().decode(
      ModelPricingSnapshot.self,
      from: Data(snapshotJSON.utf8)
    )
    let usage = ProviderUsage(
      inputTokens: 10_000,
      outputTokens: 1_000,
      cachedInputTokens: 4_000,
      reasoningTokens: 500,
      cacheWriteTokens: 1_000,
      longCacheWriteTokens: 0
    )
    let receipt = ChatBilling.requestBilling(metadata: [:], usage: usage, pricing: snapshot)
    let message = ChatMessage(
      role: .assistant,
      content: "Answer",
      status: .complete,
      usage: usage,
      metadata: ChatBilling.metadata(existing: [:], requests: [receipt], toolCallCount: 0)
    )
    let billing = ChatBilling.snapshot(for: message)
    let updatedDate = Date(timeIntervalSince1970: 1_775_000_000)
    let status = ModelCatalogStatus(
      source: .remote,
      revision: 12,
      version: "2026-04-01",
      bundledRevision: 10,
      bundledVersion: "2026-03-01",
      lastUpdatedAt: updatedDate
    )

    let pricing = MacMessageDetailsFormatter.pricingSnapshotPresentation(
      billing: billing,
      usage: usage,
      catalogStatus: status,
      locale: enUS
    )

    #expect(pricing.shouldDisplaySection == true)
    #expect(pricing.isMultiRequest == false)
    #expect(pricing.inputLabel == "Input / 1M")
    #expect(pricing.inputPerMillion == "$3.00")
    #expect(pricing.outputLabel == "Output / 1M")
    #expect(pricing.outputPerMillion == "$15.00")
    #expect(pricing.cachedInputPerMillion == "$0.3000")
    #expect(pricing.cacheWritePerMillion == "$3.75")
    #expect(pricing.longCacheWritePerMillion == "$6.00")
    #expect(pricing.reasoningPerMillionNote == "$15.00 (billed as output)")
    #expect(pricing.officialPricingURL?.absoluteString == "https://www.anthropic.com/pricing")
    #expect(pricing.sourceLabel == "Remote catalog")
    #expect(pricing.version == "2026-04-01")
    #expect(pricing.verifiedAt == "2026-04-01")
    #expect(pricing.catalogUpdatedAt == updatedDate)
    #expect(pricing.longContextThresholdLabel == "200,000+ input tokens")
    #expect(pricing.contextNote == "Standard Anthropic direct pricing.")

    // Non-HTTPS pricing URLs are rejected.
    #expect(MacMessageDetailsFormatter.validatedOfficialPricingURL("http://example.com/pricing") == nil)
    #expect(MacMessageDetailsFormatter.validatedOfficialPricingURL("https://") == nil)
    #expect(MacMessageDetailsFormatter.pricingSourceLabel("bundledCatalog") == "Bundled catalog")
    #expect(MacMessageDetailsFormatter.pricingSourceLabel("providerModelAPI") == "Model API")
  }

  @Test("Summarizes tool rounds and generates plain-text details summary")
  func summarizesToolsAndPlainTextDetails() {
    let rounds = [
      ChatToolRound(
        calls: [
          ChatToolCall(id: "c1", name: "mcp__github__search", arguments: .object([:])),
          ChatToolCall(id: "c2", name: "mcp__github__search", arguments: .object([:])),
        ],
        results: [
          ChatToolResult(callID: "c1", name: "mcp__github__search", content: .string("ok"), isError: false),
          ChatToolResult(callID: "c2", name: "mcp__github__search", content: .string("err"), isError: true),
        ]
      )
    ]

    let summary = MacMessageDetailsFormatter.toolSummary(rounds: rounds) { raw in
      raw == "mcp__github__search" ? "GitHub: search" : raw
    }
    #expect(summary?.roundCount == 1)
    #expect(summary?.callCount == 2)
    #expect(summary?.errorCount == 1)
    #expect(summary?.invocations.count == 1)
    #expect(summary?.invocations.first?.displayName == "GitHub: search")
    #expect(summary?.invocations.first?.count == 2)

    let message = ChatMessage(
      role: .assistant,
      content: "Hello",
      toolRounds: rounds,
      status: .complete,
      providerID: BuiltInProviders.openaiID,
      modelID: "gpt-5",
      finishReason: "stop",
      usage: ProviderUsage(inputTokens: 1_000, outputTokens: 250, cachedInputTokens: 500)
    )
    let billing = ChatBilling.snapshot(for: message)
    let target = MacMessageDetailsFormatter.TargetResolution(
      providerName: "OpenAI",
      accountName: "Personal",
      isAccountDeleted: false,
      modelDisplayName: "GPT-5",
      modelRawID: "gpt-5"
    )
    let cost = MacMessageDetailsFormatter.costPresentation(billing: billing)
    let pricing = MacMessageDetailsFormatter.pricingSnapshotPresentation(
      billing: billing,
      usage: message.usage,
      locale: enUS
    )
    let text = MacMessageDetailsFormatter.plainTextSummary(
      message: message,
      target: target,
      billing: billing,
      cost: cost,
      pricing: pricing,
      performanceRows: [
        MacMessageDetailsFormatter.PerformanceRow(id: "ttft", label: "TTFT", value: "250 ms")
      ],
      omittedContextCount: 2,
      toolSummary: summary,
      locale: enUS
    )

    #expect(text.contains("Provider: OpenAI"))
    #expect(text.contains("Account: Personal"))
    #expect(text.contains("Model: GPT-5 (gpt-5)"))
    #expect(text.contains("Cached input: 500 (50%)"))
    #expect(text.contains("Total tokens: 1,250"))
    #expect(text.contains("TTFT: 250 ms"))
    #expect(text.contains("Context trimmed: 2 earlier messages"))
    #expect(text.contains("Finish reason: Completed"))
    #expect(text.contains("Tools: 1 rounds, 2 calls, 1 errors"))
  }
}
