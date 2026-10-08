import Foundation
import Testing

@testable import BYOKchatProviderCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

private actor NativeMockTransport: ProviderHTTPTransport {
  var dataResponse: ProviderHTTPResponse
  var streamResponse: ProviderHTTPByteStream
  var requests: [URLRequest] = []

  init(
    data: Data = Data(),
    streamChunks: [Data] = [],
    statusCode: Int = 200,
    headers: [String: String] = [:]
  ) {
    dataResponse = ProviderHTTPResponse(statusCode: statusCode, headers: headers, data: data)
    streamResponse = ProviderHTTPByteStream(
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

@Test func anthropicDiscoveryKeepsMissingAndNegativeCapabilitiesDistinct() async throws {
  let data = Data("""
    {"data":[{"id":"claude-sonnet-5","display_name":"Sonnet","capabilities":{"image_input":{"supported":false},"thinking":{"supported":false}}},{"id":"claude-unknown","display_name":"Unknown"}]}
    """.utf8)
  let adapter = AnthropicMessagesAdapter(definition: BuiltInProviders.anthropic,
    transport: NativeMockTransport(data: data))
  let models = try await adapter.listModels(account: nativeAccount("anthropic"))
  let sonnet = try #require(models.first { $0.id == "claude-sonnet-5" })
  let unknown = try #require(models.first { $0.id == "claude-unknown" })
  let resolved = ModelCapabilityResolver.resolve(kind: .anthropic, modelID: sonnet.id, model: sonnet)
  #expect(resolved[.imageInput] == .unsupported)
  #expect(resolved.reasoning.kind == .unsupported)
  #expect(resolved[.fileInput] == .supported)
  #expect(unknown.capabilityEvidence?.facts[.imageInput] == nil)
  #expect(unknown.capabilityEvidence?.facts[.reasoning] == nil)
}

@Test func anthropicLegacyThinkingBudgetUsesEnabledWireContract() async throws {
  let data = Data("""
    {"id":"msg","model":"claude-3-7-sonnet","content":[{"type":"text","text":"OK"}],"stop_reason":"end_turn"}
    """.utf8)
  let transport = NativeMockTransport(data: data)
  let adapter = AnthropicMessagesAdapter(definition: BuiltInProviders.anthropic, transport: transport)
  _ = try await adapter.generate(request: .init(model: "claude-3-7-sonnet",
    messages: [.init(role: .user, content: "Hello")],
    options: .init(maxOutputTokens: 4_096, reasoning: .init(enabled: true, maxTokens: 1_024))),
    account: nativeAccount("anthropic"))
  let request = try #require(await transport.lastRequest())
  let bytes = try #require(request.httpBody)
  let body = try #require(JSONDecoder.provider.decode(JSONValue.self, from: bytes).objectValue)
  #expect(body["thinking"] == .object(["type": .string("enabled"), "budget_tokens": .number(1_024)]))
  #expect(body["output_config"] == nil)
}

@Test func geminiAutomaticBudgetAndOffSerializeAsDifferentValues() async throws {
  for tokens in [-1, 0] {
    let data = Data("""
      {"candidates":[{"content":{"role":"model","parts":[{"text":"OK"}]},"finishReason":"STOP"}]}
      """.utf8)
    let transport = NativeMockTransport(data: data)
    let adapter = GeminiGenerateContentAdapter(definition: BuiltInProviders.gemini, transport: transport)
    let reasoning = tokens == 0 ? ReasoningOptions(enabled: false) : ReasoningOptions(enabled: true, maxTokens: tokens)
    _ = try await adapter.generate(request: .init(model: "gemini-2.5-flash",
      messages: [.init(role: .user, content: "Hello")], options: .init(reasoning: reasoning)),
      account: nativeAccount("gemini"))
    let request = try #require(await transport.lastRequest())
    let bytes = try #require(request.httpBody)
    let root = try #require(JSONDecoder.provider.decode(JSONValue.self, from: bytes).objectValue)
    let generation = try #require(root["generationConfig"]?.objectValue)
    let thinking = try #require(generation["thinkingConfig"]?.objectValue)
    #expect(thinking["thinkingBudget"] == .number(Double(tokens)))
    #expect(thinking["thinkingLevel"] == nil)
  }
}

private func nativeAccount(_ providerID: ProviderID) -> ResolvedProviderAccount {
  ResolvedProviderAccount(
    kind: ProviderKind(providerID: providerID),
    id: ProviderAccountID(rawValue: "native-account"),
    providerID: providerID,
    label: "Native",
    apiKey: "secret"
  )
}

@Test func anthropicUsesMessagesAPIHeadersAndSeparatesThinking() async throws {
  let response = Data(
    """
    {"id":"msg_1","model":"claude-sonnet-5","content":[{"type":"thinking","thinking":"Plan briefly."},{"type":"text","text":"OK"}],"stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":4,"cache_read_input_tokens":2,"output_tokens_details":{"thinking_tokens":2}}}
    """.utf8
  )
  let transport = NativeMockTransport(data: response)
  let adapter = AnthropicMessagesAdapter(definition: BuiltInProviders.anthropic, transport: transport)
  let image = ChatAttachment(
    kind: .image,
    filename: "photo.jpg",
    mimeType: "image/jpeg",
    data: Data([0x01, 0x02])
  )

  let result = try await adapter.generate(
    request: ProviderRequest(
      model: "claude-sonnet-5",
      messages: [
        .init(role: .system, content: "Be concise."),
        .init(role: .user, content: "Describe this.", attachments: [image]),
      ],
      options: .init(
        temperature: 0.7,
        maxOutputTokens: 512,
        reasoning: .init(enabled: true, effort: .medium)
      )
    ),
    account: nativeAccount("anthropic")
  )

  #expect(result.text == "OK")
  #expect(result.reasoning == "Plan briefly.")
  #expect(result.usage?.inputTokens == 12)
  #expect(result.usage?.reasoningTokens == 2)

  let recordedRequest = await transport.lastRequest()
  let request = try #require(recordedRequest)
  #expect(request.url?.path == "/v1/messages")
  #expect(request.value(forHTTPHeaderField: "x-api-key") == "secret")
  #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")

  let body = try #require(request.httpBody)
  let object = try JSONDecoder.provider.decode(JSONValue.self, from: body)
  guard case .object(let root) = object else {
    Issue.record("Expected Anthropic object body")
    return
  }
  #expect(root["system"] == .string("Be concise."))
  #expect(root["temperature"] == nil)
  guard case .object(let thinking)? = root["thinking"] else {
    Issue.record("Missing Anthropic thinking config")
    return
  }
  #expect(thinking["type"] == .string("adaptive"))
  guard case .object(let outputConfig)? = root["output_config"] else {
    Issue.record("Missing Anthropic effort config")
    return
  }
  #expect(outputConfig["effort"] == .string("medium"))
}

@Test func anthropicStreamHandlesThinkingTextUsageAndStop() async throws {
  let stream = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_2","model":"claude-opus-5","usage":{"input_tokens":7,"output_tokens":0}}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Think "}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Answer"}}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5,"output_tokens_details":{"thinking_tokens":2}}}

    event: message_stop
    data: {"type":"message_stop"}

    """
  let transport = NativeMockTransport(streamChunks: [Data(stream.utf8)])
  let adapter = AnthropicMessagesAdapter(definition: BuiltInProviders.anthropic, transport: transport)

  var events: [ProviderStreamEvent] = []
  for try await event in adapter.stream(
    request: ProviderRequest(
      model: "claude-opus-5",
      messages: [.init(role: .user, content: "Hello")]
    ),
    account: nativeAccount("anthropic")
  ) {
    events.append(event)
  }

  #expect(events.contains(.reasoningDelta("Think ")))
  #expect(events.contains(.textDelta("Answer")))
  guard case .completed(let final) = events.last else {
    Issue.record("Missing Anthropic completion")
    return
  }
  #expect(final.text == "Answer")
  #expect(final.reasoning == "Think ")
  #expect(final.finishReason == "end_turn")
  #expect(final.usage?.inputTokens == 7)
  #expect(final.usage?.outputTokens == 5)
}

@Test func anthropicModelDiscoveryUsesCapabilities() async throws {
  let response = Data(
    """
    {"data":[{"id":"claude-test","display_name":"Claude Test","max_input_tokens":200000,"max_tokens":32000,"capabilities":{"image_input":{"supported":true},"pdf_input":{"supported":true},"thinking":{"supported":true}}}]}
    """.utf8
  )
  let transport = NativeMockTransport(data: response)
  let adapter = AnthropicMessagesAdapter(definition: BuiltInProviders.anthropic, transport: transport)
  let models = try await adapter.listModels(account: nativeAccount("anthropic"))
  let model = try #require(models.first { $0.id == "claude-test" })
  #expect(model.contextWindow == 200_000)
  #expect(model.maxOutputTokens == 32_000)
  #expect(model.inputModalities.contains("image"))
  #expect(model.inputModalities.contains("file"))
  #expect(model.supportedParameters.contains("thinking"))
}

@Test func geminiUsesGenerateContentWithInlineDataAndThoughtSummary() async throws {
  let response = Data(
    """
    {"responseId":"resp_1","modelVersion":"gemini-3.6-flash","candidates":[{"content":{"role":"model","parts":[{"text":"Reasoning summary","thought":true},{"text":"Done"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":8,"candidatesTokenCount":5,"cachedContentTokenCount":1,"thoughtsTokenCount":2}}
    """.utf8
  )
  let transport = NativeMockTransport(data: response)
  let adapter = GeminiGenerateContentAdapter(definition: BuiltInProviders.gemini, transport: transport)
  let image = ChatAttachment(
    kind: .image,
    filename: "photo.jpg",
    mimeType: "image/jpeg",
    data: Data([0x01, 0x02])
  )

  let result = try await adapter.generate(
    request: ProviderRequest(
      model: "gemini-3.6-flash",
      messages: [
        .init(role: .system, content: "Be concise."),
        .init(role: .user, content: "Describe this.", attachments: [image]),
      ],
      options: .init(
        temperature: 0.7,
        topP: 0.9,
        maxOutputTokens: 512,
        reasoning: .init(enabled: true, effort: .low)
      )
    ),
    account: nativeAccount("gemini")
  )

  #expect(result.text == "Done")
  #expect(result.reasoning == "Reasoning summary")
  #expect(result.usage?.reasoningTokens == 2)

  let recordedRequest = await transport.lastRequest()
  let request = try #require(recordedRequest)
  #expect(request.url?.path.contains("/models/gemini-3.6-flash:generateContent") == true)
  #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "secret")
  let body = try #require(request.httpBody)
  let object = try JSONDecoder.provider.decode(JSONValue.self, from: body)
  guard case .object(let root) = object,
    case .object(let generation)? = root["generationConfig"],
    case .object(let thinking)? = generation["thinkingConfig"]
  else {
    Issue.record("Missing Gemini generation config")
    return
  }
  #expect(generation["temperature"] == nil)
  #expect(generation["topP"] == nil)
  #expect(thinking["includeThoughts"] == .bool(true))
  #expect(thinking["thinkingLevel"] == .string("low"))
  guard case .array(let contents)? = root["contents"],
    case .object(let user) = contents[0],
    case .array(let parts)? = user["parts"]
  else {
    Issue.record("Missing Gemini content parts")
    return
  }
  #expect(parts.count == 2)
}

@Test func geminiStreamUsesSSEAndEmitsThoughtsSeparately() async throws {
  let stream = """
    data: {"responseId":"resp_2","modelVersion":"gemini-3.6-flash","candidates":[{"content":{"parts":[{"text":"Think ","thought":true}]}}]}

    data: {"responseId":"resp_2","candidates":[{"content":{"parts":[{"text":"Answer"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":6,"candidatesTokenCount":4,"thoughtsTokenCount":2}}

    """
  let transport = NativeMockTransport(streamChunks: [Data(stream.utf8)])
  let adapter = GeminiGenerateContentAdapter(definition: BuiltInProviders.gemini, transport: transport)

  var events: [ProviderStreamEvent] = []
  for try await event in adapter.stream(
    request: ProviderRequest(
      model: "gemini-3.6-flash",
      messages: [.init(role: .user, content: "Hello")],
      options: .init(reasoning: .init(enabled: true))
    ),
    account: nativeAccount("gemini")
  ) {
    events.append(event)
  }

  #expect(events.contains(.reasoningDelta("Think ")))
  #expect(events.contains(.textDelta("Answer")))
  guard case .completed(let final) = events.last else {
    Issue.record("Missing Gemini completion")
    return
  }
  #expect(final.finishReason == "STOP")
  #expect(final.usage?.inputTokens == 6)
  let recordedRequest = await transport.lastRequest()
  let request = try #require(recordedRequest)
  let components = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
  #expect(components.queryItems?.contains { $0.name == "alt" && $0.value == "sse" } == true)
}

@Test func geminiModelDiscoveryFiltersToGenerateContentModels() async throws {
  let response = Data(
    """
    {"models":[{"name":"models/gemini-3.6-flash","baseModelId":"gemini-3.6-flash","displayName":"Gemini 3.6 Flash","inputTokenLimit":1048576,"outputTokenLimit":65536,"supportedGenerationMethods":["generateContent"],"thinking":true},{"name":"models/embed-test","baseModelId":"embed-test","displayName":"Embed","supportedGenerationMethods":["embedContent"]}]}
    """.utf8
  )
  let transport = NativeMockTransport(data: response)
  let adapter = GeminiGenerateContentAdapter(definition: BuiltInProviders.gemini, transport: transport)
  let models = try await adapter.listModels(account: nativeAccount("gemini"))
  let model = try #require(models.first { $0.id == "gemini-3.6-flash" })
  #expect(model.contextWindow == 1_048_576)
  #expect(model.maxOutputTokens == 65_536)
  #expect(model.supportedParameters.contains("thinkingConfig"))
  #expect(model.supportedParameters.contains("temperature") == false)
  #expect(model.supportedParameters.contains("topP") == false)
  #expect(models.contains { $0.id == "embed-test" } == false)
}


@Test func anthropicCacheWriteDimensionsAndMissingInputSurviveNormalization() async throws {
  let data = Data(#"{"model":"claude-sonnet-5","content":[{"type":"text","text":"OK"}],"usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":20,"cache_creation_input_tokens":30,"cache_creation":{"ephemeral_1h_input_tokens":10}}}"#.utf8)
  let adapter = AnthropicMessagesAdapter(definition: BuiltInProviders.anthropic, transport: NativeMockTransport(data: data))
  let response = try await adapter.generate(request: .init(model: "claude-sonnet-5", messages: [.init(role: .user, content: "Hi")]), account: nativeAccount("anthropic"))
  #expect(response.usage?.inputTokens == 150)
  #expect(response.usage?.cachedInputTokens == 20)
  #expect(response.usage?.cacheWriteTokens == 30)
  #expect(response.usage?.longCacheWriteTokens == 10)
  let missing = Data(#"{"model":"claude-sonnet-5","content":[{"type":"text","text":"OK"}],"usage":{"output_tokens":10}}"#.utf8)
  let missingAdapter = AnthropicMessagesAdapter(definition: BuiltInProviders.anthropic, transport: NativeMockTransport(data: missing))
  let partial = try await missingAdapter.generate(request: .init(model: "claude-sonnet-5", messages: [.init(role: .user, content: "Hi")]), account: nativeAccount("anthropic"))
  #expect(partial.usage?.inputTokens == nil)
}

@Test func geminiBillsThinkingAsOutputAndMarksCacheStorageUnpriced() async throws {
  let data = Data(#"{"modelVersion":"gemini-3.6-flash","candidates":[{"content":{"parts":[{"text":"OK"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":100,"candidatesTokenCount":10,"thoughtsTokenCount":20,"cachedContentTokenCount":5}}"#.utf8)
  let adapter = GeminiGenerateContentAdapter(definition: BuiltInProviders.gemini, transport: NativeMockTransport(data: data))
  let response = try await adapter.generate(request: .init(model: "gemini-3.6-flash", messages: [.init(role: .user, content: "Hi")]), account: nativeAccount("gemini"))
  #expect(response.usage?.outputTokens == 30)
  #expect(response.usage?.reasoningTokens == 20)
  #expect(response.usage?.hasUnpricedCharges == true)
}
