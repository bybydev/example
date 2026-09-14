import Foundation
import Testing

@testable import BYOKchatProviderCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

private actor XAIResponsesMockTransport: ProviderHTTPTransport {
  private var dataResponses: [ProviderHTTPResponse]
  private var streamResponses: [ProviderHTTPByteStream]
  private var requests: [URLRequest] = []

  init(
    dataResponses: [Data] = [],
    streamChunks: [[Data]] = [],
    statusCode: Int = 200,
    headers: [String: String] = [:]
  ) {
    self.dataResponses = dataResponses.map {
      ProviderHTTPResponse(statusCode: statusCode, headers: headers, data: $0)
    }
    self.streamResponses = streamChunks.map { chunks in
      ProviderHTTPByteStream(
        statusCode: statusCode,
        headers: headers,
        chunks: AsyncThrowingStream { continuation in
          for chunk in chunks { continuation.yield(chunk) }
          continuation.finish()
        }
      )
    }
  }

  func data(for request: URLRequest) async throws -> ProviderHTTPResponse {
    requests.append(request)
    guard !dataResponses.isEmpty else { throw ProviderError.invalidResponse }
    return dataResponses.removeFirst()
  }

  func stream(for request: URLRequest) async throws -> ProviderHTTPByteStream {
    requests.append(request)
    guard !streamResponses.isEmpty else { throw ProviderError.invalidResponse }
    return streamResponses.removeFirst()
  }

  func request(at index: Int) -> URLRequest? {
    guard requests.indices.contains(index) else { return nil }
    return requests[index]
  }

  func lastRequest() -> URLRequest? { requests.last }
}

private func xAIAccount() -> ResolvedProviderAccount {
  ResolvedProviderAccount(
    kind: .xAI,
    id: "xai-account",
    providerID: "xai",
    label: "xAI",
    apiKey: "xai-secret"
  )
}

private func xAIRoot(from request: URLRequest) throws -> [String: JSONValue] {
  let body = try #require(request.httpBody)
  let decoded = try JSONDecoder.provider.decode(JSONValue.self, from: body)
  guard case .object(let root) = decoded else {
    Issue.record("Expected xAI Responses object body")
    return [:]
  }
  return root
}

@Test func xAIResponsesMapsReasoningToolsVisionUsageAndExactCost() async throws {
  let response = Data(
    """
    {"id":"resp_xai","model":"grok-4.6","status":"completed","output":[{"id":"rs_xai","type":"reasoning","encrypted_content":"opaque-xai","summary":[{"type":"summary_text","text":"Checked."}]},{"id":"msg_xai","type":"message","role":"assistant","content":[{"type":"output_text","text":"Done"}]}],"usage":{"input_tokens":100,"output_tokens":20,"input_tokens_details":{"cached_tokens":50},"output_tokens_details":{"reasoning_tokens":7},"cost_in_usd_ticks":37756000}}
    """.utf8
  )
  let transport = XAIResponsesMockTransport(
    dataResponses: [response], headers: ["x-request-id": "xai_req_1"])
  let adapter = XAIResponsesAdapter(definition: BuiltInProviders.xAI, transport: transport)
  let image = ChatAttachment(
    kind: .image,
    filename: "photo.png",
    mimeType: "image/png",
    data: Data([0x01, 0x02])
  )
  let tool = ChatToolDefinition(
    name: "lookup_weather",
    description: "Look up weather",
    inputSchema: .object([
      "type": .string("object"),
      "properties": .object(["city": .object(["type": .string("string")])]),
    ])
  )

  let result = try await adapter.generate(
    request: ProviderRequest(
      model: "grok-4.6",
      messages: [.init(role: .user, content: "Check this.", attachments: [image])],
      options: .init(
        temperature: 0.7,
        topP: 0.95,
        maxOutputTokens: 512,
        reasoning: .init(enabled: true, effort: .max)
      ),
      tools: [tool]
    ),
    account: xAIAccount()
  )

  #expect(result.text == "Done")
  #expect(result.reasoning == "Checked.")
  #expect(result.usage?.inputTokens == 100)
  #expect(result.usage?.outputTokens == 20)
  #expect(result.usage?.cachedInputTokens == 50)
  #expect(result.usage?.reasoningTokens == 7)
  #expect(result.metadata["requestID"] == "xai_req_1")
  #expect(result.metadata["xai.costInUSDTicks"] == "37756000")
  #expect(ChatBilling.decimal(result.metadata["costUSD"]) == Decimal(string: "0.0037756"))
  #expect(result.toolContinuation?.apiFamily == .openAIResponses)

  let request = try #require(await transport.lastRequest())
  #expect(request.url?.path == "/v1/responses")
  #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer xai-secret")
  let root = try xAIRoot(from: request)
  #expect(root["model"] == .string("grok-4.6"))
  #expect(root["store"] == .bool(false))
  #expect(root["stream"] == .bool(false))
  #expect(root["include"] == .array([.string("reasoning.encrypted_content")]))
  #expect(root["temperature"] == .number(0.7))
  #expect(root["top_p"] == .number(0.95))

  guard case .object(let reasoning)? = root["reasoning"] else {
    Issue.record("Missing xAI reasoning config")
    return
  }
  #expect(reasoning["effort"] == .string("xhigh"))

  guard case .array(let tools)? = root["tools"], case .object(let encodedTool) = tools.first else {
    Issue.record("Missing xAI function tool")
    return
  }
  #expect(encodedTool["type"] == .string("function"))
  #expect(encodedTool["name"] == .string("lookup_weather"))

  guard case .array(let input)? = root["input"], case .object(let message) = input.first,
    case .array(let parts)? = message["content"]
  else {
    Issue.record("Missing xAI input")
    return
  }
  #expect(parts.contains { part in
    guard case .object(let object) = part else { return false }
    return object["type"] == .string("input_image")
      && object["image_url"] == .string(image.dataURL)
  })
}

@Test func xAIReasoningOffRespectsMandatoryAndOptionalReasoningFamilies() async throws {
  let responses = [
    Data("{\"id\":\"r1\",\"model\":\"grok-4.6\",\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"OK\"}]}]}".utf8),
    Data("{\"id\":\"r2\",\"model\":\"grok-4.3\",\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"OK\"}]}]}".utf8),
  ]
  let transport = XAIResponsesMockTransport(dataResponses: responses)
  let adapter = XAIResponsesAdapter(definition: BuiltInProviders.xAI, transport: transport)

  _ = try await adapter.generate(
    request: ProviderRequest(
      model: "grok-4.6",
      messages: [.init(role: .user, content: "Hi")],
      options: .init(reasoning: .init(enabled: false))
    ), account: xAIAccount())
  _ = try await adapter.generate(
    request: ProviderRequest(
      model: "grok-4.3",
      messages: [.init(role: .user, content: "Hi")],
      options: .init(reasoning: .init(enabled: false))
    ), account: xAIAccount())

  let mandatory = try xAIRoot(from: #require(await transport.request(at: 0)))
  let optional = try xAIRoot(from: #require(await transport.request(at: 1)))
  guard case .object(let mandatoryReasoning)? = mandatory["reasoning"],
    case .object(let optionalReasoning)? = optional["reasoning"]
  else {
    Issue.record("Expected xAI reasoning objects")
    return
  }
  #expect(mandatoryReasoning["effort"] == .string("low"))
  #expect(optionalReasoning["effort"] == .string("none"))
}

@Test func xAIPrivateFilesUploadBeforeResponsesAndUseFileID() async throws {
  let upload = Data(
    """
    {"id":"file_xai_123","object":"file","bytes":4,"filename":"notes.pdf","purpose":"assistants"}
    """.utf8
  )
  let response = Data(
    """
    {"id":"resp_file","model":"grok-4.6","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Read"}]}]}
    """.utf8
  )
  let transport = XAIResponsesMockTransport(dataResponses: [upload, response])
  let adapter = XAIResponsesAdapter(definition: BuiltInProviders.xAI, transport: transport)
  let file = ChatAttachment(
    kind: .file,
    filename: "notes.pdf",
    mimeType: "application/pdf",
    data: Data([0x01, 0x02, 0x03, 0x04])
  )

  let result = try await adapter.generate(
    request: ProviderRequest(
      model: "grok-4.6",
      messages: [.init(role: .user, content: "Read it", attachments: [file])]
    ),
    account: xAIAccount()
  )
  #expect(result.text == "Read")

  let uploadRequest = try #require(await transport.request(at: 0))
  #expect(uploadRequest.url?.path == "/v1/files")
  #expect(uploadRequest.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
  let multipart = String(decoding: try #require(uploadRequest.httpBody), as: UTF8.self)
  let expiresRange = try #require(multipart.range(of: "name=\"expires_after\""))
  let fileRange = try #require(multipart.range(of: "name=\"file\""))
  #expect(expiresRange.lowerBound < fileRange.lowerBound)
  #expect(multipart.contains("86400"))
  #expect(multipart.contains("name=\"purpose\""))
  #expect(multipart.contains("assistants"))
  #expect(multipart.contains("filename=\"notes.pdf\""))

  let responseRequest = try #require(await transport.request(at: 1))
  #expect(responseRequest.url?.path == "/v1/responses")
  let root = try xAIRoot(from: responseRequest)
  guard case .array(let input)? = root["input"], case .object(let message) = input.first,
    case .array(let parts)? = message["content"]
  else {
    Issue.record("Missing xAI file input")
    return
  }
  #expect(parts.contains { part in
    guard case .object(let object) = part else { return false }
    return object["type"] == .string("input_file")
      && object["file_id"] == .string("file_xai_123")
      && object["file_data"] == nil
  })
}

@Test func xAIStreamingIncludesReasoningSummaryAndUsage() async throws {
  let stream = """
    event: response.reasoning_text.delta
    data: {"type":"response.reasoning_text.delta","delta":"Plan "}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","delta":"Done"}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp_stream","model":"grok-4.6","status":"completed","output":[{"id":"rs_stream","type":"reasoning","encrypted_content":"opaque","summary":[{"type":"summary_text","text":"Plan "}]},{"id":"msg_stream","type":"message","role":"assistant","content":[{"type":"output_text","text":"Done"}]}],"usage":{"input_tokens":7,"output_tokens":4,"output_tokens_details":{"reasoning_tokens":2},"cost_in_usd_ticks":20000000}}}

    """
  let transport = XAIResponsesMockTransport(streamChunks: [[Data(stream.utf8)]])
  let adapter = XAIResponsesAdapter(definition: BuiltInProviders.xAI, transport: transport)

  var events: [ProviderStreamEvent] = []
  for try await event in adapter.stream(
    request: ProviderRequest(
      model: "grok-4.6",
      messages: [.init(role: .user, content: "Hello")],
      options: .init(reasoning: .init(enabled: true, effort: .high))
    ),
    account: xAIAccount()
  ) {
    events.append(event)
  }

  #expect(events.contains(.reasoningDelta("Plan ")))
  #expect(events.contains(.textDelta("Done")))
  #expect(events.contains(.usage(.init(inputTokens: 7, outputTokens: 4, reasoningTokens: 2))))
  guard case .completed(let final) = events.last else {
    Issue.record("Missing xAI completion")
    return
  }
  #expect(final.text == "Done")
  #expect(final.reasoning == "Plan ")
  #expect(ChatBilling.decimal(final.metadata["costUSD"]) == Decimal(string: "0.002"))
  #expect(final.toolContinuation?.apiFamily == .openAIResponses)
}

@Test func xAILanguageModelDiscoveryUsesNativeEndpointAndPreservesCuratedMetadata() async throws {
  let payload = Data(
    """
    {"models":[
      {"id":"grok-4.6","context_length":500000,"input_modalities":["text","image"],"output_modalities":["text"]},
      {"id":"grok-4.5","context_length":500000,"input_modalities":["text","image"],"output_modalities":["text"]},
      {"id":"grok-4.20-non-reasoning","context_length":1000000,"input_modalities":["text","image"],"output_modalities":["text"]}
    ]}
    """.utf8
  )
  let transport = XAIResponsesMockTransport(dataResponses: [payload])
  let adapter = XAIResponsesAdapter(definition: BuiltInProviders.xAI, transport: transport)

  let models = try await adapter.listModels(account: xAIAccount())
  let request = try #require(await transport.request(at: 0))
  #expect(request.url?.path == "/v1/language-models")

  let ids = Set(models.map(\.id.rawValue))
  #expect(ids.contains("grok-4.6"))
  #expect(ids.contains("grok-4.5"))
  #expect(ids.contains("grok-4.20-non-reasoning"))

  let grok46 = try #require(models.first { $0.id == "grok-4.6" })
  #expect(grok46.displayName == "Grok 4.6")
  #expect(grok46.contextWindow == 500_000)
  #expect(grok46.supportedParameters.contains("reasoning"))
  #expect(grok46.supportedParameters.contains("tools"))
  #expect(grok46.supportedParameters.contains("temperature"))
  #expect(grok46.supportedParameters.contains("top_p"))
  #expect(grok46.inputModalities.contains("image"))
  #expect(grok46.inputModalities.contains("file"))

  let nonReasoning = try #require(models.first { $0.id == "grok-4.20-non-reasoning" })
  #expect(nonReasoning.supportedParameters.contains("reasoning") == false)
  #expect(nonReasoning.supportedParameters.contains("temperature"))
  #expect(nonReasoning.supportedParameters.contains("top_p"))
}
