import Foundation
import Testing

@testable import BYOKchatProviderCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

private actor OpenAIDiscoveryMockTransport: ProviderHTTPTransport {
  private var dataResponses: [ProviderHTTPResponse]
  private var requests: [URLRequest] = []

  init(dataResponses: [Data]) {
    self.dataResponses = dataResponses.map {
      ProviderHTTPResponse(statusCode: 200, headers: [:], data: $0)
    }
  }

  func data(for request: URLRequest) async throws -> ProviderHTTPResponse {
    requests.append(request)
    guard !dataResponses.isEmpty else { throw ProviderError.invalidResponse }
    return dataResponses.removeFirst()
  }

  func stream(for request: URLRequest) async throws -> ProviderHTTPByteStream {
    requests.append(request)
    return ProviderHTTPByteStream(
      statusCode: 200,
      headers: [:],
      chunks: AsyncThrowingStream { continuation in
        continuation.finish()
      }
    )
  }

  func request(at index: Int) -> URLRequest? {
    guard requests.indices.contains(index) else { return nil }
    return requests[index]
  }

  func lastRequest() -> URLRequest? { requests.last }
}

private func discoveryOpenAIAccount() -> ResolvedProviderAccount {
  ResolvedProviderAccount(
    kind: .openai,
    id: "openai-discovery-account",
    providerID: "openai",
    label: "OpenAI",
    apiKey: "secret"
  )
}

private func responseRoot(from request: URLRequest) throws -> [String: JSONValue] {
  let body = try #require(request.httpBody)
  let decoded = try JSONDecoder.provider.decode(JSONValue.self, from: body)
  guard case .object(let root) = decoded else {
    Issue.record("Expected Responses request object")
    return [:]
  }
  return root
}

@Test func openAIConnectionProbeUsesSafeOutputBudgetAndDisablesOptionalReasoning() async throws {
  let response = Data(
    """
    {"id":"resp_probe","model":"gpt-5.6-sol","status":"completed","output":[{"id":"msg_probe","type":"message","role":"assistant","content":[{"type":"output_text","text":"OK"}]}],"usage":{"input_tokens":1,"output_tokens":1}}
    """.utf8
  )
  let transport = OpenAIDiscoveryMockTransport(dataResponses: [response])
  let adapter = OpenAIResponsesAdapter(
    definition: BuiltInProviders.openAI,
    transport: transport
  )

  try await adapter.testConnection(
    account: discoveryOpenAIAccount(),
    model: "gpt-5.6-sol"
  )

  let recorded = await transport.lastRequest()
  let request = try #require(recorded)
  let root = try responseRoot(from: request)

  #expect(root["max_output_tokens"] == .number(256))
  guard case .object(let reasoning)? = root["reasoning"] else {
    Issue.record("Expected disabled reasoning config for GPT-5.6 probe")
    return
  }
  #expect(reasoning["effort"] == .string("none"))
  #expect(reasoning["summary"] == nil)
}

@Test func openAISamplingControlsRespectReasoningModelCompatibility() async throws {
  let astraResponse = Data(
    """
    {"id":"resp_astra","model":"gpt-6-astra","status":"completed","output":[{"id":"msg_astra","type":"message","role":"assistant","content":[{"type":"output_text","text":"Astra"}]}]}
    """.utf8
  )
  let solNoneResponse = Data(
    """
    {"id":"resp_sol_none","model":"gpt-5.6-sol","status":"completed","output":[{"id":"msg_sol_none","type":"message","role":"assistant","content":[{"type":"output_text","text":"Sol none"}]}]}
    """.utf8
  )
  let solAutoResponse = Data(
    """
    {"id":"resp_sol_auto","model":"gpt-5.6-sol","status":"completed","output":[{"id":"msg_sol_auto","type":"message","role":"assistant","content":[{"type":"output_text","text":"Sol auto"}]}]}
    """.utf8
  )
  let transport = OpenAIDiscoveryMockTransport(
    dataResponses: [astraResponse, solNoneResponse, solAutoResponse]
  )
  let adapter = OpenAIResponsesAdapter(
    definition: BuiltInProviders.openAI,
    transport: transport
  )
  let account = discoveryOpenAIAccount()

  _ = try await adapter.generate(
    request: ProviderRequest(
      model: "gpt-6-astra",
      messages: [.init(role: .user, content: "Hello")],
      options: .init(
        temperature: 0.4,
        topP: 0.8,
        reasoning: .init(enabled: false)
      )
    ),
    account: account
  )

  _ = try await adapter.generate(
    request: ProviderRequest(
      model: "gpt-5.6-sol",
      messages: [.init(role: .user, content: "Hello")],
      options: .init(
        temperature: 0.4,
        topP: 0.8,
        reasoning: .init(enabled: false)
      )
    ),
    account: account
  )

  _ = try await adapter.generate(
    request: ProviderRequest(
      model: "gpt-5.6-sol",
      messages: [.init(role: .user, content: "Hello")],
      options: .init(temperature: 0.2, topP: 0.7)
    ),
    account: account
  )

  let astraRequest = try #require(await transport.request(at: 0))
  let astraRoot = try responseRoot(from: astraRequest)
  #expect(astraRoot["temperature"] == nil)
  #expect(astraRoot["top_p"] == nil)
  guard case .object(let astraReasoning)? = astraRoot["reasoning"] else {
    Issue.record("Expected Astra reasoning config")
    return
  }
  #expect(astraReasoning["effort"] == .string("low"))

  let solNoneRequest = try #require(await transport.request(at: 1))
  let solNoneRoot = try responseRoot(from: solNoneRequest)
  #expect(solNoneRoot["temperature"] == .number(0.4))
  #expect(solNoneRoot["top_p"] == .number(0.8))
  guard case .object(let solReasoning)? = solNoneRoot["reasoning"] else {
    Issue.record("Expected GPT-5.6 reasoning config")
    return
  }
  #expect(solReasoning["effort"] == .string("none"))

  let solAutoRequest = try #require(await transport.request(at: 2))
  let solAutoRoot = try responseRoot(from: solAutoRequest)
  #expect(solAutoRoot["reasoning"] == nil)
  #expect(solAutoRoot["temperature"] == nil)
  #expect(solAutoRoot["top_p"] == nil)
}

@Test func openAIModelDiscoveryFiltersNonChatFamiliesAndAddsCapabilities() async throws {
  let modelsPayload = Data(
    """
    {"data":[
      {"id":"gpt-6-astra"},
      {"id":"gpt-4.1-mini"},
      {"id":"o4-mini"},
      {"id":"codex-mini-latest"},
      {"id":"text-embedding-3-large"},
      {"id":"gpt-image-2.5"},
      {"id":"gpt-4o-mini-transcribe"},
      {"id":"gpt-4o-realtime-preview"},
      {"id":"whisper-1"},
      {"id":"omni-moderation-latest"}
    ]}
    """.utf8
  )
  let transport = OpenAIDiscoveryMockTransport(dataResponses: [modelsPayload])
  let adapter = OpenAIResponsesAdapter(
    definition: BuiltInProviders.openAI,
    transport: transport
  )

  let models = try await adapter.listModels(account: discoveryOpenAIAccount())
  let ids = Set(models.map(\.id.rawValue))

  #expect(ids.contains("gpt-6-astra"))
  #expect(ids.contains("gpt-4.1-mini"))
  #expect(ids.contains("o4-mini"))
  #expect(ids.contains("codex-mini-latest"))

  #expect(ids.contains("text-embedding-3-large") == false)
  #expect(ids.contains("gpt-image-2.5") == false)
  #expect(ids.contains("gpt-4o-mini-transcribe") == false)
  #expect(ids.contains("gpt-4o-realtime-preview") == false)
  #expect(ids.contains("whisper-1") == false)
  #expect(ids.contains("omni-moderation-latest") == false)

  // Curated chat models remain available even if the account's /models payload omits them.
  #expect(ids.contains("gpt-5.6-sol"))
  #expect(ids.contains("gpt-5.6-terra"))
  #expect(ids.contains("gpt-5.6-luna"))

  let astra = try #require(models.first { $0.id == "gpt-6-astra" })
  #expect(astra.displayName == "GPT-6 Astra")
  #expect(astra.contextWindow == 1_050_000)
  #expect(astra.maxOutputTokens == 128_000)
  #expect(astra.inputModalities.contains("image"))
  #expect(astra.inputModalities.contains("file"))
  #expect(astra.supportedParameters.contains("reasoning"))
  #expect(astra.supportedParameters.contains("tools"))

  let o4 = try #require(models.first { $0.id == "o4-mini" })
  #expect(o4.supportedParameters.contains("reasoning"))
  #expect(o4.supportedParameters.contains("tools"))

  let gpt41 = try #require(models.first { $0.id == "gpt-4.1-mini" })
  #expect(gpt41.supportedParameters.contains("reasoning") == false)
  #expect(gpt41.supportedParameters.contains("temperature"))
  #expect(gpt41.supportedParameters.contains("top_p"))
  #expect(gpt41.supportedParameters.contains("tools"))
}
