import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Native OpenAI Responses API adapter.
///
/// BYOKchat deliberately manages conversation history locally and sends
/// `store: false`. OpenAI reasoning/output items are therefore round-tripped
/// through `ProviderToolContinuation` so stateless tool turns and later turns
/// can replay the opaque provider state without interpreting it.
public struct OpenAIResponsesAdapter: ProviderAdapter, Sendable {
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
    let control = ModelCapabilityResolver.reasoningControl(kind: .openai, modelID: model)
    let probeReasoning: ReasoningOptions?
    let probeMaxTokens: Int
    if control.allowsOff {
      probeReasoning = .init(enabled: false)
      probeMaxTokens = 256
    } else if control.kind == .efforts, let lowest = control.efforts.first {
      probeReasoning = .init(enabled: true, effort: lowest, excludeFromResponse: true)
      probeMaxTokens = 1_024
    } else if control.kind == .fixed {
      probeReasoning = nil
      probeMaxTokens = 1_024
    } else {
      probeReasoning = .init(enabled: false)
      probeMaxTokens = 256
    }

    _ = try await generate(
      request: ProviderRequest(
        model: model,
        messages: [.init(role: .user, content: "Return exactly OK.")],
        options: .init(
          maxOutputTokens: probeMaxTokens,
          reasoning: probeReasoning
        )
      ),
      account: account
    )
  }

  public func listModels(account: ResolvedProviderAccount) async throws -> [ProviderModel] {
    // OpenAI's /models payload is compatible with the generic model-list envelope,
    // but it also contains embedding, image, audio, transcription, and realtime
    // models that cannot be used as normal chat targets.
    let models = try await OpenAICompatibleAdapter(definition: definition, transport: transport)
      .listModels(account: account)
    let seedIDs = Set(definition.seedModels.map(\.id))
    return models.compactMap { model in
      guard seedIDs.contains(model.id) || isResponsesChatModelID(model.id.rawValue) else {
        return nil
      }
      return enrichDiscoveredModel(model)
    }
  }

  public func generate(request: ProviderRequest, account: ResolvedProviderAccount) async throws
    -> ProviderResponse
  {
    let validated = try validateRequest(request, account: account)
    let url = try ProviderHTTP.endpoint(
      baseURL: account.baseURLOverride ?? definition.defaultBaseURL,
      path: definition.chatCompletionsPath,
      allowsLocalHTTP: definition.allowsLocalHTTP
    )
    var urlRequest = try compatibility.makeRequest(
      url: url, method: "POST", account: account, acceptsEventStream: false)
    urlRequest.httpBody = try JSONEncoder.providerEncoder.encode(
      JSONValue.object(try requestBody(validated, streaming: false))
    )

    let response = try await transport.data(for: urlRequest)
    try compatibility.validate(response)
    let root = try decodeJSON(response.data)
    return try parseResponse(
      root,
      account: account,
      fallbackModel: validated.model,
      headers: response.headers
    )
  }

  public func stream(request: ProviderRequest, account: ResolvedProviderAccount)
    -> AsyncThrowingStream<ProviderStreamEvent, Error>
  {
    AsyncThrowingStream { continuation in
      let task = Task { @Sendable in
        do {
          let validated = try validateRequest(request, account: account)
          let url = try ProviderHTTP.endpoint(
            baseURL: account.baseURLOverride ?? definition.defaultBaseURL,
            path: definition.chatCompletionsPath,
            allowsLocalHTTP: definition.allowsLocalHTTP
          )
          var urlRequest = try compatibility.makeRequest(
            url: url, method: "POST", account: account, acceptsEventStream: true)
          urlRequest.httpBody = try JSONEncoder.providerEncoder.encode(
            JSONValue.object(try requestBody(validated, streaming: true))
          )

          let stream = try await transport.stream(for: urlRequest)
          guard (200..<300).contains(stream.statusCode) else {
            var data = Data()
            for try await chunk in stream.chunks { data.append(chunk) }
            throw compatibility.mapHTTPError(
              status: stream.statusCode, headers: stream.headers, data: data)
          }

          var decoder = SSEDecoder()
          var visibleText = ""
          var reasoningSummary = ""
          var finalResponse: ProviderResponse?

          for try await chunk in stream.chunks {
            try Task.checkCancellation()
            for event in try decoder.append(chunk) {
              try processStreamEvent(
                event,
                account: account,
                fallbackModel: validated.model,
                headers: stream.headers,
                continuation: continuation,
                visibleText: &visibleText,
                reasoningSummary: &reasoningSummary,
                finalResponse: &finalResponse
              )
            }
          }
          for event in try decoder.finish() {
            try processStreamEvent(
              event,
              account: account,
              fallbackModel: validated.model,
              headers: stream.headers,
              continuation: continuation,
              visibleText: &visibleText,
              reasoningSummary: &reasoningSummary,
              finalResponse: &finalResponse
            )
          }

          guard var response = finalResponse else {
            throw ProviderError.prematureStreamEnd
          }
          if !visibleText.isEmpty { response.text = visibleText }
          if !reasoningSummary.isEmpty { response.reasoning = reasoningSummary }
          guard
            !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || !response.reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || !response.toolCalls.isEmpty
          else {
            throw ProviderError.emptyOutput
          }
          continuation.yield(.completed(response))
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
  }

  private var compatibility: OpenAICompatibleAdapter {
    OpenAICompatibleAdapter(definition: definition, transport: transport)
  }

  private func isResponsesChatModelID(_ modelID: String) -> Bool {
    let value = modelID.lowercased()
    let excludedFragments = [
      "realtime", "transcribe", "tts", "embedding", "moderation", "image", "audio",
      "whisper", "dall-e", "sora", "instruct", "search-preview", "search-api",
    ]
    if excludedFragments.contains(where: { fragment in value.contains(fragment) }) { return false }

    return value.hasPrefix("gpt-")
      || value.hasPrefix("chatgpt-")
      || value.hasPrefix("o1")
      || value.hasPrefix("o3")
      || value.hasPrefix("o4")
      || value.hasPrefix("codex-")
  }

  private func enrichDiscoveredModel(_ model: ProviderModel) -> ProviderModel {
    var result = model
    if let seed = definition.seedModels.first(where: { $0.id == model.id }) {
      result = result.mergingCapabilities(from: seed)
      if result.displayName == result.id.rawValue { result.displayName = seed.displayName }
    }

    result.supportedParameters.insert("max_output_tokens")
    result.supportedParameters.insert("tools")
    if modelSupportsReasoning(model.id.rawValue) {
      result.supportedParameters.insert("reasoning")
    } else {
      result.supportedParameters.insert("temperature")
      result.supportedParameters.insert("top_p")
    }
    return result
  }

  // MARK: - Request mapping

  private func validateRequest(
    _ request: ProviderRequest,
    account: ResolvedProviderAccount
  ) throws -> ProviderRequest {
    let request = try ModelRequestPolicy.prepare(request, kind: definition.capabilityKind)
    let model = request.model.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !model.isEmpty else { throw ProviderError.invalidModel }
    if definition.authentication != .none {
      guard let key = account.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty
      else {
        throw ProviderError.missingCredential(definition.id)
      }
    }

    var messages: [ProviderMessage] = []
    messages.reserveCapacity(request.messages.count)
    for message in request.messages {
      let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
      let attachments = message.attachments ?? []
      let toolCalls = message.toolCalls ?? []
      let toolResults = message.toolResults ?? []
      let continuation = message.toolContinuation
      guard
        !content.isEmpty || !attachments.isEmpty || !toolCalls.isEmpty || !toolResults.isEmpty
          || continuation != nil
      else { continue }
      try validateAttachments(attachments)
      messages.append(
        ProviderMessage(
          role: message.role,
          content: content,
          reasoning: message.reasoning,
          attachments: attachments.isEmpty ? nil : attachments,
          toolCalls: toolCalls.isEmpty ? nil : toolCalls,
          toolResults: toolResults.isEmpty ? nil : toolResults,
          toolContinuation: continuation
        )
      )
    }
    guard !messages.isEmpty else { throw ProviderError.invalidMessages }

    var toolNames: Set<String> = []
    for tool in request.tools {
      let name = tool.name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else {
        throw ProviderError.invalidRequest("Tool name cannot be empty.")
      }
      guard toolNames.insert(name).inserted else {
        throw ProviderError.invalidRequest("Duplicate tool name: \(name)")
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
      throw ProviderError.invalidRequest(
        "Each attachment must be non-empty and no larger than 20 MB."
      )
    }
    guard attachments.reduce(0, { $0 + $1.byteCount }) <= 40 * 1_024 * 1_024 else {
      throw ProviderError.invalidRequest("Attachments in one message cannot exceed 40 MB total.")
    }
    let supportedImageMIMEs: Set<String> = [
      "image/png", "image/jpeg", "image/webp", "image/gif",
    ]
    if let unsupported = attachments.first(where: {
      $0.isImage && !supportedImageMIMEs.contains($0.mimeType.lowercased())
    }) {
      throw ProviderError.invalidRequest(
        "Unsupported image type for \(unsupported.filename). Use PNG, JPEG, WebP, or GIF."
      )
    }
  }

  private func requestBody(_ request: ProviderRequest, streaming: Bool) throws
    -> [String: JSONValue]
  {
    var input: [JSONValue] = []
    for message in request.messages {
      input.append(contentsOf: try inputValues(for: message))
    }

    var body: [String: JSONValue] = [
      "model": .string(request.model.rawValue),
      "input": .array(input),
      "store": .bool(false),
      "stream": .bool(streaming),
    ]
    if modelSupportsReasoning(request.model.rawValue) {
      // Required to replay reasoning items when BYOKchat manages history locally.
      body["include"] = .array([.string("reasoning.encrypted_content")])
    }

    if !request.tools.isEmpty {
      body["tools"] = .array(request.tools.map(toolValue))
    }
    if let maxOutputTokens = request.options.maxOutputTokens {
      body["max_output_tokens"] = .number(Double(maxOutputTokens))
    }

    let reasoning = reasoningValue(request.options.reasoning, control: request.capabilities?.reasoning
      ?? ModelCapabilityResolver.reasoningControl(kind: .openai, modelID: request.model))
    if let reasoning { body["reasoning"] = reasoning }

    if supportsSamplingControls(model: request.model.rawValue, reasoning: reasoning) {
      if let value = request.options.temperature { body["temperature"] = .number(value) }
      if let value = request.options.topP { body["top_p"] = .number(value) }
    }
    return body
  }

  private func inputValues(for message: ProviderMessage) throws -> [JSONValue] {
    if message.role == .tool {
      return (message.toolResults ?? []).map { result in
        .object([
          "type": .string("function_call_output"),
          "call_id": .string(result.callID),
          "output": .string(result.content.compactJSONString()),
        ])
      }
    }

    if message.role == .assistant,
      let continuation = message.toolContinuation,
      continuation.apiFamily == .openAIResponses,
      case .array(let values) = continuation.payload
    {
      return values
    }

    var values: [JSONValue] = []
    var contentParts: [JSONValue] = []
    let textPartType = message.role == .assistant ? "output_text" : "input_text"
    if !message.content.isEmpty {
      contentParts.append(
        .object([
          "type": .string(textPartType),
          "text": .string(message.content),
        ])
      )
    }

    for attachment in message.attachments ?? [] {
      if message.role == .assistant {
        if let text = attachment.utf8Text {
          contentParts.append(.object([
            "type": .string("output_text"),
            "text": .string("File: \(attachment.filename)\n\n\(text)"),
          ]))
        }
        continue
      }
      if attachment.isImage {
        contentParts.append(
          .object([
            "type": .string("input_image"),
            "image_url": .string(attachment.dataURL),
            "detail": .string("auto"),
          ])
        )
      } else if let text = attachment.utf8Text {
        contentParts.append(.object([
          "type": .string("input_text"),
          "text": .string("File: \(attachment.filename)\n\n\(text)"),
        ]))
      } else {
        var fileObject: [String: JSONValue] = [
          "type": .string("input_file"),
          "filename": .string(attachment.filename),
          "file_data": .string(attachment.dataURL),
        ]
        if attachment.mimeType.lowercased() == "application/pdf" {
          fileObject["detail"] = .string("auto")
        }
        contentParts.append(.object(fileObject))
      }
    }

    if !contentParts.isEmpty {
      values.append(
        .object([
          "type": .string("message"),
          "role": .string(message.role.rawValue),
          "content": .array(contentParts),
        ])
      )
    }

    // Imported/legacy histories may have normalized tool calls without a raw
    // Responses continuation. Reconstruct the minimum valid function-call items.
    if message.role == .assistant {
      for call in message.toolCalls ?? [] {
        values.append(
          .object([
            "type": .string("function_call"),
            "call_id": .string(call.id),
            "name": .string(call.name),
            "arguments": .string(call.arguments.compactJSONString()),
          ])
        )
      }
    }
    return values
  }

  private func toolValue(_ tool: ChatToolDefinition) -> JSONValue {
    .object([
      "type": .string("function"),
      "name": .string(tool.name),
      "description": .string(tool.description),
      "parameters": tool.inputSchema,
      // Provider-neutral MCP schemas are not guaranteed to meet OpenAI strict-mode rules.
      "strict": .bool(false),
    ])
  }

  private func reasoningValue(_ options: ReasoningOptions?, control: ModelReasoningControl) -> JSONValue? {
    guard let options = control.normalize(options) else { return nil }
    var object: [String: JSONValue] = [:]
    if options.enabled == false {
      guard let wire = control.offWireValue else { return nil }
      object["effort"] = .string(wire)
    } else {
      if let effort = options.effort { object["effort"] = .string(effort.rawValue) }
      if !options.excludeFromResponse { object["summary"] = .string("auto") }
    }
    return object.isEmpty ? nil : .object(object)
  }

  private func modelSupportsReasoning(_ model: String) -> Bool {
    let control = ModelCapabilityResolver.reasoningControl(kind: .openai, modelID: ModelID(rawValue: model))
    return control.kind != .unknown && control.kind != .unsupported
  }

  private func supportsSamplingControls(model: String, reasoning: JSONValue?) -> Bool {
    guard modelSupportsReasoning(model) else { return true }

    // Reasoning models that support effort `none` (such as GPT-5.1/5.2/5.4/5.5/5.6,
    // GPT-6.1 Terra, and GPT-6 Luna) accept sampling controls only when reasoning
    // is explicitly disabled with effort `none`. Models that reject `none`
    // (GPT-6 Astra/Sol, GPT-6.1/6.2 Sol, GPT-6.2 Astra, O-series, Codex) never
    // reach `effort == "none"`.
    guard case .object(let object)? = reasoning,
      case .string(let effort)? = object["effort"]
    else {
      return false
    }
    return effort == "none"
  }

  // MARK: - Response mapping

  private func parseResponse(
    _ root: JSONValue,
    account: ResolvedProviderAccount,
    fallbackModel: ModelID,
    headers: [String: String]
  ) throws -> ProviderResponse {
    guard case .object(let object) = root else { throw ProviderError.invalidResponse }

    if case .object(let error)? = object["error"] {
      let message = error["message"]?.stringValue ?? "OpenAI returned an error."
      throw ProviderError.provider(status: 200, message: message)
    }

    let output = object["output"]?.arrayValue ?? []
    var text = ""
    var reasoning = ""
    var toolCalls: [ChatToolCall] = []

    for item in output {
      guard case .object(let value) = item else { continue }
      switch value["type"]?.stringValue {
      case "message":
        for part in value["content"]?.arrayValue ?? [] {
          guard case .object(let content) = part else { continue }
          switch content["type"]?.stringValue {
          case "output_text":
            text += content["text"]?.stringValue ?? ""
          case "refusal":
            text += content["refusal"]?.stringValue ?? ""
          default:
            break
          }
        }
      case "reasoning":
        var summaryParts: [String] = []
        for part in value["summary"]?.arrayValue ?? [] {
          guard case .object(let summary) = part else { continue }
          if summary["type"]?.stringValue == "summary_text",
            let summaryText = summary["text"]?.stringValue,
            !summaryText.isEmpty
          {
            summaryParts.append(summaryText)
          }
        }
        if !summaryParts.isEmpty {
          let joined = summaryParts.joined(separator: "\n\n")
          if !reasoning.isEmpty { reasoning += "\n\n" }
          reasoning += joined
        }
      case "function_call":
        guard let name = value["name"]?.stringValue, !name.isEmpty,
          let callID = value["call_id"]?.stringValue ?? value["id"]?.stringValue,
          !callID.isEmpty
        else {
          throw ProviderError.invalidResponse
        }
        let arguments = try JSONValue.parseJSONString(value["arguments"]?.stringValue ?? "{}")
        toolCalls.append(.init(id: callID, name: name, arguments: arguments))
      default:
        break
      }
    }

    let status = object["status"]?.stringValue
    if status == "failed" || status == "cancelled" {
      let message = object["error"]?.objectValue?["message"]?.stringValue
        ?? "OpenAI response \(status ?? "failed")."
      throw ProviderError.provider(status: 200, message: message)
    }

    let incompleteReason = object["incomplete_details"]?.objectValue?["reason"]?.stringValue
    guard
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !toolCalls.isEmpty
    else {
      if status == "incomplete", let incompleteReason {
        switch incompleteReason {
        case "content_filter":
          throw ProviderError.provider(
            status: 200,
            message: "OpenAI blocked this response due to content filtering."
          )
        case "max_output_tokens":
          throw ProviderError.provider(
            status: 200,
            message: "OpenAI reached the maximum output token limit before producing a visible response."
          )
        default:
          throw ProviderError.provider(
            status: 200,
            message: "OpenAI response was incomplete (\(incompleteReason))."
          )
        }
      }
      throw ProviderError.emptyOutput
    }

    let usage = usageValue(object["usage"])
    let finishReason: String? = {
      if let incompleteReason { return incompleteReason }
      if !toolCalls.isEmpty { return "tool_calls" }
      if status == "completed" { return "stop" }
      return status
    }()

    var metadata: [String: String] = [:]
    if let requestID = compatibility.header("x-request-id", headers) {
      metadata["requestID"] = requestID
    }
    if let responseID = object["id"]?.stringValue { metadata["responseID"] = responseID }
    if let tier = object["service_tier"]?.stringValue, !["default", "standard", "auto"].contains(tier) {
      metadata[ChatBilling.unsupportedContextKey] = "service tier: " + tier
    }

    let providerContinuation: ProviderToolContinuation? = output.isEmpty
      ? nil
      : .init(apiFamily: .openAIResponses, payload: .array(output))

    return ProviderResponse(
      id: object["id"]?.stringValue,
      text: text,
      reasoning: reasoning,
      providerID: definition.id,
      accountID: account.id,
      modelID: ModelID(rawValue: object["model"]?.stringValue ?? fallbackModel.rawValue),
      finishReason: finishReason,
      usage: usage,
      metadata: metadata,
      toolCalls: toolCalls,
      toolContinuation: providerContinuation
    )
  }

  private func usageValue(_ value: JSONValue?) -> ProviderUsage? {
    guard case .object(let usage)? = value else { return nil }
    let inputDetails = usage["input_tokens_details"]?.objectValue
    let cacheWriteDetails = inputDetails?["cache_write_tokens_details"]?.objectValue
    return ProviderUsage(
      inputTokens: usage["input_tokens"]?.intValue,
      outputTokens: usage["output_tokens"]?.intValue,
      cachedInputTokens: inputDetails?["cached_tokens"]?.intValue,
      reasoningTokens: usage["output_tokens_details"]?.objectValue?["reasoning_tokens"]?.intValue,
      cacheWriteTokens: inputDetails?["cache_write_tokens"]?.intValue,
      longCacheWriteTokens: cacheWriteDetails?["ttl_12h_tokens"]?.intValue
    )
  }

  private func decodeJSON(_ data: Data) throws -> JSONValue {
    do {
      return try JSONDecoder.provider.decode(JSONValue.self, from: data)
    } catch {
      throw ProviderError.invalidResponse
    }
  }

  // MARK: - Streaming

  private func processStreamEvent(
    _ event: ServerSentEvent,
    account: ResolvedProviderAccount,
    fallbackModel: ModelID,
    headers: [String: String],
    continuation: AsyncThrowingStream<ProviderStreamEvent, Error>.Continuation,
    visibleText: inout String,
    reasoningSummary: inout String,
    finalResponse: inout ProviderResponse?
  ) throws {
    guard !event.data.isEmpty, event.data != "[DONE]",
      let data = event.data.data(using: .utf8)
    else { return }
    let root = try decodeJSON(data)
    guard case .object(let object) = root else { throw ProviderError.invalidResponse }
    let type = object["type"]?.stringValue ?? event.event

    switch type {
    case "response.output_text.delta", "response.refusal.delta":
      if let delta = object["delta"]?.stringValue, !delta.isEmpty {
        visibleText += delta
        continuation.yield(.textDelta(delta))
      }
    case "response.reasoning_summary_part.added":
      if !reasoningSummary.isEmpty {
        reasoningSummary += "\n\n"
        continuation.yield(.reasoningDelta("\n\n"))
      }
    case "response.reasoning_summary_text.delta":
      if let delta = object["delta"]?.stringValue, !delta.isEmpty {
        reasoningSummary += delta
        continuation.yield(.reasoningDelta(delta))
      }
    case "response.completed", "response.incomplete":
      guard let responseObject = object["response"] else {
        throw ProviderError.invalidResponse
      }
      let parsed = try parseResponse(
        responseObject,
        account: account,
        fallbackModel: fallbackModel,
        headers: headers
      )
      if let usage = parsed.usage { continuation.yield(.usage(usage)) }
      finalResponse = parsed
    case "response.failed":
      let response = object["response"]?.objectValue
      let error = response?["error"]?.objectValue
      throw ProviderError.midStreamProvider(
        code: error?["code"]?.stringValue,
        message: error?["message"]?.stringValue ?? "OpenAI response failed."
      )
    case "response.cancelled":
      let response = object["response"]?.objectValue
      let error = response?["error"]?.objectValue
      throw ProviderError.midStreamProvider(
        code: error?["code"]?.stringValue ?? "cancelled",
        message: error?["message"]?.stringValue ?? "OpenAI response was cancelled."
      )
    case "error":
      let error = object["error"]?.objectValue ?? object
      throw ProviderError.midStreamProvider(
        code: error["code"]?.stringValue,
        message: error["message"]?.stringValue ?? "OpenAI stream failed."
      )
    default:
      break
    }
  }
}

private extension JSONValue {
  var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  var arrayValue: [JSONValue]? {
    guard case .array(let value) = self else { return nil }
    return value
  }

  var intValue: Int? {
    guard case .number(let value) = self else { return nil }
    return Int(value)
  }
}
