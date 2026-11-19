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
    let discovered: [ProviderModel] = decoded.data.compactMap { wire in
      if definition.behavior == .mistral,
        wire.archived == true || wire.capabilities?.completionChat == false
      {
        return nil
      }
      var evidence = ModelCapabilityEvidence()
      // OpenRouter specifies exhaustive lists. Custom-compatible catalogs may
      // provide partial hints using the same field names.
      let exhaustive = definition.behavior == .openRouter
      evidence.modalities(wire.architecture?.inputModalities, input: true, exhaustive: exhaustive)
      evidence.modalities(wire.architecture?.outputModalities, input: false, exhaustive: exhaustive)
      evidence.parameters(wire.supportedParameters, exhaustive: exhaustive)
      var supportedParameters = Set(wire.supportedParameters ?? [])
      var inputModalities = Set(wire.architecture?.inputModalities ?? ["text"])
      if let capabilities = wire.capabilities {
        if let functionCalling = capabilities.functionCalling {
          evidence.set(.tools, supported: functionCalling, source: .discovery)
          if functionCalling { supportedParameters.insert("tools") }
        }
        if let vision = capabilities.vision {
          evidence.set(.imageInput, supported: vision, source: .discovery)
          if vision { inputModalities.insert("image") }
        }
      }
      let contextWindow = wire.contextLength.flatMap { $0 > 0 ? $0 : nil }
        ?? wire.maxContextLength.flatMap { $0 > 0 ? $0 : nil }
        ?? wire.topProvider?.contextLength.flatMap { $0 > 0 ? $0 : nil }
      let outputLimit = wire.topProvider?.maxCompletionTokens.flatMap { $0 > 0 ? $0 : nil }
      if contextWindow != nil { evidence.contextWindowSource = .discovery }
      if outputLimit != nil { evidence.maxOutputTokensSource = .discovery }
      return ProviderModel(
        providerID: definition.id,
        id: ModelID(rawValue: wire.id),
        displayName: wire.name ?? wire.id,
        contextWindow: contextWindow,
        maxOutputTokens: outputLimit,
        supportedParameters: supportedParameters,
        inputModalities: inputModalities,
        outputModalities: Set(wire.architecture?.outputModalities ?? ["text"]),
        promptPricePerToken: wire.pricing?.prompt,
        completionPricePerToken: wire.pricing?.completion,
        capabilityEvidence: evidence,
        cachedInputPricePerToken: wire.pricing?.cachedInput,
        cacheWritePricePerToken: wire.pricing?.cacheWrite,
        hasAdditionalPricingDimensions: wire.pricing?.hasAdditionalPricingDimensions
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
    let text = message?.textContent ?? ""
    let reasoning = message?.normalizedReasoning ?? ""
    let toolCalls = try normalizedToolCalls(message?.toolCalls ?? [])
    guard
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !toolCalls.isEmpty
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
      metadata: responseMetadata(response.headers, decoded),
      toolCalls: toolCalls
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
          var toolFragments: [Int: OpenAIToolCallAccumulator] = [:]

          for try await chunk in stream.chunks {
            try Task.checkCancellation()
            for event in try decoder.append(chunk) {
              try processStreamEvent(
                event,
                continuation: continuation,
                text: &text,
                reasoning: &reasoning,
                usage: &usage,
                finishReason: &finishReason,
                responseID: &responseID,
                modelID: &modelID,
                completed: &completed,
                metadata: &metadata,
                toolFragments: &toolFragments
              )
            }
          }
          for event in try decoder.finish() {
            try processStreamEvent(
              event,
              continuation: continuation,
              text: &text,
              reasoning: &reasoning,
              usage: &usage,
              finishReason: &finishReason,
              responseID: &responseID,
              modelID: &modelID,
              completed: &completed,
              metadata: &metadata,
              toolFragments: &toolFragments
            )
          }
          guard completed || finishReason != nil else {
            throw ProviderError.prematureStreamEnd
          }
          let toolCalls = try normalizedToolCalls(toolFragments)
          guard
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || !toolCalls.isEmpty
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
                metadata: metadata,
                toolCalls: toolCalls
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

  private func processStreamEvent(
    _ event: ServerSentEvent,
    continuation: AsyncThrowingStream<ProviderStreamEvent, Error>.Continuation,
    text: inout String,
    reasoning: inout String,
    usage: inout ProviderUsage?,
    finishReason: inout String?,
    responseID: inout String?,
    modelID: inout ModelID,
    completed: inout Bool,
    metadata: inout [String: String],
    toolFragments: inout [Int: OpenAIToolCallAccumulator]
  ) throws {
    if event.data == "[DONE]" {
      completed = true
      return
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
    var incomingMetadata = responseMetadata([:], decoded)
    // Running usage/cost events are not receipts. Only the final usage
    // event or a terminating choice can supply an authoritative total.
    if decoded.usage != nil {
      metadata.removeValue(forKey: "openrouter.costUSD")
      metadata.removeValue(forKey: ChatBilling.reportedCostCompleteKey)
    }
    if !decoded.choices.isEmpty && !decoded.choices.contains(where: { $0.finishReason != nil }) {
      incomingMetadata.removeValue(forKey: "openrouter.costUSD")
      incomingMetadata.removeValue(forKey: ChatBilling.reportedCostCompleteKey)
    }
    metadata.merge(incomingMetadata) { _, new in new }
    if let value = decoded.usage?.normalized {
      usage = value
      continuation.yield(.usage(value))
    }
    if let choice = decoded.choices.first {
      if let value = choice.finishReason { finishReason = value }
      if let delta = choice.delta.textDelta, !delta.isEmpty {
        text += delta
        continuation.yield(.textDelta(delta))
      }
      for delta in choice.delta.reasoningFragments where !delta.isEmpty {
        reasoning += delta
        continuation.yield(.reasoningDelta(delta))
      }
      for fragment in choice.delta.toolCalls ?? [] {
        let index = fragment.index ?? 0
        var accumulator = toolFragments[index] ?? OpenAIToolCallAccumulator()
        if let value = fragment.id { accumulator.id = value }
        if let value = fragment.function?.name { accumulator.name = value }
        if let value = fragment.function?.arguments { accumulator.arguments += value }
        toolFragments[index] = accumulator
      }
    }
  }

  private func normalizedToolCalls(_ wires: [ToolCallWire]) throws -> [ChatToolCall] {
    try wires.enumerated().map { offset, wire in
      guard let id = wire.id, !id.isEmpty,
        let name = wire.function?.name, !name.isEmpty
      else {
        throw ProviderError.invalidResponse
      }
      let arguments = try parseToolArguments(wire.function?.arguments)
      return ChatToolCall(id: id, name: name, arguments: arguments)
    }
  }

  private func normalizedToolCalls(
    _ fragments: [Int: OpenAIToolCallAccumulator]
  ) throws -> [ChatToolCall] {
    try fragments.keys.sorted().map { index in
      guard let value = fragments[index],
        let id = value.id, !id.isEmpty,
        let name = value.name, !name.isEmpty
      else {
        throw ProviderError.invalidResponse
      }
      return ChatToolCall(
        id: id,
        name: name,
        arguments: try parseToolArguments(value.arguments)
      )
    }
  }

  private func parseToolArguments(_ raw: String?) throws -> JSONValue {
    let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return .object([:]) }
    return try JSONValue.parseJSONString(value)
  }
}

private struct OpenAIToolCallAccumulator: Sendable {
  var id: String?
  var name: String?
  var arguments = ""
}
