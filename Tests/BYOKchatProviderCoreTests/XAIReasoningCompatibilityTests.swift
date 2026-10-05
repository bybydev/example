import Foundation
import Testing

@testable import BYOKchatProviderCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Test func xAIStandardGrok420KeepsEncryptedReasoningButOmitsUnsupportedEffortControl() async throws {
  let transport = XAIReasoningMockTransport(responses: [xAIReasoningResponse(model: "grok-4.20-0309-reasoning")])
  let adapter = XAIResponsesAdapter(definition: BuiltInProviders.xAI, transport: transport)

  _ = try await adapter.generate(
    request: ProviderRequest(
      model: "grok-4.20-0309-reasoning",
      messages: [.init(role: .user, content: "Hello")],
      options: .init(reasoning: .init(enabled: true, effort: .max))
    ),
    account: xAIReasoningAccount()
  )

  let root = try requestRoot(try #require(await transport.request(at: 0)))
  #expect(root["include"] == .array([.string("reasoning.encrypted_content")]))
  #expect(root["reasoning"] == nil)
}

@Test func xAIStaleMaxReasoningUsesProviderDefaultWithoutClaimingXHigh() async throws {
  let transport = XAIReasoningMockTransport(
    responses: [
      xAIReasoningResponse(model: "grok-4.6"),
      xAIReasoningResponse(model: "grok-4.5"),
      xAIReasoningResponse(model: "grok-4.20-multi-agent-0309"),
    ]
  )
  let adapter = XAIResponsesAdapter(definition: BuiltInProviders.xAI, transport: transport)

  for model in ["grok-4.6", "grok-4.5", "grok-4.20-multi-agent-0309"] {
    _ = try await adapter.generate(
      request: ProviderRequest(
        model: ModelID(rawValue: model),
        messages: [.init(role: .user, content: "Hello")],
        options: .init(reasoning: .init(enabled: true, effort: .max))
      ),
      account: xAIReasoningAccount()
    )
  }

  let grok46 = try requestRoot(try #require(await transport.request(at: 0)))
  let grok45 = try requestRoot(try #require(await transport.request(at: 1)))
  let multiAgent = try requestRoot(try #require(await transport.request(at: 2)))

  #expect(reasoningEffort(grok46) == nil)
  #expect(reasoningEffort(grok45) == nil)
  #expect(reasoningEffort(multiAgent) == nil)
}

@Test func xAIExplicitXHighIsPreservedOnSupportingFamilies() async throws {
  let transport = XAIReasoningMockTransport(responses: [xAIReasoningResponse(model: "grok-4.6")])
  let adapter = XAIResponsesAdapter(definition: BuiltInProviders.xAI, transport: transport)
  _ = try await adapter.generate(
    request: .init(model: "grok-4.6", messages: [.init(role: .user, content: "Hello")],
      options: .init(reasoning: .init(enabled: true, effort: .xhigh))),
    account: xAIReasoningAccount()
  )
  let root = try requestRoot(try #require(await transport.request(at: 0)))
  #expect(reasoningEffort(root) == "xhigh")
}

private actor XAIReasoningMockTransport: ProviderHTTPTransport {
  private var responses: [Data]
  private var requests: [URLRequest] = []

  init(responses: [Data]) {
    self.responses = responses
  }

  func data(for request: URLRequest) async throws -> ProviderHTTPResponse {
    requests.append(request)
    guard !responses.isEmpty else { throw ProviderError.invalidResponse }
    return ProviderHTTPResponse(statusCode: 200, headers: [:], data: responses.removeFirst())
  }

  func stream(for request: URLRequest) async throws -> ProviderHTTPByteStream {
    throw ProviderError.invalidResponse
  }

  func request(at index: Int) -> URLRequest? {
    guard requests.indices.contains(index) else { return nil }
    return requests[index]
  }
}

private func xAIReasoningAccount() -> ResolvedProviderAccount {
  ResolvedProviderAccount(
    kind: .xAI,
    id: "xai-reasoning-account",
    providerID: "xai",
    label: "xAI",
    apiKey: "xai-secret"
  )
}

private func xAIReasoningResponse(model: String) -> Data {
  Data(
    """
    {"id":"resp","model":"\(model)","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"OK"}]}]}
    """.utf8
  )
}

private func requestRoot(_ request: URLRequest) throws -> [String: JSONValue] {
  let data = try #require(request.httpBody)
  let value = try JSONDecoder.provider.decode(JSONValue.self, from: data)
  guard case .object(let root) = value else {
    Issue.record("Expected object request body")
    return [:]
  }
  return root
}

private func reasoningEffort(_ root: [String: JSONValue]) -> String? {
  guard case .object(let reasoning)? = root["reasoning"],
    case .string(let effort)? = reasoning["effort"]
  else { return nil }
  return effort
}
