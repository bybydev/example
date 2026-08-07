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
