import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Native xAI Responses API adapter.
///
/// xAI follows the OpenResponses wire shape closely enough to reuse BYOKchat's
/// persisted Responses continuation envelope, but model discovery, reasoning,
/// Files API attachments, and provider-reported billing remain xAI-specific.
public struct XAIResponsesAdapter: ProviderAdapter, Sendable {
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
    let control = ModelCapabilityResolver.reasoningControl(kind: .xAI, modelID: model)
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
    do {
      return try await listLanguageModels(account: account)
    } catch let error as ProviderError where shouldFallbackFromLanguageModels(error) {
      // `/language-models` is xAI's richer first-class discovery endpoint. If
      // an older/alternate xAI-compatible deployment does not expose it, keep
      // `/models` compatibility rather than making refresh unusable.
      let models = try await OpenAICompatibleAdapter(definition: definition, transport: transport)
        .listModels(account: account)
      let seedIDs = Set(definition.seedModels.map(\.id))
      return mergeModels(
        seed: definition.seedModels,
        discovered: models.compactMap { model in
          guard seedIDs.contains(model.id) || isChatModelID(model.id.rawValue) else { return nil }
          return enrichDiscoveredModel(model)
        }
      )
    }
  }

  private func shouldFallbackFromLanguageModels(_ error: ProviderError) -> Bool {
    switch error {
    case .invalidEndpoint, .invalidResponse:
      return true
    case .provider(let status, _):
      return status == 404 || status == 405 || status == 501
    default:
      return false
    }
  }

  public func generate(request: ProviderRequest, account: ResolvedProviderAccount) async throws
    -> ProviderResponse
  {
    let validated = try validateRequest(request, account: account)
    let uploadedFileIDs = try await uploadFiles(in: validated, account: account)
    let url = try ProviderHTTP.endpoint(
      baseURL: account.baseURLOverride ?? definition.defaultBaseURL,
      path: definition.chatCompletionsPath,
      allowsLocalHTTP: definition.allowsLocalHTTP
    )
    var urlRequest = try compatibility.makeRequest(
      url: url, method: "POST", account: account, acceptsEventStream: false)
    urlRequest.httpBody = try JSONEncoder.providerEncoder.encode(
      JSONValue.object(
        try requestBody(validated, streaming: false, uploadedFileIDs: uploadedFileIDs)
      )
    )

    let response = try await transport.data(for: urlRequest)
    try compatibility.validate(response)
    return try parseResponse(
      decodeJSON(response.data),
      account: account,
      fallbackModel: validated.model,
      headers: response.headers,
      reportedTicks: reportedCostTicks(from: response.data, streaming: false)
    )
  }

  public func stream(request: ProviderRequest, account: ResolvedProviderAccount)
    -> AsyncThrowingStream<ProviderStreamEvent, Error>
  {
    AsyncThrowingStream { continuation in
      let task = Task { @Sendable in
        do {
          let validated = try validateRequest(request, account: account)
          let uploadedFileIDs = try await uploadFiles(in: validated, account: account)
          let url = try ProviderHTTP.endpoint(
            baseURL: account.baseURLOverride ?? definition.defaultBaseURL,
            path: definition.chatCompletionsPath,
            allowsLocalHTTP: definition.allowsLocalHTTP
          )
          var urlRequest = try compatibility.makeRequest(
            url: url, method: "POST", account: account, acceptsEventStream: true)
          urlRequest.httpBody = try JSONEncoder.providerEncoder.encode(
            JSONValue.object(
              try requestBody(validated, streaming: true, uploadedFileIDs: uploadedFileIDs)
            )
          )

          let stream = try await transport.stream(for: urlRequest)
          guard (200..<300).contains(stream.statusCode) else {
            var data = Data()
            for try await chunk in stream.chunks { data.append(chunk) }
            throw compatibility.mapHTTPError(
              status: stream.statusCode,
              headers: stream.headers,
              data: data
            )
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

          guard var response = finalResponse else { throw ProviderError.prematureStreamEnd }
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

  // MARK: - Model discovery

  private func listLanguageModels(account: ResolvedProviderAccount) async throws -> [ProviderModel] {
    let url = try ProviderHTTP.endpoint(
      baseURL: account.baseURLOverride ?? definition.defaultBaseURL,
      path: "/language-models",
      allowsLocalHTTP: definition.allowsLocalHTTP
    )
    let request = try compatibility.makeRequest(
      url: url,
      method: "GET",
      account: account,
      acceptsEventStream: false
    )
    let response = try await transport.data(for: request)
    try compatibility.validate(response)
    let root = try decodeJSON(response.data)
    guard case .object(let object) = root,
      let values = arrayValue(object["models"])
    else {
      throw ProviderError.invalidResponse
    }

    let discovered: [ProviderModel] = values.compactMap { value in
      guard case .object(let model) = value,
        let id = stringValue(model["id"]),
        !id.isEmpty,
        isChatModelID(id)
      else { return nil }

      var evidence = ModelCapabilityEvidence()
      evidence.modalities(arrayValue(model["input_modalities"])?.compactMap(stringValue), input: true)
      evidence.modalities(arrayValue(model["output_modalities"])?.compactMap(stringValue), input: false)
      // The Files API is a separate adapter route, not an exhaustive catalog modality.
      evidence.facts.removeValue(forKey: .fileInput)
      evidence.set(.fileInput, supported: true, source: .adapter)
      let contextWindow = intValue(model["context_length"]).flatMap { $0 > 0 ? $0 : nil }
      if contextWindow != nil { evidence.contextWindowSource = .discovery }
      let inputModalities = Set(
        (arrayValue(model["input_modalities"]) ?? []).compactMap(stringValue)
      )
      let outputModalities = Set(
        (arrayValue(model["output_modalities"]) ?? []).compactMap(stringValue)
      )
      var providerModel = ProviderModel(
        providerID: definition.id,
        id: ModelID(rawValue: id),
        displayName: id,
        contextWindow: contextWindow,
        contextWindowKind: .combined,
        supportedParameters: [],
        inputModalities: inputModalities.isEmpty ? ["text"] : inputModalities,
        outputModalities: outputModalities.isEmpty ? ["text"] : outputModalities,
        promptPricePerToken: tokenPricePerToken(model["prompt_text_token_price"]),
        completionPricePerToken: tokenPricePerToken(model["completion_text_token_price"]),
        capabilityEvidence: evidence,
        cachedInputPricePerToken: tokenPricePerToken(model["cached_prompt_text_token_price"])
      )
      // xAI Files attachments are an adapter route layered on language
      // models rather than a modality reported by `/language-models`.
      providerModel.inputModalities.insert("file")
      return enrichDiscoveredModel(providerModel)
    }

    return mergeModels(seed: definition.seedModels, discovered: discovered)
  }

  private func isChatModelID(_ modelID: String) -> Bool {
    let value = modelID.lowercased()
    guard value.hasPrefix("grok-") || value == "latest" else { return false }
    let excluded = [
      "imagine", "image", "video", "voice", "tts", "transcribe", "embedding", "moderation",
    ]
    return !excluded.contains(where: { value.contains($0) })
  }

  private func enrichDiscoveredModel(_ model: ProviderModel) -> ProviderModel {
    var result = model
    if let seed = definition.seedModels.first(where: { $0.id == model.id }) {
      result = result.mergingCapabilities(from: seed)
      if result.displayName == result.id.rawValue { result.displayName = seed.displayName }
    }

    result.supportedParameters.formUnion(["temperature", "top_p", "max_output_tokens", "tools"])
    if modelSupportsReasoningControl(model.id.rawValue) {
      result.supportedParameters.insert("reasoning")
    } else {
      result.supportedParameters.remove("reasoning")
    }
    if model.id.rawValue.lowercased().hasPrefix("grok-4") {
      result.inputModalities.formUnion(["text", "file"])
      if result.capabilityEvidence?.facts[.imageInput]?.support != .unsupported {
        result.inputModalities.insert("image")
      }
    }
    return result
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

  // MARK: - Validation and request mapping

  private func validateRequest(
    _ request: ProviderRequest,
    account: ResolvedProviderAccount
  ) throws -> ProviderRequest {
    let request = try ModelRequestPolicy.prepare(request, kind: definition.capabilityKind)
    let model = request.model.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !model.isEmpty else { throw ProviderError.invalidModel }
    guard let key = account.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty
    else {
      throw ProviderError.missingCredential(definition.id)
    }

    var messages: [ProviderMessage] = []
    messages.reserveCapacity(request.messages.count)
    for message in request.messages {
      let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
      let attachments = message.attachments ?? []
      let toolCalls = message.toolCalls ?? []
      let toolResults = message.toolResults ?? []
      let providerContinuation = message.toolContinuation
      guard
        !content.isEmpty || !attachments.isEmpty || !toolCalls.isEmpty || !toolResults.isEmpty
          || providerContinuation != nil
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
          toolContinuation: providerContinuation
        )
      )
    }
    guard !messages.isEmpty else { throw ProviderError.invalidMessages }

    var toolNames: Set<String> = []
    for tool in request.tools {
      let name = tool.name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else { throw ProviderError.invalidRequest("Tool name cannot be empty.") }
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

    let supportedImageMIMEs: Set<String> = ["image/png", "image/jpeg", "image/jpg"]
    if let unsupported = attachments.first(where: {
      $0.isImage && !supportedImageMIMEs.contains($0.mimeType.lowercased())
    }) {
      throw ProviderError.invalidRequest(
        "Unsupported xAI image type for \(unsupported.filename). Use PNG or JPEG."
      )
    }
  }

  private func requestBody(
    _ request: ProviderRequest,
    streaming: Bool,
    uploadedFileIDs: [String: String]
  ) throws -> [String: JSONValue] {
    var input: [JSONValue] = []
    for message in request.messages {
      input.append(contentsOf: try inputValues(for: message, uploadedFileIDs: uploadedFileIDs))
    }

    var body: [String: JSONValue] = [
      "model": .string(request.model.rawValue),
      "input": .array(input),
      "store": .bool(false),
      "stream": .bool(streaming),
    ]
    if modelUsesReasoning(request.model.rawValue) {
      body["include"] = .array([.string("reasoning.encrypted_content")])
    }
    if !request.tools.isEmpty { body["tools"] = .array(request.tools.map(toolValue)) }
    if let maxOutputTokens = request.options.maxOutputTokens {
      body["max_output_tokens"] = .number(Double(maxOutputTokens))
    }
    if let reasoning = reasoningValue(request.options.reasoning, control: request.capabilities?.reasoning
      ?? ModelCapabilityResolver.reasoningControl(kind: .xAI, modelID: request.model)) {
      body["reasoning"] = reasoning
    }
    if let value = request.options.temperature { body["temperature"] = .number(value) }
    if let value = request.options.topP { body["top_p"] = .number(value) }
    return body
  }

  private func inputValues(
    for message: ProviderMessage,
    uploadedFileIDs: [String: String]
  ) throws -> [JSONValue] {
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
      let providerContinuation = message.toolContinuation,
      providerContinuation.apiFamily == .openAIResponses,
      case .array(let values) = providerContinuation.payload
    {
      return values
    }

    var values: [JSONValue] = []
    var contentParts: [JSONValue] = []
    let textPartType = message.role == .assistant ? "output_text" : "input_text"
    if !message.content.isEmpty {
      contentParts.append(
        .object(["type": .string(textPartType), "text": .string(message.content)])
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
          ])
        )
      } else {
        if let text = attachment.utf8Text {
          contentParts.append(.object([
            "type": .string("input_text"),
            "text": .string("File: \(attachment.filename)\n\n\(text)"),
          ]))
          continue
        }
        guard let fileID = uploadedFileIDs[attachment.id] else {
          throw ProviderError.invalidRequest(
            "xAI file upload was not available for \(attachment.filename)."
          )
        }
        contentParts.append(
          .object([
            "type": .string("input_file"),
            "file_id": .string(fileID),
          ])
        )
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
    ])
  }

  // MARK: - xAI reasoning

  private func modelUsesReasoning(_ model: String) -> Bool {
    let control = ModelCapabilityResolver.reasoningControl(kind: .xAI, modelID: ModelID(rawValue: model))
    return control.kind != .unknown && control.kind != .unsupported
  }

  private func modelSupportsReasoningControl(_ model: String) -> Bool {
    ModelCapabilityResolver.reasoningControl(kind: .xAI, modelID: ModelID(rawValue: model)).kind == .efforts
  }

  private func reasoningValue(_ options: ReasoningOptions?, control: ModelReasoningControl) -> JSONValue? {
    guard control.kind == .efforts, let options = control.normalize(options) else { return nil }
    if options.enabled == false {
      guard let value = control.offWireValue else { return nil }
      return .object(["effort": .string(value)])
    }
    guard let effort = options.effort else { return nil }
    return .object(["effort": .string(effort.rawValue)])
  }

  // MARK: - Files API

  private func uploadFiles(
    in request: ProviderRequest,
    account: ResolvedProviderAccount
  ) async throws -> [String: String] {
    var result: [String: String] = [:]
    for message in request.messages where message.role != .assistant {
      for attachment in message.attachments ?? [] where !attachment.isImage && attachment.utf8Text == nil {
        if result[attachment.id] != nil { continue }
        result[attachment.id] = try await uploadFile(attachment, account: account)
      }
    }
    return result
  }

  private func uploadFile(
    _ attachment: ChatAttachment,
    account: ResolvedProviderAccount
  ) async throws -> String {
    let url = try ProviderHTTP.endpoint(
      baseURL: account.baseURLOverride ?? definition.defaultBaseURL,
      path: "/files",
      allowsLocalHTTP: definition.allowsLocalHTTP
    )
    var request = try compatibility.makeRequest(
      url: url, method: "POST", account: account, acceptsEventStream: false)
    let boundary = "byokchat-xai-\(UUID().uuidString.lowercased())"
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.httpBody = multipartBody(attachment: attachment, boundary: boundary)

    let response = try await transport.data(for: request)
    try compatibility.validate(response)
    let root = try decodeJSON(response.data)
    guard let id = stringValue(root.objectValue?["id"]), !id.isEmpty else {
      throw ProviderError.invalidResponse
    }
    return id
  }

  private func multipartBody(attachment: ChatAttachment, boundary: String) -> Data {
    var data = Data()
    func append(_ value: String) { data.append(Data(value.utf8)) }
    let safeName = attachment.filename
      .replacingOccurrences(of: "\r", with: "")
      .replacingOccurrences(of: "\n", with: "")
      .replacingOccurrences(of: "\"", with: "'")

    func field(_ name: String, _ value: String) {
      append("--\(boundary)\r\n")
      append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
      append("\(value)\r\n")
    }

    // xAI rejects multipart requests where expires_after follows the file field.
    field("expires_after", "86400")
    field("purpose", "assistants")
    append("--\(boundary)\r\n")
    append("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\n")
    append("Content-Type: \(attachment.mimeType)\r\n\r\n")
    data.append(attachment.data)
    append("\r\n--\(boundary)--\r\n")
    return data
  }

  // MARK: - Response mapping

  private func parseResponse(
    _ root: JSONValue,
    account: ResolvedProviderAccount,
    fallbackModel: ModelID,
    headers: [String: String],
    reportedTicks: Decimal?
  ) throws -> ProviderResponse {
    guard case .object(let object) = root else { throw ProviderError.invalidResponse }

    if case .object(let error)? = object["error"] {
      let message = stringValue(error["message"]) ?? "xAI returned an error."
      throw ProviderError.provider(status: 200, message: message)
    }

    let output = arrayValue(object["output"]) ?? []
    var text = ""
    var reasoning = ""
    var toolCalls: [ChatToolCall] = []

    for item in output {
      guard case .object(let value) = item else { continue }
      switch stringValue(value["type"]) {
      case "message":
        for part in arrayValue(value["content"]) ?? [] {
          guard case .object(let content) = part else { continue }
          switch stringValue(content["type"]) {
          case "output_text": text += stringValue(content["text"]) ?? ""
          case "refusal": text += stringValue(content["refusal"]) ?? ""
          default: break
          }
        }
      case "reasoning":
        var reasoningParts: [String] = []
        for part in arrayValue(value["summary"]) ?? [] {
          guard case .object(let summary) = part else { continue }
          if stringValue(summary["type"]) == "summary_text",
            let summaryText = stringValue(summary["text"]),
            !summaryText.isEmpty
          {
            reasoningParts.append(summaryText)
          }
        }
        if reasoningParts.isEmpty {
          for part in arrayValue(value["content"]) ?? [] {
            guard case .object(let content) = part else { continue }
            if stringValue(content["type"]) == "reasoning_text",
              let reasoningText = stringValue(content["text"]),
              !reasoningText.isEmpty
            {
              reasoningParts.append(reasoningText)
            }
          }
        }
        if !reasoningParts.isEmpty {
          let joined = reasoningParts.joined(separator: "\n\n")
          if !reasoning.isEmpty { reasoning += "\n\n" }
          reasoning += joined
        }
      case "function_call":
        guard let name = stringValue(value["name"]), !name.isEmpty,
          let callID = stringValue(value["call_id"]) ?? stringValue(value["id"]),
          !callID.isEmpty
        else { throw ProviderError.invalidResponse }
        let arguments = try JSONValue.parseJSONString(stringValue(value["arguments"]) ?? "{}")
        toolCalls.append(.init(id: callID, name: name, arguments: arguments))
      default:
        break
      }
    }

    let status = stringValue(object["status"])
    if status == "failed" || status == "cancelled" {
      let errorObject = object["error"]?.objectValue
      let message = errorObject.flatMap { stringValue($0["message"]) }
        ?? "xAI response \(status ?? "failed")."
      throw ProviderError.provider(status: 200, message: message)
    }

    let incompleteObject = object["incomplete_details"]?.objectValue
    let incompleteReason = incompleteObject.flatMap { stringValue($0["reason"]) }
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
            message: "xAI blocked this response due to content filtering."
          )
        case "max_output_tokens":
          throw ProviderError.provider(
            status: 200,
            message: "xAI reached the maximum output token limit before producing a visible response."
          )
        default:
          throw ProviderError.provider(
            status: 200,
            message: "xAI response was incomplete (\(incompleteReason))."
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
    if let responseID = stringValue(object["id"]) { metadata["responseID"] = responseID }
    if let ticks = reportedTicks {
      metadata["xai.costInUSDTicks"] = ChatBilling.decimalString(ticks)
      metadata["costUSD"] = ChatBilling.decimalString(ticks / 10_000_000_000)
    }

    let providerContinuation: ProviderToolContinuation? = output.isEmpty
      ? nil
      : .init(apiFamily: .openAIResponses, payload: .array(output))

    return ProviderResponse(
      id: stringValue(object["id"]),
      text: text,
      reasoning: reasoning,
      providerID: definition.id,
      accountID: account.id,
      modelID: ModelID(rawValue: stringValue(object["model"]) ?? fallbackModel.rawValue),
      finishReason: finishReason,
      usage: usage,
      metadata: metadata,
      toolCalls: toolCalls,
      toolContinuation: providerContinuation
    )
  }

  private func usageValue(_ value: JSONValue?) -> ProviderUsage? {
    guard case .object(let usage)? = value else { return nil }
    let input = intValue(usage["input_tokens"]) ?? intValue(usage["prompt_tokens"])
    let output = intValue(usage["output_tokens"]) ?? intValue(usage["completion_tokens"])
    let inputDetails = usage["input_tokens_details"]?.objectValue
      ?? usage["prompt_tokens_details"]?.objectValue
    let outputDetails = usage["output_tokens_details"]?.objectValue
      ?? usage["completion_tokens_details"]?.objectValue
    return ProviderUsage(
      inputTokens: input,
      outputTokens: output,
      cachedInputTokens: intValue(inputDetails?["cached_tokens"]),
      reasoningTokens: intValue(outputDetails?["reasoning_tokens"])
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
    let type = stringValue(object["type"]) ?? event.event

    switch type {
    case "response.output_text.delta", "response.refusal.delta":
      if let delta = stringValue(object["delta"]), !delta.isEmpty {
        visibleText += delta
        continuation.yield(.textDelta(delta))
      }
    case "response.reasoning_summary_part.added":
      if !reasoningSummary.isEmpty {
        reasoningSummary += "\n\n"
        continuation.yield(.reasoningDelta("\n\n"))
      }
    case "response.reasoning_text.delta", "response.reasoning_summary_text.delta":
      if let delta = stringValue(object["delta"]), !delta.isEmpty {
        reasoningSummary += delta
        continuation.yield(.reasoningDelta(delta))
      }
    case "response.completed", "response.incomplete":
      guard let responseObject = object["response"] else { throw ProviderError.invalidResponse }
      let parsed = try parseResponse(
        responseObject,
        account: account,
        fallbackModel: fallbackModel,
        headers: headers,
        reportedTicks: reportedCostTicks(from: data, streaming: true)
      )
      if let usage = parsed.usage { continuation.yield(.usage(usage)) }
      finalResponse = parsed
    case "response.failed":
      let responseObject = object["response"]?.objectValue
      let errorObject = responseObject?["error"]?.objectValue
      throw ProviderError.midStreamProvider(
        code: errorObject.flatMap { stringValue($0["code"]) },
        message: errorObject.flatMap { stringValue($0["message"]) } ?? "xAI response failed."
      )
    case "response.cancelled":
      let responseObject = object["response"]?.objectValue
      let errorObject = responseObject?["error"]?.objectValue
      throw ProviderError.midStreamProvider(
        code: errorObject.flatMap { stringValue($0["code"]) } ?? "cancelled",
        message: errorObject.flatMap { stringValue($0["message"]) } ?? "xAI response was cancelled."
      )
    case "error":
      let error = object["error"]?.objectValue ?? object
      throw ProviderError.midStreamProvider(
        code: stringValue(error["code"]),
        message: stringValue(error["message"]) ?? "xAI stream failed."
      )
    default:
      break
    }
  }

  private func reportedCostTicks(from data: Data, streaming: Bool) -> Decimal? {
    let decoder = JSONDecoder.provider
    if streaming {
      return (try? decoder.decode(XAICostEvent.self, from: data))?.response?.usage?.ticks?.value
    }
    return (try? decoder.decode(XAICostResponse.self, from: data))?.usage?.ticks?.value
  }

  // MARK: - JSON helpers

  private func stringValue(_ value: JSONValue?) -> String? {
    guard case .string(let string)? = value else { return nil }
    return string
  }

  private func arrayValue(_ value: JSONValue?) -> [JSONValue]? {
    guard case .array(let array)? = value else { return nil }
    return array
  }

  private func numberValue(_ value: JSONValue?) -> Double? {
    guard case .number(let number)? = value else { return nil }
    return number
  }

  private func intValue(_ value: JSONValue?) -> Int? {
    guard let number = numberValue(value) else { return nil }
    return Int(number)
  }

  private func tokenPricePerToken(_ value: JSONValue?) -> String? {
    guard let raw = numberValue(value), raw >= 0 else { return nil }
    return NSDecimalNumber(value: raw)
      .dividing(by: NSDecimalNumber(value: 10_000_000_000))
      .stringValue
  }
}

private struct XAICostEvent: Decodable {
  var response: XAICostResponse?
}
private struct XAICostResponse: Decodable {
  var usage: XAICostUsage?
}
private struct XAICostUsage: Decodable {
  var ticks: BillingAmountWire?
  enum CodingKeys: String, CodingKey { case ticks = "cost_in_usd_ticks" }
}
