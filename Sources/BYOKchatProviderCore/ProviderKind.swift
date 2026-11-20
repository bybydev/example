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
  case zAI = "zai"
  case moonshot
  case minimax
  case mistral
  case openRouter
  case nvidia
  case ollama
  case lmStudio = "lmstudio"
  case openAICompatible

  /// Cloud providers shown under the "Cloud Providers" group in pickers.
  public static var cloudCatalog: [ProviderKind] {
    [.anthropic, .openai, .xAI, .gemini, .deepSeek, .zAI, .moonshot, .minimax, .mistral, .openRouter, .nvidia]
  }

  /// Local and custom providers shown under the "Local & Custom" group in pickers.
  public static var localAndCustomCatalog: [ProviderKind] {
    [.ollama, .lmStudio, .openAICompatible]
  }

  /// The catalog order used for built-in provider lists. `.openAICompatible`
  /// is excluded: user-defined servers are configured, not catalogued.
  public static var catalog: [ProviderKind] {
    cloudCatalog + [.ollama, .lmStudio]
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
    case .zAI: "zai"
    case .moonshot: "moonshot"
    case .minimax: "minimax"
    case .mistral: "mistral"
    case .openRouter: "openrouter"
    case .nvidia: "nvidia"
    case .ollama: "ollama"
    case .lmStudio: "lmstudio"
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
    case .zAI: "Z.ai"
    case .moonshot: "Moonshot AI"
    case .minimax: "MiniMax"
    case .mistral: "Mistral AI"
    case .openRouter: "OpenRouter"
    case .nvidia: "NVIDIA"
    case .ollama: "Ollama"
    case .lmStudio: "LM Studio"
    case .openAICompatible: ""
    }
  }

  var apiFamily: ProviderAPIFamily {
    switch self {
    case .anthropic: .anthropicMessages
    case .openai, .xAI: .openAIResponses
    case .gemini: .geminiGenerateContent
    case .deepSeek, .zAI, .moonshot, .minimax, .mistral, .openRouter, .nvidia, .ollama, .lmStudio, .openAICompatible: .openAIChatCompletions
    }
  }

  var authSpec: ProviderAuthSpec {
    switch self {
    case .anthropic: .header(name: "x-api-key")
    case .gemini: .header(name: "x-goog-api-key")
    case .openai, .xAI, .deepSeek, .zAI, .moonshot, .minimax, .mistral, .openRouter, .nvidia, .ollama, .lmStudio: .bearer
    case .openAICompatible: .userChoice
    }
  }

  /// Whether an account of this kind must store an API key to send requests.
  /// Local and custom OpenAI-compatible servers treat credentials as optional.
  var requiresCredential: Bool {
    switch self {
    case .ollama, .lmStudio, .openAICompatible: false
    default: true
    }
  }

  /// Whether cleartext `http://` is allowed for private/LAN hosts.
  var allowsLocalHTTP: Bool {
    switch self {
    case .ollama, .lmStudio, .openAICompatible: true
    default: false
    }
  }

  /// True for first-class local server kinds (Ollama, LM Studio).
  var isLocalServer: Bool {
    switch self {
    case .ollama, .lmStudio: true
    default: false
    }
  }

  /// Auto-appends `/v1` when an Ollama or LM Studio base URL omits a path.
  func normalizedBaseURL(_ url: URL) -> URL {
    guard isLocalServer,
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else {
      return url
    }
    if components.path.isEmpty || components.path == "/" {
      components.path = "/v1"
      return components.url ?? url
    }
    if components.path == "/v1/" {
      components.path = "/v1"
      return components.url ?? url
    }
    return url
  }

  var pathSpec: ProviderPathSpec {
    switch self {
    case .anthropic: .fixed(chat: "/v1/messages", models: "/v1/models")
    case .openai, .xAI: .fixed(chat: "/responses", models: "/models")
    case .gemini: .fixed(chat: "/models", models: "/models")
    case .deepSeek: .fixed(chat: "/chat/completions", models: "/models")
    case .zAI: .fixed(chat: "/chat/completions", models: "/models")
    case .moonshot: .fixed(chat: "/chat/completions", models: "/models")
    case .minimax: .fixed(chat: "/chat/completions", models: "/models")
    case .mistral: .fixed(chat: "/chat/completions", models: "/models")
    case .openRouter: .fixed(chat: "/chat/completions", models: "/models")
    case .nvidia: .fixed(chat: "/chat/completions", models: nil)
    case .ollama, .lmStudio: .fixed(chat: "/chat/completions", models: "/models")
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
    case .zAI: .brand(assetName: "provider.zai")
    case .moonshot: .brand(assetName: "provider.moonshot")
    case .minimax: .brand(assetName: "provider.minimax")
    case .mistral: .brand(assetName: "provider.mistral")
    case .openRouter: .brand(assetName: "provider.openrouter")
    case .nvidia: .brand(assetName: "provider.nvidia")
    case .ollama: .brand(assetName: "provider.ollama")
    case .lmStudio: .brand(assetName: "provider.lmstudio")
    case .openAICompatible: .monogram
    }
  }

  /// Reasoning options applied to new chats when the user has not chosen a
  /// concrete effort (the "Auto" segment of the target picker).
  var reasoningDefault: ReasoningOptions? {
    switch self {
    case .deepSeek, .anthropic, .xAI: .init(enabled: true, effort: .high)
    case .gemini: .init(enabled: true, effort: .medium)
    case .openai, .zAI, .moonshot, .minimax, .mistral, .openRouter, .nvidia, .ollama, .lmStudio, .openAICompatible: nil
    }
  }

  var contextWindowKind: ProviderContextWindowKind {
    switch self {
    case .anthropic, .gemini: .inputOnly
    case .openai, .xAI, .deepSeek, .zAI, .moonshot, .minimax, .mistral, .openRouter, .nvidia, .ollama, .lmStudio, .openAICompatible: .combined
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
          providerID: "openai", id: "gpt-6.2-astra", displayName: "GPT-6.2 Astra",
          contextWindow: 1_050_000, maxOutputTokens: 128_000,
          supportedParameters: ["max_output_tokens", "reasoning", "tools"],
          inputModalities: ["text", "image", "file"]),
        .init(
          providerID: "openai", id: "gpt-6.2-sol", displayName: "GPT-6.2 Sol",
          contextWindow: 1_050_000, maxOutputTokens: 128_000,
          supportedParameters: ["max_output_tokens", "reasoning", "tools"],
          inputModalities: ["text", "image", "file"]),
        .init(
          providerID: "openai", id: "gpt-6.1-terra", displayName: "GPT-6.1 Terra",
          contextWindow: 1_050_000, maxOutputTokens: 128_000,
          supportedParameters: ["max_output_tokens", "reasoning", "tools"],
          inputModalities: ["text", "image", "file"]),
        .init(
          providerID: "openai", id: "gpt-6-luna", displayName: "GPT-6 Luna",
          contextWindow: 1_050_000, maxOutputTokens: 128_000,
          supportedParameters: ["max_output_tokens", "reasoning", "tools"],
          inputModalities: ["text", "image", "file"]),
        .init(
          providerID: "openai", id: "gpt-6.1-sol", displayName: "GPT-6.1 Sol",
          contextWindow: 1_050_000, maxOutputTokens: 128_000,
          supportedParameters: ["max_output_tokens", "reasoning", "tools"],
          inputModalities: ["text", "image", "file"]),
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
          providerID: "xai", id: "grok-4.7", displayName: "Grok 4.7",
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
    case .zAI:
      [
        .init(
          providerID: "zai", id: "glm-5.3", displayName: "GLM-5.3",
          contextWindow: 1_000_000, maxOutputTokens: 128_000,
          supportedParameters: [
            "temperature", "top_p", "max_tokens", "thinking", "reasoning_effort", "tools",
          ]),
        .init(
          providerID: "zai", id: "glm-5.3-flash", displayName: "GLM-5.3 Flash",
          contextWindow: 1_000_000, maxOutputTokens: 128_000,
          supportedParameters: [
            "temperature", "top_p", "max_tokens", "thinking", "reasoning_effort", "tools",
          ],
          inputModalities: ["text", "image"]),
        .init(
          providerID: "zai", id: "glm-5.3-flashx", displayName: "GLM-5.3 FlashX",
          contextWindow: 1_000_000, maxOutputTokens: 128_000,
          supportedParameters: [
            "temperature", "top_p", "max_tokens", "thinking", "reasoning_effort", "tools",
          ],
          inputModalities: ["text", "image"]),
        .init(
          providerID: "zai", id: "glm-5.2", displayName: "GLM-5.2",
          contextWindow: 1_000_000, maxOutputTokens: 128_000,
          supportedParameters: [
            "temperature", "top_p", "max_tokens", "thinking", "reasoning_effort", "tools",
          ]),
        .init(
          providerID: "zai", id: "glm-5.1", displayName: "GLM-5.1",
          contextWindow: 200_000, maxOutputTokens: 128_000,
          supportedParameters: ["temperature", "top_p", "max_tokens", "thinking", "tools"]),
        .init(
          providerID: "zai", id: "glm-5v-turbo", displayName: "GLM-5V Turbo",
          contextWindow: 200_000, maxOutputTokens: 128_000,
          supportedParameters: ["temperature", "top_p", "max_tokens", "thinking", "tools"],
          inputModalities: ["text", "image"]),
        .init(
          providerID: "zai", id: "glm-5-turbo", displayName: "GLM-5 Turbo",
          contextWindow: 200_000, maxOutputTokens: 128_000,
          supportedParameters: ["temperature", "top_p", "max_tokens", "thinking", "tools"]),
        .init(
          providerID: "zai", id: "glm-5", displayName: "GLM-5",
          contextWindow: 200_000, maxOutputTokens: 128_000,
          supportedParameters: ["temperature", "top_p", "max_tokens", "thinking", "tools"]),
        .init(
          providerID: "zai", id: "glm-4.7", displayName: "GLM-4.7",
          contextWindow: 200_000, maxOutputTokens: 128_000,
          supportedParameters: ["temperature", "top_p", "max_tokens", "thinking", "tools"]),
        .init(
          providerID: "zai", id: "glm-4.7-flash", displayName: "GLM-4.7 Flash",
          contextWindow: 200_000, maxOutputTokens: 128_000,
          supportedParameters: ["temperature", "top_p", "max_tokens", "thinking", "tools"]),
      ]
    case .moonshot:
      [
        .init(
          providerID: "moonshot", id: "kimi-k3.1-pro", displayName: "Kimi K3.1 Pro",
          contextWindow: 1_048_576,
          supportedParameters: ["max_tokens", "reasoning_effort", "tools"],
          inputModalities: ["text", "image"]),
        .init(
          providerID: "moonshot", id: "kimi-k3.1-pro-highspeed",
          displayName: "Kimi K3.1 Pro Highspeed",
          contextWindow: 1_048_576,
          supportedParameters: ["max_tokens", "reasoning_effort", "tools"],
          inputModalities: ["text", "image"]),
        .init(
          providerID: "moonshot", id: "kimi-k3", displayName: "Kimi K3",
          contextWindow: 1_048_576,
          supportedParameters: ["max_tokens", "reasoning_effort", "tools"],
          inputModalities: ["text", "image"]),
      ]
    case .minimax:
      [
        .init(
          providerID: "minimax", id: "MiniMax-M3.1-Flash", displayName: "MiniMax M3.1 Flash",
          contextWindow: 1_000_000, maxOutputTokens: 512_000,
          supportedParameters: ["temperature", "top_p", "max_tokens", "reasoning_effort", "tools"],
          inputModalities: ["text", "image"]),
        .init(
          providerID: "minimax", id: "MiniMax-M3", displayName: "MiniMax M3",
          contextWindow: 1_000_000, maxOutputTokens: 512_000,
          supportedParameters: ["temperature", "top_p", "max_tokens", "thinking", "tools"],
          inputModalities: ["text", "image"]),
      ]
    case .mistral:
      [
        .init(
          providerID: "mistral", id: "mistral-large-4-0", displayName: "Mistral Large 4",
          contextWindow: 1_048_576,
          supportedParameters: ["temperature", "top_p", "max_tokens", "reasoning_effort", "tools"],
          inputModalities: ["text", "image"]),
        .init(
          providerID: "mistral", id: "mistral-small-2603", displayName: "Mistral Small 4",
          contextWindow: 262_144,
          supportedParameters: ["temperature", "top_p", "max_tokens", "reasoning_effort", "tools"],
          inputModalities: ["text", "image"]),
        .init(
          providerID: "mistral", id: "devstral-2512", displayName: "Devstral 2",
          contextWindow: 262_144,
          supportedParameters: ["temperature", "top_p", "max_tokens", "tools"]),
        .init(
          providerID: "mistral", id: "codestral-2508", displayName: "Codestral",
          contextWindow: 262_144,
          supportedParameters: ["temperature", "top_p", "max_tokens", "tools"]),
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
          providerID: "anthropic", id: "claude-sonnet-5-5", displayName: "Claude Sonnet 5.5",
          contextWindow: 1_000_000, contextWindowKind: .inputOnly, maxOutputTokens: 128_000,
          supportedParameters: ["max_tokens", "thinking", "effort", "tools"],
          inputModalities: ["text", "image", "file"]),
        .init(
          providerID: "anthropic", id: "claude-opus-5-5", displayName: "Claude Opus 5.5",
          contextWindow: 1_000_000, contextWindowKind: .inputOnly, maxOutputTokens: 128_000,
          supportedParameters: ["max_tokens", "thinking", "effort", "tools"],
          inputModalities: ["text", "image", "file"]),
        .init(
          providerID: "anthropic", id: "claude-fable-5-1", displayName: "Claude Fable 5.1",
          contextWindow: 1_000_000, contextWindowKind: .inputOnly, maxOutputTokens: 128_000,
          supportedParameters: ["max_tokens", "thinking", "effort", "tools"],
          inputModalities: ["text", "image", "file"]),
        .init(
          providerID: "anthropic", id: "claude-mythos-5-1", displayName: "Claude Mythos 5.1",
          contextWindow: 1_000_000, contextWindowKind: .inputOnly, maxOutputTokens: 128_000,
          supportedParameters: ["max_tokens", "thinking", "effort", "tools"],
          inputModalities: ["text", "image", "file"]),
        .init(
          providerID: "anthropic", id: "claude-haiku-5-5", displayName: "Claude Haiku 5.5",
          contextWindow: 1_000_000, contextWindowKind: .inputOnly, maxOutputTokens: 128_000,
          supportedParameters: ["max_tokens", "thinking", "effort", "tools"],
          inputModalities: ["text", "image", "file"]),
        .init(
          providerID: "anthropic", id: "claude-fable-5-2", displayName: "Claude Fable 5.2",
          contextWindow: 1_000_000, contextWindowKind: .inputOnly, maxOutputTokens: 128_000,
          supportedParameters: ["max_tokens", "thinking", "effort", "tools"],
          inputModalities: ["text", "image", "file"]),
        .init(
          providerID: "anthropic", id: "claude-mythos-5-2", displayName: "Claude Mythos 5.2",
          contextWindow: 1_000_000, contextWindowKind: .inputOnly, maxOutputTokens: 128_000,
          supportedParameters: ["max_tokens", "thinking", "effort", "tools"],
          inputModalities: ["text", "image", "file"]),
      ]
    case .gemini:
      [
        .init(
          providerID: "gemini", id: "gemini-3.8-flash", displayName: "Gemini 3.8 Flash",
          contextWindow: 1_048_576, contextWindowKind: .inputOnly, maxOutputTokens: 65_536,
          supportedParameters: ["maxOutputTokens", "thinkingConfig", "tools"],
          inputModalities: ["text", "image", "audio", "file"]),
        .init(
          providerID: "gemini", id: "gemini-4-carbon", displayName: "Gemini 4 Carbon",
          contextWindow: 1_048_576, contextWindowKind: .inputOnly, maxOutputTokens: 65_536,
          supportedParameters: ["maxOutputTokens", "thinkingConfig", "tools"],
          inputModalities: ["text", "image", "audio", "file"]),
        .init(
          providerID: "gemini", id: "gemini-4-argon", displayName: "Gemini 4 Argon",
          contextWindow: 1_048_576, contextWindowKind: .inputOnly, maxOutputTokens: 65_536,
          supportedParameters: ["maxOutputTokens", "thinkingConfig", "tools"],
          inputModalities: ["text", "image", "audio", "file"]),
        .init(
          providerID: "gemini", id: "gemini-4-neon", displayName: "Gemini 4 Neon",
          contextWindow: 1_048_576, contextWindowKind: .inputOnly, maxOutputTokens: 65_536,
          supportedParameters: ["maxOutputTokens", "thinkingConfig", "tools"],
          inputModalities: ["text", "image", "audio", "file"]),
        .init(
          providerID: "gemini", id: "gemini-4-hydrogen", displayName: "Gemini 4 Hydrogen",
          contextWindow: 1_048_576, contextWindowKind: .inputOnly, maxOutputTokens: 65_536,
          supportedParameters: ["maxOutputTokens", "thinkingConfig", "tools"],
          inputModalities: ["text", "image", "audio", "file"]),
      ]
    case .ollama, .lmStudio, .openAICompatible:
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
        },
        kind: .openAICompatible
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
    case .zAI: URL(string: "https://api.z.ai/api/paas/v4")
    case .moonshot: URL(string: "https://api.moonshot.ai/v1")
    case .minimax: URL(string: "https://api.minimax.io/v1")
    case .mistral: URL(string: "https://api.mistral.ai/v1")
    case .openRouter: URL(string: "https://openrouter.ai/api/v1")
    case .nvidia: URL(string: "https://integrate.api.nvidia.com/v1")
    case .ollama: URL(string: "http://localhost:11434/v1")
    case .lmStudio: URL(string: "http://localhost:1234/v1")
    case .openAICompatible: nil
    }
  }

  var behaviorID: ProviderBehaviorID {
    switch self {
    case .anthropic: .anthropic
    case .openai, .xAI: .genericOpenAICompatible
    case .gemini: .gemini
    case .deepSeek: .deepSeek
    case .zAI: .zAI
    case .moonshot: .moonshot
    case .minimax: .minimax
    case .mistral: .mistral
    case .openRouter: .openRouter
    case .nvidia: .nvidia
    case .ollama, .lmStudio, .openAICompatible: .genericOpenAICompatible
    }
  }
}
