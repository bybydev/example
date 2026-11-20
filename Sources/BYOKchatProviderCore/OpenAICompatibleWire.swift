import Foundation

enum MessageContentWire: Decodable {
  case string(String)
  case chunks([MessageContentChunkWire])

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let text = try? container.decode(String.self) {
      self = .string(text)
    } else if let chunks = try? container.decode([MessageContentChunkWire].self) {
      self = .chunks(chunks)
    } else {
      throw DecodingError.typeMismatch(
        MessageContentWire.self,
        .init(
          codingPath: decoder.codingPath,
          debugDescription: "Expected string or content chunk array"
        )
      )
    }
  }

  var text: String? {
    switch self {
    case .string(let value):
      return value
    case .chunks(let chunks):
      let joined = chunks.compactMap(\.textValue).joined()
      return joined.isEmpty ? nil : joined
    }
  }

  var reasoningFragments: [String] {
    switch self {
    case .string:
      return []
    case .chunks(let chunks):
      return chunks.flatMap(\.reasoningValues)
    }
  }
}

struct MessageContentChunkWire: Decodable {
  var type: String?
  var text: String?
  var thinking: ThinkingContentWire?

  var textValue: String? {
    guard type == nil || type == "text" else { return nil }
    return text
  }

  var reasoningValues: [String] {
    guard type == "thinking" || type == "reasoning" else { return [] }
    if let thinking {
      return thinking.fragments
    }
    return text.map { [$0] } ?? []
  }
}

enum ThinkingContentWire: Decodable {
  case string(String)
  case parts([ThinkingTextPartWire])

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let text = try? container.decode(String.self) {
      self = .string(text)
    } else if let parts = try? container.decode([ThinkingTextPartWire].self) {
      self = .parts(parts)
    } else {
      self = .parts([])
    }
  }

  var fragments: [String] {
    switch self {
    case .string(let value): return [value]
    case .parts(let parts): return parts.compactMap(\.text)
    }
  }
}

struct ThinkingTextPartWire: Decodable {
  var type: String?
  var text: String?
}

struct ChatCompletionMessageWire: Decodable {
  var content: MessageContentWire?
  var reasoning: String?
  var reasoningContent: String?
  var reasoningDetails: [ReasoningDetailWire]?
  var toolCalls: [ToolCallWire]?
  enum CodingKeys: String, CodingKey {
    case content, reasoning
    case reasoningContent = "reasoning_content"
    case reasoningDetails = "reasoning_details"
    case toolCalls = "tool_calls"
  }
  var textContent: String? { content?.text }
  var normalizedReasoning: String? {
    let details = reasoningDetails?.compactMap { $0.text ?? $0.summary }.joined() ?? ""
    let values =
      ([reasoning, reasoningContent, details].compactMap { $0 } + (content?.reasoningFragments ?? []))
      .filter { !$0.isEmpty }
    return values.isEmpty ? nil : values.joined()
  }
}

struct ReasoningDetailWire: Decodable {
  var text: String?
  var summary: String?
}

struct ToolCallWire: Decodable {
  var index: Int?
  var id: String?
  var type: String?
  var function: ToolFunctionWire?
}

struct ToolFunctionWire: Decodable {
  var name: String?
  var arguments: String?
}

struct ChatCompletionChoiceWire: Decodable {
  var message: ChatCompletionMessageWire?
  var delta: ChatCompletionDeltaWire
  var finishReason: String?
  enum CodingKeys: String, CodingKey {
    case message, delta
    case finishReason = "finish_reason"
  }
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    message = try container.decodeIfPresent(ChatCompletionMessageWire.self, forKey: .message)
    delta = try container.decodeIfPresent(ChatCompletionDeltaWire.self, forKey: .delta) ?? .init()
    finishReason = try container.decodeIfPresent(String.self, forKey: .finishReason)
  }
}

struct ChatCompletionDeltaWire: Decodable {
  var content: MessageContentWire?
  var reasoning: String?
  var reasoningContent: String?
  var reasoningDetails: [ReasoningDetailWire]?
  var toolCalls: [ToolCallWire]?
  init(
    content: MessageContentWire? = nil, reasoning: String? = nil, reasoningContent: String? = nil,
    reasoningDetails: [ReasoningDetailWire]? = nil, toolCalls: [ToolCallWire]? = nil
  ) {
    self.content = content
    self.reasoning = reasoning
    self.reasoningContent = reasoningContent
    self.reasoningDetails = reasoningDetails
    self.toolCalls = toolCalls
  }
  enum CodingKeys: String, CodingKey {
    case content, reasoning
    case reasoningContent = "reasoning_content"
    case reasoningDetails = "reasoning_details"
    case toolCalls = "tool_calls"
  }
  var textDelta: String? { content?.text }
  var reasoningFragments: [String] {
    [reasoning, reasoningContent].compactMap { $0 }
      + (reasoningDetails?.compactMap { $0.text ?? $0.summary } ?? [])
      + (content?.reasoningFragments ?? [])
  }
}

struct UsageWire: Decodable {
  var promptTokens: Int?
  var cachedTokens: Int?
  var promptCacheHitTokens: Int?
  var completionTokens: Int?
  var promptTokensDetails: PromptTokensDetailsWire?
  var completionTokensDetails: CompletionTokensDetailsWire?
  var cost: BillingAmountWire?
  var isBYOK: Bool?
  enum CodingKeys: String, CodingKey {
    case cost
    case isBYOK = "is_byok"
    case promptTokens = "prompt_tokens"
    case cachedTokens = "cached_tokens"
    case promptCacheHitTokens = "prompt_cache_hit_tokens"
    case completionTokens = "completion_tokens"
    case promptTokensDetails = "prompt_tokens_details"
    case completionTokensDetails = "completion_tokens_details"
  }
  var normalized: ProviderUsage {
    .init(
      inputTokens: promptTokens,
      outputTokens: completionTokens,
      cachedInputTokens: promptTokensDetails?.cachedTokens ?? cachedTokens ?? promptCacheHitTokens,
      reasoningTokens: completionTokensDetails?.reasoningTokens,
      cacheWriteTokens: promptTokensDetails?.cacheWriteTokens,
      hasUnpricedCharges: (promptTokensDetails?.audioTokens ?? 0) > 0
        || (completionTokensDetails?.audioTokens ?? 0) > 0
        || (completionTokensDetails?.imageTokens ?? 0) > 0 ? true : nil
    )
  }
}

struct PromptTokensDetailsWire: Decodable {
  var cachedTokens: Int?
  var cacheWriteTokens: Int?
  var audioTokens: Int?
  enum CodingKeys: String, CodingKey {
    case cachedTokens = "cached_tokens"
    case cacheWriteTokens = "cache_write_tokens"
    case audioTokens = "audio_tokens"
  }
}
struct CompletionTokensDetailsWire: Decodable {
  var reasoningTokens: Int?
  var audioTokens: Int?
  var imageTokens: Int?
  enum CodingKeys: String, CodingKey {
    case reasoningTokens = "reasoning_tokens"
    case audioTokens = "audio_tokens"
    case imageTokens = "image_tokens"
  }
}
struct ProviderErrorWire: Decodable {
  var code: String?
  var message: String
}

struct ChatCompletionResponse: Decodable {
  var id: String?
  var model: String?
  var provider: String?
  var serviceTier: String?
  var choices: [ChatCompletionChoiceWire]
  var usage: UsageWire?
  var error: ProviderErrorWire?
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decodeIfPresent(String.self, forKey: .id)
    model = try c.decodeIfPresent(String.self, forKey: .model)
    provider = try c.decodeIfPresent(String.self, forKey: .provider)
    serviceTier = try c.decodeIfPresent(String.self, forKey: .serviceTier)
    choices = try c.decodeIfPresent([ChatCompletionChoiceWire].self, forKey: .choices) ?? []
    usage = try c.decodeIfPresent(UsageWire.self, forKey: .usage)
    error = try c.decodeIfPresent(ProviderErrorWire.self, forKey: .error)
  }
  private enum CodingKeys: String, CodingKey {
    case id, model, provider, choices, usage, error
    case serviceTier = "service_tier"
  }
}

typealias ChatCompletionChunk = ChatCompletionResponse

struct ProviderErrorEnvelope: Decodable {
  var error: ProviderErrorWire?
  var message: String?
}
struct ModelsResponse: Decodable { var data: [ModelWire] }
struct ModelWire: Decodable {
  var id: String
  var name: String?
  var contextLength: Int?
  var maxContextLength: Int?
  var contextWindow: Int?
  var maxOutputTokens: Int?
  var inputModalities: [String]?
  var outputModalities: [String]?
  var effort: ModelEffortWire?
  var supportedParameters: [String]?
  var architecture: ArchitectureWire?
  var topProvider: TopProviderWire?
  var pricing: PricingWire?
  var capabilities: ModelCapabilitiesWire?
  var archived: Bool?
  enum CodingKeys: String, CodingKey {
    case id, name, architecture, pricing, capabilities, archived, effort
    case contextLength = "context_length"
    case maxContextLength = "max_context_length"
    case contextWindow = "context_window"
    case maxOutputTokens = "max_output_tokens"
    case inputModalities = "input_modalities"
    case outputModalities = "output_modalities"
    case supportedParameters = "supported_parameters"
    case topProvider = "top_provider"
  }
}
struct ModelEffortWire: Decodable {
  var supportedLevels: [String]?
  var defaultLevel: String?
  enum CodingKeys: String, CodingKey {
    case supportedLevels = "supported_levels"
    case defaultLevel = "default_level"
  }
}
struct ModelCapabilitiesWire: Decodable {
  var completionChat: Bool?
  var functionCalling: Bool?
  var vision: Bool?
  enum CodingKeys: String, CodingKey {
    case completionChat = "completion_chat"
    case functionCalling = "function_calling"
    case vision
  }
}
struct ArchitectureWire: Decodable {
  var inputModalities: [String]?
  var outputModalities: [String]?
  enum CodingKeys: String, CodingKey {
    case inputModalities = "input_modalities"
    case outputModalities = "output_modalities"
  }
}
struct TopProviderWire: Decodable {
  var contextLength: Int?
  var maxCompletionTokens: Int?
  enum CodingKeys: String, CodingKey {
    case contextLength = "context_length"
    case maxCompletionTokens = "max_completion_tokens"
  }
}
struct PricingWire: Decodable {
  var prompt: String?
  var completion: String?
  var cachedInput: String?
  var cacheWrite: String?
  var request: String?
  var image: String?
  var audio: String?
  var webSearch: String?
  var internalReasoning: String?
  var hasAdditionalPricingDimensions: Bool? {
    let extra = [request, image, audio, webSearch, internalReasoning].compactMap { $0 }
    return extra.contains { (ChatBilling.decimal($0) ?? -1) != 0 } ? true : nil
  }
  enum CodingKeys: String, CodingKey {
    case prompt, completion, request, image, audio
    case webSearch = "web_search"
    case internalReasoning = "internal_reasoning"
    case cachedInput = "input_cache_read"
    case cacheWrite = "input_cache_write"
  }
}

/// Invalid cost values must not invalidate an otherwise usable chat response.
struct BillingAmountWire: Decodable {
  var value: Decimal?
  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let string = try? container.decode(String.self) {
      value = ChatBilling.decimal(string)
    } else if let amount = try? container.decode(Decimal.self), !amount.isNaN, amount >= 0 {
      value = amount
    }
  }
}
