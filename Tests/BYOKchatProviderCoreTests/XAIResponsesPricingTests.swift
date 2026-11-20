import Foundation
import Testing

@testable import BYOKchatProviderCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Test func xAILanguageModelDiscoveryImportsLiveTokenPricing() async throws {
  let payload = Data(
    """
    {"models":[
      {"id":"grok-4.6","input_modalities":["text","image"],"output_modalities":["text"],"prompt_text_token_price":20000,"cached_prompt_text_token_price":5000,"completion_text_token_price":60000}
    ]}
    """.utf8
  )
  let transport = XAIPricingTransport(payload: payload)
  let adapter = XAIResponsesAdapter(definition: BuiltInProviders.xAI, transport: transport)

  let models = try await adapter.listModels(account: xAIPricingAccount())
  let model = try #require(models.first { $0.id == "grok-4.6" })

  #expect(model.displayName == "Grok 4.6")
  #expect(model.contextWindow == 500_000)
  #expect(model.promptPricePerToken == "0.000002")
  #expect(model.cachedInputPricePerToken == "0.0000005")
  #expect(model.completionPricePerToken == "0.000006")
  #expect(model.inputModalities.contains("image"))
  #expect(model.inputModalities.contains("file"))
  #expect(await transport.lastPath() == "/v1/language-models")
}

private actor XAIPricingTransport: ProviderHTTPTransport {
  private let payload: Data
  private var request: URLRequest?

  init(payload: Data) {
    self.payload = payload
  }

  func data(for request: URLRequest) async throws -> ProviderHTTPResponse {
    self.request = request
    return ProviderHTTPResponse(statusCode: 200, headers: [:], data: payload)
  }

  func stream(for request: URLRequest) async throws -> ProviderHTTPByteStream {
    throw ProviderError.invalidResponse
  }

  func lastPath() -> String? { request?.url?.path }
}

private func xAIPricingAccount() -> ResolvedProviderAccount {
  ResolvedProviderAccount(
    kind: .xAI,
    id: "xai-pricing-account",
    providerID: "xai",
    label: "xAI",
    apiKey: "xai-secret"
  )
}


@Test func xAIReportedCostPreservesIntegerTicksExactly() async throws {
  let data = Data(#"{"id":"r","model":"grok-4.6","status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"OK"}]}],"usage":{"input_tokens":1,"output_tokens":1,"cost_in_usd_ticks":9007199254740993}}"#.utf8)
  let adapter = XAIResponsesAdapter(definition: BuiltInProviders.xAI, transport: XAIPricingTransport(payload: data))
  let response = try await adapter.generate(request: .init(model: "grok-4.6", messages: [.init(role: .user, content: "Hi")]),
    account: xAIPricingAccount())
  #expect(response.metadata["xai.costInUSDTicks"] == "9007199254740993")
  #expect(ChatBilling.providerReportedCost(from: response.metadata) == Decimal(string: "900719.9254740993"))
}

@Test func xAIBundledPricingResolvesFallbackRatesAndLongContextMultipliers() throws {
  let account = ProviderAccount(kind: .xAI, id: "xai", providerID: "xai", label: "xAI")

  let grok47 = try #require(ModelPriceResolver.resolve(account: account, modelID: "grok-4.7", model: nil))
  #expect(grok47.source == "bundledCatalog")
  #expect(grok47.rates.input == "2")
  #expect(grok47.rates.output == "6")
  #expect(grok47.rates.cachedInput == "0.5")
  #expect(grok47.longContextThreshold == 200_000)
  let grok47Long = grok47.rates(for: ProviderUsage(inputTokens: 250_000, outputTokens: 1_000))
  #expect(grok47Long.input == "4")
  #expect(grok47Long.output == "12")
  #expect(grok47Long.cachedInput == "1")

  let grok43 = try #require(ModelPriceResolver.resolve(account: account, modelID: "grok-4.3", model: nil))
  #expect(grok43.rates.input == "1.25")
  #expect(grok43.rates.output == "2.5")
  #expect(grok43.rates.cachedInput == "0.2")
}
