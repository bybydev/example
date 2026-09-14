import Foundation

public struct ProviderID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral,
  CustomStringConvertible
{
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(stringLiteral value: String) { self.rawValue = value }
  public var description: String { rawValue }
}

public struct ProviderAccountID: RawRepresentable, Hashable, Codable, Sendable,
  ExpressibleByStringLiteral, CustomStringConvertible
{
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(stringLiteral value: String) { self.rawValue = value }
  public var description: String { rawValue }
}

public struct ModelID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral,
  CustomStringConvertible
{
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(stringLiteral value: String) { self.rawValue = value }
  public var description: String { rawValue }
}

public enum ProviderMessageRole: String, Codable, Sendable { case system, user, assistant, tool }

public struct ProviderMessage: Codable, Sendable, Equatable {
  public var role: ProviderMessageRole
  public var content: String
  public var reasoning: String?
  public var attachments: [ChatAttachment]?
  public var toolCalls: [ChatToolCall]?
  public var toolResults: [ChatToolResult]?
  public var toolContinuation: ProviderToolContinuation?

  public init(
    role: ProviderMessageRole,
    content: String,
    reasoning: String? = nil,
    attachments: [ChatAttachment]? = nil,
    toolCalls: [ChatToolCall]? = nil,
    toolResults: [ChatToolResult]? = nil,
    toolContinuation: ProviderToolContinuation? = nil
  ) {
    self.role = role
    self.content = content
    self.reasoning = reasoning
    self.attachments = attachments
    self.toolCalls = toolCalls
    self.toolResults = toolResults
    self.toolContinuation = toolContinuation
  }
}

public enum ReasoningEffort: String, Codable, Sendable, CaseIterable {
  case minimal, low, medium, high, max
}

public struct ReasoningOptions: Codable, Sendable, Equatable {
  public var enabled: Bool?
  public var effort: ReasoningEffort?
  public var maxTokens: Int?
  public var excludeFromResponse: Bool
  public init(
    enabled: Bool? = nil, effort: ReasoningEffort? = nil, maxTokens: Int? = nil,
    excludeFromResponse: Bool = false
  ) {
    self.enabled = enabled
    self.effort = effort
    self.maxTokens = maxTokens
    self.excludeFromResponse = excludeFromResponse
  }
}

public enum OpenRouterSort: String, Codable, Sendable, CaseIterable {
  case price, throughput, latency
}
public enum OpenRouterDataCollection: String, Codable, Sendable, CaseIterable { case allow, deny }

public struct OpenRouterRoutingOptions: Codable, Sendable, Equatable {
  public var providerOrder: [String]
  public var allowFallbacks: Bool?
  public var requireParameters: Bool?
  public var dataCollection: OpenRouterDataCollection?
  public var zeroDataRetention: Bool?
  public var sort: OpenRouterSort?
  public init(
    providerOrder: [String] = [],
    allowFallbacks: Bool? = nil,
    requireParameters: Bool? = nil,
    dataCollection: OpenRouterDataCollection? = nil,
    zeroDataRetention: Bool? = nil,
    sort: OpenRouterSort? = nil
  ) {
    self.providerOrder = providerOrder
    self.allowFallbacks = allowFallbacks
    self.requireParameters = requireParameters
    self.dataCollection = dataCollection
    self.zeroDataRetention = zeroDataRetention
    self.sort = sort
  }
}

public struct ProviderRequestOptions: Codable, Sendable, Equatable {
  public var temperature: Double?
  public var topP: Double?
  public var maxOutputTokens: Int?
  public var reasoning: ReasoningOptions?
  public var openRouterRouting: OpenRouterRoutingOptions?
  public init(
    temperature: Double? = nil,
    topP: Double? = nil,
    maxOutputTokens: Int? = nil,
    reasoning: ReasoningOptions? = nil,
    openRouterRouting: OpenRouterRoutingOptions? = nil
  ) {
    self.temperature = temperature
    self.topP = topP
    self.maxOutputTokens = maxOutputTokens
    self.reasoning = reasoning
    self.openRouterRouting = openRouterRouting
  }
}

public struct ProviderRequest: Sendable, Equatable {
  public var model: ModelID
  public var messages: [ProviderMessage]
  public var options: ProviderRequestOptions
  public var tools: [ChatToolDefinition]
  public init(
    model: ModelID,
    messages: [ProviderMessage],
    options: ProviderRequestOptions = .init(),
    tools: [ChatToolDefinition] = []
  ) {
    self.model = model
    self.messages = messages
    self.options = options
    self.tools = tools
  }
}

public struct ProviderUsage: Codable, Sendable, Equatable {
  public var inputTokens: Int?
  public var outputTokens: Int?
  public var cachedInputTokens: Int?
  public var reasoningTokens: Int?
  public init(
    inputTokens: Int? = nil, outputTokens: Int? = nil, cachedInputTokens: Int? = nil,
    reasoningTokens: Int? = nil
  ) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.cachedInputTokens = cachedInputTokens
    self.reasoningTokens = reasoningTokens
  }
}

public struct ProviderResponse: Sendable, Equatable {
  public var id: String?
  public var text: String
  public var reasoning: String
  public var providerID: ProviderID
  public var accountID: ProviderAccountID
  public var modelID: ModelID
  public var finishReason: String?
  public var usage: ProviderUsage?
  public var metadata: [String: String]
  public var toolCalls: [ChatToolCall]
  public var toolContinuation: ProviderToolContinuation?
  public init(
    id: String? = nil,
    text: String,
    reasoning: String = "",
    providerID: ProviderID,
    accountID: ProviderAccountID,
    modelID: ModelID,
    finishReason: String? = nil,
    usage: ProviderUsage? = nil,
    metadata: [String: String] = [:],
    toolCalls: [ChatToolCall] = [],
    toolContinuation: ProviderToolContinuation? = nil
  ) {
    self.id = id
    self.text = text
    self.reasoning = reasoning
    self.providerID = providerID
    self.accountID = accountID
    self.modelID = modelID
    self.finishReason = finishReason
    self.usage = usage
    self.metadata = metadata
    self.toolCalls = toolCalls
    self.toolContinuation = toolContinuation
  }
}

public enum ProviderStreamEvent: Sendable, Equatable {
  case textDelta(String)
  case reasoningDelta(String)
  case usage(ProviderUsage)
  case completed(ProviderResponse)
}

/// Describes what `ProviderModel.contextWindow` means for budgeting.
///
/// Some provider model-list APIs expose a combined input+output context length, while others
/// expose a dedicated maximum input-token count. Keeping the distinction explicit prevents the
/// context reducer from subtracting output capacity twice.
public enum ProviderContextWindowKind: String, Codable, Sendable, Hashable {
  case combined
  case inputOnly
}

public struct ProviderModel: Codable, Sendable, Hashable, Identifiable {
  public var providerID: ProviderID
  public var id: ModelID
  public var displayName: String
  public var contextWindow: Int?
  /// Optional for backward-compatible decoding of previously persisted provider workspaces.
  public var contextWindowKind: ProviderContextWindowKind?
  public var maxOutputTokens: Int?
  public var supportedParameters: Set<String>
  public var inputModalities: Set<String>
  public var outputModalities: Set<String>
  public var promptPricePerToken: String?
  public var completionPricePerToken: String?
  /// Legacy field: no longer written, decoded-and-dropped so old persisted
  /// workspaces and exports still decode.
  private var isSeed: Bool?

  public init(
    providerID: ProviderID,
    id: ModelID,
    displayName: String,
    contextWindow: Int? = nil,
    contextWindowKind: ProviderContextWindowKind? = nil,
    maxOutputTokens: Int? = nil,
    supportedParameters: Set<String> = [],
    inputModalities: Set<String> = ["text"],
    outputModalities: Set<String> = ["text"],
    promptPricePerToken: String? = nil,
    completionPricePerToken: String? = nil
  ) {
    self.providerID = providerID
    self.id = id
    self.displayName = displayName
    self.contextWindow = contextWindow
    self.contextWindowKind = contextWindowKind
    self.maxOutputTokens = maxOutputTokens
    self.supportedParameters = supportedParameters
    self.inputModalities = inputModalities
    self.outputModalities = outputModalities
    self.promptPricePerToken = promptPricePerToken
    self.completionPricePerToken = completionPricePerToken
    self.isSeed = nil
  }

  public var effectiveContextWindowKind: ProviderContextWindowKind {
    if let contextWindowKind { return contextWindowKind }

    // Older persisted records and native model-discovery responses do not yet carry this field.
    // Provider kind semantics now live in the kind spec; the rawValue switch remains only as a
    // decoding fallback for legacy records.
    switch providerID.rawValue {
    case "anthropic", "gemini": return .inputOnly
    default: return .combined
    }
  }
}

public enum ProviderAPIFamily: String, Codable, Sendable {
  case openAIChatCompletions
  case openAIResponses
  case anthropicMessages
  case geminiGenerateContent
}

public enum ProviderBehaviorID: String, Codable, Sendable {
  case deepSeek, openRouter, nvidia, anthropic, gemini, genericOpenAICompatible
}

public enum ProviderAuthentication: Codable, Sendable, Equatable {
  case bearer
  case header(name: String)
  case none
}

public struct ProviderDefinition: Codable, Sendable, Identifiable, Equatable {
  public var id: ProviderID
  public var displayName: String
  public var apiFamily: ProviderAPIFamily
  public var behavior: ProviderBehaviorID
  public var defaultBaseURL: URL
  public var chatCompletionsPath: String
  public var modelsPath: String?
  public var authentication: ProviderAuthentication
  public var seedModels: [ProviderModel]
  public var isBuiltIn: Bool
  /// The supported-provider kind this definition was derived from. Not
  /// persisted on custom definitions; derived views populate it for UI
  /// conditioning.
  public var kind: ProviderKind?
  public init(
    id: ProviderID,
    displayName: String,
    apiFamily: ProviderAPIFamily = .openAIChatCompletions,
    behavior: ProviderBehaviorID,
    defaultBaseURL: URL,
    chatCompletionsPath: String = "/chat/completions",
    modelsPath: String? = "/models",
    authentication: ProviderAuthentication = .bearer,
    seedModels: [ProviderModel] = [],
    isBuiltIn: Bool = false,
    kind: ProviderKind? = nil
  ) {
    self.id = id
    self.displayName = displayName
    self.apiFamily = apiFamily
    self.behavior = behavior
    self.defaultBaseURL = defaultBaseURL
    self.chatCompletionsPath = chatCompletionsPath
    self.modelsPath = modelsPath
    self.authentication = authentication
    self.seedModels = seedModels
    self.isBuiltIn = isBuiltIn
    self.kind = kind
  }
}

public struct ProviderAccount: Codable, Sendable, Identifiable, Equatable {
  /// Which supported provider this account talks to. Drives wire format, auth
  /// scheme, editor conditioning, and behavior across the app.
  public var kind: ProviderKind
  /// OpenAI-compatible-only configuration (folded in from custom provider
  /// definitions by migration, or set at creation). Nil for built-in kinds.
  public var chatCompletionsPath: String?
  public var modelsPath: String?
  public var authChoice: ProviderAuthentication?
  public var seedModelIDs: [String]?
  public var id: ProviderAccountID
  public var providerID: ProviderID
  public var label: String
  public var baseURLOverride: URL?
  public var additionalHeaders: [String: String]
  public var metadata: [String: String]
  public var defaultModelID: ModelID?
  public var isEnabled: Bool
  public var createdAt: Date
  public var updatedAt: Date
  public init(
    kind: ProviderKind,
    id: ProviderAccountID = ProviderAccountID(rawValue: UUID().uuidString.lowercased()),
    providerID: ProviderID? = nil,
    label: String,
    chatCompletionsPath: String? = nil,
    modelsPath: String? = nil,
    authChoice: ProviderAuthentication? = nil,
    seedModelIDs: [String]? = nil,
    baseURLOverride: URL? = nil,
    additionalHeaders: [String: String] = [:],
    metadata: [String: String] = [:],
    defaultModelID: ModelID? = nil,
    isEnabled: Bool = true,
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) {
    self.kind = kind
    self.id = id
    self.providerID = providerID ?? kind.defaultProviderID ?? ProviderID(rawValue: id.rawValue)
    self.chatCompletionsPath = chatCompletionsPath
    self.modelsPath = modelsPath
    self.authChoice = authChoice
    self.seedModelIDs = seedModelIDs
    self.label = label
    self.baseURLOverride = baseURLOverride
    self.additionalHeaders = additionalHeaders
    self.metadata = metadata
    self.defaultModelID = defaultModelID
    self.isEnabled = isEnabled
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct ResolvedProviderAccount: Sendable, Equatable {
  public var kind: ProviderKind
  public var id: ProviderAccountID
  public var providerID: ProviderID
  public var label: String
  public var apiKey: String?
  public var baseURLOverride: URL?
  public var additionalHeaders: [String: String]
  public var metadata: [String: String]
  public var chatCompletionsPath: String?
  public var modelsPath: String?
  public var authChoice: ProviderAuthentication?
  public var seedModelIDs: [String]?
  public init(
    kind: ProviderKind,
    id: ProviderAccountID,
    providerID: ProviderID,
    label: String,
    apiKey: String?,
    baseURLOverride: URL? = nil,
    additionalHeaders: [String: String] = [:],
    metadata: [String: String] = [:],
    chatCompletionsPath: String? = nil,
    modelsPath: String? = nil,
    authChoice: ProviderAuthentication? = nil,
    seedModelIDs: [String]? = nil
  ) {
    self.kind = kind
    self.id = id
    self.providerID = providerID
    self.label = label
    self.apiKey = apiKey
    self.baseURLOverride = baseURLOverride
    self.additionalHeaders = additionalHeaders
    self.metadata = metadata
    self.chatCompletionsPath = chatCompletionsPath
    self.modelsPath = modelsPath
    self.authChoice = authChoice
    self.seedModelIDs = seedModelIDs
  }
}
