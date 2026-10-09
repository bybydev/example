import Foundation
import Testing

@testable import BYOKchatProviderCore

@Test(arguments: ["deepseek-flash", "deepseek-v4-flash", "deepseek-v4-flash-vision-exp"])
func deepSeekVerifiedFlashAliasesUseTheSameSavedRule(model: String) throws {
  let account = ProviderAccount(kind: .deepSeek, id: "deepseek", label: "DeepSeek")
  let date = try #require(ISO8601DateFormatter().date(from: "2026-10-08T12:00:00Z"))
  let pricing = try #require(ModelPriceResolver.resolve(
    account: account, modelID: ModelID(rawValue: model), model: nil, at: date))
  #expect(pricing.source == "bundledCatalog")
  #expect(pricing.modelID == model)
  #expect(pricing.verifiedAt == "2026-10-08")
  let receipt = ChatBilling.requestBilling(metadata: [:], usage: .init(
    inputTokens: 1_000, outputTokens: 100, cachedInputTokens: 200), pricing: pricing,
    modelMatches: ModelPriceResolver.responseModelMatches(
      account: account, requestedModelID: ModelID(rawValue: model), responseModelID: "deepseek-flash"))
  #expect(receipt.isComplete && receipt.costUSD == "0.0001806")
  #expect(receipt.accuracy == .calculated)
  #expect(ModelPriceResolver.responseModelMatches(
    account: account, requestedModelID: "deepseek-flash", responseModelID: ModelID(rawValue: model)))
  #expect(!ModelPriceResolver.responseModelMatches(
    account: account, requestedModelID: ModelID(rawValue: model), responseModelID: "deepseek-v4-pro"))
}

@Test(arguments: ["https://api.deepseek.com", "https://api.deepseek.com/",
  "https://api.deepseek.com/v1", "https://api.deepseek.com/v1/", "https://api.deepseek.com:443/v1"])
func deepSeekDirectEndpointSpellingsRetainCatalogFallback(endpoint: String) {
  let account = ProviderAccount(kind: .deepSeek, id: "deepseek", label: "DeepSeek",
    baseURLOverride: URL(string: endpoint))
  #expect(ModelPriceResolver.resolve(account: account, modelID: "deepseek-flash", model: nil) != nil)
  #expect(ModelPriceResolver.responseModelMatches(
    account: account, requestedModelID: "deepseek-v4-flash", responseModelID: "deepseek-flash"))
}

@Test(arguments: ["https://proxy.example/v1", "https://api.deepseek.com.example/v1",
  "http://api.deepseek.com/v1", "https://api.deepseek.com:8443/v1",
  "https://user:password@api.deepseek.com/v1", "https://api.deepseek.com/v1?region=other",
  "https://api.deepseek.com/v1#other", "https://api.deepseek.com/beta",
  "https://api.deepseek.com/anthropic", "https://api.deepseek.com/v1/custom"])
func deepSeekCatalogAndAliasEquivalenceRejectOtherBillingContexts(endpoint: String) {
  let account = ProviderAccount(kind: .deepSeek, id: "deepseek", label: "DeepSeek",
    baseURLOverride: URL(string: endpoint))
  #expect(ModelPriceResolver.resolve(account: account, modelID: "deepseek-flash", model: nil) == nil)
  #expect(!ModelPriceResolver.responseModelMatches(
    account: account, requestedModelID: "deepseek-v4-flash", responseModelID: "deepseek-flash"))
}

@Test func deepSeekAliasesDoNotGrantDirectPricingToCustomOrOtherProviders() {
  for account in [
    ProviderAccount(kind: .openAICompatible, id: "custom", providerID: "deepseek", label: "Custom",
      baseURLOverride: URL(string: "https://api.deepseek.com")),
    ProviderAccount(kind: .openRouter, id: "openrouter", label: "OpenRouter"),
    ProviderAccount(kind: .deepSeek, id: "other", providerID: "other", label: "Other"),
  ] {
    #expect(ModelPriceResolver.resolve(account: account, modelID: "deepseek-flash", model: nil) == nil)
    #expect(!ModelPriceResolver.responseModelMatches(
      account: account, requestedModelID: "deepseek-v4-flash", responseModelID: "deepseek-flash"))
  }
  let account = ProviderAccount(kind: .deepSeek, id: "deepseek", label: "DeepSeek")
  #expect(ModelPriceResolver.resolve(account: account, modelID: "deepseek-flash-custom", model: nil) == nil)
  #expect(!ModelPriceResolver.responseModelMatches(
    account: account, requestedModelID: "deepseek-flash", responseModelID: "deepseek-flash-custom"))
}

@Test func unavailableBillingRetainsSpecificReasonsAndReportedCostStillWins() throws {
  let usage = ProviderUsage(inputTokens: 100, outputTokens: 20)
  let receipt = ChatBilling.requestBilling(metadata: [:], usage: usage, pricing: nil)
  #expect(receipt.missingDimensions == ["supported model pricing"])
  let message = ChatMessage(role: .assistant, status: .complete,
    metadata: ChatBilling.metadata(existing: [:], requests: [receipt], toolCallCount: 0))
  let encoded = try JSONEncoder().encode(ConversationIndexMessage(message: message))
  let restored = try JSONDecoder().decode(ConversationIndexMessage.self, from: encoded).summaryMessage
  #expect(ChatBilling.snapshot(for: restored).requests.first?.missingDimensions == receipt.missingDimensions)
  let reported = ChatBilling.requestBilling(metadata: ["costUSD": "0.01"], usage: nil,
    pricing: nil, modelMatches: false)
  #expect(reported.isComplete && reported.accuracy == .providerReported && reported.costUSD == "0.01")
}

@Test(arguments: 0...3)
func deepSeekAliasBillingSurvivesRuntimePersistence(scenario: Int) async throws {
  let requested: ModelID = scenario == 2 ? "deepseek-flash" : "deepseek-v4-flash"
  let returned: ModelID = scenario == 2 ? "deepseek-v4-flash" : (scenario == 3 ? "deepseek-v4-pro" : "deepseek-flash")
  let workspace = ProviderWorkspaceStore(persistence: InMemoryProviderWorkspacePersistence())
  try await workspace.load()
  let account = ProviderAccount(kind: .deepSeek, id: "alias-account", label: "DeepSeek",
    baseURLOverride: scenario == 1 ? URL(string: "https://api.deepseek.com/v1") : nil)
  try await workspace.upsertAccount(account)
  try await workspace.addManualModel(ProviderModel(providerID: account.providerID,
    id: requested, displayName: "Flash", contextWindow: 16_384, maxOutputTokens: 1_024), for: account.id)
  let persistence = InMemoryConversationWorkspacePersistence()
  let conversations = ConversationStore(persistence: persistence)
  try await conversations.load()
  let conversation = try await conversations.createConversation(
    providerID: account.providerID, accountID: account.id, modelID: requested)
  let chat = ChatRuntime(providerRuntime: DeepSeekAliasPricingRuntime(returnedModel: returned),
    providerWorkspace: workspace, conversations: conversations, partialPersistenceInterval: .zero)
  for try await _ in await chat.send(conversationID: conversation.id, userText: "Hello") {}
  let restored = ConversationStore(persistence: persistence)
  try await restored.load()
  let stored = try await restored.conversation(id: conversation.id)
  let assistant = try #require(stored.messages.last)
  #expect(assistant.status == .complete && assistant.content == "Hello")
  let billing = ChatBilling.snapshot(for: assistant)
  let receipt = try #require(billing.requests.first)
  #expect(receipt.pricing?.source == "bundledCatalog")
  #expect(receipt.pricing?.modelID == requested.rawValue)
  if scenario == 3 {
    #expect(billing.costUSD == nil && billing.accuracy == .unavailable)
    #expect(receipt.missingDimensions.contains("matching model and account configuration"))
  } else {
    #expect((billing.costUSD ?? 0) > 0 && billing.accuracy == .calculated)
    #expect(!receipt.missingDimensions.contains("matching model and account configuration"))
  }
  let summaries = await restored.conversationSummaries()
  let indexed = try #require(summaries.first?.messages.last)
  #expect(ChatBilling.snapshot(for: indexed) == billing)
}

private actor DeepSeekAliasPricingRuntime: ProviderStreamingRuntime {
  let returnedModel: ModelID
  init(returnedModel: ModelID) { self.returnedModel = returnedModel }

  func stream(request: ProviderRequest, accountID: ProviderAccountID) async throws
    -> AsyncThrowingStream<ProviderStreamEvent, Error>
  {
    let response = ProviderResponse(text: "Hello", providerID: "deepseek", accountID: accountID,
      modelID: returnedModel, finishReason: "stop",
      usage: .init(inputTokens: 1_000, outputTokens: 100, cachedInputTokens: 200))
    return AsyncThrowingStream { continuation in
      continuation.yield(.completed(response))
      continuation.finish()
    }
  }
}
