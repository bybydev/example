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
  #expect(request?.value(forHTTPHeaderField: "X-OpenRouter-Title") == "BYOKchat")
  #expect(request?.value(forHTTPHeaderField: "X-Title") == "BYOKchat")
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
  #expect(root["reasoning"] == .object(["effort": .string("high")]))
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

@Test func mistralStreamDecodesThinkingChunksAndFormatsToolMessages() async throws {
  let stream = """
    data: {"id":"mis1","model":"mistral-large-4-0","choices":[{"delta":{"content":[{"type":"thinking","thinking":[{"type":"text","text":"Step 1 "}]}]},"finish_reason":null}]}

    data: {"id":"mis1","model":"mistral-large-4-0","choices":[{"delta":{"content":[{"type":"text","text":"Answer"}]},"finish_reason":"stop"}]}

    data: {"id":"mis1","model":"mistral-large-4-0","choices":[],"usage":{"prompt_tokens":128,"completion_tokens":16,"prompt_tokens_details":{"cached_tokens":64}}}

    data: [DONE]

    """
  let transport = MockTransport(streamChunks: [Data(stream.utf8)])
  let adapter = OpenAICompatibleAdapter(definition: BuiltInProviders.mistral, transport: transport)
  let call = ChatToolCall(id: "v9a8b7c6d", name: "lookup", arguments: .object(["q": .string("m4")]))
  let result = ChatToolResult(callID: "v9a8b7c6d", name: "lookup", content: .string("ok"))

  var events: [ProviderStreamEvent] = []
  for try await event in adapter.stream(
    request: ProviderRequest(
      model: "mistral-large-4-0",
      messages: [
        .init(role: .user, content: "Check"),
        .init(role: .assistant, content: "", toolCalls: [call]),
        .init(role: .tool, content: "", toolResults: [result]),
      ],
      options: .init(temperature: 0.4, reasoning: .init(enabled: true, effort: .medium))
    ),
    account: account(providerID: "mistral")
  ) {
    events.append(event)
  }

  let sent = try #require(await transport.lastRequest())
  #expect(sent.url?.absoluteString == "https://api.mistral.ai/v1/chat/completions")
  let body = try #require(sent.httpBody)
  guard case .object(let root) = try JSONDecoder.provider.decode(JSONValue.self, from: body) else {
    Issue.record("Expected JSON object request body")
    return
  }
  #expect(root["reasoning_effort"] == .string("medium"))
  #expect(root["temperature"] == .number(0.4))
  #expect(root["stream_options"] == .object(["include_usage": .bool(true)]))
  if case .array(let messages)? = root["messages"],
    case .object(let assistantMsg) = messages[1],
    case .object(let toolMsg) = messages[2]
  {
    #expect(assistantMsg["content"] == .string(""))
    #expect(toolMsg["name"] == .string("lookup"))
    #expect(toolMsg["tool_call_id"] == .string("v9a8b7c6d"))
  } else {
    Issue.record("Missing assistant/tool messages")
  }

  #expect(events.contains(.reasoningDelta("Step 1 ")))
  #expect(events.contains(.textDelta("Answer")))
  guard case .completed(let response) = events.last else {
    Issue.record("Missing completion event")
    return
  }
  #expect(response.reasoning == "Step 1 ")
  #expect(response.text == "Answer")
  #expect(response.usage?.inputTokens == 128)
  #expect(response.usage?.cachedInputTokens == 64)
}

@Test func mistralGenerateDecodesThinkingArrayAndHonorsReasoningBoundaries() async throws {
  let responseJSON = Data(
    #"""
    {"id":"mis2","model":"mistral-large-4-0","choices":[{"message":{"role":"assistant","content":[{"type":"thinking","thinking":[{"type":"text","text":"Check math"}],"closed":true},{"type":"text","text":"42"}]},"finish_reason":"stop"}]}
    """#.utf8
  )
  let transport = MockTransport(data: responseJSON)
  let adapter = OpenAICompatibleAdapter(definition: BuiltInProviders.mistral, transport: transport)

  // Large 4 cannot disable reasoning: Off normalizes to provider default (omitted).
  let largeResponse = try await adapter.generate(
    request: ProviderRequest(
      model: "mistral-large-4-0",
      messages: [.init(role: .user, content: "What is 6*7?")],
      options: .init(reasoning: .init(enabled: false))
    ),
    account: account(providerID: "mistral")
  )
  #expect(largeResponse.reasoning == "Check math")
  #expect(largeResponse.text == "42")
  let largeBody = try #require(await transport.lastRequest()?.httpBody)
  guard case .object(let largeRoot) = try JSONDecoder.provider.decode(JSONValue.self, from: largeBody)
  else {
    Issue.record("Expected JSON object request body")
    return
  }
  #expect(largeRoot["reasoning_effort"] == nil)

  // Small 4 supports reasoning_effort = "none".
  _ = try await adapter.generate(
    request: ProviderRequest(
      model: "mistral-small-2603",
      messages: [.init(role: .user, content: "Hi")],
      options: .init(reasoning: .init(enabled: false))
    ),
    account: account(providerID: "mistral")
  )
  let smallBody = try #require(await transport.lastRequest()?.httpBody)
  guard case .object(let smallRoot) = try JSONDecoder.provider.decode(JSONValue.self, from: smallBody)
  else {
    Issue.record("Expected JSON object request body")
    return
  }
  #expect(smallRoot["reasoning_effort"] == .string("none"))
}

@Test func mistralDiscoveryFiltersNonChatAndReadsCapabilities() async throws {
  let modelsJSON = Data(
    #"""
    {
      "object": "list",
      "data": [
        {
          "id": "ministral-8b-2512",
          "name": "Ministral 3 8B",
          "max_context_length": 262144,
          "capabilities": { "completion_chat": true, "function_calling": true, "vision": true },
          "archived": false
        },
        {
          "id": "mistral-embed",
          "name": "Mistral Embed",
          "max_context_length": 8192,
          "capabilities": { "completion_chat": false, "function_calling": false, "vision": false },
          "archived": false
        },
        {
          "id": "mistral-legacy-archived",
          "name": "Legacy",
          "max_context_length": 32768,
          "capabilities": { "completion_chat": true },
          "archived": true
        }
      ]
    }
    """#.utf8
  )
  let transport = MockTransport(data: modelsJSON)
  let adapter = OpenAICompatibleAdapter(definition: BuiltInProviders.mistral, transport: transport)
  let models = try await adapter.listModels(account: account(providerID: "mistral"))

  let ministral = try #require(models.first { $0.id == "ministral-8b-2512" })
  #expect(ministral.contextWindow == 262_144)
  #expect(ministral.inputModalities.contains("image"))
  #expect(ministral.supportedParameters.contains("tools"))
  #expect(!models.contains { $0.id == "mistral-embed" })
  #expect(!models.contains { $0.id == "mistral-legacy-archived" })
}

@Test func localProvidersSupportOptionalAPIKeyAndAutoV1Path() async throws {
  let modelsJSON = Data(#"{"object":"list","data":[{"id":"qwen3:8b","name":"Qwen 3 8B"}]}"#.utf8)
  let transport = MockTransport(data: modelsJSON)
  let ollamaAdapter = OpenAICompatibleAdapter(
    definition: BuiltInProviders.ollama, transport: transport)
  let localAccount = ResolvedProviderAccount(
    kind: .ollama,
    id: "ollama-local",
    providerID: BuiltInProviders.ollamaID,
    label: "Ollama",
    apiKey: nil,
    baseURLOverride: URL(string: "http://192.168.1.42:11434")
  )

  let models = try await ollamaAdapter.listModels(account: localAccount)
  #expect(models.map(\.id) == ["qwen3:8b"])
  let discoveryRequest = try #require(await transport.lastRequest())
  #expect(discoveryRequest.url?.absoluteString == "http://192.168.1.42:11434/v1/models")
  #expect(discoveryRequest.value(forHTTPHeaderField: "Authorization") == nil)
  #expect(discoveryRequest.timeoutInterval == 120)

  let chatJSON = Data(
    #"{"id":"local-1","model":"qwen3:8b","choices":[{"message":{"content":"Hi"},"finish_reason":"stop"}]}"#
      .utf8
  )
  let chatTransport = MockTransport(data: chatJSON)
  let lmAdapter = OpenAICompatibleAdapter(
    definition: BuiltInProviders.lmStudio, transport: chatTransport)
  let noKeyLM = ResolvedProviderAccount(
    kind: .lmStudio,
    id: "lm-local",
    providerID: BuiltInProviders.lmStudioID,
    label: "LM Studio",
    apiKey: "",
    baseURLOverride: URL(string: "http://macbook.local:1234")
  )
  let noKeyResponse = try await lmAdapter.generate(
    request: ProviderRequest(model: "qwen3:8b", messages: [.init(role: .user, content: "Hello")]),
    account: noKeyLM
  )
  #expect(noKeyResponse.text == "Hi")
  let noKeyReq = try #require(await chatTransport.lastRequest())
  #expect(noKeyReq.url?.absoluteString == "http://macbook.local:1234/v1/chat/completions")
  #expect(noKeyReq.value(forHTTPHeaderField: "Authorization") == nil)

  var keyedLM = noKeyLM
  keyedLM.apiKey = "lm-secret"
  _ = try await lmAdapter.generate(
    request: ProviderRequest(model: "qwen3:8b", messages: [.init(role: .user, content: "Hello")]),
    account: keyedLM
  )
  let keyedReq = try #require(await chatTransport.lastRequest())
  #expect(keyedReq.value(forHTTPHeaderField: "Authorization") == "Bearer lm-secret")

  let customAccount = ResolvedProviderAccount(
    kind: .openAICompatible,
    id: "custom-local",
    providerID: "custom-local",
    label: "vLLM",
    apiKey: nil,
    baseURLOverride: URL(string: "http://homelab:8000/v1"),
    chatCompletionsPath: "/chat/completions",
    modelsPath: "/models",
    authChoice: .bearer
  )
  let customAdapter = OpenAICompatibleAdapter(
    definition: customAccount.definition, transport: chatTransport)
  _ = try await customAdapter.generate(
    request: ProviderRequest(model: "llama-3", messages: [.init(role: .user, content: "Hello")]),
    account: customAccount
  )
  let customReq = try #require(await chatTransport.lastRequest())
  #expect(customReq.url?.absoluteString == "http://homelab:8000/v1/chat/completions")
  #expect(customReq.value(forHTTPHeaderField: "Authorization") == nil)
}

@Test func deepSeekPreservesReasoningContentAcrossToolTurnsAndOmitsWithoutTools() async throws {
  let okResponse = Data(
    #"{"id":"ds-1","model":"deepseek-flash","choices":[{"message":{"content":"Done"},"finish_reason":"stop"}]}"#
      .utf8
  )
  let transport = MockTransport(data: okResponse)
  let adapter = OpenAICompatibleAdapter(definition: BuiltInProviders.deepSeek, transport: transport)
  let tool = ChatToolDefinition(
    name: "lookup",
    description: "Look up data",
    inputSchema: .object(["type": .string("object")])
  )
  let call1 = ChatToolCall(id: "call_1", name: "lookup", arguments: .object(["q": .string("a")]))
  let result1 = ChatToolResult(callID: "call_1", name: "lookup", content: .string("1"))
  let call2 = ChatToolCall(id: "call_2", name: "lookup", arguments: .object(["q": .string("b")]))
  let result2 = ChatToolResult(callID: "call_2", name: "lookup", content: .string("2"))

  // Request with tools: prior assistant turn, tool-call turn with reasoning, and
  // tool-call turn missing reasoning (e.g., after model switch) all carry reasoning_content.
  _ = try await adapter.generate(
    request: ProviderRequest(
      model: "deepseek-flash",
      messages: [
        .init(role: .user, content: "First question"),
        .init(role: .assistant, content: "First answer", reasoning: "Turn 1 thought"),
        .init(role: .user, content: "Use tools"),
        .init(role: .assistant, content: "", reasoning: "Need lookup a", toolCalls: [call1]),
        .init(role: .tool, content: "", toolResults: [result1]),
        .init(role: .assistant, content: "", reasoning: nil, toolCalls: [call2]),
        .init(role: .tool, content: "", toolResults: [result2]),
      ],
      options: .init(reasoning: .init(enabled: true, effort: .high)),
      tools: [tool]
    ),
    account: account(providerID: "deepseek")
  )

  let toolBody = try #require(await transport.lastRequest()?.httpBody)
  guard case .object(let toolRoot) = try JSONDecoder.provider.decode(JSONValue.self, from: toolBody),
    case .array(let toolMessages)? = toolRoot["messages"],
    toolMessages.count == 7,
    case .object(let userMsg) = toolMessages[0],
    case .object(let priorAssistant) = toolMessages[1],
    case .object(let toolCallWithReasoning) = toolMessages[3],
    case .object(let toolCallWithoutReasoning) = toolMessages[5]
  else {
    Issue.record("Missing expected DeepSeek tool messages")
    return
  }
  #expect(userMsg["reasoning_content"] == nil)
  #expect(priorAssistant["reasoning_content"] == .string("Turn 1 thought"))
  #expect(toolCallWithReasoning["reasoning_content"] == .string("Need lookup a"))
  #expect(toolCallWithoutReasoning["reasoning_content"] == .string(""))

  // Plain multi-turn request without tools omits reasoning_content to avoid unnecessary payload bloat.
  _ = try await adapter.generate(
    request: ProviderRequest(
      model: "deepseek-flash",
      messages: [
        .init(role: .user, content: "Hi"),
        .init(role: .assistant, content: "Hello", reasoning: "Old thought"),
        .init(role: .user, content: "Next"),
      ],
      options: .init(reasoning: .init(enabled: true, effort: .high))
    ),
    account: account(providerID: "deepseek")
  )

  let plainBody = try #require(await transport.lastRequest()?.httpBody)
  guard case .object(let plainRoot) = try JSONDecoder.provider.decode(JSONValue.self, from: plainBody),
    case .array(let plainMessages)? = plainRoot["messages"],
    case .object(let plainAssistant) = plainMessages[1]
  else {
    Issue.record("Missing expected DeepSeek plain messages")
    return
  }
  #expect(plainAssistant["reasoning_content"] == nil)
}

@Test func deepSeekDiscoveryDecodesLimitsModalitiesAndEffortLevels() async throws {
  let modelsJSON = Data(
    #"""
    {
      "object": "list",
      "data": [
        {
          "id": "deepseek-flash",
          "object": "model",
          "owned_by": "deepseek",
          "name": "DeepSeek-V4.1-Flash",
          "context_window": 1000000,
          "max_output_tokens": 384000,
          "input_modalities": ["text", "image"],
          "output_modalities": ["text"],
          "effort": {
            "supported_levels": ["low", "high", "max"],
            "default_level": "high"
          }
        },
        {
          "id": "deepseek-v4-pro",
          "object": "model",
          "owned_by": "deepseek",
          "name": "DeepSeek-V4-Pro",
          "context_window": 1000000,
          "max_output_tokens": 384000,
          "input_modalities": ["text"],
          "output_modalities": ["text"],
          "effort": {
            "supported_levels": ["low", "high", "max"],
            "default_level": "high"
          }
        },
        {
          "id": "deepseek-v5-preview",
          "object": "model",
          "owned_by": "deepseek",
          "name": "DeepSeek V5 Preview",
          "context_window": 2000000,
          "max_output_tokens": 256000,
          "input_modalities": ["text", "image"],
          "output_modalities": ["text"],
          "effort": {
            "supported_levels": ["low", "medium", "high", "max"],
            "default_level": "high"
          }
        }
      ]
    }
    """#.utf8
  )
  let transport = MockTransport(data: modelsJSON)
  let adapter = OpenAICompatibleAdapter(definition: BuiltInProviders.deepSeek, transport: transport)
  let models = try await adapter.listModels(account: account(providerID: "deepseek"))

  let flash = try #require(models.first { $0.id == "deepseek-flash" })
  let flashCaps = ModelCapabilityResolver.resolve(kind: .deepSeek, modelID: flash.id, model: flash)
  #expect(flashCaps.contextWindow == 1_000_000)
  #expect(flashCaps.maxOutputTokens == 384_000)
  #expect(flashCaps[.imageInput] == .supported)
  #expect(flashCaps[.fileInput] == .unsupported)
  #expect(flashCaps.reasoning.efforts == [.low, .high, .max])
  #expect(flashCaps.reasoning.allowsOff)

  let pro = try #require(models.first { $0.id == "deepseek-v4-pro" })
  let proCaps = ModelCapabilityResolver.resolve(kind: .deepSeek, modelID: pro.id, model: pro)
  #expect(proCaps[.imageInput] == .unsupported)
  #expect(proCaps[.fileInput] == .unsupported)
  #expect(proCaps.reasoning.efforts == [.low, .high, .max])

  let v5 = try #require(models.first { $0.id == "deepseek-v5-preview" })
  let v5Caps = ModelCapabilityResolver.resolve(kind: .deepSeek, modelID: v5.id, model: v5)
  #expect(v5Caps.contextWindow == 2_000_000)
  #expect(v5Caps.maxOutputTokens == 256_000)
  #expect(v5Caps[.imageInput] == .supported)
  #expect(v5Caps.reasoning.efforts == [.low, .medium, .high, .max])
  #expect(v5Caps.reasoning.defaultEffort == .high)
  #expect(v5Caps.reasoning.source == .discovery)
}

@Test func deepSeekTestConnectionDisablesThinkingForKnownModelsAndBudgetsUnknownModels() async throws {
  let okResponse = Data(
    #"{"id":"ds-ok","model":"deepseek-flash","choices":[{"message":{"content":"OK"},"finish_reason":"stop"}]}"#
      .utf8
  )
  let transport = MockTransport(data: okResponse)
  let adapter = OpenAICompatibleAdapter(definition: BuiltInProviders.deepSeek, transport: transport)

  try await adapter.testConnection(account: account(providerID: "deepseek"), model: "deepseek-flash")
  let knownBody = try #require(await transport.lastRequest()?.httpBody)
  guard case .object(let knownRoot) = try JSONDecoder.provider.decode(JSONValue.self, from: knownBody)
  else {
    Issue.record("Expected JSON object request body")
    return
  }
  #expect(knownRoot["thinking"] == .object(["type": .string("disabled")]))
  #expect(knownRoot["reasoning_effort"] == nil)
  #expect(knownRoot["max_tokens"] == .number(16))

  try await adapter.testConnection(account: account(providerID: "deepseek"), model: "deepseek-future")
  let unknownBody = try #require(await transport.lastRequest()?.httpBody)
  guard case .object(let unknownRoot) = try JSONDecoder.provider.decode(JSONValue.self, from: unknownBody)
  else {
    Issue.record("Expected JSON object request body")
    return
  }
  #expect(unknownRoot["max_tokens"] == .number(1024))
}

@Test func openAICompatibleEmptyContentSurfacesContentFilterAndLengthFinishReasons() async throws {
  let filteredJSON = Data(
    #"{"id":"ds-cf","model":"deepseek-flash","choices":[{"message":{"content":""},"finish_reason":"content_filter"}]}"#
      .utf8
  )
  let adapter = OpenAICompatibleAdapter(
    definition: BuiltInProviders.deepSeek,
    transport: MockTransport(data: filteredJSON)
  )
  do {
    _ = try await adapter.generate(
      request: ProviderRequest(model: "deepseek-flash", messages: [.init(role: .user, content: "Hi")]),
      account: account(providerID: "deepseek")
    )
    Issue.record("Expected content_filter error")
  } catch let error as ProviderError {
    if case .provider(_, let message) = error {
      #expect(message.localizedCaseInsensitiveContains("content filter"))
    } else {
      Issue.record("Expected .provider error for content_filter, got \(error)")
    }
  }

  let lengthStream = """
    data: {"id":"ds-len","model":"deepseek-flash","choices":[{"delta":{"content":""},"finish_reason":"length"}]}

    data: [DONE]

    """
  let streamAdapter = OpenAICompatibleAdapter(
    definition: BuiltInProviders.deepSeek,
    transport: MockTransport(streamChunks: [Data(lengthStream.utf8)])
  )
  do {
    for try await _ in streamAdapter.stream(
      request: ProviderRequest(model: "deepseek-flash", messages: [.init(role: .user, content: "Hi")]),
      account: account(providerID: "deepseek")
    ) {}
    Issue.record("Expected length limit error")
  } catch let error as ProviderError {
    if case .provider(_, let message) = error {
      #expect(message.localizedCaseInsensitiveContains("token limit"))
    } else {
      Issue.record("Expected .provider error for length, got \(error)")
    }
  }
}

@Test func openRouterIntegerErrorCodesAndMetadataAreDecodedInHTTPAndStreams() async throws {
  let httpErrorJSON = Data(
    #"""
    {"error":{"code":400,"message":"Provider returned error","metadata":{"raw":"{\"error\":{\"message\":\"Invalid reasoning config\"}}","provider_name":"Anthropic"}}}
    """#.utf8
  )
  let httpAdapter = OpenAICompatibleAdapter(
    definition: BuiltInProviders.openRouter,
    transport: MockTransport(data: httpErrorJSON, statusCode: 400)
  )
  do {
    _ = try await httpAdapter.generate(
      request: ProviderRequest(model: "openrouter/free", messages: [.init(role: .user, content: "Hi")]),
      account: account(providerID: "openrouter")
    )
    Issue.record("Expected HTTP 400 error")
  } catch let error as ProviderError {
    if case .provider(let status, let message) = error {
      #expect(status == 400)
      #expect(message.contains("Provider returned error"))
      #expect(message.contains("Anthropic"))
      #expect(message.contains("Invalid reasoning config"))
    } else {
      Issue.record("Expected .provider error, got \(error)")
    }
  }

  let streamError = """
    data: {"id":"or-err","model":"openrouter/free","error":{"code":502,"message":"Upstream provider crashed","metadata":{"provider_name":"Google"}},"choices":[{"delta":{"content":""},"finish_reason":"error"}]}

    """
  let streamAdapter = OpenAICompatibleAdapter(
    definition: BuiltInProviders.openRouter,
    transport: MockTransport(streamChunks: [Data(streamError.utf8)])
  )
  do {
    for try await _ in streamAdapter.stream(
      request: ProviderRequest(model: "openrouter/free", messages: [.init(role: .user, content: "Hi")]),
      account: account(providerID: "openrouter")
    ) {}
    Issue.record("Expected mid-stream error")
  } catch let error as ProviderError {
    if case .midStreamProvider(let code, let message) = error {
      #expect(code == "502")
      #expect(message.contains("Upstream provider crashed"))
      #expect(message.contains("Google"))
    } else {
      Issue.record("Expected .midStreamProvider error, got \(error)")
    }
  }
}

@Test func openRouterDeduplicatesReasoningAndPreservesReasoningDetailsAcrossToolTurns() async throws {
  let stream = """
    data: {"id":"or-1","model":"anthropic/claude-sonnet-4.6","choices":[{"delta":{"reasoning":"Step 1. ","reasoning_details":[{"type":"reasoning.text","text":"Step 1. ","format":"anthropic-claude-v1","index":0}]},"finish_reason":null}]}

    data: {"id":"or-1","model":"anthropic/claude-sonnet-4.6","choices":[{"delta":{"reasoning":"Step 2.","reasoning_details":[{"type":"reasoning.text","text":"Step 2.","format":"anthropic-claude-v1","index":0}]},"finish_reason":null}]}

    data: {"id":"or-1","model":"anthropic/claude-sonnet-4.6","choices":[{"delta":{"reasoning_details":[{"type":"reasoning.text","signature":"sig_xyz","format":"anthropic-claude-v1","index":0},{"type":"reasoning.encrypted","data":"enc_blob","id":"rs_1","format":"openai-responses-v1","index":1}]},"finish_reason":null}]}

    data: {"id":"or-1","model":"anthropic/claude-sonnet-4.6","choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_or1","type":"function","function":{"name":"lookup","arguments":"{\\"q\\":\\"test\\"}"}}]},"finish_reason":"tool_calls"}]}

    data: [DONE]

    """
  let streamTransport = MockTransport(streamChunks: [Data(stream.utf8)])
  let streamAdapter = OpenAICompatibleAdapter(
    definition: BuiltInProviders.openRouter, transport: streamTransport)
  var reasoningDeltas: [String] = []
  var finalResponse: ProviderResponse?
  for try await event in streamAdapter.stream(
    request: ProviderRequest(
      model: "anthropic/claude-sonnet-4.6",
      messages: [.init(role: .user, content: "Check")]
    ),
    account: account(providerID: "openrouter")
  ) {
    switch event {
    case .reasoningDelta(let delta): reasoningDeltas.append(delta)
    case .completed(let response): finalResponse = response
    default: break
    }
  }

  // Reasoning must NOT be duplicated when both `reasoning` and `reasoning_details` appear.
  #expect(reasoningDeltas == ["Step 1. ", "Step 2."])
  let completed = try #require(finalResponse)
  #expect(completed.reasoning == "Step 1. Step 2.")
  let continuation = try #require(completed.toolContinuation)
  #expect(continuation.apiFamily == .openAIChatCompletions)
  guard case .array(let blocks) = continuation.payload else {
    Issue.record("Expected array payload for OpenRouter reasoning_details")
    return
  }
  #expect(blocks.count == 2)
  if case .object(let textBlock) = blocks[0], case .object(let encryptedBlock) = blocks[1] {
    #expect(textBlock["type"] == .string("reasoning.text"))
    #expect(textBlock["text"] == .string("Step 1. Step 2."))
    #expect(textBlock["signature"] == .string("sig_xyz"))
    #expect(encryptedBlock["type"] == .string("reasoning.encrypted"))
    #expect(encryptedBlock["data"] == .string("enc_blob"))
  } else {
    Issue.record("Unexpected reasoning_details block structure")
  }

  // Replay the continuation on the next tool turn and verify reasoning_details is sent verbatim.
  let followUpTransport = MockTransport(
    data: Data(
      #"{"id":"or-2","model":"anthropic/claude-sonnet-4.6","choices":[{"message":{"content":"All set","reasoning":"Done","reasoning_details":[{"type":"reasoning.text","text":"Done","signature":"sig_2"}]},"finish_reason":"stop"}]}"#
        .utf8
    )
  )
  let followUpAdapter = OpenAICompatibleAdapter(
    definition: BuiltInProviders.openRouter, transport: followUpTransport)
  let call = try #require(completed.toolCalls.first)
  let followUp = try await followUpAdapter.generate(
    request: ProviderRequest(
      model: "anthropic/claude-sonnet-4.6",
      messages: [
        .init(role: .user, content: "Check"),
        .init(
          role: .assistant, content: "", reasoning: completed.reasoning,
          toolCalls: [call], toolContinuation: continuation),
        .init(
          role: .tool, content: "",
          toolResults: [.init(callID: call.id, name: call.name, content: .string("ok"))]),
      ]
    ),
    account: account(providerID: "openrouter")
  )
  #expect(followUp.reasoning == "Done")
  #expect(followUp.toolContinuation?.apiFamily == .openAIChatCompletions)

  let sentBody = try #require(await followUpTransport.lastRequest()?.httpBody)
  guard case .object(let sentRoot) = try JSONDecoder.provider.decode(JSONValue.self, from: sentBody),
    case .array(let sentMessages)? = sentRoot["messages"],
    case .object(let assistantMsg) = sentMessages[1]
  else {
    Issue.record("Missing assistant message in follow-up request")
    return
  }
  #expect(assistantMsg["reasoning_details"] == .array(blocks))
}

@Test func openRouterDiscoveryDecodesReasoningMetadataAndSerializesValidWireOptions() async throws {
  let modelsJSON = Data(
    #"""
    {
      "data": [
        {
          "id": "anthropic/claude-opus-5.5",
          "name": "Claude Opus 5.5",
          "context_length": 1000000,
          "supported_parameters": ["max_tokens", "reasoning", "tools"],
          "architecture": {"input_modalities": ["text", "image", "file"], "output_modalities": ["text"]},
          "top_provider": {"max_completion_tokens": 128000},
          "reasoning": {
            "mandatory": true,
            "default_enabled": true,
            "default_effort": "medium",
            "supported_efforts": ["low", "medium", "high", "xhigh", "max"],
            "supports_max_tokens": false
          }
        },
        {
          "id": "anthropic/claude-sonnet-4.6",
          "name": "Claude Sonnet 4.6",
          "context_length": 1000000,
          "supported_parameters": ["max_tokens", "reasoning", "tools"],
          "architecture": {"input_modalities": ["text", "image"], "output_modalities": ["text"]},
          "top_provider": {"max_completion_tokens": 64000},
          "reasoning": {
            "mandatory": false,
            "default_enabled": false,
            "supported_efforts": ["low", "medium", "high"],
            "supports_max_tokens": true
          }
        },
        {
          "id": "vendor/legacy-reasoner",
          "name": "Legacy Reasoner",
          "context_length": 128000,
          "supported_parameters": ["max_tokens", "reasoning"],
          "architecture": {"input_modalities": ["text"], "output_modalities": ["text"]}
        }
      ]
    }
    """#.utf8
  )
  let discoveryAdapter = OpenAICompatibleAdapter(
    definition: BuiltInProviders.openRouter,
    transport: MockTransport(data: modelsJSON)
  )
  let discovered = try await discoveryAdapter.listModels(account: account(providerID: "openrouter"))

  let opus = try #require(discovered.first { $0.id == "anthropic/claude-opus-5.5" })
  let opusCaps = ModelCapabilityResolver.resolve(kind: .openRouter, modelID: opus.id, model: opus)
  #expect(opusCaps.reasoning.efforts == [.low, .medium, .high, .xhigh, .max])
  #expect(opusCaps.reasoning.defaultEffort == .medium)
  #expect(!opusCaps.reasoning.allowsOff)
  #expect(opusCaps.reasoning.normalize(.init(enabled: false)) == nil)

  let sonnet = try #require(discovered.first { $0.id == "anthropic/claude-sonnet-4.6" })
  let sonnetCaps = ModelCapabilityResolver.resolve(
    kind: .openRouter, modelID: sonnet.id, model: sonnet)
  #expect(sonnetCaps.reasoning.allowsOff)
  #expect(sonnetCaps.reasoning.efforts == [.low, .medium, .high])
  #expect(sonnetCaps.reasoning.budget?.minimum == 1_024)
  #expect(sonnetCaps.reasoning.combinesEffortAndBudget == false)

  let legacy = try #require(discovered.first { $0.id == "vendor/legacy-reasoner" })
  let legacyCaps = ModelCapabilityResolver.resolve(
    kind: .openRouter, modelID: legacy.id, model: legacy)
  #expect(legacyCaps.reasoning.efforts == [.low, .medium, .high])
  #expect(!legacyCaps.reasoning.allowsOff)

  // Verify wire serialization: off sends {"enabled": false} only; budget never combines with effort.
  let okTransport = MockTransport(
    data: Data(
      #"{"id":"r","model":"anthropic/claude-sonnet-4.6","choices":[{"message":{"content":"OK"},"finish_reason":"stop"}]}"#
        .utf8
    )
  )
  let requestAdapter = OpenAICompatibleAdapter(
    definition: BuiltInProviders.openRouter, transport: okTransport)

  _ = try await requestAdapter.generate(
    request: ProviderRequest(
      model: sonnet.id,
      messages: [.init(role: .user, content: "Hi")],
      options: .init(reasoning: .init(enabled: false)),
      capabilities: sonnetCaps
    ),
    account: account(providerID: "openrouter")
  )
  let offBody = try #require(await okTransport.lastRequest()?.httpBody)
  if case .object(let offRoot) = try JSONDecoder.provider.decode(JSONValue.self, from: offBody) {
    #expect(offRoot["reasoning"] == .object(["enabled": .bool(false)]))
  } else {
    Issue.record("Expected JSON object for off request")
  }

  _ = try await requestAdapter.generate(
    request: ProviderRequest(
      model: sonnet.id,
      messages: [.init(role: .user, content: "Hi")],
      options: .init(reasoning: .init(enabled: true, effort: .high, maxTokens: 4_096)),
      capabilities: sonnetCaps
    ),
    account: account(providerID: "openrouter")
  )
  let budgetBody = try #require(await okTransport.lastRequest()?.httpBody)
  if case .object(let budgetRoot) = try JSONDecoder.provider.decode(JSONValue.self, from: budgetBody)
  {
    #expect(budgetRoot["reasoning"] == .object(["max_tokens": .number(4096)]))
  } else {
    Issue.record("Expected JSON object for budget request")
  }

  // testConnection on an arbitrary routed OpenRouter model uses 1024 tokens and never sends enabled: false.
  try await requestAdapter.testConnection(
    account: account(providerID: "openrouter"),
    model: "anthropic/claude-opus-5.5"
  )
  let probeBody = try #require(await okTransport.lastRequest()?.httpBody)
  if case .object(let probeRoot) = try JSONDecoder.provider.decode(JSONValue.self, from: probeBody)
  {
    #expect(probeRoot["max_tokens"] == .number(1024))
    #expect(probeRoot["reasoning"] == nil)
  } else {
    Issue.record("Expected JSON object for probe request")
  }
}
