import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct AnthropicMessagesAdapter: ProviderAdapter, Sendable {
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
    let request = try makeRequest(url: url, method: "GET", account: account, streaming: false)
    let response = try await transport.data(for: request)
    try validate(response)

    let decoded: AnthropicModelsResponse
    do {
      decoded = try JSONDecoder.provider.decode(AnthropicModelsResponse.self, from: response.data)
    } catch {
      throw ProviderError.invalidResponse
    }

    let discovered = decoded.data.map { wire in
      var modalities: Set<String> = ["text"]
      if wire.capabilities?.imageInput?.supported == true { modalities.insert("image") }
      if wire.capabilities?.pdfInput?.supported == true { modalities.insert("file") }
      var parameters: Set<String> = ["max_tokens"]
      if wire.capabilities?.thinking?.supported == true {
        parameters.formUnion(["thinking", "effort"])
      }
      return ProviderModel(
        providerID: definition.id,
        id: ModelID(rawValue: wire.id),
        displayName: wire.displayName ?? wire.id,
        contextWindow: wire.maxInputTokens.flatMap { $0 > 0 ? $0 : nil },
        maxOutputTokens: wire.maxTokens.flatMap { $0 > 0 ? $0 : nil },
        supportedParameters: parameters,
        inputModalities: modalities,
        outputModalities: ["text"],
        isSeed: false
      )
    }
    return mergeModels(seed: definition.seedModels, discovered: discovered)
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
    var urlRequest = try makeRequest(url: url, method: "POST", account: account, streaming: false)
    urlRequest.httpBody = try JSONEncoder.providerEncoder.encode(
      JSONValue.object(try requestBody(validated, streaming: false))
    )
    let response = try await transport.data(for: urlRequest)
    try validate(response)

    let decoded: AnthropicMessageResponse
    do {
      decoded = try JSONDecoder.provider.decode(AnthropicMessageResponse.self, from: response.data)
    } catch {
      throw ProviderError.invalidResponse
    }

    let text = decoded.content.compactMap { $0.type == "text" ? $0.text : nil }.joined()
    let reasoning = decoded.content.compactMap { $0.type == "thinking" ? $0.thinking : nil }.joined()
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
      finishReason: decoded.stopReason,
      usage: decoded.usage?.normalized
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
          var urlRequest = try makeRequest(url: url, method: "POST", account: account, streaming: true)
          urlRequest.httpBody = try JSONEncoder.providerEncoder.encode(
            JSONValue.object(try requestBody(validated, streaming: true))
          )
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
          var responseID: String?
          var modelID = validated.model
          var finishReason: String?
          var completed = false

          for try await chunk in stream.chunks {
            try Task.checkCancellation()
            for event in try decoder.append(chunk) {
              try process(
                event,
                continuation: continuation,
                text: &text,
                reasoning: &reasoning,
                usage: &usage,
                responseID: &responseID,
                modelID: &modelID,
                finishReason: &finishReason,
                completed: &completed
              )
            }
          }
          for event in try decoder.finish() {
            try process(
              event,
              continuation: continuation,
              text: &text,
              reasoning: &reasoning,
              usage: &usage,
              responseID: &responseID,
              modelID: &modelID,
              finishReason: &finishReason,
              completed: &completed
            )
          }

          guard completed else { throw ProviderError.prematureStreamEnd }
          guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                usage: usage
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

  private func process(
    _ event: ServerSentEvent,
    continuation: AsyncThrowingStream<ProviderStreamEvent, Error>.Continuation,
    text: inout String,
    reasoning: inout String,
    usage: inout ProviderUsage?,
    responseID: inout String?,
    modelID: inout ModelID,
    finishReason: inout String?,
    completed: inout Bool
  ) throws {
    guard let payload = event.data.data(using: .utf8) else { throw ProviderError.invalidResponse }
    let decoded: AnthropicStreamEvent
    do {
      decoded = try JSONDecoder.provider.decode(AnthropicStreamEvent.self, from: payload)
    } catch {
      throw ProviderError.invalidResponse
    }

    switch decoded.type {
    case "message_start":
      if let message = decoded.message {
        responseID = message.id ?? responseID
        if let model = message.model { modelID = ModelID(rawValue: model) }
        if let incoming = message.usage?.normalized {
          usage = mergeUsage(usage, incoming)
          continuation.yield(.usage(usage!))
        }
      }
    case "content_block_delta":
      guard let delta = decoded.delta else { return }
      if delta.type == "text_delta", let value = delta.text, !value.isEmpty {
        text += value
        continuation.yield(.textDelta(value))
      } else if delta.type == "thinking_delta", let value = delta.thinking, !value.isEmpty {
        reasoning += value
        continuation.yield(.reasoningDelta(value))
      }
    case "message_delta":
      if let stop = decoded.delta?.stopReason { finishReason = stop }
      if let incoming = decoded.usage?.normalized {
        usage = mergeUsage(usage, incoming)
        continuation.yield(.usage(usage!))
      }
    case "message_stop":
      completed = true
    case "error":
      throw ProviderError.midStreamProvider(
        code: decoded.error?.type,
        message: decoded.error?.message ?? "Anthropic stream failed."
      )
    case "ping", "content_block_start", "content_block_stop":
      break
    default:
      // Anthropic may add new event types without changing the API version.
      break
    }
  }

  private func validateRequest(_ request: ProviderRequest, account: ResolvedProviderAccount) throws
    -> ProviderRequest
  {
    let model = request.model.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !model.isEmpty else { throw ProviderError.invalidModel }
    guard account.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
      throw ProviderError.missingCredential(definition.id)
    }

    var messages: [ProviderMessage] = []
    for message in request.messages {
      let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
      let attachments = message.attachments ?? []
      guard !content.isEmpty || !attachments.isEmpty else { continue }
      if message.role == .system, !attachments.isEmpty {
        throw ProviderError.invalidRequest("Anthropic system messages cannot contain attachments.")
      }
      try validateAttachments(attachments)
      messages.append(
        .init(
          role: message.role,
          content: content,
          reasoning: message.reasoning,
          attachments: attachments.isEmpty ? nil : attachments
        )
      )
    }
    guard messages.contains(where: { $0.role != .system }) else {
      throw ProviderError.invalidMessages
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
    let imageMIMEs: Set<String> = ["image/jpeg", "image/png", "image/gif", "image/webp"]
    if let bad = attachments.first(where: { $0.isImage && !imageMIMEs.contains($0.mimeType.lowercased()) }) {
      throw ProviderError.invalidRequest("Unsupported Anthropic image type for \(bad.filename).")
    }
    if let bad = attachments.first(where: {
      !$0.isImage && $0.utf8Text == nil && $0.mimeType.lowercased() != "application/pdf"
    }) {
      throw ProviderError.invalidRequest(
        "Anthropic native file input currently supports text files, images, and PDFs. \(bad.filename) must be converted first."
      )
    }
  }

  func requestBody(_ request: ProviderRequest, streaming: Bool) throws -> [String: JSONValue] {
    var body: [String: JSONValue] = [
      "model": .string(request.model.rawValue),
      "max_tokens": .number(Double(request.options.maxOutputTokens ?? 4_096)),
      "messages": .array(try request.messages.filter { $0.role != .system }.map(messageValue)),
      "stream": .bool(streaming),
    ]

    let system = request.messages
      .filter { $0.role == .system }
      .map(\.content)
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")
    if !system.isEmpty { body["system"] = .string(system) }

    if let reasoning = request.options.reasoning {
      if reasoning.enabled == false {
        body["thinking"] = .object(["type": .string("disabled")])
      } else if reasoning.enabled == true || reasoning.effort != nil || reasoning.maxTokens != nil {
        body["thinking"] = .object([
          "type": .string("adaptive"),
          "display": .string(reasoning.excludeFromResponse ? "omitted" : "summarized"),
        ])
      }
      if let effort = reasoning.effort {
        let value = effort == .minimal ? "low" : effort.rawValue
        body["output_config"] = .object(["effort": .string(value)])
      }
    }
    return body
  }

  private func messageValue(_ message: ProviderMessage) throws -> JSONValue {
    let role = message.role == .assistant ? "assistant" : "user"
    let attachments = message.attachments ?? []
    if attachments.isEmpty {
      return .object(["role": .string(role), "content": .string(message.content)])
    }

    var blocks: [JSONValue] = []
    for attachment in attachments {
      if attachment.isImage {
        blocks.append(
          .object([
            "type": .string("image"),
            "source": .object([
              "type": .string("base64"),
              "media_type": .string(attachment.mimeType.lowercased()),
              "data": .string(attachment.data.base64EncodedString()),
            ]),
          ])
        )
      } else if attachment.mimeType.lowercased() == "application/pdf" {
        blocks.append(
          .object([
            "type": .string("document"),
            "source": .object([
              "type": .string("base64"),
              "media_type": .string("application/pdf"),
              "data": .string(attachment.data.base64EncodedString()),
            ]),
          ])
        )
      } else if let text = attachment.utf8Text {
        blocks.append(
          .object([
            "type": .string("text"),
            "text": .string("File: \(attachment.filename)\n\n\(text)"),
          ])
        )
      }
    }
    if !message.content.isEmpty {
      blocks.append(.object(["type": .string("text"), "text": .string(message.content)]))
    }
    return .object(["role": .string(role), "content": .array(blocks)])
  }

  private func makeRequest(
    url: URL,
    method: String,
    account: ResolvedProviderAccount,
    streaming: Bool
  ) throws -> URLRequest {
    var request = try ProviderHTTP.makeRequest(
      url: url,
      method: method,
      authentication: definition.authentication,
      secret: account.apiKey,
      additionalHeaders: account.additionalHeaders
    )
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    if streaming { request.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
    return request
  }

  private func validate(_ response: ProviderHTTPResponse) throws {
    guard (200..<300).contains(response.statusCode) else {
      throw mapHTTPError(status: response.statusCode, headers: response.headers, data: response.data)
    }
  }

  private func mapHTTPError(status: Int, headers: [String: String], data: Data) -> ProviderError {
    let envelope = try? JSONDecoder.provider.decode(AnthropicErrorEnvelope.self, from: data)
    let message = envelope?.error?.message ?? HTTPURLResponse.localizedString(forStatusCode: status)
    let lowered = message.lowercased()
    switch status {
    case 401: return .authenticationFailed
    case 403: return .permissionDenied
    case 404 where lowered.contains("model"): return .modelUnavailable
    case 404: return .invalidEndpoint
    case 429: return .rateLimited(retryAfter: header("Retry-After", headers))
    default:
      if lowered.contains("credit") || lowered.contains("billing") || lowered.contains("quota") {
        return .insufficientCredits
      }
      return .provider(status: status, message: message)
    }
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
        merged.inputModalities.formUnion(existing.inputModalities)
        values[model.id] = merged
      } else {
        values[model.id] = model
      }
    }
    return values.values.sorted {
      $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
  }

  private func mergeUsage(_ current: ProviderUsage?, _ incoming: ProviderUsage) -> ProviderUsage {
    ProviderUsage(
      inputTokens: incoming.inputTokens ?? current?.inputTokens,
      outputTokens: incoming.outputTokens ?? current?.outputTokens,
      cachedInputTokens: incoming.cachedInputTokens ?? current?.cachedInputTokens,
      reasoningTokens: incoming.reasoningTokens ?? current?.reasoningTokens
    )
  }
}

private struct AnthropicModelsResponse: Decodable {
  var data: [AnthropicModelWire]
}

private struct AnthropicModelWire: Decodable {
  var id: String
  var displayName: String?
  var maxInputTokens: Int?
  var maxTokens: Int?
  var capabilities: AnthropicModelCapabilities?

  enum CodingKeys: String, CodingKey {
    case id, capabilities
    case displayName = "display_name"
    case maxInputTokens = "max_input_tokens"
    case maxTokens = "max_tokens"
  }
}

private struct AnthropicModelCapabilities: Decodable {
  var imageInput: AnthropicCapability?
  var pdfInput: AnthropicCapability?
  var thinking: AnthropicCapability?

  enum CodingKeys: String, CodingKey {
    case imageInput = "image_input"
    case pdfInput = "pdf_input"
    case thinking
  }
}

private struct AnthropicCapability: Decodable {
  var supported: Bool?
}

private struct AnthropicMessageResponse: Decodable {
  var id: String?
  var model: String?
  var content: [AnthropicContentBlock]
  var stopReason: String?
  var usage: AnthropicUsage?

  enum CodingKeys: String, CodingKey {
    case id, model, content, usage
    case stopReason = "stop_reason"
  }
}

private struct AnthropicContentBlock: Decodable {
  var type: String
  var text: String?
  var thinking: String?
}

private struct AnthropicUsage: Decodable {
  var inputTokens: Int?
  var outputTokens: Int?
  var cacheCreationInputTokens: Int?
  var cacheReadInputTokens: Int?
  var outputTokensDetails: AnthropicOutputTokenDetails?

  enum CodingKeys: String, CodingKey {
    case inputTokens = "input_tokens"
    case outputTokens = "output_tokens"
    case cacheCreationInputTokens = "cache_creation_input_tokens"
    case cacheReadInputTokens = "cache_read_input_tokens"
    case outputTokensDetails = "output_tokens_details"
  }

  var normalized: ProviderUsage {
    let totalInput = (inputTokens ?? 0) + (cacheCreationInputTokens ?? 0) + (cacheReadInputTokens ?? 0)
    return ProviderUsage(
      inputTokens: totalInput == 0 ? inputTokens : totalInput,
      outputTokens: outputTokens,
      cachedInputTokens: cacheReadInputTokens,
      reasoningTokens: outputTokensDetails?.thinkingTokens
    )
  }
}

private struct AnthropicOutputTokenDetails: Decodable {
  var thinkingTokens: Int?
  enum CodingKeys: String, CodingKey { case thinkingTokens = "thinking_tokens" }
}

private struct AnthropicStreamEvent: Decodable {
  var type: String
  var message: AnthropicStreamMessage?
  var delta: AnthropicStreamDelta?
  var usage: AnthropicUsage?
  var error: AnthropicAPIError?
}

private struct AnthropicStreamMessage: Decodable {
  var id: String?
  var model: String?
  var usage: AnthropicUsage?
}

private struct AnthropicStreamDelta: Decodable {
  var type: String?
  var text: String?
  var thinking: String?
  var stopReason: String?

  enum CodingKeys: String, CodingKey {
    case type, text, thinking
    case stopReason = "stop_reason"
  }
}

private struct AnthropicAPIError: Decodable {
  var type: String?
  var message: String
}

private struct AnthropicErrorEnvelope: Decodable {
  var error: AnthropicAPIError?
}
