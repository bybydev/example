import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

extension OpenAICompatibleAdapter {
  func validate(
    request: ProviderRequest,
    account: ResolvedProviderAccount
  ) throws -> ProviderRequest {
    let model = request.model.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !model.isEmpty else { throw ProviderError.invalidModel }
    let messages = request.messages.compactMap { message -> ProviderMessage? in
      let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !content.isEmpty else { return nil }
      return ProviderMessage(role: message.role, content: content, reasoning: message.reasoning)
    }
    guard !messages.isEmpty else { throw ProviderError.invalidMessages }
    guard let key = account.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
      !key.isEmpty
    else {
      throw ProviderError.missingCredential(definition.id)
    }
    var validated = request
    validated.model = ModelID(rawValue: model)
    validated.messages = messages
    return validated
  }

  func makeRequest(
    url: URL,
    method: String,
    account: ResolvedProviderAccount,
    acceptsEventStream: Bool
  ) throws -> URLRequest {
    var headers = account.additionalHeaders
    switch definition.behavior {
    case .openRouter:
      headers["X-OpenRouter-Metadata"] = "enabled"
      if let referer = account.metadata["httpReferer"], !referer.isEmpty {
        headers["HTTP-Referer"] = referer
      }
      if let title = account.metadata["appTitle"], !title.isEmpty {
        headers["X-Title"] = title
      }
    case .deepSeek, .nvidia, .genericOpenAICompatible:
      break
    }
    var request = try ProviderHTTP.makeRequest(
      url: url,
      method: method,
      apiKey: account.apiKey,
      additionalHeaders: headers
    )
    if acceptsEventStream {
      request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    }
    return request
  }

  func requestBody(
    _ request: ProviderRequest,
    streaming: Bool
  ) throws -> [String: JSONValue] {
    var body: [String: JSONValue] = [
      "model": .string(request.model.rawValue),
      "messages": .array(
        request.messages.map { message in
          var object: [String: JSONValue] = [
            "role": .string(message.role.rawValue),
            "content": .string(message.content),
          ]
          if let reasoning = message.reasoning, !reasoning.isEmpty {
            switch definition.behavior {
            case .deepSeek:
              object["reasoning_content"] = .string(reasoning)
            case .openRouter:
              object["reasoning"] = .string(reasoning)
            case .nvidia, .genericOpenAICompatible:
              break
            }
          }
          return .object(object)
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
      if streaming {
        body["stream_options"] = .object(["include_usage": .bool(true)])
      }
    case .openRouter:
      if let reasoning = request.options.reasoning {
        var object: [String: JSONValue] = [:]
        if let enabled = reasoning.enabled { object["enabled"] = .bool(enabled) }
        if let effort = reasoning.effort { object["effort"] = .string(effort.rawValue) }
        if let maxTokens = reasoning.maxTokens { object["max_tokens"] = .number(Double(maxTokens)) }
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
      if streaming {
        body["stream_options"] = .object(["include_usage": .bool(true)])
      }
    case .nvidia, .genericOpenAICompatible:
      break
    }
    return body
  }

  func validate(response: ProviderHTTPResponse) throws {
    guard (200..<300).contains(response.statusCode) else {
      throw mapHTTPError(
        statusCode: response.statusCode,
        headers: response.headers,
        data: response.data
      )
    }
  }

  func mapHTTPError(
    statusCode: Int,
    headers: [String: String],
    data: Data
  ) -> ProviderError {
    let decoded = try? JSONDecoder.provider.decode(ProviderErrorEnvelope.self, from: data)
    let message =
      decoded?.error?.message
      ?? decoded?.message
      ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)
    let lowered = message.lowercased()
    switch statusCode {
    case 401: return .authenticationFailed
    case 402: return .insufficientCredits
    case 403: return .permissionDenied
    case 404 where lowered.contains("model"): return .modelUnavailable
    case 404: return .invalidEndpoint
    case 429:
      return .rateLimited(retryAfter: header("Retry-After", in: headers))
    default:
      if lowered.contains("credit") || lowered.contains("quota") || lowered.contains("billing") {
        return .insufficientCredits
      }
      if lowered.contains("model")
        && (lowered.contains("not found") || lowered.contains("unavailable"))
      {
        return .modelUnavailable
      }
      return .provider(status: statusCode, message: message)
    }
  }

  func responseMetadata(
    headers: [String: String],
    decoded: ChatCompletionResponse?
  ) -> [String: String] {
    var metadata: [String: String] = [:]
    if let value = header("X-Generation-Id", in: headers) {
      metadata["generationID"] = value
    }
    if let value = decoded?.provider {
      metadata["provider"] = value
    }
    return metadata
  }

  func header(_ name: String, in headers: [String: String]) -> String? {
    headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
  }

  func mergeModels(
    seed: [ProviderModel],
    discovered: [ProviderModel]
  ) -> [ProviderModel] {
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
