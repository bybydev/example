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

  public static func defaultMaxTokens(
    reasoning: ReasoningOptions?,
    capabilities: ResolvedModelCapabilities?
  ) -> Int {
    let reasoningActive =
      reasoning?.enabled == true || reasoning?.effort != nil || reasoning?.maxTokens != nil
    let preferred = reasoningActive ? 16_384 : 4_096
    if let modelMaximum = capabilities?.maxOutputTokens, modelMaximum > 0 {
      return min(preferred, modelMaximum)
    }
    return preferred
  }

  public func listModels(account: ResolvedProviderAccount) async throws -> [ProviderModel] {
    guard let path = definition.modelsPath else { return definition.seedModels }
    let baseEndpoint = try ProviderHTTP.endpoint(
      baseURL: account.baseURLOverride ?? definition.defaultBaseURL,
      path: path,
      allowsLocalHTTP: definition.allowsLocalHTTP
    )

    var wires: [AnthropicModelWire] = []
    var seenCursors: Set<String> = []
    var afterID: String?
    let maxPages = 20

    for _ in 0..<maxPages {
      let pageURL = try modelsPageURL(baseEndpoint: baseEndpoint, afterID: afterID)
      let request = try makeRequest(url: pageURL, method: "GET", account: account, streaming: false)
      let response = try await transport.data(for: request)
      try validate(response)

      let decoded: AnthropicModelsResponse
      do {
        decoded = try JSONDecoder.provider.decode(AnthropicModelsResponse.self, from: response.data)
      } catch {
        throw ProviderError.invalidResponse
      }
      wires.append(contentsOf: decoded.data)

      guard decoded.hasMore == true,
        let next = decoded.lastID?.trimmingCharacters(in: .whitespacesAndNewlines),
        !next.isEmpty,
        seenCursors.insert(next).inserted
      else {
        break
      }
      afterID = next
    }

    let discovered = wires.map { wire in
      var evidence = ModelCapabilityEvidence()
      evidence.set(.imageInput, supported: wire.capabilities?.imageInput?.supported, source: .discovery)
      evidence.set(.fileInput, supported: wire.capabilities?.pdfInput?.supported, source: .discovery)
      evidence.set(.reasoning, supported: wire.capabilities?.thinking?.supported, source: .discovery)
      evidence.set(.textInput, supported: true, source: .adapter)
      evidence.set(.textOutput, supported: true, source: .adapter)
      evidence.set(.tools, supported: true, source: .adapter)
      if let value = wire.maxInputTokens, value > 0 { evidence.contextWindowSource = .discovery }
      if let value = wire.maxTokens, value > 0 { evidence.maxOutputTokensSource = .discovery }
      var modalities: Set<String> = ["text"]
      if wire.capabilities?.imageInput?.supported == true { modalities.insert("image") }
      if wire.capabilities?.pdfInput?.supported == true { modalities.insert("file") }
      var parameters: Set<String> = ["max_tokens", "tools"]
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
        capabilityEvidence: evidence
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
    let toolCalls = try decoded.content.compactMap(normalizedToolCall)
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !toolCalls.isEmpty
    else {
      if decoded.stopReason == "refusal" {
        throw ProviderError.provider(
          status: response.statusCode,
          message: "Anthropic refused to answer this request."
        )
      }
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
      usage: decoded.usage?.normalized,
      toolCalls: toolCalls,
      toolContinuation: anthropicContinuation(content: decoded.content, hasToolCalls: !toolCalls.isEmpty)
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
          var toolFragments: [Int: AnthropicToolAccumulator] = [:]
          var thinkingFragments: [Int: AnthropicThinkingAccumulator] = [:]

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
                completed: &completed,
                toolFragments: &toolFragments,
                thinkingFragments: &thinkingFragments
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
              completed: &completed,
              toolFragments: &toolFragments,
              thinkingFragments: &thinkingFragments
            )
          }

          guard completed else { throw ProviderError.prematureStreamEnd }
          let toolCalls = try normalizedToolCalls(toolFragments)
          guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !toolCalls.isEmpty
          else {
            if finishReason == "refusal" {
              throw ProviderError.midStreamProvider(
                code: "refusal",
                message: "Anthropic refused to answer this request."
              )
            }
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
                toolCalls: toolCalls,
                toolContinuation: anthropicContinuation(
                  thinkingFragments: thinkingFragments,
                  hasToolCalls: !toolCalls.isEmpty
                )
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
    completed: inout Bool,
    toolFragments: inout [Int: AnthropicToolAccumulator],
    thinkingFragments: inout [Int: AnthropicThinkingAccumulator]
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
    case "content_block_start":
      if let index = decoded.index, let block = decoded.contentBlock {
        if block.type == "tool_use" {
          toolFragments[index] = AnthropicToolAccumulator(id: block.id, name: block.name)
        } else if block.type == "thinking" {
          thinkingFragments[index] = AnthropicThinkingAccumulator(
            kind: .thinking,
            thinking: block.thinking ?? "",
            signature: block.signature
          )
        } else if block.type == "redacted_thinking", let redactedData = block.data, !redactedData.isEmpty {
          thinkingFragments[index] = AnthropicThinkingAccumulator(
            kind: .redacted,
            redactedData: redactedData
          )
        }
      }
    case "content_block_delta":
      guard let delta = decoded.delta else { return }
      if delta.type == "text_delta", let value = delta.text, !value.isEmpty {
        text += value
        continuation.yield(.textDelta(value))
      } else if delta.type == "thinking_delta", let value = delta.thinking, !value.isEmpty {
        reasoning += value
        if let index = decoded.index {
          var accumulator = thinkingFragments[index] ?? AnthropicThinkingAccumulator()
          accumulator.thinking += value
          thinkingFragments[index] = accumulator
        }
        continuation.yield(.reasoningDelta(value))
      } else if delta.type == "signature_delta", let value = delta.signature,
        let index = decoded.index
      {
        var accumulator = thinkingFragments[index] ?? AnthropicThinkingAccumulator()
        accumulator.signature = (accumulator.signature ?? "") + value
        thinkingFragments[index] = accumulator
      } else if delta.type == "input_json_delta",
        let index = decoded.index,
        let value = delta.partialJSON
      {
        var accumulator = toolFragments[index] ?? AnthropicToolAccumulator()
        accumulator.arguments += value
        toolFragments[index] = accumulator
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
    case "ping", "content_block_stop":
      break
    default:
      break
    }
  }

  private func validateRequest(_ request: ProviderRequest, account: ResolvedProviderAccount) throws
    -> ProviderRequest
  {
    let request = try ModelRequestPolicy.prepare(request, kind: definition.capabilityKind)
    let model = request.model.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !model.isEmpty else { throw ProviderError.invalidModel }
    guard account.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
      throw ProviderError.missingCredential(definition.id)
    }

    var messages: [ProviderMessage] = []
    for message in request.messages {
      let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
      let attachments = message.attachments ?? []
      let calls = message.toolCalls ?? []
      let results = message.toolResults ?? []
      guard !content.isEmpty || !attachments.isEmpty || !calls.isEmpty || !results.isEmpty else {
        continue
      }
      if message.role == .system, (!attachments.isEmpty || !calls.isEmpty || !results.isEmpty) {
        throw ProviderError.invalidRequest("Anthropic system messages cannot contain attachments or tools.")
      }
      try validateAttachments(attachments)
      messages.append(
        .init(
          role: message.role,
          content: content,
          reasoning: message.reasoning,
          attachments: attachments.isEmpty ? nil : attachments,
          toolCalls: calls.isEmpty ? nil : calls,
          toolResults: results.isEmpty ? nil : results,
          toolContinuation: message.toolContinuation
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
    if let bad = attachments.first(where: { $0.isImage && $0.byteCount > 5 * 1_024 * 1_024 }) {
      throw ProviderError.invalidRequest("\(bad.filename) exceeds Anthropic's 5 MB image limit.")
    }
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
    let maxTokens =
      request.options.maxOutputTokens
      ?? Self.defaultMaxTokens(
        reasoning: request.options.reasoning,
        capabilities: request.capabilities
      )
    var body: [String: JSONValue] = [
      "model": .string(request.model.rawValue),
      "max_tokens": .number(Double(maxTokens)),
      "messages": .array(try request.messages.filter { $0.role != .system }.map(messageValue)),
      "stream": .bool(streaming),
    ]

    if !request.tools.isEmpty {
      body["tools"] = .array(request.tools.map { tool in
        .object([
          "name": .string(tool.name),
          "description": .string(tool.description),
          "input_schema": tool.inputSchema,
        ])
      })
    }

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
        if let budget = reasoning.maxTokens {
          body["thinking"] = .object([
            "type": .string("enabled"), "budget_tokens": .number(Double(budget)),
          ])
        } else {
          body["thinking"] = .object([
            "type": .string("adaptive"),
            "display": .string(reasoning.excludeFromResponse ? "omitted" : "summarized"),
          ])
        }
      }
      if let effort = reasoning.effort {
        let value = effort.rawValue
        body["output_config"] = .object(["effort": .string(value)])
      }
    }
    return body
  }

  private func messageValue(_ message: ProviderMessage) throws -> JSONValue {
    if message.role == .tool {
      let blocks = (message.toolResults ?? []).map { result in
        JSONValue.object([
          "type": .string("tool_result"),
          "tool_use_id": .string(result.callID),
          "content": .string(result.content.compactJSONString()),
          "is_error": .bool(result.isError),
        ])
      }
      return .object(["role": .string("user"), "content": .array(blocks)])
    }

    let role = message.role == .assistant ? "assistant" : "user"
    let attachments = message.attachments ?? []
    let toolCalls = message.toolCalls ?? []
    if attachments.isEmpty && toolCalls.isEmpty {
      return .object(["role": .string(role), "content": .string(message.content)])
    }

    var blocks: [JSONValue] = []
    if message.role == .assistant,
      let continuation = message.toolContinuation,
      continuation.apiFamily == .anthropicMessages,
      case .array(let thinkingBlocks) = continuation.payload
    {
      blocks.append(contentsOf: thinkingBlocks)
    }

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
    for call in toolCalls {
      blocks.append(
        .object([
          "type": .string("tool_use"),
          "id": .string(call.id),
          "name": .string(call.name),
          "input": call.arguments,
        ])
      )
    }
    return .object(["role": .string(role), "content": .array(blocks)])
  }

  private func normalizedToolCall(_ block: AnthropicContentBlock) throws -> ChatToolCall? {
    guard block.type == "tool_use" else { return nil }
    guard let id = block.id, !id.isEmpty,
      let name = block.name, !name.isEmpty
    else {
      throw ProviderError.invalidResponse
    }
    return ChatToolCall(id: id, name: name, arguments: block.input ?? .object([:]))
  }

  private func normalizedToolCalls(
    _ fragments: [Int: AnthropicToolAccumulator]
  ) throws -> [ChatToolCall] {
    try fragments.keys.sorted().map { index in
      guard let fragment = fragments[index],
        let id = fragment.id, !id.isEmpty,
        let name = fragment.name, !name.isEmpty
      else {
        throw ProviderError.invalidResponse
      }
      let raw = fragment.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
      let arguments = raw.isEmpty ? JSONValue.object([:]) : try JSONValue.parseJSONString(raw)
      return ChatToolCall(id: id, name: name, arguments: arguments)
    }
  }

  private func anthropicContinuation(
    content: [AnthropicContentBlock],
    hasToolCalls: Bool
  ) -> ProviderToolContinuation? {
    guard hasToolCalls else { return nil }
    let blocks = content.compactMap { block -> JSONValue? in
      if block.type == "thinking", let signature = block.signature, !signature.isEmpty {
        return .object([
          "type": .string("thinking"),
          "thinking": .string(block.thinking ?? ""),
          "signature": .string(signature),
        ])
      }
      if block.type == "redacted_thinking", let data = block.data, !data.isEmpty {
        return .object([
          "type": .string("redacted_thinking"),
          "data": .string(data),
        ])
      }
      return nil
    }
    guard !blocks.isEmpty else { return nil }
    return ProviderToolContinuation(apiFamily: .anthropicMessages, payload: .array(blocks))
  }

  private func anthropicContinuation(
    thinkingFragments: [Int: AnthropicThinkingAccumulator],
    hasToolCalls: Bool
  ) -> ProviderToolContinuation? {
    guard hasToolCalls else { return nil }
    let blocks = thinkingFragments.keys.sorted().compactMap { index -> JSONValue? in
      guard let block = thinkingFragments[index] else { return nil }
      switch block.kind {
      case .thinking:
        guard let signature = block.signature, !signature.isEmpty else { return nil }
        return .object([
          "type": .string("thinking"),
          "thinking": .string(block.thinking),
          "signature": .string(signature),
        ])
      case .redacted:
        guard let data = block.redactedData, !data.isEmpty else { return nil }
        return .object([
          "type": .string("redacted_thinking"),
          "data": .string(data),
        ])
      }
    }
    guard !blocks.isEmpty else { return nil }
    return ProviderToolContinuation(apiFamily: .anthropicMessages, payload: .array(blocks))
  }

  private func modelsPageURL(baseEndpoint: URL, afterID: String?) throws -> URL {
    guard var components = URLComponents(url: baseEndpoint, resolvingAgainstBaseURL: false) else {
      throw ProviderError.invalidEndpoint
    }
    var items = components.queryItems ?? []
    if !items.contains(where: { $0.name == "limit" }) {
      items.append(URLQueryItem(name: "limit", value: "1000"))
    }
    if let afterID {
      items.removeAll { $0.name == "after_id" }
      items.append(URLQueryItem(name: "after_id", value: afterID))
    }
    components.queryItems = items
    guard let result = components.url else { throw ProviderError.invalidEndpoint }
    return result
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
    let fallbackMessage =
      status == 529
      ? "Anthropic is temporarily overloaded. Try again in a moment."
      : HTTPURLResponse.localizedString(forStatusCode: status)
    let message = envelope?.error?.message ?? fallbackMessage
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
        values[model.id] = model.mergingCapabilities(from: existing)
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
      reasoningTokens: incoming.reasoningTokens ?? current?.reasoningTokens,
      cacheWriteTokens: incoming.cacheWriteTokens ?? current?.cacheWriteTokens,
      longCacheWriteTokens: incoming.longCacheWriteTokens ?? current?.longCacheWriteTokens,
      hasUnpricedCharges: incoming.hasUnpricedCharges ?? current?.hasUnpricedCharges
    )
  }
}

private struct AnthropicToolAccumulator: Sendable {
  var id: String?
  var name: String?
  var arguments = ""
}

private struct AnthropicThinkingAccumulator: Sendable {
  enum Kind: Sendable { case thinking, redacted }
  var kind: Kind = .thinking
  var thinking = ""
  var signature: String?
  var redactedData: String?
}

private struct AnthropicModelsResponse: Decodable {
  var data: [AnthropicModelWire]
  var hasMore: Bool?
  var lastID: String?

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    data = try container.decodeIfPresent([AnthropicModelWire].self, forKey: .data) ?? []
    hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore)
    lastID = try container.decodeIfPresent(String.self, forKey: .lastID)
  }

  enum CodingKeys: String, CodingKey {
    case data
    case hasMore = "has_more"
    case lastID = "last_id"
  }
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
  var signature: String?
  var data: String?
  var id: String?
  var name: String?
  var input: JSONValue?
}

private struct AnthropicUsage: Decodable {
  var inputTokens: Int?
  var outputTokens: Int?
  var cacheCreationInputTokens: Int?
  var cacheReadInputTokens: Int?
  var cacheCreation: AnthropicCacheCreation?
  var serverToolUse: [String: Int]?
  var outputTokensDetails: AnthropicOutputTokenDetails?

  enum CodingKeys: String, CodingKey {
    case inputTokens = "input_tokens"
    case outputTokens = "output_tokens"
    case cacheCreationInputTokens = "cache_creation_input_tokens"
    case cacheReadInputTokens = "cache_read_input_tokens"
    case cacheCreation = "cache_creation"
    case serverToolUse = "server_tool_use"
    case outputTokensDetails = "output_tokens_details"
  }

  var normalized: ProviderUsage {
    let totalInput = (inputTokens ?? 0) + (cacheCreationInputTokens ?? 0) + (cacheReadInputTokens ?? 0)
    return ProviderUsage(
      inputTokens: inputTokens == nil ? nil : totalInput,
      outputTokens: outputTokens,
      cachedInputTokens: cacheReadInputTokens ?? (inputTokens == nil ? nil : 0),
      reasoningTokens: outputTokensDetails?.thinkingTokens,
      cacheWriteTokens: cacheCreationInputTokens ?? (inputTokens == nil ? nil : 0),
      longCacheWriteTokens: cacheCreation?.ephemeral1hInputTokens,
      hasUnpricedCharges: serverToolUse?.values.contains(where: { $0 > 0 })
    )
  }
}

private struct AnthropicCacheCreation: Decodable {
  var ephemeral1hInputTokens: Int?
  enum CodingKeys: String, CodingKey { case ephemeral1hInputTokens = "ephemeral_1h_input_tokens" }
}

private struct AnthropicOutputTokenDetails: Decodable {
  var thinkingTokens: Int?
  enum CodingKeys: String, CodingKey { case thinkingTokens = "thinking_tokens" }
}

private struct AnthropicStreamEvent: Decodable {
  var type: String
  var index: Int?
  var message: AnthropicStreamMessage?
  var contentBlock: AnthropicContentBlock?
  var delta: AnthropicStreamDelta?
  var usage: AnthropicUsage?
  var error: AnthropicAPIError?

  enum CodingKeys: String, CodingKey {
    case type, index, message, delta, usage, error
    case contentBlock = "content_block"
  }
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
  var signature: String?
  var partialJSON: String?
  var stopReason: String?

  enum CodingKeys: String, CodingKey {
    case type, text, thinking, signature
    case partialJSON = "partial_json"
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
