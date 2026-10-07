import Foundation
import Testing

@testable import BYOKchatProviderCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

private actor CorrectnessCaptureTransport: ProviderHTTPTransport {
  private var capturedRequest: URLRequest?

  func data(for request: URLRequest) async throws -> ProviderHTTPResponse {
    capturedRequest = request
    let response = Data(
      #"{"id":"test","model":"deepseek-v4-flash","choices":[{"message":{"content":"OK"},"finish_reason":"stop"}]}"#
        .utf8
    )
    return ProviderHTTPResponse(statusCode: 200, headers: [:], data: response)
  }

  func stream(for request: URLRequest) async throws -> ProviderHTTPByteStream {
    capturedRequest = request
    return ProviderHTTPByteStream(
      statusCode: 200,
      headers: [:],
      chunks: AsyncThrowingStream { continuation in continuation.finish() }
    )
  }

  func lastRequest() -> URLRequest? { capturedRequest }
}

private func correctnessAccount(baseURLOverride: URL? = nil) -> ResolvedProviderAccount {
  ResolvedProviderAccount(
    kind: ProviderKind(providerID: BuiltInProviders.deepSeekID),
    id: "correctness-account",
    providerID: BuiltInProviders.deepSeekID,
    label: "Correctness",
    apiKey: "secret",
    baseURLOverride: baseURLOverride
  )
}

@Test(arguments: [ReasoningEffort.low, .high])
func deepSeekThinkingOmitsIgnoredSamplingParameters(_ effort: ReasoningEffort) async throws {
  let transport = CorrectnessCaptureTransport()
  let adapter = OpenAICompatibleAdapter(
    definition: BuiltInProviders.deepSeek,
    transport: transport
  )

  _ = try await adapter.generate(
    request: ProviderRequest(
      model: "deepseek-v4-flash",
      messages: [.init(role: .user, content: "Hello")],
      options: .init(
        temperature: 0.4,
        topP: 0.8,
        reasoning: .init(enabled: true, effort: effort)
      )
    ),
    account: correctnessAccount()
  )

  let request = try #require(await transport.lastRequest())
  let body = try #require(request.httpBody)
  let decoded = try JSONDecoder.provider.decode(JSONValue.self, from: body)
  guard case .object(let root) = decoded else {
    Issue.record("Expected an object request body")
    return
  }

  #expect(root["temperature"] == nil)
  #expect(root["top_p"] == nil)
  // A supported effort is encoded; an unsupported saved effort uses provider Default.
  #expect(root["reasoning_effort"] == (effort == .high ? .string("high") : nil))
}

@Test func deepSeekNonThinkingKeepsSamplingParameters() async throws {
  let transport = CorrectnessCaptureTransport()
  let adapter = OpenAICompatibleAdapter(
    definition: BuiltInProviders.deepSeek,
    transport: transport
  )

  _ = try await adapter.generate(
    request: ProviderRequest(
      model: "deepseek-v4-flash",
      messages: [.init(role: .user, content: "Hello")],
      options: .init(
        temperature: 0.4,
        topP: 0.8,
        reasoning: .init(enabled: false, effort: .max)
      )
    ),
    account: correctnessAccount()
  )

  let request = try #require(await transport.lastRequest())
  let body = try #require(request.httpBody)
  let decoded = try JSONDecoder.provider.decode(JSONValue.self, from: body)
  guard case .object(let root) = decoded else {
    Issue.record("Expected an object request body")
    return
  }

  #expect(root["temperature"] == .number(0.4))
  #expect(root["top_p"] == .number(0.8))
  #expect(root["reasoning_effort"] == nil)
}

@Test func accountOverrideCannotBypassProviderLocalHTTPPolicy() async throws {
  let transport = CorrectnessCaptureTransport()
  let adapter = OpenAICompatibleAdapter(
    definition: BuiltInProviders.deepSeek,
    transport: transport
  )
  let privateHTTP = try #require(URL(string: "http://192.168.1.10:11434/v1"))

  await #expect(throws: ProviderError.self) {
    _ = try await adapter.generate(
      request: ProviderRequest(
        model: "deepseek-v4-flash",
        messages: [.init(role: .user, content: "Hello")]
      ),
      account: correctnessAccount(baseURLOverride: privateHTTP)
    )
  }

  #expect(await transport.lastRequest() == nil)
}
