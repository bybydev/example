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
  #expect(peak.rates.input == "0.3" && peak.version == "2026-10-07:peak")
  #expect(peak.timeRule != nil)
  let offPeakDate = try #require(ISO8601DateFormatter().date(from: "2026-10-07T04:00:00Z"))
  #expect(ModelPriceResolver.resolve(account: account, modelID: "deepseek-v4-flash", model: nil, at: offPeakDate)?.rates.input == "0.15")
  let gemini = ProviderAccount(kind: .gemini, id: "g", providerID: "gemini", label: "G")
  let expiry = try #require(ISO8601DateFormatter().date(from: "2027-01-01T00:00:00Z"))
  #expect(ModelPriceResolver.resolve(account: gemini, modelID: "gemini-3.6-flash", model: nil, at: expiry) == nil)
}

@Test func timePricingRejectsCrossedBucketsEvenWithMatchingEndpoints() throws {
  let start = try #require(ISO8601DateFormatter().date(from: "2026-10-07T00:30:00Z"))
  let end = try #require(ISO8601DateFormatter().date(from: "2026-10-07T04:30:00Z"))
  let account = ProviderAccount(kind: .deepSeek, id: "d", providerID: "deepseek", label: "D")
  let pricing = try #require(ModelPriceResolver.resolve(account: account, modelID: "deepseek-v4-pro", model: nil, at: start))
  #expect(!pricing.coversRequest(startedAt: start, endedAt: end))
  #expect(pricing.coversRequest(startedAt: start, endedAt: start.addingTimeInterval(60)))
}
