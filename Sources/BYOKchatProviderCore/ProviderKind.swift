import Foundation

/// The supported provider catalog. Every provider account stores its kind, and
/// every provider decision — wire adapter, auth header, editor fields, logos,
/// reasoning defaults — conditions on it. `.openAICompatible` covers
/// user-defined and self-hosted OpenAI-compatible servers; their endpoint,
/// auth, and path configuration lives on the account itself rather than in a
/// separate provider definition.
public enum ProviderKind: String, Codable, CaseIterable, Sendable {
  case anthropic
  case openai
  case xAI = "xai"
  case gemini
  case deepSeek
  case openRouter
  case nvidia
  case openAICompatible

  /// The catalog order used for provider pickers and lists. `.openAICompatible`
  /// is excluded: user-defined servers are configured, not catalogued.
  public static var catalog: [ProviderKind] {
    [.anthropic, .openai, .xAI, .gemini, .deepSeek, .openRouter, .nvidia]
  }

  /// The canonical provider ID for built-in kinds; `.openAICompatible` has no
  /// canonical identity (accounts carry their own).
  public var defaultProviderID: ProviderID? {
    switch self {
    case .anthropic: "anthropic"
    case .openai: "openai"
    case .xAI: "xai"
    case .gemini: "gemini"
    case .deepSeek: "deepseek"
    case .openRouter: "openrouter"
    case .nvidia: "nvidia"
    case .openAICompatible: nil
    }
  }

  /// Maps a stored provider ID to its kind. Unknown IDs are OpenAI-compatible
  /// servers; this is also the migration mapping for pre-kind workspaces.
  public init(providerID: ProviderID) {
    self = ProviderKind.allCases.first { $0.defaultProviderID == providerID } ?? .openAICompatible
  }
}

/// How an account authenticates. Built-in kinds pin one scheme;
/// `.userChoice` marks kinds (`.openAICompatible`) where the account itself
/// records the chosen scheme in `ProviderAccount.authChoice`.
public enum ProviderAuthSpec: Sendable, Equatable {
  case bearer
  case header(name: String)
  case none
  case userChoice

  /// The fixed scheme for spec-pinned kinds; nil for `.userChoice`.
  public var fixedAuthentication: ProviderAuthentication? {
    switch self {
    case .bearer: return .bearer
    case .header(let name): return .header(name: name)
    case .none: return ProviderAuthentication.none
    case .userChoice: return nil
    }
  }
}

/// Whether chat/models paths are pinned by the kind or configured per account.
public enum ProviderPathSpec: Sendable, Equatable {
  case fixed(chat: String, models: String?)
  case userEditable
}

/// Visual identity for list rows, picker strips, editor headers, and the chat
/// chip. Brand assets are optional at runtime: renderers fall back to a
/// monogram tile when the asset is not in the catalog.
public enum ProviderLogoSpec: Sendable, Equatable {
  case brand(assetName: String)
  case monogram
}

/// Per-kind extra credential/metadata fields surfaced in the editor
/// (currently OpenRouter's X-Title/HTTP-Referer routing metadata).
public enum ProviderExtraCredentialField: String, Sendable, CaseIterable {
  case appTitle
  case httpReferer
}

// MARK: - Kind spec

public extension ProviderKind {
  /// User-facing name. `.openAICompatible` providers are named by the user at
  /// creation, so the spec carries no display name for them.
  var displayName: String {
    switch self {
    case .anthropic: "Anthropic"
    case .openai: "OpenAI"
    case .xAI: "xAI"
    case .gemini: "Gemini"
    case .deepSeek: "DeepSeek"
    case .openRouter: "OpenRouter"
    case .nvidia: "NVIDIA"
    case .openAICompatible: ""
    }
  }

  var apiFamily: ProviderAPIFamily {
    switch self {
    case .anthropic: .anthropicMessages
    case .openai, .xAI: .openAIResponses
    case .gemini: .geminiGenerateContent
    case .deepSeek, .openRouter, .nvidia, .openAICompatible: .openAIChatCompletions
    }
  }

  var authSpec: ProviderAuthSpec {
    switch self {
    case .anthropic: .header(name: "x-api-key")
    case .gemini: .header(name: "x-goog-api-key")
    case .openai, .xAI, .deepSeek, .openRouter, .nvidia: .bearer
    case .openAICompatible: .userChoice
    }
  }

  var pathSpec: ProviderPathSpec {
    switch self {
    case .anthropic: .fixed(chat: "/v1/messages", models: "/v1/models")
    case .openai, .xAI: .fixed(chat: "/responses", models: "/models")
    case .gemini: .fixed(chat: "/models", models: "/models")
    case .deepSeek: .fixed(chat: "/chat/completions", models: "/models")
    case .openRouter: .fixed(chat: "/chat/completions", models: "/models")
    case .nvidia: .fixed(chat: "/chat/completions", models: nil)
    case .openAICompatible: .userEditable
    }
  }

  /// Coarse discovery capability of the kind. Whether a specific account can
  /// discover models also depends on its configured models path; use the
  /// account's derived definition for the exact answer.
  var supportsDiscovery: Bool {
    switch self {
    case .nvidia, .openAICompatible: false
    default: true
    }
  }

  var logo: ProviderLogoSpec {
    switch self {
    case .anthropic: .brand(assetName: "provider.anthropic")
    case .openai: .brand(assetName: "provider.openai")
    case .xAI: .brand(assetName: "provider.xai")
    case .gemini: .brand(assetName: "provider.gemini")
    case .deepSeek: .brand(assetName: "provider.deepseek")
    case .openRouter: .brand(assetName: "provider.openrouter")
    case .nvidia: .brand(assetName: "provider.nvidia")
    case .openAICompatible: .monogram
    }
  }

  /// Reasoning options applied to new chats when the user has not chosen a
  /// concrete effort (the "Auto" segment of the target picker).
  var reasoningDefault: ReasoningOptions? {
    switch self {
    case .deepSeek, .anthropic, .xAI: .init(enabled: true, effort: .high)
    case .gemini: .init(enabled: true, effort: .medium)
    case .openai, .openRouter, .nvidia, .openAICompatible: nil
    }
  }

  var contextWindowKind: ProviderContextWindowKind {
    switch self {
    case .anthropic, .gemini: .inputOnly
    case .openai, .xAI, .deepSeek, .openRouter, .nvidia, .openAICompatible: .combined
    }
  }

  var extraCredentialFields: Set<ProviderExtraCredentialField> {
    switch self {
    case .openRouter: [.appTitle, .httpReferer]
    default: []
    }
  }

  /// Curated fallback models merged into a fresh account so the model picker
  /// is usable before (or without) discovery.
  var seedModels: [ProviderModel] {
    catalogModels.map { $0.withCatalogEvidence() }
  }

  private var catalogModels: [ProviderModel] {
    switch self {
    case .openai:
      [
        .init(
          providerID: "openai", id: "gpt-6-astra", displayName: "GPT-6 Astra",
          contextWindow: 1_050_000, maxOutputTokens: 128_000,
          supportedParameters: ["max_output_tokens", "reasoning", "tools"],
          inputModalities: ["text", "image", "file"]),
        .init(
          providerID: "openai", id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol",
          contextWindow: 1_050_000, maxOutputTokens: 128_000,
          supportedParameters: ["max_output_tokens", "reasoning", "tools"],
          inputModalities: ["text", "image", "file"]),
        .init(
          providerID: "openai", id: "gpt-5.6-terra", displayName: "GPT-5.6 Terra",
          contextWindow: 1_050_000, maxOutputTokens: 128_000,
          supportedParameters: ["max_output_tokens", "reasoning", "tools"],
          inputModalities: ["text", "image", "file"]),
        .init(
          providerID: "openai", id: "gpt-5.6-luna", displayName: "GPT-5.6 Luna",
          contextWindow: 1_050_000, maxOutputTokens: 128_000,
          supportedParameters: ["max_output_tokens", "reasoning", "tools"],
          inputModalities: ["text", "image", "file"]),
      ]
    case .xAI:
      [
        .init(
          providerID: "xai", id: "grok-4.6", displayName: "Grok 4.6",
          contextWindow: 500_000,
          supportedParameters: ["max_output_tokens", "reasoning", "tools"],
          inputModalities: ["text", "image", "file"]),
        .init(
          providerID: "xai", id: "grok-4.20-0309-reasoning",
          displayName: "Grok 4.20 Reasoning", contextWindow: 1_000_000,
          supportedParameters: ["max_output_tokens", "reasoning", "tools"],
          inputModalities: ["text", "image", "file"]),
        .init(
          providerID: "xai", id: "grok-4.20-non-reasoning",
          displayName: "Grok 4.20 Non-Reasoning", contextWindow: 1_000_000,
          supportedParameters: ["temperature", "top_p", "max_output_tokens", "tools"],
          inputModalities: ["text", "image", "file"]),
        .init(
          providerID: "xai", id: "grok-4.20-multi-agent",
          displayName: "Grok 4.20 Multi-Agent", contextWindow: 1_000_000,
          supportedParameters: ["max_output_tokens", "reasoning", "tools"],
          inputModalities: ["text", "image", "file"]),
        .init(
          providerID: "xai", id: "grok-4.3", displayName: "Grok 4.3",
          contextWindow: 1_000_000,
          supportedParameters: ["max_output_tokens", "reasoning", "tools"],
          inputModalities: ["text", "image", "file"]),
      ]
    case .deepSeek:
      [
        .init(
          providerID: "deepseek", id: "deepseek-flash", displayName: "DeepSeek Flash",
          contextWindow: 1_000_000, maxOutputTokens: 384_000,
          supportedParameters: [
            "temperature", "top_p", "max_tokens", "thinking", "reasoning_effort", "tools",
          ]),
        .init(
          providerID: "deepseek", id: "deepseek-v4-pro", displayName: "DeepSeek V4 Pro",
          contextWindow: 1_000_000, maxOutputTokens: 384_000,
          supportedParameters: [
            "temperature", "top_p", "max_tokens", "thinking", "reasoning_effort", "tools",
          ]),
      ]
    case .openRouter:
      [
        .init(
          providerID: "openrouter", id: "openrouter/free", displayName: "OpenRouter Free",
          supportedParameters: ["temperature", "top_p", "max_tokens", "reasoning"]),
      ]
    case .nvidia:
      [
        .init(
          providerID: "nvidia", id: "deepseek-ai/deepseek-v4-flash",
          displayName: "DeepSeek V4 Flash",
          supportedParameters: ["temperature", "top_p", "max_tokens"]),
        .init(
          providerID: "nvidia", id: "deepseek-ai/deepseek-v4-pro", displayName: "DeepSeek V4 Pro",
          supportedParameters: ["temperature", "top_p", "max_tokens"]),
        .init(
          providerID: "nvidia", id: "nvidia/nemotron-3-ultra-550b-a55b",
          displayName: "Nemotron 3 Ultra 550B",
          supportedParameters: ["temperature", "top_p", "max_tokens"]),
        .init(
          providerID: "nvidia", id: "qwen/qwen3.5-122b-a10b", displayName: "Qwen 3.5 122B A10B",
          supportedParameters: ["temperature", "top_p", "max_tokens"]),
      ]
    case .anthropic:
      [
        .init(
          providerID: "anthropic", id: "claude-sonnet-5", displayName: "Claude Sonnet 5",
          contextWindow: 1_000_000, contextWindowKind: .inputOnly, maxOutputTokens: 128_000,
          supportedParameters: ["max_tokens", "thinking", "effort", "tools"],
          inputModalities: ["text", "image", "file"]),
        .init(
          providerID: "anthropic", id: "claude-opus-5", displayName: "Claude Opus 5",
          contextWindow: 1_000_000, contextWindowKind: .inputOnly, maxOutputTokens: 128_000,
          supportedParameters: ["max_tokens", "thinking", "effort", "tools"],
          inputModalities: ["text", "image", "file"]),
      ]
    case .gemini:
      [
        .init(
          providerID: "gemini", id: "gemini-3.6-flash", displayName: "Gemini 3.6 Flash",
          contextWindow: 1_048_576, contextWindowKind: .inputOnly, maxOutputTokens: 65_536,
          supportedParameters: ["maxOutputTokens", "thinkingConfig", "tools"],
          inputModalities: ["text", "image", "file"]),
      ]
    case .openAICompatible:
      []
    }
  }
}

// MARK: - Derived wire definitions

/// Placeholder base URL for accounts that cannot produce a valid endpoint.
/// Requests through such a definition fail URL validation with a clear error.
private let invalidEndpointPlaceholder = URL(string: "https://invalid.invalid")!

public extension ProviderAccount {
  /// The account's wire definition, derived from its kind. Built-in kinds use
  /// the static catalog spec; `.openAICompatible` accounts carry endpoint,
  /// auth, path, and seed configuration on the account itself (folded in by
  /// migration or set at creation).
  var definition: ProviderDefinition {
    kind.definition(
      providerID: providerID,
      displayName: label,
      baseURLOverride: baseURLOverride,
      chatPath: chatCompletionsPath,
      modelsPath: modelsPath,
      authentication: authChoice,
      seedModelIDs: seedModelIDs
    )
    .withKind(kind)
  }
}

public extension ResolvedProviderAccount {
  /// Same derivation as `ProviderAccount.definition`, evaluated against the
  /// resolved (credential-bearing) view of the account.
  var definition: ProviderDefinition {
    kind.definition(
      providerID: providerID,
      displayName: label,
      baseURLOverride: baseURLOverride,
      chatPath: chatCompletionsPath,
      modelsPath: modelsPath,
      authentication: authChoice,
      seedModelIDs: seedModelIDs
    )
    .withKind(kind)
  }
}

public extension ProviderDefinition {
  /// UI conditioning aid: the kind this definition was derived from.
  func withKind(_ value: ProviderKind) -> ProviderDefinition {
    var result = self
    result.kind = value
    return result
  }
}

public extension ProviderKind {
  /// Builds the wire definition consumed by the API-family adapters.
  ///
  /// - For built-in kinds the base URL is the kind default; per-account
  ///   endpoint overrides are applied by the adapters on top of it.
  /// - For `.openAICompatible` the account's endpoint *is* the base URL; a
  ///   missing endpoint degrades to an invalid placeholder so requests fail
  ///   validation instead of crashing derivation.
  func definition(
    providerID: ProviderID,
    displayName: String,
    baseURLOverride: URL?,
    chatPath: String?,
    modelsPath: String?,
    authentication: ProviderAuthentication?,
    seedModelIDs: [String]?
  ) -> ProviderDefinition {
    switch self {
    case .openAICompatible:
      return ProviderDefinition(
        id: providerID,
        displayName: displayName,
        behavior: .genericOpenAICompatible,
        defaultBaseURL: baseURLOverride ?? invalidEndpointPlaceholder,
        chatCompletionsPath: chatPath ?? "/chat/completions",
        modelsPath: modelsPath,
        authentication: authentication ?? .bearer,
        seedModels: (seedModelIDs ?? []).map {
          .init(providerID: providerID, id: ModelID(rawValue: $0), displayName: $0)
        }
      )
    default:
      let chat: String
      let models: String?
      switch pathSpec {
      case .fixed(let fixedChatPath, let fixedModelsPath):
        chat = fixedChatPath
        models = fixedModelsPath
      case .userEditable:
        chat = chatPath ?? "/chat/completions"
        models = modelsPath
      }
      let effectiveAuth = authSpec.fixedAuthentication ?? authentication ?? .bearer
      return ProviderDefinition(
        id: providerID,
        displayName: self.displayName,
        apiFamily: apiFamily,
        behavior: behaviorID,
        defaultBaseURL: defaultEndpoint ?? invalidEndpointPlaceholder,
        chatCompletionsPath: chat,
        modelsPath: models,
        authentication: effectiveAuth,
        seedModels: seedModels.map { model in
          var remapped = model
          remapped.providerID = providerID
          return remapped
        },
        isBuiltIn: true,
        kind: self
      )
    }
  }

  /// Default base URL for built-in kinds; nil means the account must supply
  /// the endpoint (`.openAICompatible`).
  var defaultEndpoint: URL? {
    switch self {
    case .anthropic: URL(string: "https://api.anthropic.com")
    case .openai: URL(string: "https://api.openai.com/v1")
    case .xAI: URL(string: "https://api.x.ai/v1")
    case .gemini: URL(string: "https://generativelanguage.googleapis.com/v1beta")
    case .deepSeek: URL(string: "https://api.deepseek.com")
    case .openRouter: URL(string: "https://openrouter.ai/api/v1")
    case .nvidia: URL(string: "https://integrate.api.nvidia.com/v1")
    case .openAICompatible: nil
    }
  }

  var behaviorID: ProviderBehaviorID {
    switch self {
    case .anthropic: .anthropic
    case .openai, .xAI: .genericOpenAICompatible
    case .gemini: .gemini
    case .deepSeek: .deepSeek
    case .openRouter: .openRouter
    case .nvidia: .nvidia
    case .openAICompatible: .genericOpenAICompatible
    }
  }
}
