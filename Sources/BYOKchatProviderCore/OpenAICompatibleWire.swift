import Foundation

struct ChatCompletionMessageWire: Decodable {
  var content: String?
  var reasoning: String?
  var reasoningContent: String?
  var reasoningDetails: [ReasoningDetailWire]?
  enum CodingKeys: String, CodingKey {
    case content, reasoning
    case reasoningContent = "reasoning_content"
    case reasoningDetails = "reasoning_details"
  }
  var normalizedReasoning: String? {
    let details = reasoningDetails?.compactMap { $0.text ?? $0.summary }.joined() ?? ""
    let values = [reasoning, reasoningContent, details].compactMap { $0 }.filter { !$0.isEmpty }
    return values.isEmpty ? nil : values.joined()
  }
}

struct ReasoningDetailWire: Decodable {
  var text: String?
  var summary: String?
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
  var content: String?
  var reasoning: String?
  var reasoningContent: String?
  var reasoningDetails: [ReasoningDetailWire]?
  init(
    content: String? = nil, reasoning: String? = nil, reasoningContent: String? = nil,
    reasoningDetails: [ReasoningDetailWire]? = nil
  ) {
    self.content = content
    self.reasoning = reasoning
    self.reasoningContent = reasoningContent
    self.reasoningDetails = reasoningDetails
  }
  enum CodingKeys: String, CodingKey {
    case content, reasoning
    case reasoningContent = "reasoning_content"
    case reasoningDetails = "reasoning_details"
  }
  var reasoningFragments: [String] {
    [reasoning, reasoningContent].compactMap { $0 }
      + (reasoningDetails?.compactMap { $0.text ?? $0.summary } ?? [])
  }
}

struct UsageWire: Decodable {
  var promptTokens: Int?
  var completionTokens: Int?
  var promptTokensDetails: PromptTokensDetailsWire?
  var completionTokensDetails: CompletionTokensDetailsWire?
  enum CodingKeys: String, CodingKey {
    case promptTokens = "prompt_tokens"
    case completionTokens = "completion_tokens"
    case promptTokensDetails = "prompt_tokens_details"
    case completionTokensDetails = "completion_tokens_details"
  }
  var normalized: ProviderUsage {
    .init(
      inputTokens: promptTokens,
      outputTokens: completionTokens,
      cachedInputTokens: promptTokensDetails?.cachedTokens,
      reasoningTokens: completionTokensDetails?.reasoningTokens
    )
  }
}

struct PromptTokensDetailsWire: Decodable {
  var cachedTokens: Int?
  enum CodingKeys: String, CodingKey { case cachedTokens = "cached_tokens" }
}
struct CompletionTokensDetailsWire: Decodable {
  var reasoningTokens: Int?
  enum CodingKeys: String, CodingKey { case reasoningTokens = "reasoning_tokens" }
}
struct ProviderErrorWire: Decodable {
  var code: String?
  var message: String
}

struct ChatCompletionResponse: Decodable {
  var id: String?
  var model: String?
  var provider: String?
  var choices: [ChatCompletionChoiceWire]
  var usage: UsageWire?
  var error: ProviderErrorWire?
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decodeIfPresent(String.self, forKey: .id)
    model = try c.decodeIfPresent(String.self, forKey: .model)
    provider = try c.decodeIfPresent(String.self, forKey: .provider)
    choices = try c.decodeIfPresent([ChatCompletionChoiceWire].self, forKey: .choices) ?? []
    usage = try c.decodeIfPresent(UsageWire.self, forKey: .usage)
    error = try c.decodeIfPresent(ProviderErrorWire.self, forKey: .error)
  }
  private enum CodingKeys: String, CodingKey { case id, model, provider, choices, usage, error }
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
  var supportedParameters: [String]?
  var architecture: ArchitectureWire?
  var topProvider: TopProviderWire?
  var pricing: PricingWire?
  enum CodingKeys: String, CodingKey {
    case id, name, architecture, pricing
    case contextLength = "context_length"
    case supportedParameters = "supported_parameters"
    case topProvider = "top_provider"
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
}
