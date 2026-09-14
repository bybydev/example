import Foundation
import Testing

@testable import BYOKchatProviderCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

private actor XAIToolContinuationTransport: ProviderHTTPTransport {
  private var responses: [ProviderHTTPResponse]
  private var requests: [URLRequest] = []

  init(_ responses: [Data]) {
    self.responses = responses.map {
      ProviderHTTPResponse(statusCode: 200, headers: [:], data: $0)
    }
  }

  func data(for request: URLRequest) async throws -> ProviderHTTPResponse {
    requests.append(request)
    guard !responses.isEmpty else { throw ProviderError.invalidResponse }
    return responses.removeFirst()
  }

  func stream(for request: URLRequest) async throws -> ProviderHTTPByteStream {
    requests.append(request)
    return ProviderHTTPByteStream(
      statusCode: 200,
      headers: [:],
      chunks: AsyncThrowingStream { $0.finish() }
    )
  }

  func request(at index: Int) -> URLRequest? {
    guard requests.indices.contains(index) else { return nil }
    return requests[index]
  }
}

private func xAIToolAccount() -> ResolvedProviderAccount {
  ResolvedProviderAccount(
    kind: .xAI,
    id: "xai-tool-account",
    providerID: "xai",
    label: "xAI",
    apiKey: "secret"
  )
}

@Test func xAIResponsesReplaysEncryptedReasoningAndFunctionCallAcrossToolRound() async throws {
  let toolResponse = Data(
    """
    {"id":"resp_tool","model":"grok-4.6","status":"completed","output":[{"id":"rs_tool","type":"reasoning","encrypted_content":"encrypted-xai-state","summary":[]},{"id":"fc_1","type":"function_call","call_id":"call_1","name":"lookup_weather","arguments":"{\"city\":\"Hanoi\"}"}],"usage":{"input_tokens":5,"output_tokens":3}}
    """.utf8
  )
  let finalResponse = Data(
    """
    {"id":"resp_final","model":"grok-4.6","status":"completed","output":[{"id":"msg_final","type":"message","role":"assistant","content":[{"type":"output_text","text":"Sunny"}]}],"usage":{"input_tokens":8,"output_tokens":2}}
    """.utf8
  )
  let transport = XAIToolContinuationTransport([toolResponse, finalResponse])
  let adapter = XAIResponsesAdapter(definition: BuiltInProviders.xAI, transport: transport)
  let account = xAIToolAccount()
  let tool = ChatToolDefinition(name: "lookup_weather", description: "Look up weather")

  let first = try await adapter.generate(
    request: ProviderRequest(
      model: "grok-4.6",
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
  #expect(continuation.apiFamily == .openAIResponses)

  let second = try await adapter.generate(
    request: ProviderRequest(
      model: "grok-4.6",
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

  let recorded = try #require(await transport.request(at: 1))
  let body = try #require(recorded.httpBody)
  let decoded = try JSONDecoder.provider.decode(JSONValue.self, from: body)
  guard case .object(let root) = decoded, case .array(let input)? = root["input"] else {
    Issue.record("Missing xAI continuation input")
    return
  }

  #expect(input.contains { item in
    guard case .object(let value) = item else { return false }
    return value["type"] == .string("reasoning")
      && value["encrypted_content"] == .string("encrypted-xai-state")
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
