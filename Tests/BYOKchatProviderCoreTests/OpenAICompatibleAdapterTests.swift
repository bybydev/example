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


@Test(arguments: ["0", "0.0123", "\"invalid\""])
func openRouterNonStreamingCostIncludingZeroAndInvalid(cost: String) async throws {
  let data = Data("""
    {"id":"r","model":"openrouter/free","choices":[{"message":{"content":"OK"}}],"usage":{"prompt_tokens":10,"completion_tokens":5,"cost":\(cost),"is_byok":false}}
    """.utf8)
  let adapter = OpenAICompatibleAdapter(definition: BuiltInProviders.openRouter, transport: MockTransport(data: data))
  let response = try await adapter.generate(request: .init(model: "openrouter/free", messages: [.init(role: .user, content: "Hi")]),
    account: account(providerID: "openrouter"))
  #expect(ChatBilling.providerReportedCost(from: response.metadata) == ChatBilling.decimal(cost))
  #expect(response.text == "OK")
}

@Test func openRouterFinalStreamingCostReplacesRunningAmount() async throws {
  let data = """
    data: {"model":"openrouter/free","choices":[{"delta":{"content":"OK"}}],"usage":{"cost":0.002}}

    data: {"model":"openrouter/free","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5,"cost":0.01,"is_byok":false}}

    data: [DONE]

    """
  let adapter = OpenAICompatibleAdapter(definition: BuiltInProviders.openRouter,
    transport: MockTransport(streamChunks: [Data(data.utf8)]))
  var final: ProviderResponse?
  for try await event in adapter.stream(request: .init(model: "openrouter/free", messages: [.init(role: .user, content: "Hi")]),
    account: account(providerID: "openrouter")) {
    if case .completed(let value) = event { final = value }
  }
  let response = try #require(final)
  #expect(ChatBilling.providerReportedCost(from: response.metadata) == Decimal(string: "0.01"))
  #expect(response.usage?.outputTokens == 5)
}

@Test func openRouterBYOKFeeDoesNotClaimCompleteInferenceCost() async throws {
  let data = Data(#"{"model":"openrouter/free","choices":[{"message":{"content":"OK"}}],"usage":{"cost":0.01,"is_byok":true,"cost_details":{"upstream_inference_cost":0.2}}}"#.utf8)
  let adapter = OpenAICompatibleAdapter(definition: BuiltInProviders.openRouter, transport: MockTransport(data: data))
  let response = try await adapter.generate(request: .init(model: "openrouter/free", messages: [.init(role: .user, content: "Hi")]),
    account: account(providerID: "openrouter"))
  let receipt = ChatBilling.requestBilling(metadata: response.metadata, usage: response.usage, pricing: nil)
  #expect(receipt.costUSD == "0.01" && !receipt.isComplete)
}

@Test func billingAmountDecodesTicksWithoutDoubleRounding() throws {
  let amount = try JSONDecoder().decode(BillingAmountWire.self, from: Data("9007199254740993".utf8))
  #expect(amount.value == Decimal(string: "9007199254740993"))
}

@Test func openRouterMissingFinalCostDoesNotRetainRunningCost() async throws {
  let data = """
    data: {"model":"openrouter/free","choices":[{"delta":{"content":"OK"}}],"usage":{"cost":0.002}}

    data: {"model":"openrouter/free","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5}}

    data: [DONE]

    """
  let adapter = OpenAICompatibleAdapter(definition: BuiltInProviders.openRouter,
    transport: MockTransport(streamChunks: [Data(data.utf8)]))
  for try await event in adapter.stream(request: .init(model: "openrouter/free", messages: [.init(role: .user, content: "Hi")]),
    account: account(providerID: "openrouter")) {
    if case .completed(let response) = event { #expect(ChatBilling.providerReportedCost(from: response.metadata) == nil) }
  }
}

@Test func deepSeekCacheHitsAndUnsupportedModelFeesRemainVisible() throws {
  let usage = try JSONDecoder().decode(UsageWire.self, from: Data(#"{"prompt_tokens":100,"completion_tokens":10,"prompt_cache_hit_tokens":20}"#.utf8)).normalized
  #expect(usage.cachedInputTokens == 20)
  let prices = try JSONDecoder().decode(PricingWire.self, from: Data(#"{"prompt":"0.000001","completion":"0.000002","request":"0.01"}"#.utf8))
  #expect(prices.hasAdditionalPricingDimensions == true)
  var pricing = ModelPricingSnapshot(source: "providerModelAPI", modelID: "m", rates: .init(input: "1", output: "2"))
  pricing.hasAdditionalPricingDimensions = true
  let receipt = ChatBilling.requestBilling(metadata: [:], usage: .init(inputTokens: 100, outputTokens: 10), pricing: pricing)
  #expect(!receipt.isComplete && receipt.costUSD != nil)
}

@Test func zAIStreamSendsThinkingAndEffortAndSeparatesReasoning() async throws {
  let stream = """
    data: {"id":"z1","model":"glm-5.3","choices":[{"delta":{"reasoning_content":"Plan "},"finish_reason":null}]}

    data: {"id":"z1","model":"glm-5.3","choices":[{"delta":{"content":"Done"},"finish_reason":"stop"}],"usage":{"prompt_tokens":12,"completion_tokens":6,"prompt_tokens_details":{"cached_tokens":4}}}

    data: [DONE]

    """
  let transport = MockTransport(streamChunks: [Data(stream.utf8)])
  let adapter = OpenAICompatibleAdapter(definition: BuiltInProviders.zAI, transport: transport)

  var events: [ProviderStreamEvent] = []
  for try await event in adapter.stream(
    request: ProviderRequest(
      model: "glm-5.3",
      messages: [.init(role: .user, content: "Hello")],
      options: .init(temperature: 0.7, reasoning: .init(enabled: true, effort: .high))
    ),
    account: account(providerID: "zai")
  ) {
    events.append(event)
  }

  let sent = try #require(await transport.lastRequest())
  #expect(sent.url?.absoluteString == "https://api.z.ai/api/paas/v4/chat/completions")
  let body = try #require(sent.httpBody)
  let decoded = try JSONDecoder.provider.decode(JSONValue.self, from: body)
  guard case .object(let root) = decoded else {
    Issue.record("Expected JSON object request body")
    return
  }
  #expect(root["thinking"] == .object(["type": .string("enabled")]))
  #expect(root["reasoning_effort"] == .string("high"))
  #expect(root["temperature"] == .number(0.7))
  #expect(root["stream_options"] == .object(["include_usage": .bool(true)]))

  #expect(events.contains(.reasoningDelta("Plan ")))
  #expect(events.contains(.textDelta("Done")))
  guard case .completed(let response) = events.last else {
    Issue.record("Missing completion event")
    return
  }
  #expect(response.reasoning == "Plan ")
  #expect(response.text == "Done")
  #expect(response.usage?.inputTokens == 12)
  #expect(response.usage?.cachedInputTokens == 4)
}

@Test func zAIForcedThinkingNeverSendsDisabledWhileGLM52AllowsDisabling() async throws {
  let okResponse = Data(
    #"{"id":"z","model":"glm-5.3","choices":[{"message":{"content":"OK"},"finish_reason":"stop"}]}"#.utf8
  )
  let transport53 = MockTransport(data: okResponse)
  let adapter53 = OpenAICompatibleAdapter(definition: BuiltInProviders.zAI, transport: transport53)
  _ = try await adapter53.generate(
    request: ProviderRequest(
      model: "glm-5.3",
      messages: [.init(role: .user, content: "Hi")],
      options: .init(reasoning: .init(enabled: false))
    ),
    account: account(providerID: "zai")
  )
  let body53 = try #require(await transport53.lastRequest()?.httpBody)
  guard case .object(let root53) = try JSONDecoder.provider.decode(JSONValue.self, from: body53) else {
    Issue.record("Expected JSON object request body")
    return
  }
  #expect(root53["thinking"] == nil)
  #expect(root53["reasoning_effort"] == nil)

  let transport52 = MockTransport(data: okResponse)
  let adapter52 = OpenAICompatibleAdapter(definition: BuiltInProviders.zAI, transport: transport52)
  _ = try await adapter52.generate(
    request: ProviderRequest(
      model: "glm-5.2",
      messages: [.init(role: .user, content: "Hi")],
      options: .init(reasoning: .init(enabled: false))
    ),
    account: account(providerID: "zai")
  )
  let body52 = try #require(await transport52.lastRequest()?.httpBody)
  guard case .object(let root52) = try JSONDecoder.provider.decode(JSONValue.self, from: body52) else {
    Issue.record("Expected JSON object request body")
    return
  }
  #expect(root52["thinking"] == .object(["type": .string("disabled")]))
  #expect(root52["reasoning_effort"] == nil)
}

@Test func moonshotStreamSendsEffortOmitsTemperatureAndPreservesToolReasoning() async throws {
  let stream = """
    data: {"id":"m1","model":"kimi-k3.1-pro","choices":[{"delta":{"reasoning_content":"Inspect "},"finish_reason":null}]}

    data: {"id":"m1","model":"kimi-k3.1-pro","choices":[{"delta":{"content":"Result"},"finish_reason":"stop"}]}

    data: {"id":"m1","model":"kimi-k3.1-pro","choices":[],"usage":{"prompt_tokens":20,"completion_tokens":8,"cached_tokens":5}}

    data: [DONE]

    """
  let transport = MockTransport(streamChunks: [Data(stream.utf8)])
  let adapter = OpenAICompatibleAdapter(definition: BuiltInProviders.moonshot, transport: transport)
  let call = ChatToolCall(id: "call_1", name: "lookup", arguments: .object(["q": .string("k3")]))
  let result = ChatToolResult(callID: "call_1", name: "lookup", content: .string("ok"))

  var events: [ProviderStreamEvent] = []
  for try await event in adapter.stream(
    request: ProviderRequest(
      model: "kimi-k3.1-pro",
      messages: [
        .init(role: .user, content: "Check"),
        .init(role: .assistant, content: "", reasoning: "Need tool", toolCalls: [call]),
        .init(role: .tool, content: "", toolResults: [result]),
      ],
      options: .init(temperature: 0.7, topP: 0.8, reasoning: .init(enabled: true, effort: .high))
    ),
    account: account(providerID: "moonshot")
  ) {
    events.append(event)
  }

  let sent = try #require(await transport.lastRequest())
  #expect(sent.url?.absoluteString == "https://api.moonshot.ai/v1/chat/completions")
  let body = try #require(sent.httpBody)
  guard case .object(let root) = try JSONDecoder.provider.decode(JSONValue.self, from: body) else {
    Issue.record("Expected JSON object request body")
    return
  }
  #expect(root["thinking"] == nil)
  #expect(root["reasoning_effort"] == .string("high"))
  #expect(root["temperature"] == nil)
  #expect(root["top_p"] == nil)
  #expect(root["stream_options"] == .object(["include_usage": .bool(true)]))
  if case .array(let messages)? = root["messages"],
    case .object(let assistantMsg) = messages[1]
  {
    #expect(assistantMsg["reasoning_content"] == .string("Need tool"))
  } else {
    Issue.record("Missing assistant tool-call message")
  }

  #expect(events.contains(.reasoningDelta("Inspect ")))
  #expect(events.contains(.textDelta("Result")))
  guard case .completed(let response) = events.last else {
    Issue.record("Missing completion event")
    return
  }
  #expect(response.reasoning == "Inspect ")
  #expect(response.text == "Result")
  #expect(response.usage?.inputTokens == 20)
  #expect(response.usage?.cachedInputTokens == 5)
}

@Test func moonshotK3NeverSendsThinkingDisabled() async throws {
  let okResponse = Data(
    #"{"id":"m","model":"kimi-k3.1-pro","choices":[{"message":{"content":"OK"},"finish_reason":"stop"}]}"#.utf8
  )
  let transport = MockTransport(data: okResponse)
  let adapter = OpenAICompatibleAdapter(definition: BuiltInProviders.moonshot, transport: transport)
  _ = try await adapter.generate(
    request: ProviderRequest(
      model: "kimi-k3.1-pro",
      messages: [.init(role: .user, content: "Hi")],
      options: .init(reasoning: .init(enabled: false))
    ),
    account: account(providerID: "moonshot")
  )
  let body = try #require(await transport.lastRequest()?.httpBody)
  guard case .object(let root) = try JSONDecoder.provider.decode(JSONValue.self, from: body) else {
    Issue.record("Expected JSON object request body")
    return
  }
  #expect(root["thinking"] == nil)
  #expect(root["reasoning_effort"] == nil)
}

@Test func minimaxStreamSendsEffortClampsTemperatureAndPreservesToolReasoning() async throws {
  let stream = """
    data: {"id":"mm1","model":"MiniMax-M3.1-Flash","choices":[{"delta":{"reasoning_content":"Plan "},"finish_reason":null}]}

    data: {"id":"mm1","model":"MiniMax-M3.1-Flash","choices":[{"delta":{"content":"Done"},"finish_reason":"stop"}]}

    data: {"id":"mm1","model":"MiniMax-M3.1-Flash","choices":[],"usage":{"prompt_tokens":30,"completion_tokens":12,"prompt_tokens_details":{"cached_tokens":10}}}

    data: [DONE]

    """
  let transport = MockTransport(streamChunks: [Data(stream.utf8)])
  let adapter = OpenAICompatibleAdapter(definition: BuiltInProviders.minimax, transport: transport)
  let call = ChatToolCall(id: "call_mm1", name: "lookup", arguments: .object(["q": .string("m3")]))
  let result = ChatToolResult(callID: "call_mm1", name: "lookup", content: .string("ok"))

  var events: [ProviderStreamEvent] = []
  for try await event in adapter.stream(
    request: ProviderRequest(
      model: "MiniMax-M3.1-Flash",
      messages: [
        .init(role: .user, content: "Check"),
        .init(role: .assistant, content: "", reasoning: "Need tool", toolCalls: [call]),
        .init(role: .tool, content: "", toolResults: [result]),
      ],
      options: .init(temperature: 0.0, topP: 0.95, reasoning: .init(enabled: true, effort: .xhigh))
    ),
    account: account(providerID: "minimax")
  ) {
    events.append(event)
  }

  let sent = try #require(await transport.lastRequest())
  #expect(sent.url?.absoluteString == "https://api.minimax.io/v1/chat/completions")
  let body = try #require(sent.httpBody)
  guard case .object(let root) = try JSONDecoder.provider.decode(JSONValue.self, from: body) else {
    Issue.record("Expected JSON object request body")
    return
  }
  #expect(root["thinking"] == nil)
  #expect(root["reasoning_effort"] == .string("xhigh"))
  #expect(root["temperature"] == .number(0.01))
  #expect(root["top_p"] == .number(0.95))
  #expect(root["stream_options"] == .object(["include_usage": .bool(true)]))
  if case .array(let messages)? = root["messages"],
    case .object(let assistantMsg) = messages[1]
  {
    #expect(assistantMsg["reasoning_content"] == .string("Need tool"))
  } else {
    Issue.record("Missing assistant tool-call message")
  }

  #expect(events.contains(.reasoningDelta("Plan ")))
  #expect(events.contains(.textDelta("Done")))
  guard case .completed(let response) = events.last else {
    Issue.record("Missing completion event")
    return
  }
  #expect(response.reasoning == "Plan ")
  #expect(response.text == "Done")
  #expect(response.usage?.inputTokens == 30)
  #expect(response.usage?.cachedInputTokens == 10)
}

@Test func minimaxReasoningToggleHonorsModelBoundaries() async throws {
  let okResponse = Data(
    #"{"id":"mm","model":"MiniMax-M3.1-Flash","choices":[{"message":{"content":"OK"},"finish_reason":"stop"}]}"#.utf8
  )
  let transport = MockTransport(data: okResponse)
  let adapter = OpenAICompatibleAdapter(definition: BuiltInProviders.minimax, transport: transport)

  // M3.1-Flash cannot disable thinking: Off normalizes to provider default (omitted).
  _ = try await adapter.generate(
    request: ProviderRequest(
      model: "MiniMax-M3.1-Flash",
      messages: [.init(role: .user, content: "Hi")],
      options: .init(temperature: 1.5, reasoning: .init(enabled: false))
    ),
    account: account(providerID: "minimax")
  )
  let flashBody = try #require(await transport.lastRequest()?.httpBody)
  guard case .object(let flashRoot) = try JSONDecoder.provider.decode(JSONValue.self, from: flashBody)
  else {
    Issue.record("Expected JSON object request body")
    return
  }
  #expect(flashRoot["thinking"] == nil)
  #expect(flashRoot["reasoning_effort"] == nil)
  #expect(flashRoot["temperature"] == .number(1.0))

  // Base M3 supports disabling thinking and explicit adaptive thinking.
  _ = try await adapter.generate(
    request: ProviderRequest(
      model: "MiniMax-M3",
      messages: [.init(role: .user, content: "Hi")],
      options: .init(reasoning: .init(enabled: false))
    ),
    account: account(providerID: "minimax")
  )
  let m3OffBody = try #require(await transport.lastRequest()?.httpBody)
  guard case .object(let m3OffRoot) = try JSONDecoder.provider.decode(JSONValue.self, from: m3OffBody)
  else {
    Issue.record("Expected JSON object request body")
    return
  }
  #expect(m3OffRoot["thinking"] == .object(["type": .string("disabled")]))
  #expect(m3OffRoot["reasoning_effort"] == nil)

  _ = try await adapter.generate(
    request: ProviderRequest(
      model: "MiniMax-M3",
      messages: [.init(role: .user, content: "Hi")],
      options: .init(reasoning: .init(enabled: true))
    ),
    account: account(providerID: "minimax")
  )
  let m3OnBody = try #require(await transport.lastRequest()?.httpBody)
  guard case .object(let m3OnRoot) = try JSONDecoder.provider.decode(JSONValue.self, from: m3OnBody)
  else {
    Issue.record("Expected JSON object request body")
    return
  }
  #expect(m3OnRoot["thinking"] == .object(["type": .string("adaptive")]))
  #expect(m3OnRoot["reasoning_effort"] == nil)
}
