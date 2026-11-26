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

struct URLCitationWire: Decodable {
  var url: String?
  var title: String?
  var content: String?
  var startIndex: Int?
  var endIndex: Int?

  enum CodingKeys: String, CodingKey {
    case url, title, content
    case startIndex = "start_index"
    case endIndex = "end_index"
  }
}

struct MessageAnnotationWire: Decodable {
  var type: String?
  var urlCitation: URLCitationWire?
  var url: String?
  var title: String?
  var content: String?
  var startIndex: Int?
  var endIndex: Int?

  enum CodingKeys: String, CodingKey {
    case type, url, title, content
    case urlCitation = "url_citation"
    case startIndex = "start_index"
    case endIndex = "end_index"
  }

  var normalizedCitation: ChatCitation? {
    if let nested = urlCitation, let url = nested.url, !url.isEmpty {
      return ChatCitation(
        url: url,
        title: nested.title,
        snippet: nested.content,
        startIndex: nested.startIndex,
        endIndex: nested.endIndex
      )
    }
    if type == "url_citation", let url, !url.isEmpty {
      return ChatCitation(
        url: url,
        title: title,
        snippet: content,
        startIndex: startIndex,
        endIndex: endIndex
      )
    }
    return nil
  }
}

struct ChatCompletionMessageWire: Decodable {
  var content: MessageContentWire?
  var reasoning: String?
  var reasoningContent: String?
  var reasoningDetails: [ReasoningDetailWire]?
  var toolCalls: [ToolCallWire]?
  var annotations: [MessageAnnotationWire]?
  enum CodingKeys: String, CodingKey {
    case content, reasoning, annotations
    case reasoningContent = "reasoning_content"
    case reasoningDetails = "reasoning_details"
    case toolCalls = "tool_calls"
  }
  var textContent: String? { content?.text }
  var normalizedReasoning: String? {
    let detailFragments = reasoningDetails?.compactMap(\.visibleText) ?? []
    if !detailFragments.isEmpty {
      return detailFragments.joined()
    }
    if let reasoning, !reasoning.isEmpty {
      return reasoning
    }
    if let reasoningContent, !reasoningContent.isEmpty {
      return reasoningContent
    }
    let contentFragments = (content?.reasoningFragments ?? []).filter { !$0.isEmpty }
    return contentFragments.isEmpty ? nil : contentFragments.joined()
  }
}

struct ReasoningDetailWire: Decodable {
  var rawObject: [String: JSONValue]

  init(from decoder: Decoder) throws {
    let value = try JSONValue(from: decoder)
    if case .object(let dict) = value {
      rawObject = dict
    } else {
      rawObject = [:]
    }
  }

  var type: String? {
    if case .string(let v)? = rawObject["type"] { return v }
    return nil
  }

  var id: String? {
    if case .string(let v)? = rawObject["id"] { return v }
    return nil
  }

  var format: String? {
    if case .string(let v)? = rawObject["format"] { return v }
    return nil
  }

  var index: Int? {
    if case .number(let n)? = rawObject["index"] { return Int(n) }
    return nil
  }

  var text: String? {
    if case .string(let v)? = rawObject["text"] { return v }
    return nil
  }

  var summary: String? {
    if case .string(let v)? = rawObject["summary"] { return v }
    return nil
  }

  var data: String? {
    if case .string(let v)? = rawObject["data"] { return v }
    return nil
  }

  var signature: String? {
    if case .string(let v)? = rawObject["signature"] { return v }
    return nil
  }

  var visibleText: String? {
    if let text, !text.isEmpty { return text }
    if let summary, !summary.isEmpty { return summary }
    return nil
  }
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
  var annotations: [MessageAnnotationWire]?
  init(
    content: MessageContentWire? = nil, reasoning: String? = nil, reasoningContent: String? = nil,
    reasoningDetails: [ReasoningDetailWire]? = nil, toolCalls: [ToolCallWire]? = nil,
    annotations: [MessageAnnotationWire]? = nil
  ) {
    self.content = content
    self.reasoning = reasoning
    self.reasoningContent = reasoningContent
    self.reasoningDetails = reasoningDetails
    self.toolCalls = toolCalls
    self.annotations = annotations
  }
  enum CodingKeys: String, CodingKey {
    case content, reasoning, annotations
    case reasoningContent = "reasoning_content"
    case reasoningDetails = "reasoning_details"
    case toolCalls = "tool_calls"
  }
  var textDelta: String? { content?.text }
  var reasoningFragments: [String] {
    let detailFragments = reasoningDetails?.compactMap(\.visibleText) ?? []
    if !detailFragments.isEmpty {
      return detailFragments
    }
    if let reasoning, !reasoning.isEmpty {
      return [reasoning]
    }
    if let reasoningContent, !reasoningContent.isEmpty {
      return [reasoningContent]
    }
    return (content?.reasoningFragments ?? []).filter { !$0.isEmpty }
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
      cacheWriteTokens: promptTokensDetails?.cacheWriteTokens
        ?? promptTokensDetails?.cacheCreationInputTokens,
      hasUnpricedCharges: (promptTokensDetails?.audioTokens ?? 0) > 0
        || (completionTokensDetails?.audioTokens ?? 0) > 0
        || (completionTokensDetails?.imageTokens ?? 0) > 0 ? true : nil
    )
  }
}

struct PromptTokensDetailsWire: Decodable {
  var cachedTokens: Int?
  var cacheWriteTokens: Int?
  var cacheCreationInputTokens: Int?
  var audioTokens: Int?
  enum CodingKeys: String, CodingKey {
    case cachedTokens = "cached_tokens"
    case cacheWriteTokens = "cache_write_tokens"
    case cacheCreationInputTokens = "cache_creation_input_tokens"
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
struct ProviderErrorMetadataWire: Decodable {
  var providerName: String?
  var raw: String?
  enum CodingKeys: String, CodingKey {
    case raw
    case providerName = "provider_name"
  }
}

struct ProviderErrorWire: Decodable {
  var code: String?
  var message: String
  var metadata: ProviderErrorMetadataWire?

  private enum CodingKeys: String, CodingKey {
    case code, message, metadata
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let stringCode = try? container.decodeIfPresent(String.self, forKey: .code) {
      code = stringCode
    } else if let intCode = try? container.decodeIfPresent(Int.self, forKey: .code) {
      code = String(intCode)
    } else {
      code = nil
    }
    message = try container.decode(String.self, forKey: .message)
    metadata = try? container.decodeIfPresent(ProviderErrorMetadataWire.self, forKey: .metadata)
  }

  var displayMessage: String {
    guard let metadata else { return message }
    let provider = metadata.providerName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let rawDetail = Self.extractRawMessage(metadata.raw)
    if let rawDetail, !rawDetail.isEmpty, rawDetail != message {
      if let provider, !provider.isEmpty {
        return "\(message) (\(provider): \(rawDetail))"
      }
      return "\(message) (\(rawDetail))"
    }
    if let provider, !provider.isEmpty {
      return "\(message) (\(provider))"
    }
    return message
  }

  private static func extractRawMessage(_ raw: String?) -> String? {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
      return nil
    }
    if let data = raw.data(using: .utf8),
      let json = try? JSONDecoder().decode(JSONValue.self, from: data),
      case .object(let root) = json
    {
      if case .object(let nested)? = root["error"],
        case .string(let nestedMsg)? = nested["message"],
        !nestedMsg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        return nestedMsg.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      if case .string(let topMsg)? = root["message"],
        !topMsg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        return topMsg.trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
    return raw.count <= 240 ? raw : String(raw.prefix(240)) + "…"
  }
}

struct XGroqWire: Decodable {
  var id: String?
  var usage: UsageWire?
}

struct ChatCompletionResponse: Decodable {
  var id: String?
  var model: String?
  var provider: String?
  var serviceTier: String?
  var choices: [ChatCompletionChoiceWire]
  var citations: [String]?
  var usage: UsageWire?
  var xGroq: XGroqWire?
  var error: ProviderErrorWire?
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decodeIfPresent(String.self, forKey: .id)
    model = try c.decodeIfPresent(String.self, forKey: .model)
    provider = try c.decodeIfPresent(String.self, forKey: .provider)
    serviceTier = try c.decodeIfPresent(String.self, forKey: .serviceTier)
    choices = try c.decodeIfPresent([ChatCompletionChoiceWire].self, forKey: .choices) ?? []
    citations = try? c.decodeIfPresent([String].self, forKey: .citations)
    xGroq = try c.decodeIfPresent(XGroqWire.self, forKey: .xGroq)
    usage = try c.decodeIfPresent(UsageWire.self, forKey: .usage) ?? xGroq?.usage
    error = try c.decodeIfPresent(ProviderErrorWire.self, forKey: .error)
  }
  private enum CodingKeys: String, CodingKey {
    case id, model, provider, choices, citations, usage, error
    case serviceTier = "service_tier"
    case xGroq = "x_groq"
  }
}

typealias ChatCompletionChunk = ChatCompletionResponse

struct ProviderErrorEnvelope: Decodable {
  var error: ProviderErrorWire?
  var message: String?
  var detail: ProviderErrorDetailWire?
  var title: String?

  var displayMessage: String? {
    if let value = error?.displayMessage.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    {
      return value
    }
    if let value = message?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
      return value
    }
    if let value = detail?.displayMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    {
      return value
    }
    if let value = title?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
      return value
    }
    return nil
  }
}

enum ProviderErrorDetailWire: Decodable {
  case string(String)
  case validationErrors([ProviderValidationErrorWire])

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let text = try? container.decode(String.self) {
      self = .string(text)
    } else if let errors = try? container.decode([ProviderValidationErrorWire].self) {
      self = .validationErrors(errors)
    } else {
      self = .string("")
    }
  }

  var displayMessage: String? {
    switch self {
    case .string(let text):
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    case .validationErrors(let errors):
      let parts = errors.compactMap(\.displayMessage)
      return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }
  }
}

struct ProviderValidationErrorWire: Decodable {
  var loc: [JSONValue]?
  var msg: String?

  var displayMessage: String? {
    guard let msg = msg?.trimmingCharacters(in: .whitespacesAndNewlines), !msg.isEmpty else {
      return nil
    }
    let path = (loc ?? []).compactMap { segment -> String? in
      switch segment {
      case .string(let value): return value
      case .number(let value): return String(Int(value))
      default: return nil
      }
    }
    guard !path.isEmpty else { return msg }
    return "\(path.joined(separator: ".")): \(msg)"
  }
}
struct ModelsResponse: Decodable {
  var data: [ModelWire]

  private enum CodingKeys: String, CodingKey { case data }

  init(from decoder: Decoder) throws {
    if let container = try? decoder.container(keyedBy: CodingKeys.self),
      let list = try? container.decode([ModelWire].self, forKey: .data)
    {
      data = list
      return
    }
    let singleValue = try decoder.singleValueContainer()
    data = try singleValue.decode([ModelWire].self)
  }
}
struct ModelWire: Decodable {
  var id: String
  var name: String?
  var displayName: String?
  var type: String?
  var active: Bool?
  var contextLength: Int?
  var maxContextLength: Int?
  var contextWindow: Int?
  var maxOutputTokens: Int?
  var maxCompletionTokens: Int?
  var inputModalities: [String]?
  var outputModalities: [String]?
  var effort: ModelEffortWire?
  var reasoning: ModelReasoningWire?
  var supportedParameters: [String]?
  var architecture: ArchitectureWire?
  var topProvider: TopProviderWire?
  var pricing: PricingWire?
  var capabilities: ModelCapabilitiesWire?
  var supportsChat: Bool?
  var supportsImageInput: Bool?
  var supportsTools: Bool?
  var archived: Bool?
  var endpoints: [String]?
  enum CodingKeys: String, CodingKey {
    case id, name, type, active, architecture, pricing, capabilities, archived, effort, reasoning, endpoints
    case displayName = "display_name"
    case contextLength = "context_length"
    case maxContextLength = "max_context_length"
    case contextWindow = "context_window"
    case maxOutputTokens = "max_output_tokens"
    case maxCompletionTokens = "max_completion_tokens"
    case inputModalities = "input_modalities"
    case outputModalities = "output_modalities"
    case supportedParameters = "supported_parameters"
    case topProvider = "top_provider"
    case supportsChat = "supports_chat"
    case supportsImageInput = "supports_image_input"
    case supportsTools = "supports_tools"
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
struct ModelReasoningWire: Decodable {
  var mandatory: Bool?
  var defaultEnabled: Bool?
  var defaultEffort: String?
  var supportedEfforts: [String]?
  var supportsMaxTokens: Bool?
  enum CodingKeys: String, CodingKey {
    case mandatory
    case defaultEnabled = "default_enabled"
    case defaultEffort = "default_effort"
    case supportedEfforts = "supported_efforts"
    case supportsMaxTokens = "supports_max_tokens"
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
  var inputPerMillion: BillingAmountWire?
  var outputPerMillion: BillingAmountWire?
  var cachedInputPerMillion: BillingAmountWire?
  var hourly: BillingAmountWire?
  var request: String?
  var image: String?
  var imageOutput: String?
  var audio: String?
  var webSearch: String?
  var internalReasoning: String?
  var hasAdditionalPricingDimensions: Bool? {
    let extra = [request, image, imageOutput, audio, webSearch, internalReasoning].compactMap { $0 }
    return extra.contains { (ChatBilling.decimal($0) ?? -1) != 0 } ? true : nil
  }
  enum CodingKeys: String, CodingKey {
    case prompt, completion, hourly, request, image, audio
    case inputPerMillion = "input"
    case outputPerMillion = "output"
    case cachedInputPerMillion = "cached_input"
    case imageOutput = "image_output"
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
