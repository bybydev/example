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
  case qwen
  case mistral
  case groq
  case together
  case openRouter
  case nvidia
  case ollama
  case lmStudio = "lmstudio"
  case openAICompatible

  /// Cloud providers shown under the "Cloud Providers" group in pickers.
  public static var cloudCatalog: [ProviderKind] {
    [.anthropic, .openai, .xAI, .gemini, .deepSeek, .zAI, .moonshot, .minimax, .qwen, .mistral, .groq, .together, .openRouter, .nvidia]
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
    case .qwen: "qwen"
    case .mistral: "mistral"
    case .groq: "groq"
    case .together: "together"
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
    case .qwen: "Alibaba Qwen"
    case .mistral: "Mistral AI"
    case .groq: "Groq"
    case .together: "Together AI"
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
    case .deepSeek, .zAI, .moonshot, .minimax, .qwen, .mistral, .groq, .together, .openRouter, .nvidia, .ollama, .lmStudio, .openAICompatible: .openAIChatCompletions
    }
  }

  var authSpec: ProviderAuthSpec {
    switch self {
    case .anthropic: .header(name: "x-api-key")
    case .gemini: .header(name: "x-goog-api-key")
    case .openai, .xAI, .deepSeek, .zAI, .moonshot, .minimax, .qwen, .mistral, .groq, .together, .openRouter, .nvidia, .ollama, .lmStudio: .bearer
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
    case .qwen: .fixed(chat: "/chat/completions", models: nil)
    case .mistral: .fixed(chat: "/chat/completions", models: "/models")
    case .groq: .fixed(chat: "/chat/completions", models: "/models")
    case .together: .fixed(chat: "/chat/completions", models: "/models")
    case .openRouter: .fixed(chat: "/chat/completions", models: "/models")
    case .nvidia: .fixed(chat: "/chat/completions", models: "/models")
    case .ollama, .lmStudio: .fixed(chat: "/chat/completions", models: "/models")
    case .openAICompatible: .userEditable
    }
  }

  /// Coarse discovery capability of the kind. Whether a specific account can
  /// discover models also depends on its configured models path; use the
  /// account's derived definition for the exact answer.
  var supportsDiscovery: Bool {
    switch self {
    case .qwen, .openAICompatible: false
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
    case .qwen: .brand(assetName: "provider.qwen")
    case .mistral: .brand(assetName: "provider.mistral")
    case .groq: .brand(assetName: "provider.groq")
    case .together: .brand(assetName: "provider.together")
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
    case .openai, .zAI, .moonshot, .minimax, .qwen, .mistral, .groq, .together, .openRouter, .nvidia, .ollama, .lmStudio, .openAICompatible: nil
    }
  }

  var contextWindowKind: ProviderContextWindowKind {
    switch self {
    case .anthropic, .gemini: .inputOnly
    case .openai, .xAI, .deepSeek, .zAI, .moonshot, .minimax, .qwen, .mistral, .groq, .together, .openRouter, .nvidia, .ollama, .lmStudio, .openAICompatible: .combined
    }
  }

  var extraCredentialFields: Set<ProviderExtraCredentialField> {
    switch self {
    case .openRouter: [.appTitle, .httpReferer]
    default: []
    }
  }

  /// Curated fallback models from the active 2-layer catalog, merged into a
  /// fresh account so the model picker is usable before (or without) discovery.
  var seedModels: [ProviderModel] {
    ModelCatalogRegistry.current?.seedModels(for: self) ?? []
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
    case .qwen: URL(string: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1")
    case .mistral: URL(string: "https://api.mistral.ai/v1")
    case .groq: URL(string: "https://api.groq.com/openai/v1")
    case .together: URL(string: "https://api.together.ai/v1")
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
    case .qwen: .qwen
    case .mistral: .mistral
    case .groq: .groq
    case .together: .together
    case .openRouter: .openRouter
    case .nvidia: .nvidia
    case .ollama, .lmStudio, .openAICompatible: .genericOpenAICompatible
    }
  }
}
