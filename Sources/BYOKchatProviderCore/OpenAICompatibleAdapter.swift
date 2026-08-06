import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public protocol ProviderAdapter: Sendable {
  var providerID: ProviderID { get }
  func testConnection(account: ResolvedProviderAccount, model: ModelID) async throws
  func listModels(account: ResolvedProviderAccount) async throws -> [ProviderModel]
  func generate(request: ProviderRequest, account: ResolvedProviderAccount) async throws
    -> ProviderResponse
  func stream(request: ProviderRequest, account: ResolvedProviderAccount) -> AsyncThrowingStream<
    ProviderStreamEvent, Error
  >
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

  public func testConnection(account: ResolvedProviderAccount, model: ModelID) async throws {
    _ = try await generate(
      request: .init(
        model: model,
        messages: [.init(role: .user, content: "Return exactly OK.")],
        options: .init(maxOutputTokens: 16)
      ),
      account: account
    )
  }

  public func listModels(account: ResolvedProviderAccount) async throws -> [ProviderModel] {
    guard let path = definition.modelsPath else { return definition.seedModels }
    let url = try ProviderHTTP.endpoint(
      baseURL: account.baseURLOverride ?? definition.defaultBaseURL,
      path: path,
      allowsLocalHTTP: definition.allowsLocalHTTP
    )
    let request = try makeRequest(
      url: url, method: "GET", account: account, acceptsEventStream: false)
    let response = try await transport.data(for: request)
    try validate(response)
    let decoded: ModelsResponse
    do {
      decoded = try JSONDecoder.provider.decode(ModelsResponse.self, from: response.data)
    } catch {
      throw ProviderError.invalidResponse
    }
    let discovered = decoded.data.map {
      ProviderModel(
        providerID: definition.id,
        id: ModelID(rawValue: $0.id),
        displayName: $0.name ?? $0.id,
        contextWindow: $0.contextLength ?? $0.topProvider?.contextLength,
        maxOutputTokens: $0.topProvider?.maxCompletionTokens,
        supportedParameters: Set($0.supportedParameters ?? []),
        inputModalities: Set($0.architecture?.inputModalities ?? ["text"]),
        outputModalities: Set($0.architecture?.outputModalities ?? ["text"]),
        promptPricePerToken: $0.pricing?.prompt,
        completionPricePerToken: $0.pricing?.completion,
        isSeed: false
      )
    }
    return mergeModels(seed: definition.seedModels, discovered: discovered)
  }

  public func generate(request: ProviderRequest, account: ResolvedProviderAccount) async throws
    -> ProviderResponse
  {
    let validated = try validate(request: request, account: account)
    let url = try ProviderHTTP.endpoint(
      baseURL: account.baseURLOverride ?? definition.defaultBaseURL,
      path: definition.chatCompletionsPath,
      allowsLocalHTTP: definition.allowsLocalHTTP
    )
    var urlRequest = try makeRequest(
      url: url, method: "POST", account: account, acceptsEventStream: false)
    urlRequest.httpBody = try JSONEncoder.providerEncoder.encode(
      JSONValue.object(requestBody(validated, streaming: false)))
    let response = try await transport.data(for: urlRequest)
    try validate(response)
    let decoded: ChatCompletionResponse
    do {
      decoded = try JSONDecoder.provider.decode(ChatCompletionResponse.self, from: response.data)
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
    return .init(
      id: decoded.id,
      text: text,
      reasoning: reasoning,
      providerID: definition.id,
      accountID: account.id,
      modelID: ModelID(rawValue: decoded.model ?? validated.model.rawValue),
      finishReason: decoded.choices.first?.finishReason,
      usage: decoded.usage?.normalized,
      metadata: responseMetadata(response.headers, decoded)
    )
  }

  public func stream(request: ProviderRequest, account: ResolvedProviderAccount)
    -> AsyncThrowingStream<ProviderStreamEvent, Error>
  {
    AsyncThrowingStream { continuation in
      let task = Task { @Sendable in
        do {
          let validated = try validate(request: request, account: account)
          let url = try ProviderHTTP.endpoint(
            baseURL: account.baseURLOverride ?? definition.defaultBaseURL,
            path: definition.chatCompletionsPath,
            allowsLocalHTTP: definition.allowsLocalHTTP
          )
          var urlRequest = try makeRequest(
            url: url, method: "POST", account: account, acceptsEventStream: true)
          urlRequest.httpBody = try JSONEncoder.providerEncoder.encode(
            JSONValue.object(requestBody(validated, streaming: true)))
          let stream = try await transport.stream(for: urlRequest)
          guard (200..<300).contains(stream.statusCode) else {
            var data = Data()
            for try await chunk in stream.chunks { data.append(chunk) }
            throw mapHTTPError(status: stream.statusCode, headers: stream.headers, data: data)
          }

          var decoder = SSEDecoder()
          var text = ""
          var reasoning = ""
          var usage: ProviderUsage?
          var finishReason: String?
          var responseID: String?
          var modelID = validated.model
          var completed = false
          var metadata = responseMetadata(stream.headers, nil)

          for try await chunk in stream.chunks {
            try Task.checkCancellation()
            for event in try decoder.append(chunk) {
              if event.data == "[DONE]" {
                completed = true
                continue
              }
              guard let payload = event.data.data(using: .utf8) else {
                throw ProviderError.invalidResponse
              }
              let decoded: ChatCompletionChunk
              do {
                decoded = try JSONDecoder.provider.decode(ChatCompletionChunk.self, from: payload)
              } catch {
                throw ProviderError.invalidResponse
              }
              if let error = decoded.error {
                throw ProviderError.midStreamProvider(code: error.code, message: error.message)
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
          for event in try decoder.finish() where event.data == "[DONE]" {
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
              .init(
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
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
  }
}
