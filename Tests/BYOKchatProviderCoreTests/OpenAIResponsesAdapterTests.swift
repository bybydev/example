import Foundation
import Testing

@testable import BYOKchatProviderCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

private actor OpenAIResponsesMockTransport: ProviderHTTPTransport {
  private var dataResponses: [ProviderHTTPResponse]
  private let streamResponse: ProviderHTTPByteStream
  private var requests: [URLRequest] = []

  init(
    dataResponses: [Data] = [],
    streamChunks: [Data] = [],
    statusCode: Int = 200,
    headers: [String: String] = [:]
  ) {
    self.dataResponses = dataResponses.map {
      ProviderHTTPResponse(statusCode: statusCode, headers: headers, data: $0)
    }
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
    guard !dataResponses.isEmpty else { throw ProviderError.invalidResponse }
    return dataResponses.removeFirst()
  }

  func stream(for request: URLRequest) async throws -> ProviderHTTPByteStream {
    requests.append(request)
    return streamResponse
  }

  func request(at index: Int) -> URLRequest? {
    guard requests.indices.contains(index) else { return nil }
    return requests[index]
  }

  func lastRequest() -> URLRequest? { requests.last }
}

private func openAIResponsesAccount() -> ResolvedProviderAccount {
  ResolvedProviderAccount(
    kind: .openai,
    id: "openai-account",
    providerID: "openai",
    label: "OpenAI",
    apiKey: "secret"
  )
}

@Test func openAIResponsesMapsReasoningAttachmentsToolsAndUsage() async throws {
  let response = Data(
    """
    {"id":"resp_1","model":"gpt-5.6-sol","status":"completed","output":[{"id":"rs_1","type":"reasoning","encrypted_content":"opaque-reasoning","summary":[{"type":"summary_text","text":"Checked carefully."}]},{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"output_text","text":"Done"}]}],"usage":{"input_tokens":10,"output_tokens":6,"input_tokens_details":{"cached_tokens":3},"output_tokens_details":{"reasoning_tokens":2}}}
    """.utf8
  )
  let transport = OpenAIResponsesMockTransport(
    dataResponses: [response], headers: ["x-request-id": "req_1"])
  let adapter = OpenAIResponsesAdapter(
    definition: BuiltInProviders.openAI,
    transport: transport
  )
  let image = ChatAttachment(
    kind: .image,
    filename: "photo.png",
    mimeType: "image/png",
    data: Data([0x01, 0x02])
  )
  let file = ChatAttachment(
    kind: .file,
    filename: "notes.pdf",
    mimeType: "application/pdf",
    data: Data([0x03, 0x04])
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
      model: "gpt-5.6-sol",
      messages: [
        .init(role: .system, content: "Be concise."),
        .init(role: .user, content: "Check this.", attachments: [image, file]),
      ],
      options: .init(
        temperature: 0.7,
        topP: 0.9,
        maxOutputTokens: 512,
        reasoning: .init(enabled: true, effort: .max)
      ),
      tools: [tool]
    ),
    account: openAIResponsesAccount()
  )

  #expect(result.text == "Done")
  #expect(result.reasoning == "Checked carefully.")
  #expect(result.usage?.inputTokens == 10)
  #expect(result.usage?.outputTokens == 6)
  #expect(result.usage?.cachedInputTokens == 3)
  #expect(result.usage?.reasoningTokens == 2)
  #expect(result.metadata["requestID"] == "req_1")
  #expect(result.toolContinuation?.apiFamily == .openAIResponses)

  let recorded = await transport.lastRequest()
  let request = try #require(recorded)
  #expect(request.url?.path == "/v1/responses")
  #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")

  let body = try #require(request.httpBody)
  let decoded = try JSONDecoder.provider.decode(JSONValue.self, from: body)
  guard case .object(let root) = decoded else {
    Issue.record("Expected Responses object body")
    return
  }
  #expect(root["model"] == .string("gpt-5.6-sol"))
  #expect(root["store"] == .bool(false))
  #expect(root["stream"] == .bool(false))
  #expect(root["max_output_tokens"] == .number(512))
  #expect(root["temperature"] == nil)
  #expect(root["top_p"] == nil)
  #expect(root["include"] == .array([.string("reasoning.encrypted_content")]))

  guard case .object(let reasoning)? = root["reasoning"] else {
    Issue.record("Missing OpenAI reasoning config")
    return
  }
  #expect(reasoning["effort"] == .string("max"))
  #expect(reasoning["summary"] == .string("auto"))

  guard case .array(let tools)? = root["tools"], case .object(let encodedTool) = tools.first else {
    Issue.record("Missing Responses tool")
    return
  }
  #expect(encodedTool["type"] == .string("function"))
  #expect(encodedTool["name"] == .string("lookup_weather"))
  #expect(encodedTool["strict"] == .bool(false))

  guard case .array(let input)? = root["input"], input.count == 2,
    case .object(let userMessage) = input[1],
    case .array(let parts)? = userMessage["content"]
  else {
    Issue.record("Missing Responses input")
    return
  }
  #expect(parts.contains { part in
    guard case .object(let value) = part else { return false }
    return value["type"] == .string("input_image")
  })
  #expect(parts.contains { part in
    guard case .object(let value) = part else { return false }
    return value["type"] == .string("input_file")
      && value["filename"] == .string("notes.pdf")
  })
}

@Test func openAIResponsesReplaysRawOutputForToolContinuation() async throws {
  let toolResponse = Data(
    """
    {"id":"resp_tool","model":"gpt-5.6-sol","status":"completed","output":[{"id":"rs_tool","type":"reasoning","encrypted_content":"encrypted-state","summary":[]},{"id":"fc_1","type":"function_call","call_id":"call_1","name":"lookup_weather","arguments":"{\\\"city\\\":\\\"Hanoi\\\"}"}],"usage":{"input_tokens":5,"output_tokens":3}}
    """.utf8
  )
  let finalResponse = Data(
    """
    {"id":"resp_final","model":"gpt-5.6-sol","status":"completed","output":[{"id":"msg_final","type":"message","role":"assistant","content":[{"type":"output_text","text":"Sunny"}]}],"usage":{"input_tokens":8,"output_tokens":2}}
    """.utf8
  )
  let transport = OpenAIResponsesMockTransport(dataResponses: [toolResponse, finalResponse])
  let adapter = OpenAIResponsesAdapter(
    definition: BuiltInProviders.openAI,
    transport: transport
  )
  let account = openAIResponsesAccount()
  let tool = ChatToolDefinition(name: "lookup_weather", description: "Look up weather")

  let first = try await adapter.generate(
    request: ProviderRequest(
      model: "gpt-5.6-sol",
      messages: [.init(role: .user, content: "Weather in Hanoi?")],
      tools: [tool]
    ),
    account: account
  )
  let call = try #require(first.toolCalls.first)
  let continuation = try #require(first.toolContinuation)
  #expect(call.id == "call_1")
  #expect(call.name == "lookup_weather")
  #expect(call.arguments == .object(["city": .string("Hanoi")]))

  let second = try await adapter.generate(
    request: ProviderRequest(
      model: "gpt-5.6-sol",
      messages: [
        .init(role: .user, content: "Weather in Hanoi?"),
        .init(
          role: .assistant,
          content: "",
          toolCalls: first.toolCalls,
          toolContinuation: continuation
        ),
        .init(
          role: .tool,
          content: "",
          toolResults: [
            .init(
              callID: "call_1",
              name: "lookup_weather",
              content: .object(["condition": .string("sunny")])
            )
          ]
        ),
      ],
      tools: [tool]
    ),
    account: account
  )
  #expect(second.text == "Sunny")

  let recorded = await transport.request(at: 1)
  let request = try #require(recorded)
  let body = try #require(request.httpBody)
  let decoded = try JSONDecoder.provider.decode(JSONValue.self, from: body)
  guard case .object(let root) = decoded, case .array(let input)? = root["input"] else {
    Issue.record("Missing continuation input")
    return
  }
  #expect(input.contains { item in
    guard case .object(let value) = item else { return false }
    return value["type"] == .string("reasoning")
      && value["encrypted_content"] == .string("encrypted-state")
  })
  #expect(input.contains { item in
    guard case .object(let value) = item else { return false }
    return value["type"] == .string("function_call")
      && value["call_id"] == .string("call_1")
  })
  #expect(input.contains { item in
    guard case .object(let value) = item else { return false }
    return value["type"] == .string("function_call_output")
      && value["call_id"] == .string("call_1")
  })
}

@Test func openAIResponsesContinuationSurvivesCompletedConversationHistory() throws {
  let rawOutput: JSONValue = .array([
    .object([
      "id": .string("rs_history"),
      "type": .string("reasoning"),
      "encrypted_content": .string("opaque-history"),
      "summary": .array([]),
    ]),
    .object([
      "id": .string("msg_history"),
      "type": .string("message"),
      "role": .string("assistant"),
      "content": .array([
        .object(["type": .string("output_text"), "text": .string("First answer")])
      ]),
    ]),
  ])
  let response = ProviderResponse(
    text: "First answer",
    providerID: "openai",
    accountID: "openai-account",
    modelID: "gpt-5.6-sol",
    toolContinuation: .init(apiFamily: .openAIResponses, payload: rawOutput)
  )
  let historicalAssistant = ChatMessage(
    role: .assistant,
    content: response.text,
    status: .complete,
    providerID: "openai",
    accountID: "openai-account",
    modelID: "gpt-5.6-sol",
    providerContinuation: response.toolContinuation,
    metadata: response.metadata
  )
  let conversation = ChatConversation(
    providerID: "openai",
    accountID: "openai-account",
    modelID: "gpt-5.6-sol",
    messages: [
      ChatMessage(role: .user, content: "First question", status: .complete),
      historicalAssistant,
      ChatMessage(role: .user, content: "Follow up", status: .complete),
    ]
  )

  let context = try ChatContextBuilder.build(conversation: conversation, contextWindow: nil)
  let replayed = try #require(context.messages.first { $0.role == .assistant })
  #expect(replayed.toolContinuation?.apiFamily == .openAIResponses)
  #expect(replayed.toolContinuation?.payload == rawOutput)

  let compact = ConversationIndexMessage(message: historicalAssistant)
  #expect(compact.summaryMessage.providerContinuation == nil)
}

@Test func openAIResponsesStreamingSeparatesReasoningTextUsageAndCompletion() async throws {
  let stream = """
    event: response.reasoning_summary_text.delta
    data: {"type":"response.reasoning_summary_text.delta","delta":"Plan "}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","delta":"Done"}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp_stream","model":"gpt-5.6-sol","status":"completed","output":[{"id":"rs_stream","type":"reasoning","encrypted_content":"opaque","summary":[{"type":"summary_text","text":"Plan "}]},{"id":"msg_stream","type":"message","role":"assistant","content":[{"type":"output_text","text":"Done"}]}],"usage":{"input_tokens":7,"output_tokens":4,"output_tokens_details":{"reasoning_tokens":2}}}}

    """
  let transport = OpenAIResponsesMockTransport(streamChunks: [Data(stream.utf8)])
  let adapter = OpenAIResponsesAdapter(
    definition: BuiltInProviders.openAI,
    transport: transport
  )

  var events: [ProviderStreamEvent] = []
  for try await event in adapter.stream(
    request: ProviderRequest(
      model: "gpt-5.6-sol",
      messages: [.init(role: .user, content: "Hello")],
      options: .init(reasoning: .init(enabled: true, effort: .high))
    ),
    account: openAIResponsesAccount()
  ) {
    events.append(event)
  }

  #expect(events.contains(.reasoningDelta("Plan ")))
  #expect(events.contains(.textDelta("Done")))
  #expect(events.contains(.usage(.init(inputTokens: 7, outputTokens: 4, reasoningTokens: 2))))
  guard case .completed(let final) = events.last else {
    Issue.record("Missing OpenAI completion")
    return
  }
  #expect(final.text == "Done")
  #expect(final.reasoning == "Plan ")
  #expect(final.toolContinuation?.apiFamily == .openAIResponses)
}
