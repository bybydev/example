import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

extension OpenAICompatibleAdapter {
  func validate(request: ProviderRequest, account: ResolvedProviderAccount) throws
    -> ProviderRequest
  {
    let model = request.model.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !model.isEmpty else { throw ProviderError.invalidModel }
    let messages = request.messages.compactMap { message -> ProviderMessage? in
      let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
      let attachments = message.attachments ?? []
      guard !content.isEmpty || !attachments.isEmpty else { return nil }
      return .init(
        role: message.role,
        content: content,
        reasoning: message.reasoning,
        attachments: attachments.isEmpty ? nil : attachments
      )
    }
    guard !messages.isEmpty else { throw ProviderError.invalidMessages }

    for message in messages {
      try validateAttachments(message.attachments ?? [])
    }

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

  private func validateAttachments(_ attachments: [ChatAttachment]) throws {
    guard attachments.count <= 8 else {
      throw ProviderError.invalidRequest("A message can include at most 8 attachments.")
    }
    guard attachments.allSatisfy({ !$0.data.isEmpty && $0.byteCount <= 20 * 1_024 * 1_024 }) else {
      throw ProviderError.invalidRequest("Each attachment must be non-empty and no larger than 20 MB.")
    }
    guard attachments.reduce(0, { $0 + $1.byteCount }) <= 40 * 1_024 * 1_024 else {
      throw ProviderError.invalidRequest("Attachments in one message cannot exceed 40 MB total.")
    }

    let supportedImageMIMEs: Set<String> = [
      "image/png", "image/jpeg", "image/webp", "image/gif",
    ]
    if let unsupportedImage = attachments.first(where: {
      $0.isImage && !supportedImageMIMEs.contains($0.mimeType.lowercased())
    }) {
      throw ProviderError.invalidRequest(
        "Unsupported image type for \(unsupportedImage.filename). Use PNG, JPEG, WebP, or GIF."
      )
    }

    if definition.behavior == .deepSeek {
      if attachments.contains(where: \.isImage) {
        throw ProviderError.invalidRequest(
          "DeepSeek V4 is text-only and cannot receive images. Choose a vision-capable model or provider before sending."
        )
      }
      if attachments.contains(where: { !$0.isImage && $0.utf8Text == nil }) {
        throw ProviderError.invalidRequest(
          "DeepSeek V4 is text-only and cannot receive binary documents directly. Attach a text file or choose a file-capable model before sending."
        )
      }
    }
  }

  func makeRequest(
    url: URL, method: String, account: ResolvedProviderAccount, acceptsEventStream: Bool
  ) throws -> URLRequest {
    var headers = account.additionalHeaders
    if definition.behavior == .openRouter {
      headers["X-OpenRouter-Metadata"] = "enabled"
      if let value = account.metadata["httpReferer"], !value.isEmpty {
        headers["HTTP-Referer"] = value
      }
      if let value = account.metadata["appTitle"], !value.isEmpty {
        headers["X-Title"] = value
      }
    }
    var request = try ProviderHTTP.makeRequest(
      url: url,
      method: method,
      authentication: definition.authentication,
      secret: account.apiKey,
      additionalHeaders: headers
    )
    if acceptsEventStream {
      request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    }
    return request
  }

  func requestBody(_ request: ProviderRequest, streaming: Bool) -> [String: JSONValue] {
    var body: [String: JSONValue] = [
      "model": .string(request.model.rawValue),
      "messages": .array(request.messages.map(requestMessage)),
      "stream": .bool(streaming),
    ]

    let deepSeekThinkingEnabled =
      definition.behavior == .deepSeek && request.options.reasoning?.enabled != false
    if !deepSeekThinkingEnabled {
      if let value = request.options.temperature { body["temperature"] = .number(value) }
      if let value = request.options.topP { body["top_p"] = .number(value) }
    }
    if let value = request.options.maxOutputTokens {
      body["max_tokens"] = .number(Double(value))
    }

    switch definition.behavior {
    case .deepSeek:
      if let reasoning = request.options.reasoning {
        if let enabled = reasoning.enabled {
          body["thinking"] = .object(["type": .string(enabled ? "enabled" : "disabled")])
        }
        if reasoning.enabled != false, let effort = reasoning.effort {
          body["reasoning_effort"] = .string(effort == .max ? "max" : "high")
        }
      }
      if streaming {
        body["stream_options"] = .object(["include_usage": .bool(true)])
      }
    case .openRouter:
      if let reasoning = request.options.reasoning {
        var object: [String: JSONValue] = [:]
        if let value = reasoning.enabled { object["enabled"] = .bool(value) }
        if let value = reasoning.effort { object["effort"] = .string(value.rawValue) }
        if let value = reasoning.maxTokens {
          object["max_tokens"] = .number(Double(value))
        }
        if reasoning.excludeFromResponse { object["exclude"] = .bool(true) }
        if !object.isEmpty { body["reasoning"] = .object(object) }
      }
      if let routing = request.options.openRouterRouting {
        var object: [String: JSONValue] = [:]
        if !routing.providerOrder.isEmpty {
          object["order"] = .array(routing.providerOrder.map(JSONValue.string))
        }
        if let value = routing.allowFallbacks {
          object["allow_fallbacks"] = .bool(value)
        }
        if let value = routing.requireParameters {
          object["require_parameters"] = .bool(value)
        }
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
    case .nvidia, .anthropic, .gemini, .genericOpenAICompatible:
      break
    }
    return body
  }

  private func requestMessage(_ message: ProviderMessage) -> JSONValue {
    let attachments = message.attachments ?? []
    guard !attachments.isEmpty else {
      return .object([
        "role": .string(message.role.rawValue),
        "content": .string(message.content),
      ])
    }

    var parts: [JSONValue] = []
    if !message.content.isEmpty {
      parts.append(.object(["type": .string("text"), "text": .string(message.content)]))
    }

    for attachment in attachments {
      if attachment.isImage {
        parts.append(
          .object([
            "type": .string("image_url"),
            "image_url": .object(["url": .string(attachment.dataURL)]),
          ])
        )
      } else if let text = attachment.utf8Text {
        parts.append(
          .object([
            "type": .string("text"),
            "text": .string("File: \(attachment.filename)\n\n\(text)"),
          ])
        )
      } else {
        parts.append(
          .object([
            "type": .string("file"),
            "file": .object([
              "filename": .string(attachment.filename),
              "file_data": .string(attachment.dataURL),
            ]),
          ])
        )
      }
    }

    return .object([
      "role": .string(message.role.rawValue),
      "content": .array(parts),
    ])
  }

  func validate(_ response: ProviderHTTPResponse) throws {
    guard (200..<300).contains(response.statusCode) else {
      throw mapHTTPError(
        status: response.statusCode, headers: response.headers, data: response.data)
    }
  }

  func mapHTTPError(status: Int, headers: [String: String], data: Data) -> ProviderError {
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

  func responseMetadata(_ headers: [String: String], _ decoded: ChatCompletionResponse?)
    -> [String: String]
  {
    var metadata: [String: String] = [:]
    if let value = header("X-Generation-Id", headers) {
      metadata["generationID"] = value
    }
    if let value = decoded?.provider { metadata["provider"] = value }
    return metadata
  }

  func header(_ name: String, _ headers: [String: String]) -> String? {
    headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
  }

  func mergeModels(seed: [ProviderModel], discovered: [ProviderModel]) -> [ProviderModel] {
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
