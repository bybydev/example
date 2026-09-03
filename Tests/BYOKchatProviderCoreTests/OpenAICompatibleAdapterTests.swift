import Foundation
import Testing

@testable import BYOKchatProviderCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

private actor MockTransport: ProviderHTTPTransport {
  var dataResponse: ProviderHTTPResponse
  var streamResponse: ProviderHTTPByteStream
  var requests: [URLRequest] = []

  init(
    data: Data = Data(), streamChunks: [Data] = [], statusCode: Int = 200,
    headers: [String: String] = [:]
  ) {
    self.dataResponse = ProviderHTTPResponse(statusCode: statusCode, headers: headers, data: data)
    self.streamResponse = ProviderHTTPByteStream(
      statusCode: statusCode,
      headers: headers,
      chunks: AsyncThrowingStream { continuation in
        for chunk in streamChunks { continuation.yield(chunk) }
        continuation.finish()
      }
    )
  }

  func data(for request: URLRequest) async throws -> ProviderHTTPResponse {
    requests.append(request)
    return dataResponse
  }

  func stream(for request: URLRequest) async throws -> ProviderHTTPByteStream {
    requests.append(request)
    return streamResponse
  }

  func lastRequest() -> URLRequest? { requests.last }
}

private func account(providerID: ProviderID) -> ResolvedProviderAccount {
  ResolvedProviderAccount(
    kind: ProviderKind(providerID: providerID),
    id: "test-account",
    providerID: providerID,
    label: "Test",
    apiKey: "secret"
  )
}

@Test func deepSeekStreamSeparatesReasoningFromAnswer() async throws {
  let stream = """
    data: {"id":"x","model":"deepseek-v4-flash","choices":[{"delta":{"reasoning_content":"Think "},"finish_reason":null}]}

    data: {"id":"x","model":"deepseek-v4-flash","choices":[{"delta":{"content":"Answer"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5}}

    data: [DONE]

    """
  let transport = MockTransport(streamChunks: [Data(stream.utf8)])
  let adapter = OpenAICompatibleAdapter(definition: BuiltInProviders.deepSeek, transport: transport)

  var events: [ProviderStreamEvent] = []
  for try await event in adapter.stream(
    request: ProviderRequest(
      model: "deepseek-v4-flash",
      messages: [.init(role: .user, content: "Hello")],
      options: .init(reasoning: .init(enabled: true, effort: .max))
    ),
    account: account(providerID: "deepseek")
  ) {
    events.append(event)
  }

  #expect(events.contains(.reasoningDelta("Think ")))
  #expect(events.contains(.textDelta("Answer")))
  guard case .completed(let response) = events.last else {
    Issue.record("Missing completion event")
    return
  }
  #expect(response.reasoning == "Think ")
  #expect(response.text == "Answer")
  #expect(response.usage?.inputTokens == 10)
}

@Test func openRouterRequestIncludesRoutingAndMetadataHeader() async throws {
  let response = Data(
    "{\"id\":\"x\",\"model\":\"openrouter/free\",\"choices\":[{\"message\":{\"content\":\"OK\"},\"finish_reason\":\"stop\"}]}"
      .utf8)
  let transport = MockTransport(data: response)
  let adapter = OpenAICompatibleAdapter(
    definition: BuiltInProviders.openRouter, transport: transport)
  let configuredAccount = ResolvedProviderAccount(
    kind: ProviderKind(providerID: "openrouter"),
    id: "or",
    providerID: "openrouter",
    label: "OpenRouter",
    apiKey: "secret",
    metadata: ["httpReferer": "https://example.com", "appTitle": "BYOKchat"]
  )

  _ = try await adapter.generate(
    request: ProviderRequest(
      model: "openrouter/free",
      messages: [.init(role: .user, content: "Hello")],
      options: .init(
        reasoning: .init(enabled: true, effort: .high),
        openRouterRouting: .init(
          providerOrder: ["deepinfra/turbo"],
          allowFallbacks: false,
          dataCollection: .deny,
          zeroDataRetention: true,
          sort: .throughput
        )
      )
    ),
    account: configuredAccount
  )

  let request = await transport.lastRequest()
  #expect(request?.value(forHTTPHeaderField: "X-OpenRouter-Metadata") == "enabled")
  #expect(request?.value(forHTTPHeaderField: "HTTP-Referer") == "https://example.com")
  let body = try #require(request?.httpBody)
  let object = try JSONDecoder.provider.decode(JSONValue.self, from: body)
  guard case .object(let root) = object,
    case .object(let routing)? = root["provider"]
  else {
    Issue.record("Missing provider routing body")
    return
  }
  #expect(routing["zdr"] == .bool(true))
  #expect(routing["allow_fallbacks"] == .bool(false))
}

@Test func midStreamProviderErrorIsSurfaced() async throws {
  let stream = """
    data: {"id":"x","model":"openrouter/free","error":{"code":"server_error","message":"Provider disconnected"},"choices":[{"delta":{"content":""},"finish_reason":"error"}]}

    """
  let transport = MockTransport(streamChunks: [Data(stream.utf8)])
  let adapter = OpenAICompatibleAdapter(
    definition: BuiltInProviders.openRouter, transport: transport)

  await #expect(throws: ProviderError.self) {
    for try await _ in adapter.stream(
      request: ProviderRequest(
        model: "openrouter/free", messages: [.init(role: .user, content: "Hi")]),
      account: account(providerID: "openrouter")
    ) {}
  }
}

@Test func modelDiscoveryMergesSeedAndRemoteMetadata() async throws {
  let models = Data(
    """
    {"data":[{"id":"openrouter/free","name":"Free Router","context_length":200000,"supported_parameters":["temperature","reasoning"],"architecture":{"input_modalities":["text"],"output_modalities":["text"]},"pricing":{"prompt":"0","completion":"0"}}]}
    """.utf8)
  let transport = MockTransport(data: models)
  let adapter = OpenAICompatibleAdapter(
    definition: BuiltInProviders.openRouter, transport: transport)
  let result = try await adapter.listModels(account: account(providerID: "openrouter"))
  let model = try #require(result.first { $0.id == "openrouter/free" })
  #expect(model.contextWindow == 200000)
  #expect(model.supportedParameters.contains("max_tokens"))
  #expect(model.supportedParameters.contains("reasoning"))
}
