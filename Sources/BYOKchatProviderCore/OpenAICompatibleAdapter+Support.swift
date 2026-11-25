import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

extension OpenAICompatibleAdapter {
  func validate(request: ProviderRequest, account: ResolvedProviderAccount) throws
    -> ProviderRequest
  {
    let request = try ModelRequestPolicy.prepare(request, kind: definition.capabilityKind)
    let model = request.model.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !model.isEmpty else { throw ProviderError.invalidModel }
    let messages = request.messages.compactMap { message -> ProviderMessage? in
      let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
      let attachments = message.attachments ?? []
      let toolCalls = message.toolCalls ?? []
      let toolResults = message.toolResults ?? []
      guard
        !content.isEmpty || !attachments.isEmpty || !toolCalls.isEmpty || !toolResults.isEmpty
          || message.toolContinuation != nil
      else { return nil }
      return .init(
        role: message.role,
        content: content,
        reasoning: message.reasoning,
        attachments: attachments.isEmpty ? nil : attachments,
        toolCalls: toolCalls.isEmpty ? nil : toolCalls,
        toolResults: toolResults.isEmpty ? nil : toolResults,
        toolContinuation: message.toolContinuation
      )
    }
    guard !messages.isEmpty else { throw ProviderError.invalidMessages }

    for message in messages {
      try validateAttachments(message.attachments ?? [])
    }
    try validateTools(request.tools)

    if definition.requiresCredential {
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

  private func validateTools(_ tools: [ChatToolDefinition]) throws {
    var names: Set<String> = []
    for tool in tools {
      let name = tool.name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else {
        throw ProviderError.invalidRequest("Tool name cannot be empty.")
      }
      guard names.insert(name).inserted else {
        throw ProviderError.invalidRequest("Duplicate tool name: \(name)")
      }
    }
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

    if let unsupportedImage = attachments.first(where: {
      $0.isImage && !ModelRequestPolicy.supportsImageMIME($0.mimeType, for: .openAICompatible)
    }) {
      throw ProviderError.invalidRequest(
        "Unsupported image type for \(unsupportedImage.filename). Use PNG, JPEG, WebP, or GIF."
      )
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
        headers["X-OpenRouter-Title"] = value
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
    let hasTools = !request.tools.isEmpty
    let thinkingEnabled = request.options.reasoning?.enabled != false
    var body: [String: JSONValue] = [
      "model": .string(request.model.rawValue),
      "messages": .array(
        request.messages.flatMap {
          requestMessageValues($0, hasTools: hasTools, thinkingEnabled: thinkingEnabled)
        }
      ),
      "stream": .bool(streaming),
    ]

    if !request.tools.isEmpty {
      body["tools"] = .array(request.tools.map(toolValue))
    }

    let normalizedModelID = request.model.rawValue.lowercased().replacingOccurrences(of: "_", with: "-")
    let suppressesSamplingParameters =
      (definition.behavior == .deepSeek && request.options.reasoning?.enabled != false)
      || (definition.behavior == .moonshot
        && (normalizedModelID.hasPrefix("kimi-k3")
          || normalizedModelID.hasPrefix("kimi-k2.6")
          || normalizedModelID.hasPrefix("kimi-k2.5")))
    if !suppressesSamplingParameters {
      if let value = request.options.temperature {
        let temperature = definition.behavior == .minimax ? min(max(value, 0.01), 1.0) : value
        body["temperature"] = .number(temperature)
      }
      if let value = request.options.topP { body["top_p"] = .number(value) }
    }
    if let value = request.options.maxOutputTokens {
      if definition.behavior == .groq {
        body["max_completion_tokens"] = .number(Double(value))
      } else {
        body["max_tokens"] = .number(Double(value))
      }
    }

    switch definition.behavior {
    case .deepSeek, .zAI:
      if let reasoning = request.options.reasoning {
        if let enabled = reasoning.enabled {
          body["thinking"] = .object(["type": .string(enabled ? "enabled" : "disabled")])
        }
        if reasoning.enabled != false, let effort = reasoning.effort {
          body["reasoning_effort"] = .string(effort.rawValue)
        }
      }
      if streaming {
        body["stream_options"] = .object(["include_usage": .bool(true)])
      }
    case .moonshot:
      if let reasoning = request.options.reasoning {
        if reasoning.enabled == false {
          body["thinking"] = .object(["type": .string("disabled")])
        } else if let effort = reasoning.effort {
          body["reasoning_effort"] = .string(effort.rawValue)
        }
      }
      if streaming {
        body["stream_options"] = .object(["include_usage": .bool(true)])
      }
    case .minimax:
      if let reasoning = request.options.reasoning {
        if reasoning.enabled == false {
          body["thinking"] = .object(["type": .string("disabled")])
        } else if let effort = reasoning.effort {
          body["reasoning_effort"] = .string(effort.rawValue)
        } else if reasoning.enabled == true {
          body["thinking"] = .object(["type": .string("adaptive")])
        }
      }
      if streaming {
        body["stream_options"] = .object(["include_usage": .bool(true)])
      }
    case .qwen:
      if let reasoning = request.options.reasoning {
        if reasoning.enabled == false {
          body["enable_thinking"] = .bool(false)
        } else {
          body["enable_thinking"] = .bool(true)
          if let tokens = reasoning.maxTokens {
            body["thinking_budget"] = .number(Double(tokens))
          } else if let effort = reasoning.effort {
            body["reasoning_effort"] = .string(effort.rawValue)
          }
        }
      }
      if streaming {
        body["stream_options"] = .object(["include_usage": .bool(true)])
      }
    case .mistral:
      if let reasoning = request.options.reasoning {
        if reasoning.enabled == false {
          body["reasoning_effort"] = .string("none")
        } else if let effort = reasoning.effort {
          body["reasoning_effort"] = .string(effort.rawValue)
        }
      }
      if streaming {
        body["stream_options"] = .object(["include_usage": .bool(true)])
      }
    case .groq:
      let isGPTOSS = normalizedModelID.contains("gpt-oss")
      if let reasoning = request.options.reasoning {
        if reasoning.enabled == false {
          body["reasoning_effort"] = .string("none")
        } else if let effort = reasoning.effort {
          body["reasoning_effort"] = .string(effort.rawValue)
        }
        if isGPTOSS, reasoning.excludeFromResponse {
          body["include_reasoning"] = .bool(false)
        }
      }
      if !isGPTOSS,
        request.options.reasoning?.enabled != false,
        let capabilities = request.capabilities,
        capabilities.reasoning.kind != .unknown,
        capabilities.reasoning.kind != .unsupported
      {
        body["reasoning_format"] = .string(
          request.options.reasoning?.excludeFromResponse == true ? "hidden" : "parsed"
        )
      }
      if streaming {
        body["stream_options"] = .object(["include_usage": .bool(true)])
      }
    case .together:
      if let reasoning = request.options.reasoning {
        if reasoning.enabled == false {
          body["reasoning"] = .object(["enabled": .bool(false)])
        } else if let effort = reasoning.effort {
          body["reasoning_effort"] = .string(effort.rawValue)
        } else if reasoning.enabled == true {
          body["reasoning"] = .object(["enabled": .bool(true)])
        }
      }
      if streaming {
        body["stream_options"] = .object(["include_usage": .bool(true)])
      }
    case .fireworks:
      if let reasoning = request.options.reasoning {
        if reasoning.enabled == false {
          body["reasoning_effort"] = .string("none")
        } else if let effort = reasoning.effort {
          body["reasoning_effort"] = .string(effort.rawValue)
        }
      }
      if streaming {
        body["stream_options"] = .object(["include_usage": .bool(true)])
      }
    case .openRouter:
      if let reasoning = request.options.reasoning {
        var object: [String: JSONValue] = [:]
        if reasoning.enabled == false {
          object["enabled"] = .bool(false)
        } else {
          // OpenRouter treats reasoning.max_tokens and reasoning.effort as mutually exclusive.
          if let value = reasoning.maxTokens {
            object["max_tokens"] = .number(Double(value))
          } else if let value = reasoning.effort {
            object["effort"] = .string(value.rawValue)
          } else if reasoning.enabled == true {
            object["enabled"] = .bool(true)
          }
          if reasoning.excludeFromResponse { object["exclude"] = .bool(true) }
        }
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

  private func toolValue(_ tool: ChatToolDefinition) -> JSONValue {
    .object([
      "type": .string("function"),
      "function": .object([
        "name": .string(tool.name),
        "description": .string(tool.description),
        "parameters": tool.inputSchema,
      ]),
    ])
  }

  private func requestMessageValues(
    _ message: ProviderMessage,
    hasTools: Bool,
    thinkingEnabled: Bool
  ) -> [JSONValue] {
    if message.role == .tool {
      return (message.toolResults ?? []).map { result in
        var object: [String: JSONValue] = [
          "role": .string("tool"),
          "tool_call_id": .string(result.callID),
          "content": .string(result.content.compactJSONString()),
        ]
        if definition.behavior == .mistral {
          object["name"] = .string(result.name)
        }
        return .object(object)
      }
    }

    let attachments = message.attachments ?? []
    var object: [String: JSONValue] = ["role": .string(message.role.rawValue)]

    if attachments.isEmpty {
      if definition.behavior == .mistral {
        object["content"] = .string(message.content)
      } else {
        object["content"] = message.content.isEmpty ? .null : .string(message.content)
      }
    } else {
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
      object["content"] = .array(parts)
    }

    if definition.behavior == .openRouter,
      message.role == .assistant,
      let continuation = message.toolContinuation,
      continuation.apiFamily == .openAIChatCompletions,
      case .array(let reasoningDetails) = continuation.payload,
      !reasoningDetails.isEmpty
    {
      object["reasoning_details"] = .array(reasoningDetails)
    }

    if definition.behavior == .deepSeek, message.role == .assistant {
      let hasToolCalls = !(message.toolCalls ?? []).isEmpty
      if let reasoning = message.reasoning, !reasoning.isEmpty, hasToolCalls || hasTools {
        object["reasoning_content"] = .string(reasoning)
      } else if hasToolCalls, thinkingEnabled {
        object["reasoning_content"] = .string("")
      }
    }

    if let calls = message.toolCalls, !calls.isEmpty {
      if (definition.behavior == .moonshot || definition.behavior == .minimax
        || definition.behavior == .fireworks || definition.behavior == .nvidia),
        message.role == .assistant,
        let reasoning = message.reasoning,
        !reasoning.isEmpty
      {
        object["reasoning_content"] = .string(reasoning)
      }
      object["tool_calls"] = .array(calls.map { call in
        .object([
          "id": .string(call.id),
          "type": .string("function"),
          "function": .object([
            "name": .string(call.name),
            "arguments": .string(call.arguments.compactJSONString()),
          ]),
        ])
      })
    }

    return [.object(object)]
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
      decoded?.displayMessage
      ?? HTTPURLResponse.localizedString(forStatusCode: status)
    let lowered = message.lowercased()
    switch status {
    case 401: return .authenticationFailed
    case 402: return .insufficientCredits
    case 403: return .permissionDenied
    case 404 where lowered.contains("model")
      || (definition.behavior == .nvidia && lowered.contains("function")):
      return .modelUnavailable
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
    if definition.behavior == .openRouter, let cost = decoded?.usage?.cost?.value {
      metadata["openrouter.costUSD"] = ChatBilling.decimalString(cost)
      // BYOK usage.cost is the OpenRouter account charge. Upstream provider
      // billing has a separate scope; never silently call this a full total.
      if decoded?.usage?.isBYOK == true { metadata[ChatBilling.reportedCostCompleteKey] = "false" }
    }
    if let tier = decoded?.serviceTier, !["default", "standard", "auto"].contains(tier) {
      metadata[ChatBilling.unsupportedContextKey] = "service tier: " + tier
    }
    return metadata
  }

  func header(_ name: String, _ headers: [String: String]) -> String? {
    headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
  }

  func mergeModels(seed: [ProviderModel], discovered: [ProviderModel]) -> [ProviderModel] {
    var values = Dictionary(uniqueKeysWithValues: seed.map { ($0.id, $0) })
    for model in discovered {
      if let existing = values[model.id] {
        values[model.id] = model.mergingCapabilities(from: existing)
      } else {
        values[model.id] = model
      }
    }
    return values.values.sorted {
      $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
  }
}
