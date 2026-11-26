import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct GeminiGenerateContentAdapter: ProviderAdapter, Sendable {
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

  private static let syntheticCallIDPrefix = "gemini-call-"
  private static let skipThoughtSignatureValidator = "skip_thought_signature_validator"

  public func listModels(account: ResolvedProviderAccount) async throws -> [ProviderModel] {
    guard let path = definition.modelsPath else { return definition.seedModels }
    let baseEndpoint = try ProviderHTTP.endpoint(
      baseURL: account.baseURLOverride ?? definition.defaultBaseURL,
      path: path,
      allowsLocalHTTP: definition.allowsLocalHTTP
    )

    var wires: [GeminiModelWire] = []
    var seenTokens: Set<String> = []
    var pageToken: String?
    let maxPages = 20

    for _ in 0..<maxPages {
      let pageURL = try modelsPageURL(baseEndpoint: baseEndpoint, pageToken: pageToken)
      let request = try makeRequest(url: pageURL, method: "GET", account: account, streaming: false)
      let response = try await transport.data(for: request)
      try validate(response)

      let decoded: GeminiModelsResponse
      do {
        decoded = try JSONDecoder.provider.decode(GeminiModelsResponse.self, from: response.data)
      } catch {
        throw ProviderError.invalidResponse
      }
      wires.append(contentsOf: decoded.models)

      guard let next = decoded.nextPageToken?.trimmingCharacters(in: .whitespacesAndNewlines),
        !next.isEmpty,
        seenTokens.insert(next).inserted
      else {
        break
      }
      pageToken = next
    }

    let discovered = wires.compactMap { wire -> ProviderModel? in
      guard wire.supportedGenerationMethods?.contains("generateContent") != false else { return nil }
      let strippedName = wire.name
        .replacingOccurrences(of: "models/", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let fallbackBaseID = wire.baseModelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let id = !strippedName.isEmpty ? strippedName : fallbackBaseID
      guard !id.isEmpty else { return nil }
      var evidence = ModelCapabilityEvidence()
      evidence.set(.reasoning, supported: wire.thinking, source: .discovery)
      evidence.set(.textInput, supported: true, source: .adapter)
      evidence.set(.textOutput, supported: true, source: .adapter)
      // These are adapter/model-family assumptions, not live modality discovery.
      evidence.set(.imageInput, supported: true, source: .inference)
      evidence.set(.fileInput, supported: true, source: .inference)
      evidence.set(.tools, supported: true, source: .inference)
      if let value = wire.inputTokenLimit, value > 0 { evidence.contextWindowSource = .discovery }
      if let value = wire.outputTokenLimit, value > 0 { evidence.maxOutputTokensSource = .discovery }
      var parameters: Set<String> = ["maxOutputTokens", "tools"]
      if supportsSamplingParameters(id) {
        parameters.formUnion(["temperature", "topP"])
      }
      if wire.thinking == true { parameters.insert("thinkingConfig") }
      return ProviderModel(
        providerID: definition.id,
        id: ModelID(rawValue: id),
        displayName: wire.displayName ?? id,
        contextWindow: wire.inputTokenLimit.flatMap { $0 > 0 ? $0 : nil },
        maxOutputTokens: wire.outputTokenLimit.flatMap { $0 > 0 ? $0 : nil },
        supportedParameters: parameters,
        inputModalities: ["text", "image", "file"],
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
    let url = try generationURL(
      baseURL: account.baseURLOverride ?? definition.defaultBaseURL,
      model: validated.model,
      streaming: false
    )
    var urlRequest = try makeRequest(url: url, method: "POST", account: account, streaming: false)
    urlRequest.httpBody = try JSONEncoder.providerEncoder.encode(
      JSONValue.object(requestBody(validated))
    )
    let response = try await transport.data(for: urlRequest)
    try validate(response)

    let decoded: GeminiGenerateResponse
    do {
      decoded = try JSONDecoder.provider.decode(GeminiGenerateResponse.self, from: response.data)
    } catch {
      throw ProviderError.invalidResponse
    }
    if let error = decoded.error {
      throw ProviderError.provider(status: error.code ?? response.statusCode, message: error.message)
    }
    if let blocked = promptBlockError(decoded.promptFeedback) {
      throw ProviderError.provider(status: response.statusCode, message: blocked.message)
    }

    let output = try collectOutput(decoded)
    guard !output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !output.reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !output.toolCalls.isEmpty
    else {
      throw ProviderError.emptyOutput
    }

    return ProviderResponse(
      id: decoded.responseID,
      text: output.text,
      reasoning: output.reasoning,
      providerID: definition.id,
      accountID: account.id,
      modelID: validated.model,
      finishReason: decoded.candidates.first?.finishReason,
      usage: decoded.usageMetadata?.normalized,
      metadata: decoded.modelVersion.map { ["modelVersion": $0] } ?? [:],
      toolCalls: output.toolCalls,
      toolContinuation: geminiContinuation(
        signatures: output.toolSignatures,
        hasToolCalls: !output.toolCalls.isEmpty
      ),
      citations: output.citations
    )
  }

  public func stream(request: ProviderRequest, account: ResolvedProviderAccount)
    -> AsyncThrowingStream<ProviderStreamEvent, Error>
  {
    AsyncThrowingStream { continuation in
      let task = Task { @Sendable in
        do {
          let validated = try validateRequest(request, account: account)
          let url = try generationURL(
            baseURL: account.baseURLOverride ?? definition.defaultBaseURL,
            model: validated.model,
            streaming: true
          )
          var urlRequest = try makeRequest(url: url, method: "POST", account: account, streaming: true)
          urlRequest.httpBody = try JSONEncoder.providerEncoder.encode(
            JSONValue.object(requestBody(validated))
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
          var finishReason: String?
          var modelVersion: String?
          var completed = false
          var toolCalls: [ChatToolCall] = []
          var toolSignatures: [String: String] = [:]
          var citations: [ChatCitation] = []

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
                finishReason: &finishReason,
                modelVersion: &modelVersion,
                completed: &completed,
                toolCalls: &toolCalls,
                toolSignatures: &toolSignatures,
                citations: &citations
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
              finishReason: &finishReason,
              modelVersion: &modelVersion,
              completed: &completed,
              toolCalls: &toolCalls,
              toolSignatures: &toolSignatures,
              citations: &citations
            )
          }

          guard completed else { throw ProviderError.prematureStreamEnd }
          guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !toolCalls.isEmpty
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
                modelID: validated.model,
                finishReason: finishReason,
                usage: usage,
                metadata: modelVersion.map { ["modelVersion": $0] } ?? [:],
                toolCalls: toolCalls,
                toolContinuation: geminiContinuation(
                  signatures: toolSignatures,
                  hasToolCalls: !toolCalls.isEmpty
                ),
                citations: citations
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
    finishReason: inout String?,
    modelVersion: inout String?,
    completed: inout Bool,
    toolCalls: inout [ChatToolCall],
    toolSignatures: inout [String: String],
    citations: inout [ChatCitation]
  ) throws {
    guard let payload = event.data.data(using: .utf8) else { throw ProviderError.invalidResponse }
    let decoded: GeminiGenerateResponse
    do {
      decoded = try JSONDecoder.provider.decode(GeminiGenerateResponse.self, from: payload)
    } catch {
      throw ProviderError.invalidResponse
    }
    if let error = decoded.error {
      throw ProviderError.midStreamProvider(code: error.status, message: error.message)
    }
    if let blocked = promptBlockError(decoded.promptFeedback) {
      throw ProviderError.midStreamProvider(code: blocked.code, message: blocked.message)
    }

    if let value = decoded.responseID { responseID = value }
    if let value = decoded.modelVersion { modelVersion = value }
    if let incoming = decoded.usageMetadata?.normalized {
      usage = incoming
      continuation.yield(.usage(incoming))
    }

    for part in decoded.candidates.first?.content?.parts ?? [] {
      if let value = part.text, !value.isEmpty {
        if part.thought == true {
          reasoning += value
          continuation.yield(.reasoningDelta(value))
        } else {
          text += value
          continuation.yield(.textDelta(value))
        }
      }
      if let functionCall = part.functionCall {
        let call = try normalizedToolCall(functionCall, index: toolCalls.count)
        if let index = toolCalls.firstIndex(where: { $0.id == call.id }) {
          toolCalls[index] = call
        } else {
          toolCalls.append(call)
        }
        if let signature = part.thoughtSignature, !signature.isEmpty {
          toolSignatures[call.id] = signature
        }
      }
    }
    if let grounding = decoded.candidates.first?.groundingMetadata {
      for citation in extractCitations(from: grounding) where !citations.contains(citation) {
        citations.append(citation)
      }
    }
    if let finish = decoded.candidates.first?.finishReason {
      finishReason = finish
      completed = true
    }
  }

  private func validateRequest(_ request: ProviderRequest, account: ResolvedProviderAccount) throws
    -> ProviderRequest
  {
    let request = try ModelRequestPolicy.prepare(request, kind: definition.capabilityKind)
    let model = request.model.rawValue
      .replacingOccurrences(of: "models/", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
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
        throw ProviderError.invalidRequest("Gemini system instructions cannot contain attachments or tools.")
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
  }

  func requestBody(_ request: ProviderRequest) -> [String: JSONValue] {
    let system = request.messages
      .filter { $0.role == .system }
      .map(\.content)
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")

    let needsThoughtSignature = requiresThoughtSignature(request.model.rawValue)
    var body: [String: JSONValue] = [
      "contents": .array(
        request.messages
          .filter { $0.role != .system }
          .map { messageValue($0, requiresThoughtSignature: needsThoughtSignature) }
      )
    ]
    if !system.isEmpty {
      body["systemInstruction"] = .object([
        "parts": .array([.object(["text": .string(system)])])
      ])
    }
    if !request.tools.isEmpty {
      body["tools"] = .array([
        .object([
          "functionDeclarations": .array(request.tools.map { tool in
            .object([
              "name": .string(tool.name),
              "description": .string(tool.description),
              // Preserve JSON Schema keywords such as additionalProperties.
              "parametersJsonSchema": tool.inputSchema,
            ])
          })
        ])
      ])
    }

    var generation: [String: JSONValue] = [:]
    if supportsSamplingParameters(request.model.rawValue) {
      if let value = request.options.temperature { generation["temperature"] = .number(value) }
      if let value = request.options.topP { generation["topP"] = .number(value) }
    }
    if let value = request.options.maxOutputTokens {
      generation["maxOutputTokens"] = .number(Double(value))
    }

    if let reasoning = request.options.reasoning {
      var thinking: [String: JSONValue] = [:]
      if reasoning.enabled != false && !reasoning.excludeFromResponse {
        thinking["includeThoughts"] = .bool(true)
      } else if reasoning.excludeFromResponse {
        thinking["includeThoughts"] = .bool(false)
      }

      if request.capabilities?.reasoning.kind == .efforts {
        if let effort = reasoning.effort {
          thinking["thinkingLevel"] = .string(effort.rawValue)
        }
      } else if reasoning.enabled == false {
        thinking["thinkingBudget"] = .number(0)
      } else if let budget = reasoning.maxTokens {
        thinking["thinkingBudget"] = .number(Double(budget))
      }
      if !thinking.isEmpty { generation["thinkingConfig"] = .object(thinking) }
    }

    if !generation.isEmpty { body["generationConfig"] = .object(generation) }
    return body
  }

  private func messageValue(
    _ message: ProviderMessage,
    requiresThoughtSignature: Bool
  ) -> JSONValue {
    if message.role == .tool {
      let parts = (message.toolResults ?? []).map { result -> JSONValue in
        let response: JSONValue
        if result.isError {
          response = .object(["error": result.content])
        } else if case .object = result.content {
          response = result.content
        } else {
          response = .object(["result": result.content])
        }
        var functionResponse: [String: JSONValue] = [
          "name": .string(result.name),
          "response": response,
        ]
        if !result.callID.hasPrefix(Self.syntheticCallIDPrefix) {
          functionResponse["id"] = .string(result.callID)
        }
        return .object(["functionResponse": .object(functionResponse)])
      }
      return .object(["role": .string("user"), "parts": .array(parts)])
    }

    let role = message.role == .assistant ? "model" : "user"
    let signatures: [String: JSONValue]
    if message.role == .assistant,
      let continuation = message.toolContinuation,
      continuation.apiFamily == .geminiGenerateContent,
      case .object(let values) = continuation.payload
    {
      signatures = values
    } else {
      signatures = [:]
    }

    var parts: [JSONValue] = []
    for attachment in message.attachments ?? [] {
      if let text = attachment.utf8Text {
        parts.append(
          .object(["text": .string("File: \(attachment.filename)\n\n\(text)")])
        )
      } else {
        parts.append(
          .object([
            "inlineData": .object([
              "mimeType": .string(attachment.mimeType),
              "data": .string(attachment.data.base64EncodedString()),
            ])
          ])
        )
      }
    }
    if !message.content.isEmpty {
      parts.append(.object(["text": .string(message.content)]))
    }
    let calls = message.toolCalls ?? []
    let hasStoredSignature = calls.contains { call in
      if case .string(let signature)? = signatures[call.id], !signature.isEmpty { return true }
      return false
    }
    for (index, call) in calls.enumerated() {
      var functionCall: [String: JSONValue] = [
        "name": .string(call.name),
        "args": call.arguments,
      ]
      if !call.id.hasPrefix(Self.syntheticCallIDPrefix) {
        functionCall["id"] = .string(call.id)
      }
      var part: [String: JSONValue] = [
        "functionCall": .object(functionCall)
      ]
      if case .string(let signature)? = signatures[call.id], !signature.isEmpty {
        part["thoughtSignature"] = .string(signature)
      } else if requiresThoughtSignature, !hasStoredSignature, index == 0 {
        part["thoughtSignature"] = .string(Self.skipThoughtSignatureValidator)
      }
      parts.append(.object(part))
    }
    return .object(["role": .string(role), "parts": .array(parts)])
  }

  private func modelsPageURL(baseEndpoint: URL, pageToken: String?) throws -> URL {
    guard var components = URLComponents(url: baseEndpoint, resolvingAgainstBaseURL: false) else {
      throw ProviderError.invalidEndpoint
    }
    var items = components.queryItems ?? []
    if !items.contains(where: { $0.name == "pageSize" }) {
      items.append(URLQueryItem(name: "pageSize", value: "1000"))
    }
    if let pageToken {
      items.removeAll { $0.name == "pageToken" }
      items.append(URLQueryItem(name: "pageToken", value: pageToken))
    }
    components.queryItems = items
    guard let result = components.url else { throw ProviderError.invalidEndpoint }
    return result
  }

  private func generationURL(baseURL: URL, model: ModelID, streaming: Bool) throws -> URL {
    let method = streaming ? "streamGenerateContent" : "generateContent"
    let url = try ProviderHTTP.endpoint(
      baseURL: baseURL,
      path: "/models/\(model.rawValue):\(method)",
      allowsLocalHTTP: definition.allowsLocalHTTP
    )
    guard streaming else { return url }
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      throw ProviderError.invalidEndpoint
    }
    components.queryItems = [URLQueryItem(name: "alt", value: "sse")]
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
    if streaming { request.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
    return request
  }

  private func validate(_ response: ProviderHTTPResponse) throws {
    guard (200..<300).contains(response.statusCode) else {
      throw mapHTTPError(status: response.statusCode, headers: response.headers, data: response.data)
    }
  }

  private func mapHTTPError(status: Int, headers: [String: String], data: Data) -> ProviderError {
    let envelope = try? JSONDecoder.provider.decode(GeminiErrorEnvelope.self, from: data)
    let message = envelope?.error?.message ?? HTTPURLResponse.localizedString(forStatusCode: status)
    let lowered = message.lowercased()
    switch status {
    case 401: return .authenticationFailed
    case 403: return .permissionDenied
    case 404 where lowered.contains("model"): return .modelUnavailable
    case 404: return .invalidEndpoint
    case 429: return .rateLimited(retryAfter: header("Retry-After", headers))
    default:
      if lowered.contains("quota") || lowered.contains("billing") || lowered.contains("credit") {
        return .insufficientCredits
      }
      return .provider(status: status, message: message)
    }
  }

  private func header(_ name: String, _ headers: [String: String]) -> String? {
    headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
  }

  private func collectOutput(
    _ response: GeminiGenerateResponse
  ) throws -> (
    text: String,
    reasoning: String,
    toolCalls: [ChatToolCall],
    toolSignatures: [String: String],
    citations: [ChatCitation]
  ) {
    var text = ""
    var reasoning = ""
    var toolCalls: [ChatToolCall] = []
    var signatures: [String: String] = [:]
    for part in response.candidates.first?.content?.parts ?? [] {
      if let value = part.text {
        if part.thought == true { reasoning += value } else { text += value }
      }
      if let functionCall = part.functionCall {
        let call = try normalizedToolCall(functionCall, index: toolCalls.count)
        toolCalls.append(call)
        if let signature = part.thoughtSignature, !signature.isEmpty {
          signatures[call.id] = signature
        }
      }
    }
    let citations = response.candidates.first?.groundingMetadata
      .map { extractCitations(from: $0) } ?? []
    return (text, reasoning, toolCalls, signatures, citations)
  }

  private func extractCitations(from metadata: GeminiGroundingMetadata) -> [ChatCitation] {
    let chunks = metadata.groundingChunks ?? []
    guard !chunks.isEmpty else { return [] }

    var citations: [ChatCitation] = []
    var supportedChunkIndices = Set<Int>()

    for support in metadata.groundingSupports ?? [] {
      let startIndex = support.segment?.startIndex
      let endIndex = support.segment?.endIndex
      let snippet = support.segment?.text
      for chunkIndex in support.groundingChunkIndices ?? [] {
        guard chunkIndex >= 0, chunkIndex < chunks.count,
          let web = chunks[chunkIndex].web,
          let uri = web.uri,
          !uri.isEmpty
        else { continue }
        supportedChunkIndices.insert(chunkIndex)
        let citation = ChatCitation(
          url: uri,
          title: web.title,
          snippet: snippet,
          startIndex: startIndex,
          endIndex: endIndex
        )
        if !citations.contains(citation) {
          citations.append(citation)
        }
      }
    }

    for (index, chunk) in chunks.enumerated() where !supportedChunkIndices.contains(index) {
      guard let web = chunk.web, let uri = web.uri, !uri.isEmpty else { continue }
      let citation = ChatCitation(url: uri, title: web.title)
      if !citations.contains(citation) {
        citations.append(citation)
      }
    }

    return citations
  }

  private func normalizedToolCall(_ value: GeminiFunctionCall, index: Int) throws -> ChatToolCall {
    guard let name = value.name, !name.isEmpty else { throw ProviderError.invalidResponse }
    let rawID = value.id?.trimmingCharacters(in: .whitespacesAndNewlines)
    let id: String
    if let rawID, !rawID.isEmpty {
      id = rawID
    } else {
      id = "\(Self.syntheticCallIDPrefix)\(index)-\(UUID().uuidString.lowercased())"
    }
    return ChatToolCall(id: id, name: name, arguments: value.args ?? .object([:]))
  }

  private func promptBlockError(_ feedback: GeminiPromptFeedback?) -> (code: String, message: String)? {
    guard let reason = feedback?.blockReason?.trimmingCharacters(in: .whitespacesAndNewlines),
      !reason.isEmpty
    else { return nil }
    let detail = feedback?.blockReasonMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
    let message: String
    if let detail, !detail.isEmpty {
      message = "Prompt blocked by Gemini (\(reason)): \(detail)"
    } else {
      message = "Prompt blocked by Gemini (\(reason))."
    }
    return (reason, message)
  }

  private func geminiContinuation(
    signatures: [String: String],
    hasToolCalls: Bool
  ) -> ProviderToolContinuation? {
    guard hasToolCalls, !signatures.isEmpty else { return nil }
    return ProviderToolContinuation(
      apiFamily: .geminiGenerateContent,
      payload: .object(signatures.mapValues(JSONValue.string))
    )
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

  private func supportsSamplingParameters(_ modelID: String) -> Bool {
    let id = modelID.lowercased()
    return !id.hasPrefix("gemini-4")
      && !id.hasPrefix("gemini-3.8")
      && !id.hasPrefix("gemini-3.7")
      && !id.hasPrefix("gemini-3.6")
      && !id.hasPrefix("gemini-3.5-flash-lite")
  }

  private func requiresThoughtSignature(_ modelID: String) -> Bool {
    let id = modelID.lowercased()
    return id.hasPrefix("gemini-3") || id.hasPrefix("gemini-4")
  }
}

private struct GeminiModelsResponse: Decodable {
  var models: [GeminiModelWire]
  var nextPageToken: String?

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    models = try container.decodeIfPresent([GeminiModelWire].self, forKey: .models) ?? []
    nextPageToken = try container.decodeIfPresent(String.self, forKey: .nextPageToken)
  }

  enum CodingKeys: String, CodingKey {
    case models, nextPageToken
  }
}

private struct GeminiModelWire: Decodable {
  var name: String
  var baseModelID: String?
  var displayName: String?
  var inputTokenLimit: Int?
  var outputTokenLimit: Int?
  var supportedGenerationMethods: [String]?
  var thinking: Bool?

  enum CodingKeys: String, CodingKey {
    case name, displayName, inputTokenLimit, outputTokenLimit, supportedGenerationMethods, thinking
    case baseModelID = "baseModelId"
  }
}

private struct GeminiGenerateResponse: Decodable {
  var candidates: [GeminiCandidate]
  var promptFeedback: GeminiPromptFeedback?
  var usageMetadata: GeminiUsage?
  var modelVersion: String?
  var responseID: String?
  var error: GeminiAPIError?

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    candidates = try container.decodeIfPresent([GeminiCandidate].self, forKey: .candidates) ?? []
    promptFeedback = try container.decodeIfPresent(GeminiPromptFeedback.self, forKey: .promptFeedback)
    usageMetadata = try container.decodeIfPresent(GeminiUsage.self, forKey: .usageMetadata)
    modelVersion = try container.decodeIfPresent(String.self, forKey: .modelVersion)
    responseID = try container.decodeIfPresent(String.self, forKey: .responseID)
    error = try container.decodeIfPresent(GeminiAPIError.self, forKey: .error)
  }

  enum CodingKeys: String, CodingKey {
    case candidates, promptFeedback, usageMetadata, modelVersion, error
    case responseID = "responseId"
  }
}

private struct GeminiPromptFeedback: Decodable {
  var blockReason: String?
  var blockReasonMessage: String?
}

private struct GeminiCandidate: Decodable {
  var content: GeminiContent?
  var finishReason: String?
  var groundingMetadata: GeminiGroundingMetadata?
}

private struct GeminiGroundingMetadata: Decodable {
  var groundingChunks: [GeminiGroundingChunk]?
  var groundingSupports: [GeminiGroundingSupport]?
}

private struct GeminiGroundingChunk: Decodable {
  var web: GeminiGroundingWeb?
}

private struct GeminiGroundingWeb: Decodable {
  var uri: String?
  var title: String?
}

private struct GeminiGroundingSupport: Decodable {
  var segment: GeminiGroundingSegment?
  var groundingChunkIndices: [Int]?
}

private struct GeminiGroundingSegment: Decodable {
  var startIndex: Int?
  var endIndex: Int?
  var text: String?
}

private struct GeminiContent: Decodable {
  var parts: [GeminiPart]
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    parts = try container.decodeIfPresent([GeminiPart].self, forKey: .parts) ?? []
  }
  enum CodingKeys: String, CodingKey { case parts }
}

private struct GeminiPart: Decodable {
  var text: String?
  var thought: Bool?
  var functionCall: GeminiFunctionCall?
  var thoughtSignature: String?
}

private struct GeminiFunctionCall: Decodable {
  var id: String?
  var name: String?
  var args: JSONValue?
}

private struct GeminiUsage: Decodable {
  var promptTokenCount: Int?
  var candidatesTokenCount: Int?
  var cachedContentTokenCount: Int?
  var thoughtsTokenCount: Int?

  var normalized: ProviderUsage {
    let outputTokens: Int?
    if let candidatesTokenCount {
      outputTokens = candidatesTokenCount + (thoughtsTokenCount ?? 0)
    } else if let thoughtsTokenCount {
      outputTokens = thoughtsTokenCount
    } else {
      outputTokens = nil
    }
    return ProviderUsage(
      inputTokens: promptTokenCount,
      outputTokens: outputTokens,
      cachedInputTokens: cachedContentTokenCount ?? (promptTokenCount == nil ? nil : 0),
      reasoningTokens: thoughtsTokenCount,
      hasUnpricedCharges: (cachedContentTokenCount ?? 0) > 0 ? true : nil
    )
  }
}

private struct GeminiAPIError: Decodable {
  var code: Int?
  var message: String
  var status: String?
}

private struct GeminiErrorEnvelope: Decodable {
  var error: GeminiAPIError?
}
