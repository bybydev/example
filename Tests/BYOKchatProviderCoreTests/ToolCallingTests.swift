import Foundation
import Testing

@testable import BYOKchatProviderCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Test func toolRuntimeExecutesRegisteredHandlerAndReturnsErrorsAsResults() async throws {
  let runtime = ToolRuntime()
  try await runtime.register(
    ChatToolDefinition(
      name: "lookup",
      description: "Look up a value",
      inputSchema: .object([
        "type": .string("object"),
        "properties": .object(["key": .object(["type": .string("string")])]),
      ])
    )
  ) { arguments in
    guard case .object(let object) = arguments,
      case .string(let key)? = object["key"]
    else {
      throw ProviderError.invalidRequest("Missing key")
    }
    return .object(["value": .string("value-for-\(key)")])
  }

  let tools = await runtime.availableTools()
  #expect(tools.map(\.name) == ["lookup"])

  let success = await runtime.execute(
    ChatToolCall(
      id: "call-1",
      name: "lookup",
      arguments: .object(["key": .string("alpha")])
    )
  )
  #expect(success.isError == false)
  #expect(success.content == .object(["value": .string("value-for-alpha")]))

  let failure = await runtime.execute(
    ChatToolCall(id: "call-2", name: "lookup", arguments: .object([:]))
  )
  #expect(failure.isError)
  #expect(failure.callID == "call-2")
}

@Test func openAICompatibleEncodesToolSchemaCallAndResult() throws {
  let adapter = OpenAICompatibleAdapter(definition: BuiltInProviders.openRouter)
  let tool = weatherTool()
  let call = weatherCall()
  let result = ChatToolResult(
    callID: call.id,
    name: call.name,
    content: .object(["temperature": .number(21)])
  )
  let request = ProviderRequest(
    model: "openai/gpt-test",
    messages: [
      .init(role: .user, content: "Weather?"),
      .init(role: .assistant, content: "", toolCalls: [call]),
      .init(role: .tool, content: "", toolResults: [result]),
    ],
    tools: [tool]
  )

  let body = adapter.requestBody(request, streaming: false)
  guard case .array(let tools)? = body["tools"],
    case .object(let toolObject) = tools[0],
    case .object(let function)? = toolObject["function"]
  else {
    Issue.record("Missing OpenAI tool declaration")
    return
  }
  #expect(function["name"] == .string("get_weather"))
  #expect(function["parameters"] == tool.inputSchema)

  guard case .array(let messages)? = body["messages"], messages.count == 3,
    case .object(let assistant) = messages[1],
    case .array(let calls)? = assistant["tool_calls"],
    case .object(let encodedCall) = calls[0],
    case .object(let encodedFunction)? = encodedCall["function"],
    case .object(let toolResult) = messages[2]
  else {
    Issue.record("Missing OpenAI tool history")
    return
  }
  #expect(encodedCall["id"] == .string(call.id))
  #expect(encodedFunction["name"] == .string(call.name))
  #expect(encodedFunction["arguments"] == .string("{\"city\":\"Paris\"}"))
  #expect(toolResult["role"] == .string("tool"))
  #expect(toolResult["tool_call_id"] == .string(call.id))
}

@Test func openAICompatibleStreamReassemblesFragmentedToolArguments() async throws {
  let stream = """
    data: {"id":"chat_1","model":"model","choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"get_weather","arguments":"{\\\"city\\\":"}}]},"finish_reason":null}]}

    data: {"id":"chat_1","model":"model","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\\"Paris\\\"}"}}]},"finish_reason":"tool_calls"}]}

    data: [DONE]

    """
  let transport = ToolMockTransport(streamChunks: [Data(stream.utf8)])
  let adapter = OpenAICompatibleAdapter(definition: BuiltInProviders.openRouter, transport: transport)

  var final: ProviderResponse?
  for try await event in adapter.stream(
    request: ProviderRequest(
      model: "model",
      messages: [.init(role: .user, content: "Weather?")],
      tools: [weatherTool()]
    ),
    account: toolAccount("openrouter")
  ) {
    if case .completed(let response) = event { final = response }
  }

  let call = try #require(final?.toolCalls.first)
  #expect(call.id == "call_1")
  #expect(call.name == "get_weather")
  #expect(call.arguments == .object(["city": .string("Paris")]))
}

@Test func anthropicToolHistoryReplaysThinkingSignatureAndToolResult() throws {
  let adapter = AnthropicMessagesAdapter(definition: BuiltInProviders.anthropic)
  let call = weatherCall()
  let continuation = ProviderToolContinuation(
    apiFamily: .anthropicMessages,
    payload: .array([
      .object([
        "type": .string("thinking"),
        "thinking": .string("Need weather."),
        "signature": .string("opaque-anthropic-signature"),
      ])
    ])
  )
  let result = ChatToolResult(
    callID: call.id,
    name: call.name,
    content: .object(["temperature": .number(21)])
  )
  let request = ProviderRequest(
    model: "claude-sonnet-5",
    messages: [
      .init(role: .user, content: "Weather?"),
      .init(
        role: .assistant,
        content: "",
        reasoning: "Need weather.",
        toolCalls: [call],
        toolContinuation: continuation
      ),
      .init(role: .tool, content: "", toolResults: [result]),
    ],
    tools: [weatherTool()]
  )

  let body = try adapter.requestBody(request, streaming: false)
  guard case .array(let tools)? = body["tools"],
    case .object(let toolObject) = tools[0]
  else {
    Issue.record("Missing Anthropic tools")
    return
  }
  #expect(toolObject["input_schema"] == weatherTool().inputSchema)

  guard case .array(let messages)? = body["messages"], messages.count == 3,
    case .object(let assistant) = messages[1],
    case .array(let assistantBlocks)? = assistant["content"],
    case .object(let thinking) = assistantBlocks[0],
    case .object(let toolUse) = assistantBlocks[1],
    case .object(let resultMessage) = messages[2],
    case .array(let resultBlocks)? = resultMessage["content"],
    case .object(let toolResult) = resultBlocks[0]
  else {
    Issue.record("Missing Anthropic tool history")
    return
  }
  #expect(thinking["signature"] == .string("opaque-anthropic-signature"))
  #expect(toolUse["type"] == .string("tool_use"))
  #expect(toolUse["id"] == .string(call.id))
  #expect(toolResult["type"] == .string("tool_result"))
  #expect(toolResult["tool_use_id"] == .string(call.id))
}

@Test func anthropicStreamPreservesThinkingSignatureForToolContinuation() async throws {
  let stream = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_tool","model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":0}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Need weather."}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig-123"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: content_block_start
    data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"call_1","name":"get_weather","input":{}}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\\"city\\\":\\\"Paris\\\"}"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":1}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":7}}

    event: message_stop
    data: {"type":"message_stop"}

    """
  let transport = ToolMockTransport(streamChunks: [Data(stream.utf8)])
  let adapter = AnthropicMessagesAdapter(definition: BuiltInProviders.anthropic, transport: transport)

  var final: ProviderResponse?
  for try await event in adapter.stream(
    request: ProviderRequest(
      model: "claude-sonnet-5",
      messages: [.init(role: .user, content: "Weather?")],
      tools: [weatherTool()]
    ),
    account: toolAccount("anthropic")
  ) {
    if case .completed(let response) = event { final = response }
  }

  let response = try #require(final)
  #expect(response.toolCalls.first?.arguments == .object(["city": .string("Paris")]))
  guard let continuation = response.toolContinuation,
    case .array(let blocks) = continuation.payload,
    case .object(let thinking) = blocks.first
  else {
    Issue.record("Missing Anthropic thinking continuation")
    return
  }
  #expect(continuation.apiFamily == .anthropicMessages)
  #expect(thinking["thinking"] == .string("Need weather."))
  #expect(thinking["signature"] == .string("sig-123"))
}

@Test func geminiToolHistoryReplaysThoughtSignatureAndFunctionResponse() {
  let adapter = GeminiGenerateContentAdapter(definition: BuiltInProviders.gemini)
  let call = weatherCall()
  let continuation = ProviderToolContinuation(
    apiFamily: .geminiGenerateContent,
    payload: .object([call.id: .string("gemini-thought-signature")])
  )
  let result = ChatToolResult(
    callID: call.id,
    name: call.name,
    content: .object(["temperature": .number(21)])
  )
  let body = adapter.requestBody(
    ProviderRequest(
      model: "gemini-3.6-flash",
      messages: [
        .init(role: .user, content: "Weather?"),
        .init(role: .assistant, content: "", toolCalls: [call], toolContinuation: continuation),
        .init(role: .tool, content: "", toolResults: [result]),
      ],
      tools: [weatherTool()]
    )
  )

  guard case .array(let tools)? = body["tools"],
    case .object(let declarationsContainer) = tools[0],
    case .array(let declarations)? = declarationsContainer["functionDeclarations"],
    case .object(let declaration) = declarations[0]
  else {
    Issue.record("Missing Gemini function declarations")
    return
  }
  #expect(declaration["name"] == .string(call.name))

  guard case .array(let contents)? = body["contents"], contents.count == 3,
    case .object(let modelContent) = contents[1],
    case .array(let modelParts)? = modelContent["parts"],
    case .object(let callPart) = modelParts[0],
    case .object(let userContent) = contents[2],
    case .array(let resultParts)? = userContent["parts"],
    case .object(let resultPart) = resultParts[0],
    case .object(let functionResponse)? = resultPart["functionResponse"]
  else {
    Issue.record("Missing Gemini function history")
    return
  }
  #expect(callPart["thoughtSignature"] == .string("gemini-thought-signature"))
  #expect(functionResponse["id"] == .string(call.id))
  #expect(functionResponse["name"] == .string(call.name))
}

@Test func geminiStreamCapturesThoughtSignatureOnFunctionCall() async throws {
  let stream = """
    data: {"responseId":"resp_tool","modelVersion":"gemini-3.6-flash","candidates":[{"content":{"parts":[{"functionCall":{"id":"call_1","name":"get_weather","args":{"city":"Paris"}},"thoughtSignature":"sig-gemini"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":8,"candidatesTokenCount":3}}

    """
  let transport = ToolMockTransport(streamChunks: [Data(stream.utf8)])
  let adapter = GeminiGenerateContentAdapter(definition: BuiltInProviders.gemini, transport: transport)

  var final: ProviderResponse?
  for try await event in adapter.stream(
    request: ProviderRequest(
      model: "gemini-3.6-flash",
      messages: [.init(role: .user, content: "Weather?")],
      tools: [weatherTool()]
    ),
    account: toolAccount("gemini")
  ) {
    if case .completed(let response) = event { final = response }
  }

  let response = try #require(final)
  #expect(response.toolCalls.first == weatherCall())
  guard let continuation = response.toolContinuation,
    case .object(let signatures) = continuation.payload
  else {
    Issue.record("Missing Gemini tool continuation")
    return
  }
  #expect(continuation.apiFamily == .geminiGenerateContent)
  #expect(signatures["call_1"] == .string("sig-gemini"))
}

@Test func chatRuntimeExecutesToolPersistsRoundAndContinuesModel() async throws {
  let providerWorkspace = ProviderWorkspaceStore(
    persistence: InMemoryProviderWorkspacePersistence()
  )
  try await providerWorkspace.load()
  let account = ProviderAccount(
    id: "account",
    providerID: "openrouter",
    label: "OpenRouter",
    defaultModelID: "model"
  )
  try await providerWorkspace.upsertAccount(account)
  try await providerWorkspace.addManualModel(
    ProviderModel(
      providerID: "openrouter",
      id: "model",
      displayName: "Model",
      contextWindow: 16_384,
      maxOutputTokens: 1_024
    ),
    for: account.id
  )

  let conversations = ConversationStore(
    persistence: InMemoryConversationWorkspacePersistence()
  )
  try await conversations.load()
  let conversation = try await conversations.createConversation(
    providerID: account.providerID,
    accountID: account.id,
    modelID: "model"
  )

  let tools = ToolRuntime()
  try await tools.register(weatherTool()) { arguments in
    #expect(arguments == .object(["city": .string("Paris")]))
    return .object(["temperature": .number(21)])
  }

  let continuation = ProviderToolContinuation(
    apiFamily: .geminiGenerateContent,
    payload: .object(["call_1": .string("opaque")])
  )
  let provider = ToolLoopProviderRuntime(continuation: continuation)
  let chat = ChatRuntime(
    providerRuntime: provider,
    providerWorkspace: providerWorkspace,
    conversations: conversations,
    toolRuntime: tools,
    partialPersistenceInterval: .zero
  )

  var sawRound = false
  for try await event in await chat.send(
    conversationID: conversation.id,
    userText: "What's the weather in Paris?"
  ) {
    if case .toolRound(_, let round) = event {
      sawRound = true
      #expect(round.calls == [weatherCall()])
      #expect(round.results.first?.content == .object(["temperature": .number(21)]))
      #expect(round.providerContinuation == continuation)
    }
  }
  #expect(sawRound)

  let requests = await provider.requests
  #expect(requests.count == 2)
  #expect(requests[0].tools.map(\.name) == ["get_weather"])
  #expect(requests[1].messages.suffix(2).first?.toolCalls == [weatherCall()])
  #expect(requests[1].messages.suffix(2).first?.toolContinuation == continuation)
  #expect(requests[1].messages.last?.toolResults?.first?.content == .object(["temperature": .number(21)]))

  let stored = try await conversations.conversation(id: conversation.id)
  let assistant = try #require(stored.messages.last)
  #expect(assistant.status == .complete)
  #expect(assistant.content == "It is 21°C in Paris.")
  #expect(assistant.toolRounds?.count == 1)
  #expect(assistant.toolRounds?.first?.calls == [weatherCall()])
  #expect(assistant.toolRounds?.first?.providerContinuation == continuation)
  #expect(assistant.usage?.inputTokens == 30)
  #expect(assistant.usage?.outputTokens == 6)

  let rebuilt = try ChatContextBuilder.build(conversation: stored, contextWindow: nil)
  #expect(rebuilt.messages.contains { $0.toolCalls == [weatherCall()] })
  #expect(rebuilt.messages.contains { $0.toolResults?.first?.callID == "call_1" })
  #expect(rebuilt.messages.contains { $0.toolContinuation == continuation })
}

private func weatherTool() -> ChatToolDefinition {
  ChatToolDefinition(
    name: "get_weather",
    description: "Get weather for a city",
    inputSchema: .object([
      "type": .string("object"),
      "properties": .object([
        "city": .object(["type": .string("string")])
      ]),
      "required": .array([.string("city")]),
    ])
  )
}

private func weatherCall() -> ChatToolCall {
  ChatToolCall(
    id: "call_1",
    name: "get_weather",
    arguments: .object(["city": .string("Paris")])
  )
}

private func toolAccount(_ providerID: ProviderID) -> ResolvedProviderAccount {
  ResolvedProviderAccount(
    id: "account",
    providerID: providerID,
    label: "Tool Test",
    apiKey: "secret"
  )
}

private actor ToolMockTransport: ProviderHTTPTransport {
  let dataResponse: ProviderHTTPResponse
  let streamResponse: ProviderHTTPByteStream
  private(set) var requests: [URLRequest] = []

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
}

private actor ToolLoopProviderRuntime: ProviderStreamingRuntime {
  private(set) var requests: [ProviderRequest] = []
  let continuationMetadata: ProviderToolContinuation

  init(continuation: ProviderToolContinuation) {
    continuationMetadata = continuation
  }

  func stream(
    request: ProviderRequest,
    accountID: ProviderAccountID
  ) async throws -> AsyncThrowingStream<ProviderStreamEvent, Error> {
    requests.append(request)
    let index = requests.count
    return AsyncThrowingStream { continuation in
      if index == 1 {
        continuation.yield(
          .completed(
            ProviderResponse(
              text: "",
              providerID: "openrouter",
              accountID: accountID,
              modelID: request.model,
              finishReason: "tool_calls",
              usage: .init(inputTokens: 10, outputTokens: 2),
              toolCalls: [weatherCall()],
              toolContinuation: continuationMetadata
            )
          )
        )
      } else {
        continuation.yield(.textDelta("It is 21°C in Paris."))
        continuation.yield(
          .completed(
            ProviderResponse(
              text: "It is 21°C in Paris.",
              providerID: "openrouter",
              accountID: accountID,
              modelID: request.model,
              finishReason: "stop",
              usage: .init(inputTokens: 20, outputTokens: 4)
            )
          )
        )
      }
      continuation.finish()
    }
  }
}
