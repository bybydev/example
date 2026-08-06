import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public protocol ProviderAdapter: Sendable {
  var providerID: ProviderID { get }

  func testConnection(
    account: ResolvedProviderAccount,
    model: ModelID
  ) async throws

  func listModels(
    account: ResolvedProviderAccount
  ) async throws -> [ProviderModel]

  func generate(
    request: ProviderRequest,
    account: ResolvedProviderAccount
  ) async throws -> ProviderResponse

  func stream(
    request: ProviderRequest,
    account: ResolvedProviderAccount
  ) -> AsyncThrowingStream<ProviderStreamEvent, Error>
}

public struct OpenAICompatibleAdapter: ProviderAdapter, Sendable {
  public let definition: ProviderDefinition
  public let transport: any ProviderHTTPTransport

  public var providerID: ProviderID { definition.id }

  public init(
    definition: ProviderDefinition,
    transport: any ProviderHTTPTransport = URLSessionProviderHTTPTransport()
  ) {
    self.definition = definition
    self.transport = transport
  }

  public func testConnection(
    account: ResolvedProviderAccount,
    model: ModelID
  ) async throws {
    _ = try await generate(
      request: ProviderRequest(
        model: model,
        messages: [.init(role: .user, content: "Return exactly OK.")],
        options: .init(maxOutputTokens: 16)
      ),
      account: account
    )
  }

  public func listModels(
    account: ResolvedProviderAccount
  ) async throws -> [ProviderModel] {
    guard let path = definition.modelsPath else {
      return definition.seedModels
    }
    let url = try ProviderHTTP.endpoint(
      baseURL: account.baseURLOverride ?? definition.defaultBaseURL,
      path: path
    )
    let request = try makeRequest(
      url: url,
      method: "GET",
      account: account,
      acceptsEventStream: false
    )
    let response = try await transport.data(for: request)
    try validate(response: response)
    let decoded: ModelsResponse
    do {
      decoded = try JSONDecoder.provider.decode(ModelsResponse.self, from: response.data)
    } catch {
      throw ProviderError.invalidResponse
    }

    let discovered = decoded.data.map { wire in
      ProviderModel(
        providerID: definition.id,
        id: ModelID(rawValue: wire.id),
        displayName: wire.name ?? wire.id,
        contextWindow: wire.contextLength ?? wire.topProvider?.contextLength,
        maxOutputTokens: wire.topProvider?.maxCompletionTokens,
        supportedParameters: Set(wire.supportedParameters ?? []),
        inputModalities: Set(wire.architecture?.inputModalities ?? ["text"]),
        outputModalities: Set(wire.architecture?.outputModalities ?? ["text"]),
        promptPricePerToken: wire.pricing?.prompt,
        completionPricePerToken: wire.pricing?.completion,
        isSeed: false
      )
    }
    return mergeModels(seed: definition.seedModels, discovered: discovered)
  }

  public func generate(
    request: ProviderRequest,
    account: ResolvedProviderAccount
  ) async throws -> ProviderResponse {
    let validated = try validate(request: request, account: account)
    let url = try ProviderHTTP.endpoint(
      baseURL: account.baseURLOverride ?? definition.defaultBaseURL,
      path: definition.chatCompletionsPath
    )
    var urlRequest = try makeRequest(
      url: url,
      method: "POST",
      account: account,
      acceptsEventStream: false
    )
    let body = try requestBody(validated, streaming: false)
    urlRequest.httpBody = try JSONEncoder.providerEncoder.encode(JSONValue.object(body))

    let response = try await transport.data(for: urlRequest)
    try validate(response: response)
    let decoded: ChatCompletionResponse
    do {
      decoded = try JSONDecoder.provider.decode(
        ChatCompletionResponse.self, from: response.data)
    } catch {
      throw ProviderError.invalidResponse
    }
    if let error = decoded.error {
      throw ProviderError.provider(status: response.statusCode, message: error.message)
    }
    let message = decoded.choices.first?.message
    let text = message?.content ?? ""
    let reasoning = message?.normalizedReasoning ?? ""
    guard
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw ProviderError.emptyOutput
    }
    return ProviderResponse(
      id: decoded.id,
      text: text,
      reasoning: reasoning,
      providerID: definition.id,
      accountID: account.id,
      modelID: ModelID(rawValue: decoded.model ?? validated.model.rawValue),
      finishReason: decoded.choices.first?.finishReason,
      usage: decoded.usage?.normalized,
      metadata: responseMetadata(headers: response.headers, decoded: decoded)
    )
  }

  public func stream(
    request: ProviderRequest,
    account: ResolvedProviderAccount
  ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let validated = try validate(request: request, account: account)
          let url = try ProviderHTTP.endpoint(
            baseURL: account.baseURLOverride ?? definition.defaultBaseURL,
            path: definition.chatCompletionsPath
          )
          var urlRequest = try makeRequest(
            url: url,
            method: "POST",
            account: account,
            acceptsEventStream: true
          )
          let body = try requestBody(validated, streaming: true)
          urlRequest.httpBody = try JSONEncoder.providerEncoder.encode(JSONValue.object(body))

          let stream = try await transport.stream(for: urlRequest)
          guard (200..<300).contains(stream.statusCode) else {
            var data = Data()
            for try await chunk in stream.chunks { data.append(chunk) }
            throw mapHTTPError(
              statusCode: stream.statusCode,
              headers: stream.headers,
              data: data
            )
          }

          var decoder = SSEDecoder()
          var text = ""
          var reasoning = ""
          var usage: ProviderUsage?
          var finishReason: String?
          var responseID: String?
          var modelID = validated.model
          var completed = false
          var metadata = responseMetadata(headers: stream.headers, decoded: nil)

          for try await chunk in stream.chunks {
            try Task.checkCancellation()
            let events = try decoder.append(chunk)
            for event in events {
              if event.data == "[DONE]" {
                completed = true
                continue
              }
              guard let payload = event.data.data(using: .utf8) else {
                throw ProviderError.invalidResponse
              }
              let decoded: ChatCompletionChunk
              do {
                decoded = try JSONDecoder.provider.decode(
                  ChatCompletionChunk.self, from: payload)
              } catch {
                throw ProviderError.invalidResponse
              }
              if let error = decoded.error {
                throw ProviderError.midStreamProvider(
                  code: error.code,
                  message: error.message
                )
              }
              if let value = decoded.id { responseID = value }
              if let value = decoded.model { modelID = ModelID(rawValue: value) }
              if let value = decoded.provider { metadata["provider"] = value }
              if let value = decoded.usage?.normalized {
                usage = value
                continuation.yield(.usage(value))
              }
              if let choice = decoded.choices.first {
                if let value = choice.finishReason { finishReason = value }
                if let delta = choice.delta.content, !delta.isEmpty {
                  text += delta
                  continuation.yield(.textDelta(delta))
                }
                for delta in choice.delta.reasoningFragments where !delta.isEmpty {
                  reasoning += delta
                  continuation.yield(.reasoningDelta(delta))
                }
              }
            }
          }

          let finalEvents = try decoder.finish()
          for event in finalEvents where event.data == "[DONE]" {
            completed = true
          }

          guard completed || finishReason != nil else {
            throw ProviderError.prematureStreamEnd
          }
          guard
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          else {
            throw ProviderError.emptyOutput
          }
          continuation.yield(
            .completed(
              ProviderResponse(
                id: responseID,
                text: text,
                reasoning: reasoning,
                providerID: definition.id,
                accountID: account.id,
                modelID: modelID,
                finishReason: finishReason,
                usage: usage,
                metadata: metadata
              )
            )
          )
          continuation.finish()
        } catch is CancellationError {
          continuation.finish(throwing: CancellationError())
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

}
