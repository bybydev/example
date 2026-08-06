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
        model: model, messages: [.init(role: .user, content: "Return exactly OK.")],
        options: .init(maxOutputTokens: 16)),
      account: account
    )
  }

  public func listModels(account: ResolvedProviderAccount) async throws -> [ProviderModel] {
    guard let path = definition.modelsPath else { return definition.seedModels }
    let url = try ProviderHTTP.endpoint(
      baseURL: account.baseURLOverride ?? definition.defaultBaseURL, path: path)
    let request = try makeRequest(
      url: url, method: "GET", account: account, acceptsEventStream: false)
    let response = try await transport.data(for: request)
    try validate(response)
    let decoded: ModelsResponse
    do { decoded = try JSONDecoder.provider.decode(ModelsResponse.self, from: response.data) } catch
    { throw ProviderError.invalidResponse }
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
      path: definition.chatCompletionsPath)
    var urlRequest = try makeRequest(
      url: url, method: "POST", account: account, acceptsEventStream: false)
    urlRequest.httpBody = try JSONEncoder.providerEncoder.encode(
      JSONValue.object(requestBody(validated, streaming: false)))
    let response = try await transport.data(for: urlRequest)
    try validate(response)
    let decoded: ChatCompletionResponse
    do {
      decoded = try JSONDecoder.provider.decode(ChatCompletionResponse.self, from: response.data)
    } catch { throw ProviderError.invalidResponse }
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
      let task = Task {
        do {
          let validated = try validate(request: request, account: account)
          let url = try ProviderHTTP.endpoint(
            baseURL: account.baseURLOverride ?? definition.defaultBaseURL,
            path: definition.chatCompletionsPath)
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
              } catch { throw ProviderError.invalidResponse }
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
          for event in try decoder.finish() where event.data == "[DONE]" { completed = true }
          guard completed || finishReason != nil else { throw ProviderError.prematureStreamEnd }
          guard
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          else {
            throw ProviderError.emptyOutput
          }
          continuation.yield(
            .completed(
              .init(
                id: responseID, text: text, reasoning: reasoning, providerID: definition.id,
                accountID: account.id, modelID: modelID, finishReason: finishReason, usage: usage,
                metadata: metadata)))
          continuation.finish()
        } catch { continuation.finish(throwing: error) }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func validate(request: ProviderRequest, account: ResolvedProviderAccount) throws
    -> ProviderRequest
  {
    let model = request.model.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !model.isEmpty else { throw ProviderError.invalidModel }
    let messages = request.messages.compactMap { message -> ProviderMessage? in
      let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
      return content.isEmpty
        ? nil : .init(role: message.role, content: content, reasoning: message.reasoning)
    }
    guard !messages.isEmpty else { throw ProviderError.invalidMessages }
    if definition.authentication != .none {
      guard let key = account.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty
      else {
        throw ProviderError.missingCredential(definition.id)
      }
    }
    var result = request
    result.model = ModelID(rawValue: model)
    result.messages = messages
    return result
  }

  private func makeRequest(
    url: URL, method: String, account: ResolvedProviderAccount, acceptsEventStream: Bool
  ) throws -> URLRequest {
    var headers = account.additionalHeaders
    if definition.behavior == .openRouter {
      headers["X-OpenRouter-Metadata"] = "enabled"
      if let value = account.metadata["httpReferer"], !value.isEmpty {
        headers["HTTP-Referer"] = value
      }
      if let value = account.metadata["appTitle"], !value.isEmpty { headers["X-Title"] = value }
    }
    var request = try ProviderHTTP.makeRequest(
      url: url, method: method, authentication: definition.authentication, secret: account.apiKey,
      additionalHeaders: headers)
    if acceptsEventStream { request.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
    return request
  }

  private func requestBody(_ request: ProviderRequest, streaming: Bool) -> [String: JSONValue] {
    var body: [String: JSONValue] = [
      "model": .string(request.model.rawValue),
      "messages": .array(
        request.messages.map {
          .object(["role": .string($0.role.rawValue), "content": .string($0.content)])
        }),
      "stream": .bool(streaming),
    ]
    if let value = request.options.temperature { body["temperature"] = .number(value) }
    if let value = request.options.topP { body["top_p"] = .number(value) }
    if let value = request.options.maxOutputTokens { body["max_tokens"] = .number(Double(value)) }
    switch definition.behavior {
    case .deepSeek:
      if let reasoning = request.options.reasoning {
        if let enabled = reasoning.enabled {
          body["thinking"] = .object(["type": .string(enabled ? "enabled" : "disabled")])
        }
        if let effort = reasoning.effort {
          body["reasoning_effort"] = .string(effort == .max ? "max" : "high")
        }
      }
      if streaming { body["stream_options"] = .object(["include_usage": .bool(true)]) }
    case .openRouter:
      if let reasoning = request.options.reasoning {
        var object: [String: JSONValue] = [:]
        if let value = reasoning.enabled { object["enabled"] = .bool(value) }
        if let value = reasoning.effort { object["effort"] = .string(value.rawValue) }
        if let value = reasoning.maxTokens { object["max_tokens"] = .number(Double(value)) }
        if reasoning.excludeFromResponse { object["exclude"] = .bool(true) }
        if !object.isEmpty { body["reasoning"] = .object(object) }
      }
      if let routing = request.options.openRouterRouting {
        var object: [String: JSONValue] = [:]
        if !routing.providerOrder.isEmpty {
          object["order"] = .array(routing.providerOrder.map(JSONValue.string))
        }
        if let value = routing.allowFallbacks { object["allow_fallbacks"] = .bool(value) }
        if let value = routing.requireParameters { object["require_parameters"] = .bool(value) }
        if let value = routing.dataCollection {
          object["data_collection"] = .string(value.rawValue)
        }
        if let value = routing.zeroDataRetention { object["zdr"] = .bool(value) }
        if let value = routing.sort { object["sort"] = .string(value.rawValue) }
        if !object.isEmpty { body["provider"] = .object(object) }
      }
      if streaming { body["stream_options"] = .object(["include_usage": .bool(true)]) }
    case .nvidia, .genericOpenAICompatible:
      break
    }
    return body
  }

  private func validate(_ response: ProviderHTTPResponse) throws {
    guard (200..<300).contains(response.statusCode) else {
      throw mapHTTPError(
        status: response.statusCode, headers: response.headers, data: response.data)
    }
  }

  private func mapHTTPError(status: Int, headers: [String: String], data: Data) -> ProviderError {
    let decoded = try? JSONDecoder.provider.decode(ProviderErrorEnvelope.self, from: data)
    let message =
      decoded?.error?.message ?? decoded?.message
      ?? HTTPURLResponse.localizedString(forStatusCode: status)
    let lowered = message.lowercased()
    switch status {
    case 401: return .authenticationFailed
    case 402: return .insufficientCredits
    case 403: return .permissionDenied
    case 404 where lowered.contains("model"): return .modelUnavailable
    case 404: return .invalidEndpoint
    case 429: return .rateLimited(retryAfter: header("Retry-After", headers))
    default:
      if lowered.contains("credit") || lowered.contains("quota") || lowered.contains("billing") {
        return .insufficientCredits
      }
      if lowered.contains("model")
        && (lowered.contains("not found") || lowered.contains("unavailable"))
      {
        return .modelUnavailable
      }
      return .provider(status: status, message: message)
    }
  }

  private func responseMetadata(_ headers: [String: String], _ decoded: ChatCompletionResponse?)
    -> [String: String]
  {
    var metadata: [String: String] = [:]
    if let value = header("X-Generation-Id", headers) { metadata["generationID"] = value }
    if let value = decoded?.provider { metadata["provider"] = value }
    return metadata
  }

  private func header(_ name: String, _ headers: [String: String]) -> String? {
    headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
  }

  private func mergeModels(seed: [ProviderModel], discovered: [ProviderModel]) -> [ProviderModel] {
    var values = Dictionary(uniqueKeysWithValues: seed.map { ($0.id, $0) })
    for model in discovered {
      if let existing = values[model.id] {
        var merged = model
        if merged.contextWindow == nil { merged.contextWindow = existing.contextWindow }
        if merged.maxOutputTokens == nil { merged.maxOutputTokens = existing.maxOutputTokens }
        merged.supportedParameters.formUnion(existing.supportedParameters)
        values[model.id] = merged
      } else {
        values[model.id] = model
      }
    }
    return values.values.sorted {
      $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
  }
}
