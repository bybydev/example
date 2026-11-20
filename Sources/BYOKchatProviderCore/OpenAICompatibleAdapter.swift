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
    let control = ModelCapabilityResolver.reasoningControl(
      kind: definition.capabilityKind, modelID: model
    )
    let probeReasoning: ReasoningOptions?
    let probeMaxTokens: Int
    if control.allowsOff {
      probeReasoning = .init(enabled: false)
      probeMaxTokens = 16
    } else if control.kind == .efforts, let lowest = control.efforts.first {
      probeReasoning = .init(enabled: true, effort: lowest)
      probeMaxTokens = 1_024
    } else if control.kind == .fixed {
      probeReasoning = nil
      probeMaxTokens = 1_024
    } else if definition.behavior == .deepSeek || definition.behavior == .openRouter {
      probeReasoning = nil
      probeMaxTokens = 1_024
    } else {
      probeReasoning = nil
      probeMaxTokens = 16
    }

    _ = try await generate(
      request: .init(
        model: model,
        messages: [.init(role: .user, content: "Return exactly OK.")],
        options: .init(maxOutputTokens: probeMaxTokens, reasoning: probeReasoning)
      ),
      account: account
    )
  }

  public func listModels(account: ResolvedProviderAccount) async throws -> [ProviderModel] {
    guard let path = definition.modelsPath else { return definition.seedModels }
    let baseURL = account.kind.normalizedBaseURL(
      account.baseURLOverride ?? definition.defaultBaseURL)
    let url = try ProviderHTTP.endpoint(
      baseURL: baseURL,
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
      // OpenRouter and DeepSeek supply exhaustive modality lists when present.
      // Custom-compatible catalogs may provide partial hints using the same field names.
      let rawInputModalities = wire.architecture?.inputModalities ?? wire.inputModalities
      let rawOutputModalities = wire.architecture?.outputModalities ?? wire.outputModalities
      let exhaustiveModalities = definition.behavior == .openRouter || definition.behavior == .deepSeek
      let exhaustiveParameters = definition.behavior == .openRouter
      evidence.modalities(rawInputModalities, input: true, exhaustive: exhaustiveModalities)
      evidence.modalities(rawOutputModalities, input: false, exhaustive: exhaustiveModalities)
      evidence.parameters(wire.supportedParameters, exhaustive: exhaustiveParameters)
      var supportedParameters = Set(wire.supportedParameters ?? [])
      var inputModalities = Set(rawInputModalities ?? ["text"])
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
      if definition.behavior == .deepSeek, let effortWire = wire.effort {
        var parsedEfforts: [ReasoningEffort] = []
        for rawLevel in effortWire.supportedLevels ?? [] {
          if let level = ReasoningEffort(rawValue: rawLevel.lowercased()),
            !parsedEfforts.contains(level)
          {
            parsedEfforts.append(level)
          }
        }
        if !parsedEfforts.isEmpty {
          let defaultEffort = effortWire.defaultLevel
            .flatMap { ReasoningEffort(rawValue: $0.lowercased()) }
            .flatMap { parsedEfforts.contains($0) ? $0 : nil }
            ?? (parsedEfforts.contains(.high) ? .high : parsedEfforts.first)
          evidence.set(.reasoning, supported: true, source: .discovery)
          evidence.reasoningControl = ModelReasoningControl(
            kind: .efforts,
            efforts: parsedEfforts,
            defaultEffort: defaultEffort,
            allowsOff: true,
            offWireValue: "disabled",
            source: .discovery
          )
          supportedParameters.formUnion(["thinking", "reasoning_effort"])
        }
      }
      let contextWindow = wire.contextLength.flatMap { $0 > 0 ? $0 : nil }
        ?? wire.maxContextLength.flatMap { $0 > 0 ? $0 : nil }
        ?? wire.contextWindow.flatMap { $0 > 0 ? $0 : nil }
        ?? wire.topProvider?.contextLength.flatMap { $0 > 0 ? $0 : nil }
      let outputLimit = wire.maxOutputTokens.flatMap { $0 > 0 ? $0 : nil }
        ?? wire.topProvider?.maxCompletionTokens.flatMap { $0 > 0 ? $0 : nil }
      if definition.behavior == .openRouter {
        if let reasoningWire = wire.reasoning {
          let rawLevels = reasoningWire.supportedEfforts ?? []
          let hasNone = rawLevels.contains { $0.lowercased() == "none" }
          var parsedEfforts: [ReasoningEffort] = []
          for rawLevel in rawLevels {
            if let level = ReasoningEffort(rawValue: rawLevel.lowercased()),
              !parsedEfforts.contains(level)
            {
              parsedEfforts.append(level)
            }
          }
          let allowsOff = reasoningWire.mandatory == true
            ? false
            : (reasoningWire.mandatory == false || hasNone)
          let offWireValue: String? = allowsOff ? (hasNone ? "none" : "disabled") : nil
          let defaultEffort = reasoningWire.defaultEffort
            .flatMap { ReasoningEffort(rawValue: $0.lowercased()) }
            .flatMap { parsedEfforts.contains($0) ? $0 : nil }
          let budget: ReasoningBudgetControl? =
            (reasoningWire.supportsMaxTokens == true && (outputLimit == nil || (outputLimit ?? 0) >= 1_024))
            ? .init(
              minimum: 1_024,
              maximum: outputLimit,
              defaultTokens: max(1_024, min(2_048, outputLimit ?? 2_048))
            )
            : nil
          let control: ModelReasoningControl
          if !parsedEfforts.isEmpty {
            control = ModelReasoningControl(
              kind: .efforts,
              efforts: parsedEfforts,
              defaultEffort: defaultEffort,
              allowsOff: allowsOff,
              offWireValue: offWireValue,
              budget: budget,
              combinesEffortAndBudget: false,
              source: .discovery
            )
          } else if let budget {
            control = ModelReasoningControl(
              kind: .budget,
              allowsOff: allowsOff,
              offWireValue: offWireValue,
              budget: budget,
              source: .discovery
            )
          } else {
            control = ModelReasoningControl(
              kind: .fixed,
              allowsOff: allowsOff,
              offWireValue: offWireValue,
              source: .discovery
            )
          }
          evidence.set(.reasoning, supported: true, source: .discovery)
          evidence.reasoningControl = control
          supportedParameters.insert("reasoning")
        } else if supportedParameters.contains("reasoning") {
          evidence.reasoningControl = ModelReasoningControl(
            kind: .efforts,
            efforts: [.low, .medium, .high],
            defaultEffort: nil,
            allowsOff: false,
            source: .discovery
          )
        }
      }
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
        outputModalities: Set(rawOutputModalities ?? ["text"]),
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
    let baseURL = account.kind.normalizedBaseURL(
      account.baseURLOverride ?? definition.defaultBaseURL)
    let url = try ProviderHTTP.endpoint(
      baseURL: baseURL,
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
      throw ProviderError.provider(status: response.statusCode, message: error.displayMessage)
    }
    let message = decoded.choices.first?.message
    let text = message?.textContent ?? ""
    let reasoning = message?.normalizedReasoning ?? ""
    let toolCalls = try normalizedToolCalls(message?.toolCalls ?? [])
    let finishReason = decoded.choices.first?.finishReason
    let reasoningDetailValues = (message?.reasoningDetails ?? [])
      .filter { !$0.rawObject.isEmpty }
      .map { JSONValue.object($0.rawObject) }
    let toolContinuation: ProviderToolContinuation? =
      definition.behavior == .openRouter && !reasoningDetailValues.isEmpty
      ? ProviderToolContinuation(
        apiFamily: .openAIChatCompletions,
        payload: .array(reasoningDetailValues)
      )
      : nil
    guard
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !toolCalls.isEmpty
    else {
      throw emptyOutputError(finishReason: finishReason)
    }
    return .init(
      id: decoded.id,
      text: text,
      reasoning: reasoning,
      providerID: definition.id,
      accountID: account.id,
      modelID: ModelID(rawValue: decoded.model ?? validated.model.rawValue),
      finishReason: finishReason,
      usage: decoded.usage?.normalized,
      metadata: responseMetadata(response.headers, decoded),
      toolCalls: toolCalls,
      toolContinuation: toolContinuation
    )
  }

  public func stream(request: ProviderRequest, account: ResolvedProviderAccount)
    -> AsyncThrowingStream<ProviderStreamEvent, Error>
  {
    AsyncThrowingStream { continuation in
      let task = Task { @Sendable in
        do {
          let validated = try validate(request: request, account: account)
          let baseURL = account.kind.normalizedBaseURL(
            account.baseURLOverride ?? definition.defaultBaseURL)
          let url = try ProviderHTTP.endpoint(
            baseURL: baseURL,
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
          var reasoningDetailsAccumulator = OpenRouterReasoningDetailsAccumulator()

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
                toolFragments: &toolFragments,
                reasoningDetailsAccumulator: &reasoningDetailsAccumulator
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
              toolFragments: &toolFragments,
              reasoningDetailsAccumulator: &reasoningDetailsAccumulator
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
            throw emptyOutputError(finishReason: finishReason)
          }
          let accumulatedDetails = reasoningDetailsAccumulator.values
          let toolContinuation: ProviderToolContinuation? =
            definition.behavior == .openRouter && !accumulatedDetails.isEmpty
            ? ProviderToolContinuation(
              apiFamily: .openAIChatCompletions,
              payload: .array(accumulatedDetails)
            )
            : nil
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
                toolCalls: toolCalls,
                toolContinuation: toolContinuation
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
    toolFragments: inout [Int: OpenAIToolCallAccumulator],
    reasoningDetailsAccumulator: inout OpenRouterReasoningDetailsAccumulator
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
      throw ProviderError.midStreamProvider(code: error.code, message: error.displayMessage)
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
      if definition.behavior == .openRouter, let details = choice.delta.reasoningDetails {
        for detail in details {
          reasoningDetailsAccumulator.append(detail)
        }
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

  private func emptyOutputError(finishReason: String?) -> ProviderError {
    switch finishReason?.lowercased() {
    case "content_filter":
      return .provider(
        status: 200,
        message: "The response was blocked by the provider's content filter."
      )
    case "length":
      return .provider(
        status: 200,
        message: "The model reached the maximum output token limit before producing a response."
      )
    default:
      return .emptyOutput
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

private struct OpenRouterReasoningDetailsAccumulator: Sendable {
  private var blocks: [[String: JSONValue]] = []

  var values: [JSONValue] {
    blocks.map(JSONValue.object)
  }

  mutating func append(_ detail: ReasoningDetailWire) {
    let incoming = detail.rawObject
    guard !incoming.isEmpty else { return }

    let incomingType = detail.type
    let incomingIndex = detail.index
    let incomingID = detail.id

    if incomingType == "reasoning.encrypted" {
      if let matchIndex = blocks.lastIndex(where: { block in
        guard case .string("reasoning.encrypted")? = block["type"] else { return false }
        if let incomingID, case .string(let existingID)? = block["id"] {
          return existingID == incomingID
        }
        if let incomingIndex, case .number(let existingIndex)? = block["index"] {
          return Int(existingIndex) == incomingIndex && incomingID == nil
        }
        return false
      }) {
        mergeEncrypted(incoming, into: &blocks[matchIndex])
      } else {
        blocks.append(incoming)
      }
      return
    }

    if let matchIndex = blocks.lastIndex(where: { block in
      let existingType = stringField("type", in: block)
      guard existingType == incomingType else { return false }
      if let incomingIndex {
        if case .number(let existingIndex)? = block["index"] {
          return Int(existingIndex) == incomingIndex
        }
        return false
      }
      if let incomingID {
        return stringField("id", in: block) == incomingID
      }
      return incomingType == "reasoning.text" || incomingType == "reasoning.summary"
    }) {
      mergeTextual(incoming, into: &blocks[matchIndex])
    } else {
      blocks.append(incoming)
    }
  }

  private func stringField(_ key: String, in object: [String: JSONValue]) -> String? {
    if case .string(let value)? = object[key] { return value }
    return nil
  }

  private func mergeTextual(
    _ incoming: [String: JSONValue],
    into existing: inout [String: JSONValue]
  ) {
    for (key, value) in incoming {
      switch key {
      case "text", "summary", "signature":
        if case .string(let addition) = value, !addition.isEmpty {
          if case .string(let current)? = existing[key] {
            existing[key] = .string(current + addition)
          } else {
            existing[key] = .string(addition)
          }
        }
      default:
        if existing[key] == nil || existing[key] == .null {
          existing[key] = value
        }
      }
    }
  }

  private func mergeEncrypted(
    _ incoming: [String: JSONValue],
    into existing: inout [String: JSONValue]
  ) {
    for (key, value) in incoming {
      if key == "data" {
        if case .string(let addition) = value, !addition.isEmpty {
          if case .string(let current)? = existing[key], !current.isEmpty {
            if current != addition {
              existing[key] = .string(current + addition)
            }
          } else {
            existing[key] = .string(addition)
          }
        }
      } else if existing[key] == nil || existing[key] == .null {
        existing[key] = value
      }
    }
  }
}
