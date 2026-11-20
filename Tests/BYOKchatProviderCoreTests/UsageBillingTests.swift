import Foundation
import Testing

@testable import BYOKchatProviderCore

@Test func billingPersistsCalculatedPriceSnapshot() throws {
  let usage = ProviderUsage(inputTokens: 1_000, outputTokens: 500)
  let model = ProviderModel(
    providerID: "priced",
    id: "model",
    displayName: "Model",
    promptPricePerToken: "0.000001",
    completionPricePerToken: "0.000002"
  )

  let metadata = ChatBilling.metadata(
    existing: [:],
    usage: usage,
    model: model,
    modelRequestCount: 3,
    toolCallCount: 2
  )

  #expect(metadata[ChatBilling.costKey] == "0.002")
  #expect(metadata[ChatBilling.accuracyKey] == ChatCostAccuracy.calculated.rawValue)
  #expect(metadata[ChatBilling.inputPriceKey] == "0.000001")
  #expect(metadata[ChatBilling.outputPriceKey] == "0.000002")
  #expect(metadata[ChatBilling.modelRequestCountKey] == "3")
  #expect(metadata[ChatBilling.toolCallCountKey] == "2")
}

@Test func billingLeavesUnknownPricingUnavailable() {
  let metadata = ChatBilling.metadata(
    existing: [:],
    usage: ProviderUsage(inputTokens: 100, outputTokens: 20),
    model: ProviderModel(providerID: "local", id: "qwen", displayName: "Qwen"),
    modelRequestCount: 1,
    toolCallCount: 0
  )

  #expect(metadata[ChatBilling.costKey] == nil)
  #expect(metadata[ChatBilling.accuracyKey] == ChatCostAccuracy.unavailable.rawValue)
}

@Test func usageAggregateTracksPartialSpendAndToolRequests() throws {
  let priced = ChatMessage(
    role: .assistant,
    content: "one",
    status: .complete,
    providerID: "openrouter",
    accountID: "account",
    modelID: "model",
    usage: ProviderUsage(inputTokens: 1_000, outputTokens: 100),
    metadata: [
      ChatBilling.costKey: "0.01",
      ChatBilling.accuracyKey: ChatCostAccuracy.calculated.rawValue,
      ChatBilling.modelRequestCountKey: "2",
      ChatBilling.toolCallCountKey: "1",
    ]
  )
  let unknown = ChatMessage(
    role: .assistant,
    content: "two",
    status: .complete,
    providerID: "local",
    accountID: "local-account",
    modelID: "local-model",
    usage: ProviderUsage(inputTokens: 500, outputTokens: 50)
  )

  let aggregate = ChatBilling.aggregate(messages: [priced, unknown])
  #expect(aggregate.assistantMessageCount == 2)
  #expect(aggregate.inputTokens == 1_500)
  #expect(aggregate.outputTokens == 150)
  #expect(aggregate.modelRequestCount == 3)
  #expect(aggregate.toolCallCount == 1)
  #expect(aggregate.knownCostMessageCount == 1)
  #expect(aggregate.costUSD == Decimal(string: "0.01"))
  #expect(aggregate.hasPartialCost)
}


private func testPricing(input: String? = "1", output: String? = "2") -> ModelPricingSnapshot {
  .init(source: "test", version: "original", modelID: "model",
    rates: .init(input: input, output: output))
}

private func billedMessage(_ receipts: [ChatRequestBilling]) -> ChatMessage {
  .init(role: .assistant, status: .complete,
    metadata: ChatBilling.metadata(existing: [:], requests: receipts, toolCallCount: 0))
}

@Test func incompleteDimensionsPropagateEvenWhenEveryMessageHasCost() {
  let missingOutputPrice = ChatBilling.requestBilling(metadata: [:],
    usage: .init(inputTokens: 100, outputTokens: 50), pricing: testPricing(output: nil))
  let missingInputPrice = ChatBilling.requestBilling(metadata: [:],
    usage: .init(inputTokens: 100, outputTokens: 50), pricing: testPricing(input: nil))
  let missingOutputUsage = ChatBilling.requestBilling(metadata: [:],
    usage: .init(inputTokens: 100), pricing: testPricing())
  let missingInputUsage = ChatBilling.requestBilling(metadata: [:],
    usage: .init(outputTokens: 50), pricing: testPricing())
  for receipt in [missingOutputPrice, missingInputPrice, missingOutputUsage, missingInputUsage] {
    #expect(receipt.costUSD == "0.0001")
    #expect(!receipt.isComplete)
    let aggregate = ChatBilling.aggregate(messages: [billedMessage([receipt])])
    #expect(aggregate.hasKnownCost && aggregate.hasPartialCost)
    #expect(aggregate.hasEstimatedCost && !aggregate.isLowerBound)
  }
}

@Test func knownZeroIsDifferentFromUnknown() {
  let zeroTokens = ChatBilling.requestBilling(metadata: [:],
    usage: .init(inputTokens: 0, outputTokens: 0), pricing: testPricing(input: nil, output: nil))
  #expect(zeroTokens.isComplete && zeroTokens.costUSD == "0")
  let free = ChatBilling.requestBilling(metadata: [:],
    usage: .init(inputTokens: 100, outputTokens: 50), pricing: testPricing(input: "0", output: "0"))
  #expect(free.isComplete && free.costUSD == "0")
  let unknown = ChatBilling.requestBilling(metadata: [:], usage: nil, pricing: nil)
  let aggregate = ChatBilling.aggregate(messages: [billedMessage([unknown])])
  #expect(!aggregate.hasKnownCost && aggregate.hasPartialCost)
  #expect(aggregate.modelRequestCount == 1)
  #expect(ChatBilling.aggregate(messages: []).assistantMessageCount == 0)
}

@Test func requestReceiptsPreserveMissingRoundAndMixedCostSources() throws {
  let reported = ChatBilling.requestBilling(metadata: ["costUSD": "0.01"], usage: nil, pricing: nil)
  let partial = ChatBilling.requestBilling(metadata: [:],
    usage: .init(inputTokens: 100), pricing: testPricing())
  let complete = ChatBilling.requestBilling(metadata: [:],
    usage: .init(inputTokens: 100, outputTokens: 50), pricing: testPricing())
  let message = billedMessage([reported, partial, complete])
  let billing = ChatBilling.snapshot(for: message)
  #expect(billing.costUSD == Decimal(string: "0.0103"))
  #expect(billing.accuracy == .calculated && !billing.isComplete && !billing.isLowerBound)
  // Encoding the lightweight index must retain all receipts without chat content.
  let data = try JSONEncoder().encode(ConversationIndexMessage(message: message))
  let restored = try JSONDecoder().decode(ConversationIndexMessage.self, from: data).summaryMessage
  #expect(ChatBilling.snapshot(for: restored) == billing)
  #expect(billing.requests.last?.pricing?.version == "original")
  let reportedPartial = ChatBilling.snapshot(for: billedMessage([reported,
    ChatBilling.requestBilling(metadata: [:], usage: nil, pricing: nil)]))
  #expect(reportedPartial.isLowerBound && !reportedPartial.isComplete)
}

@Test func completeReportedCostWinsAndBYOKScopeStaysPartial() {
  let zero = ChatBilling.requestBilling(metadata: ["openrouter.costUSD": "0"],
    usage: .init(inputTokens: 100, outputTokens: 50), pricing: testPricing())
  #expect(zero.costUSD == "0" && zero.accuracy == .providerReported && zero.isComplete)
  let byok = ChatBilling.requestBilling(metadata: ["openrouter.costUSD": "0.01",
    ChatBilling.reportedCostCompleteKey: "false"], usage: nil, pricing: nil)
  #expect(byok.costUSD == "0.01" && !byok.isComplete)
  #expect(byok.missingDimensions == ["provider billing scope"])
}

@Test func savedCacheAndContextRulesApplyWithoutDoubleCounting() {
  var pricing = testPricing(input: "2", output: "10")
  pricing.rates.cachedInput = "0.2"
  pricing.rates.cacheWrite = "2.5"
  pricing.rates.longCacheWrite = "4"
  pricing.supportsCacheWriteDuration = true
  let receipt = ChatBilling.requestBilling(metadata: [:], usage: .init(
    inputTokens: 1_000, outputTokens: 100, cachedInputTokens: 200,
    cacheWriteTokens: 300, longCacheWriteTokens: 100), pricing: pricing)
  #expect(receipt.costUSD == "0.00294" && receipt.isComplete)
  let unknownDuration = ChatBilling.requestBilling(metadata: [:], usage: .init(
    inputTokens: 1_000, outputTokens: 100, cachedInputTokens: 0, cacheWriteTokens: 100), pricing: pricing)
  #expect(!unknownDuration.isComplete)
  pricing.longContextThreshold = 1_000
  pricing.longContextInputMultiplier = "2"
  pricing.longContextOutputMultiplier = "1.5"
  let long = ChatBilling.requestBilling(metadata: [:], usage: .init(
    inputTokens: 1_000, outputTokens: 100, cachedInputTokens: 0, cacheWriteTokens: 0), pricing: pricing)
  #expect(long.costUSD == "0.0055" && long.isComplete)
  let unpriced = ChatBilling.requestBilling(metadata: [:], usage: .init(
    inputTokens: 100, outputTokens: 50, hasUnpricedCharges: true), pricing: testPricing())
  #expect(!unpriced.isComplete)
}

@Test func resolverUsesExactProviderModelAndEndpointWithAPIPrecedence() throws {
  let account = ProviderAccount(kind: .anthropic, id: "a", providerID: "anthropic", label: "A")
  let snapshot = try #require(ModelPriceResolver.resolve(account: account, modelID: "claude-sonnet-5", model: nil))
  #expect(snapshot.source == "bundledCatalog" && snapshot.rates.input == "2")
  let discovered = ProviderModel(providerID: "anthropic", id: "claude-sonnet-5", displayName: "M",
    promptPricePerToken: "0.000009")
  let api = try #require(ModelPriceResolver.resolve(account: account, modelID: discovered.id, model: discovered))
  #expect(api.source == "providerModelAPI" && api.rates.input == "9" && api.rates.output == nil)
  #expect(ModelPriceResolver.resolve(account: account, modelID: "claude-sonnet-5-custom", model: nil) == nil)
  var custom = account
  custom.baseURLOverride = URL(string: "https://proxy.example.test")
  #expect(ModelPriceResolver.resolve(account: custom, modelID: "claude-sonnet-5", model: nil) == nil)
  #expect(ModelPriceResolver.resolve(account: custom, modelID: discovered.id, model: discovered)?.source == "providerModelAPI")
  let other = ProviderAccount(kind: .openRouter, id: "or", providerID: "openrouter", label: "OR")
  #expect(ModelPriceResolver.resolve(account: other, modelID: "claude-sonnet-5", model: nil) == nil)
}

@Test func catalogValidationRejectsInvalidCurrencyAndRates() throws {
  #expect(ModelPricingCatalog.bundled != nil)
  let malformed = #"{"schemaVersion":1,"version":"v","currency":"EUR","units":"USD per 1000000 tokens","entries":[]}"#
  #expect(ModelPricingCatalog.decode(Data(malformed.utf8)) == nil)
  let negative = #"{"schemaVersion":1,"version":"v","currency":"USD","units":"USD per 1000000 tokens","entries":[{"provider":"openai","modelIDs":["m"],"sourceURL":"https://openai.com","verifiedAt":"2026-10-07","rates":{"input":"-1"}}]}"#
  #expect(ModelPricingCatalog.decode(Data(negative.utf8)) == nil)
}

@Test func decimalBillingRejectsMalformedNonfiniteAndNegativeNumbers() {
  for value in ["NaN", "Infinity", "-1", "1junk", "", "1,2"] { #expect(ChatBilling.decimal(value) == nil) }
  #expect(ChatBilling.decimal("0") == 0)
  #expect(ChatBilling.decimal("1e-6") == Decimal(string: "0.000001"))
}

@Test func legacyCalculatedHistoryRetainsAmountAndConservativeUncertainty() {
  let message = ChatMessage(role: .assistant, status: .complete,
    usage: .init(inputTokens: 10, outputTokens: 5), metadata: [
      ChatBilling.costKey: "0.01", ChatBilling.accuracyKey: "calculated",
      ChatBilling.inputPriceKey: "0.001", ChatBilling.outputPriceKey: "0.002",
      ChatBilling.modelRequestCountKey: "2"])
  let before = ChatBilling.snapshot(for: message)
  #expect(before.costUSD == Decimal(string: "0.01") && !before.isComplete)
  let index = ConversationIndexMessage(message: message)
  #expect(ChatBilling.snapshot(for: index.summaryMessage) == before)
}

@Test func deepSeekTimeBucketsAndGeminiExpiryUseSavedRules() throws {
  let date = try #require(ISO8601DateFormatter().date(from: "2026-10-07T02:00:00Z"))
  let account = ProviderAccount(kind: .deepSeek, id: "d", providerID: "deepseek", label: "D")
  let peak = try #require(ModelPriceResolver.resolve(account: account, modelID: "deepseek-v4-flash", model: nil, at: date))
  #expect(peak.rates.input == "0.3" && peak.version == "2026-11-20:peak")
  #expect(peak.timeRule != nil)
  let offPeakDate = try #require(ISO8601DateFormatter().date(from: "2026-10-07T04:00:00Z"))
  #expect(ModelPriceResolver.resolve(account: account, modelID: "deepseek-v4-flash", model: nil, at: offPeakDate)?.rates.input == "0.15")
  let gemini = ProviderAccount(kind: .gemini, id: "g", providerID: "gemini", label: "G")
  let expiry = try #require(ISO8601DateFormatter().date(from: "2027-01-01T00:00:00Z"))
  #expect(ModelPriceResolver.resolve(account: gemini, modelID: "gemini-3.6-flash", model: nil, at: expiry) == nil)
}

@Test func geminiCurrentCatalogPricingResolvesAndRespectsExpiry() throws {
  let active = try #require(ISO8601DateFormatter().date(from: "2026-11-20T00:00:00Z"))
  let carbonExpiry = try #require(ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z"))
  let flashExpiry = try #require(ISO8601DateFormatter().date(from: "2027-01-01T00:00:00Z"))
  let gemini = ProviderAccount(kind: .gemini, id: "g", providerID: "gemini", label: "Gemini")

  let flash38 = try #require(ModelPriceResolver.resolve(account: gemini, modelID: "gemini-3.8-flash", model: nil, at: active))
  #expect(flash38.rates.input == "0.75")
  #expect(flash38.rates.output == "3.75")
  #expect(flash38.rates.cachedInput == "0.075")
  #expect(ModelPriceResolver.resolve(account: gemini, modelID: "gemini-3.8-flash", model: nil, at: flashExpiry) == nil)

  let carbon = try #require(ModelPriceResolver.resolve(account: gemini, modelID: "gemini-4-carbon", model: nil, at: active))
  #expect(carbon.rates.input == "2")
  #expect(carbon.rates.output == "10")
  #expect(carbon.rates.cachedInput == "0.1")
  #expect(ModelPriceResolver.resolve(account: gemini, modelID: "gemini-4-carbon", model: nil, at: carbonExpiry) == nil)

  let argon = try #require(ModelPriceResolver.resolve(account: gemini, modelID: "gemini-4-argon", model: nil, at: active))
  #expect(argon.rates.input == "2")
  #expect(argon.rates.output == "10")
  #expect(ModelPriceResolver.resolve(account: gemini, modelID: "gemini-4-argon", model: nil, at: carbonExpiry) == nil)
  #expect(
    ModelPriceResolver.responseModelMatches(
      account: gemini,
      requestedModelID: "gemini-4-carbon",
      responseModelID: "gemini-4-argon"
    ) == false
  )

  let neon = try #require(ModelPriceResolver.resolve(account: gemini, modelID: "gemini-4-neon", model: nil, at: active))
  #expect(neon.rates.input == "3")
  #expect(neon.rates.output == "15")
  #expect(neon.rates.cachedInput == "0.15")

  let hydrogen = try #require(ModelPriceResolver.resolve(account: gemini, modelID: "gemini-4-hydrogen", model: nil, at: active))
  #expect(hydrogen.rates.input == "1.5")
  #expect(hydrogen.rates.output == "7.5")
  #expect(hydrogen.rates.cachedInput == "0.075")
}

@Test func anthropicCurrentCatalogPricingResolvesIncludingHaikuLongContextTier() throws {
  let account = ProviderAccount(kind: .anthropic, id: "a", providerID: "anthropic", label: "Anthropic")

  let sonnet55 = try #require(ModelPriceResolver.resolve(account: account, modelID: "claude-sonnet-5-5", model: nil))
  #expect(sonnet55.rates.input == "2")
  #expect(sonnet55.rates.output == "10")
  #expect(sonnet55.rates.cachedInput == "0.1")
  #expect(sonnet55.rates.cacheWrite == "2.5")
  #expect(sonnet55.rates.longCacheWrite == "4")

  let opus55 = try #require(ModelPriceResolver.resolve(account: account, modelID: "claude-opus-5-5", model: nil))
  #expect(opus55.rates.input == "4")
  #expect(opus55.rates.output == "20")
  #expect(opus55.rates.cachedInput == "0.2")
  #expect(opus55.rates.cacheWrite == "5")
  #expect(opus55.rates.longCacheWrite == "8")

  let haiku55 = try #require(ModelPriceResolver.resolve(account: account, modelID: "claude-haiku-5-5", model: nil))
  let standardRates = haiku55.rates(for: ProviderUsage(inputTokens: 100_000, outputTokens: 1_000))
  #expect(standardRates.input == "0.1")
  #expect(standardRates.output == "0.5")
  #expect(standardRates.cachedInput == "0.01")
  let longRates = haiku55.rates(for: ProviderUsage(inputTokens: 100_001, outputTokens: 1_000))
  #expect(longRates.input == "0.5")
  #expect(longRates.output == "2.5")
  #expect(longRates.cachedInput == "0.05")

  let fable52 = try #require(ModelPriceResolver.resolve(account: account, modelID: "claude-fable-5-2", model: nil))
  #expect(fable52.rates.input == "8")
  #expect(fable52.rates.output == "40")
  #expect(fable52.rates.cachedInput == "0.2")

  let fable51 = try #require(ModelPriceResolver.resolve(account: account, modelID: "claude-fable-5-1", model: nil))
  #expect(fable51.rates.input == "10")
  #expect(fable51.rates.output == "50")
}

@Test func zAIPricingResolvesForDefaultEndpointOnly() throws {
  let account = ProviderAccount(kind: .zAI, id: "z", providerID: "zai", label: "Z.ai")
  let glm53 = try #require(ModelPriceResolver.resolve(account: account, modelID: "glm-5.3", model: nil))
  #expect(glm53.source == "bundledCatalog")
  #expect(glm53.rates.input == "1.4")
  #expect(glm53.rates.output == "4.4")
  #expect(glm53.rates.cachedInput == "0.26")

  let glm53Flash = try #require(ModelPriceResolver.resolve(account: account, modelID: "glm-5.3-flash", model: nil))
  #expect(glm53Flash.rates.input == "0.15")
  #expect(glm53Flash.rates.output == "0.5")

  let codingPlanAccount = ProviderAccount(
    kind: .zAI, id: "z-coding", providerID: "zai", label: "Z.ai Coding",
    baseURLOverride: URL(string: "https://api.z.ai/api/coding/paas/v4")!
  )
  #expect(ModelPriceResolver.resolve(account: codingPlanAccount, modelID: "glm-5.3", model: nil) == nil)
}

@Test func moonshotPricingResolvesForGlobalEndpointOnly() throws {
  let account = ProviderAccount(kind: .moonshot, id: "m", providerID: "moonshot", label: "Moonshot AI")
  let k31Pro = try #require(ModelPriceResolver.resolve(account: account, modelID: "kimi-k3.1-pro", model: nil))
  #expect(k31Pro.source == "bundledCatalog")
  #expect(k31Pro.rates.input == "2")
  #expect(k31Pro.rates.output == "10")
  #expect(k31Pro.rates.cachedInput == "0.2")

  let highspeed = try #require(ModelPriceResolver.resolve(account: account, modelID: "kimi-k3.1-pro-highspeed", model: nil))
  #expect(highspeed.rates.input == "4")
  #expect(highspeed.rates.output == "20")
  #expect(highspeed.rates.cachedInput == "0.2")

  let k3 = try #require(ModelPriceResolver.resolve(account: account, modelID: "kimi-k3", model: nil))
  #expect(k3.rates.input == "3")
  #expect(k3.rates.output == "15")
  #expect(k3.rates.cachedInput == "0.3")

  let chinaAccount = ProviderAccount(
    kind: .moonshot, id: "m-cn", providerID: "moonshot", label: "Moonshot CN",
    baseURLOverride: URL(string: "https://api.moonshot.cn/v1")!
  )
  #expect(ModelPriceResolver.resolve(account: chinaAccount, modelID: "kimi-k3.1-pro", model: nil) == nil)
}

@Test func minimaxPricingResolvesForGlobalEndpointWithLongContextTier() throws {
  let account = ProviderAccount(kind: .minimax, id: "mm", providerID: "minimax", label: "MiniMax")
  let flash = try #require(ModelPriceResolver.resolve(account: account, modelID: "MiniMax-M3.1-Flash", model: nil))
  #expect(flash.source == "bundledCatalog")
  #expect(flash.rates.input == "0.15")
  #expect(flash.rates.output == "0.6")
  #expect(flash.rates.cachedInput == "0.015")

  let m3 = try #require(ModelPriceResolver.resolve(account: account, modelID: "MiniMax-M3", model: nil))
  #expect(m3.rates.input == "0.3")
  #expect(m3.rates.output == "1.2")
  #expect(m3.rates.cachedInput == "0.06")
  let longRates = m3.rates(for: ProviderUsage(inputTokens: 600_000, outputTokens: 1_000))
  #expect(longRates.input == "0.6")
  #expect(longRates.output == "2.4")
  #expect(longRates.cachedInput == "0.12")

  let chinaAccount = ProviderAccount(
    kind: .minimax, id: "mm-cn", providerID: "minimax", label: "MiniMax CN",
    baseURLOverride: URL(string: "https://api.minimaxi.com/v1")!
  )
  #expect(ModelPriceResolver.resolve(account: chinaAccount, modelID: "MiniMax-M3.1-Flash", model: nil) == nil)
}

@Test func mistralPricingResolvesForDefaultEndpointOnly() throws {
  let account = ProviderAccount(kind: .mistral, id: "mis", providerID: "mistral", label: "Mistral AI")
  let large4 = try #require(ModelPriceResolver.resolve(account: account, modelID: "mistral-large-4-0", model: nil))
  #expect(large4.source == "bundledCatalog")
  #expect(large4.rates.input == "0.7")
  #expect(large4.rates.output == "2.1")
  #expect(large4.rates.cachedInput == "0.07")

  let small4 = try #require(ModelPriceResolver.resolve(account: account, modelID: "mistral-small-2603", model: nil))
  #expect(small4.rates.input == "0.15")
  #expect(small4.rates.output == "0.6")
  #expect(small4.rates.cachedInput == "0.015")

  let devstral = try #require(ModelPriceResolver.resolve(account: account, modelID: "devstral-2512", model: nil))
  #expect(devstral.rates.input == "0.4")
  #expect(devstral.rates.output == "2")

  let regionalAccount = ProviderAccount(
    kind: .mistral, id: "mis-eu", providerID: "mistral", label: "Mistral EU",
    baseURLOverride: URL(string: "https://eu.api.mistral.ai/v1")!
  )
  #expect(ModelPriceResolver.resolve(account: regionalAccount, modelID: "mistral-large-4-0", model: nil) == nil)
}

@Test func timePricingRejectsCrossedBucketsEvenWithMatchingEndpoints() throws {
  let start = try #require(ISO8601DateFormatter().date(from: "2026-10-07T00:30:00Z"))
  let end = try #require(ISO8601DateFormatter().date(from: "2026-10-07T04:30:00Z"))
  let account = ProviderAccount(kind: .deepSeek, id: "d", providerID: "deepseek", label: "D")
  let pricing = try #require(ModelPriceResolver.resolve(account: account, modelID: "deepseek-v4-pro", model: nil, at: start))
  #expect(!pricing.coversRequest(startedAt: start, endedAt: end))
  #expect(pricing.coversRequest(startedAt: start, endedAt: start.addingTimeInterval(60)))
}

@Test("Free analytics excludes history from overview and conversation detail after downgrade")
func analyticsRangesClampHistoryAfterEntitlementLoss() {
  let reference = Date(timeIntervalSince1970: 1_800_000_000)
  let today = Calendar.current.startOfDay(for: reference).addingTimeInterval(60)
  let yesterday = today.addingTimeInterval(-86_400)
  let conversation = ChatConversation(
    providerID: "provider",
    accountID: "account",
    modelID: "model",
    messages: [
      ChatMessage(
        role: .assistant,
        createdAt: yesterday,
        updatedAt: yesterday,
        status: .complete,
        usage: ProviderUsage(inputTokens: 900, outputTokens: 90)
      ),
      ChatMessage(
        role: .assistant,
        createdAt: today,
        updatedAt: today,
        status: .complete,
        usage: ProviderUsage(inputTokens: 100, outputTokens: 10)
      ),
    ]
  )

  for selectedRange in UsageAnalyticsRange.allCases {
    let range = selectedRange.accessible(hasPro: false)
    let overview = UsageAnalytics.snapshot(
      conversations: [conversation],
      telemetryEvents: [],
      range: range,
      reference: reference
    )
    let detail = UsageAnalytics.conversationSnapshot(
      conversation: conversation,
      telemetryEvents: [],
      range: range,
      reference: reference
    )
    #expect(overview.aggregate.inputTokens == 100)
    #expect(detail.aggregate.inputTokens == 100)
    #expect(selectedRange.accessible(hasPro: true) == selectedRange)
    #expect(selectedRange.requiresPro == (selectedRange != .today))
  }

  let pro = UsageAnalytics.snapshot(
    conversations: [conversation],
    telemetryEvents: [],
    range: UsageAnalyticsRange.all.accessible(hasPro: true),
    reference: reference
  )
  #expect(pro.aggregate.inputTokens == 1_000)
}

@Test func openAIGPT6PricingResolvesForAllSeedModels() throws {
  let account = ProviderAccount(kind: .openai, id: "oai", providerID: "openai", label: "OpenAI")

  let astra62 = try #require(
    ModelPriceResolver.resolve(account: account, modelID: "gpt-6.2-astra", model: nil)
  )
  #expect(astra62.source == "bundledCatalog")
  #expect(astra62.rates.input == "8")
  #expect(astra62.rates.output == "40")
  #expect(astra62.rates.cachedInput == "0.4")
  #expect(astra62.rates.cacheWrite == "10")
  #expect(astra62.rates.longCacheWrite == "20")
  #expect(astra62.longContextThreshold == 272_000)
  let astra62Long = astra62.rates(for: ProviderUsage(inputTokens: 300_000, outputTokens: 1_000))
  #expect(astra62Long.input == "16")
  #expect(astra62Long.output == "60")

  let sol62 = try #require(
    ModelPriceResolver.resolve(account: account, modelID: "gpt-6.2-sol", model: nil)
  )
  #expect(sol62.rates.input == "2")
  #expect(sol62.rates.output == "10")
  #expect(sol62.rates.cachedInput == "0.1")
  #expect(sol62.rates.cacheWrite == "2.5")

  let sol61 = try #require(
    ModelPriceResolver.resolve(account: account, modelID: "gpt-6.1-sol", model: nil)
  )
  #expect(sol61.rates.input == "2")
  #expect(sol61.rates.output == "10")

  let terra61 = try #require(
    ModelPriceResolver.resolve(account: account, modelID: "gpt-6.1-terra", model: nil)
  )
  #expect(terra61.rates.input == "1")
  #expect(terra61.rates.output == "5")
  #expect(terra61.rates.cachedInput == "0.05")
  #expect(terra61.rates.cacheWrite == "1.25")

  let luna6 = try #require(
    ModelPriceResolver.resolve(account: account, modelID: "gpt-6-luna", model: nil)
  )
  #expect(luna6.rates.input == "0.1")
  #expect(luna6.rates.output == "0.5")
  #expect(luna6.rates.cachedInput == "0.01")
  #expect(luna6.rates.cacheWrite == "0.125")
}
