import Foundation

public enum BuiltInProviders {
  public static let openAIID: ProviderID = "openai"
  public static let xAIID: ProviderID = "xai"
  public static let deepSeekID: ProviderID = "deepseek"
  public static let zAIID: ProviderID = "zai"
  public static let moonshotID: ProviderID = "moonshot"
  public static let minimaxID: ProviderID = "minimax"
  public static let mistralID: ProviderID = "mistral"
  public static let openRouterID: ProviderID = "openrouter"
  public static let nvidiaID: ProviderID = "nvidia"
  public static let ollamaID: ProviderID = "ollama"
  public static let lmStudioID: ProviderID = "lmstudio"
  public static let anthropicID: ProviderID = "anthropic"
  public static let geminiID: ProviderID = "gemini"

  public static let openAI = ProviderDefinition(
    id: openAIID,
    displayName: "OpenAI",
    apiFamily: .openAIResponses,
    behavior: .genericOpenAICompatible,
    defaultBaseURL: URL(string: "https://api.openai.com/v1")!,
    chatCompletionsPath: "/responses",
    modelsPath: "/models",
    authentication: .bearer,
    seedModels: ProviderKind.openai.seedModels,
    isBuiltIn: true,
    kind: .openai
  )

  public static let xAI = ProviderDefinition(
    id: xAIID,
    displayName: "xAI",
    apiFamily: .openAIResponses,
    behavior: .genericOpenAICompatible,
    defaultBaseURL: URL(string: "https://api.x.ai/v1")!,
    chatCompletionsPath: "/responses",
    modelsPath: "/models",
    authentication: .bearer,
    seedModels: ProviderKind.xAI.seedModels,
    isBuiltIn: true,
    kind: .xAI
  )

  public static let deepSeek = ProviderDefinition(
    id: deepSeekID,
    displayName: "DeepSeek",
    behavior: .deepSeek,
    defaultBaseURL: URL(string: "https://api.deepseek.com")!,
    modelsPath: "/models",
    authentication: .bearer,
    seedModels: [
      .init(
        providerID: deepSeekID, id: "deepseek-flash", displayName: "DeepSeek Flash",
        contextWindow: 1_000_000, maxOutputTokens: 384_000,
        supportedParameters: [
          "temperature", "top_p", "max_tokens", "thinking", "reasoning_effort", "tools",
        ]),
      .init(
        providerID: deepSeekID, id: "deepseek-v4-pro", displayName: "DeepSeek V4 Pro",
        contextWindow: 1_000_000, maxOutputTokens: 384_000,
        supportedParameters: [
          "temperature", "top_p", "max_tokens", "thinking", "reasoning_effort", "tools",
        ]),
    ],
    isBuiltIn: true,
    kind: .deepSeek
  )

  public static let zAI = ProviderDefinition(
    id: zAIID,
    displayName: "Z.ai",
    behavior: .zAI,
    defaultBaseURL: URL(string: "https://api.z.ai/api/paas/v4")!,
    modelsPath: "/models",
    authentication: .bearer,
    seedModels: ProviderKind.zAI.seedModels,
    isBuiltIn: true,
    kind: .zAI
  )

  public static let moonshot = ProviderDefinition(
    id: moonshotID,
    displayName: "Moonshot AI",
    behavior: .moonshot,
    defaultBaseURL: URL(string: "https://api.moonshot.ai/v1")!,
    modelsPath: "/models",
    authentication: .bearer,
    seedModels: ProviderKind.moonshot.seedModels,
    isBuiltIn: true,
    kind: .moonshot
  )

  public static let minimax = ProviderDefinition(
    id: minimaxID,
    displayName: "MiniMax",
    behavior: .minimax,
    defaultBaseURL: URL(string: "https://api.minimax.io/v1")!,
    modelsPath: "/models",
    authentication: .bearer,
    seedModels: ProviderKind.minimax.seedModels,
    isBuiltIn: true,
    kind: .minimax
  )

  public static let mistral = ProviderDefinition(
    id: mistralID,
    displayName: "Mistral AI",
    behavior: .mistral,
    defaultBaseURL: URL(string: "https://api.mistral.ai/v1")!,
    modelsPath: "/models",
    authentication: .bearer,
    seedModels: ProviderKind.mistral.seedModels,
    isBuiltIn: true,
    kind: .mistral
  )

  public static let openRouter = ProviderDefinition(
    id: openRouterID,
    displayName: "OpenRouter",
    behavior: .openRouter,
    defaultBaseURL: URL(string: "https://openrouter.ai/api/v1")!,
    modelsPath: "/models",
    authentication: .bearer,
    seedModels: [
      .init(
        providerID: openRouterID, id: "openrouter/free", displayName: "OpenRouter Free",
        supportedParameters: ["temperature", "top_p", "max_tokens", "reasoning"])
    ],
    isBuiltIn: true,
    kind: .openRouter
  )

  public static let nvidia = ProviderDefinition(
    id: nvidiaID,
    displayName: "NVIDIA",
    behavior: .nvidia,
    defaultBaseURL: URL(string: "https://integrate.api.nvidia.com/v1")!,
    modelsPath: nil,
    authentication: .bearer,
    seedModels: [
      .init(
        providerID: nvidiaID, id: "deepseek-ai/deepseek-v4-flash", displayName: "DeepSeek V4 Flash",
        supportedParameters: ["temperature", "top_p", "max_tokens"]),
      .init(
        providerID: nvidiaID, id: "deepseek-ai/deepseek-v4-pro", displayName: "DeepSeek V4 Pro",
        supportedParameters: ["temperature", "top_p", "max_tokens"]),
      .init(
        providerID: nvidiaID, id: "nvidia/nemotron-3-ultra-550b-a55b",
        displayName: "Nemotron 3 Ultra 550B",
        supportedParameters: ["temperature", "top_p", "max_tokens"]),
      .init(
        providerID: nvidiaID, id: "qwen/qwen3.5-122b-a10b", displayName: "Qwen 3.5 122B A10B",
        supportedParameters: ["temperature", "top_p", "max_tokens"]),
    ],
    isBuiltIn: true,
    kind: .nvidia
  )

  public static let anthropic = ProviderDefinition(
    id: anthropicID,
    displayName: "Anthropic",
    apiFamily: .anthropicMessages,
    behavior: .anthropic,
    defaultBaseURL: URL(string: "https://api.anthropic.com")!,
    chatCompletionsPath: "/v1/messages",
    modelsPath: "/v1/models",
    authentication: .header(name: "x-api-key"),
    seedModels: [
      .init(
        providerID: anthropicID,
        id: "claude-sonnet-5-5",
        displayName: "Claude Sonnet 5.5",
        contextWindow: 1_000_000,
        contextWindowKind: .inputOnly,
        maxOutputTokens: 128_000,
        supportedParameters: ["max_tokens", "thinking", "effort", "tools"],
        inputModalities: ["text", "image", "file"]
      ),
      .init(
        providerID: anthropicID,
        id: "claude-opus-5-5",
        displayName: "Claude Opus 5.5",
        contextWindow: 1_000_000,
        contextWindowKind: .inputOnly,
        maxOutputTokens: 128_000,
        supportedParameters: ["max_tokens", "thinking", "effort", "tools"],
        inputModalities: ["text", "image", "file"]
      ),
    ],
    isBuiltIn: true,
    kind: .anthropic
  )

  public static let gemini = ProviderDefinition(
    id: geminiID,
    displayName: "Gemini",
    apiFamily: .geminiGenerateContent,
    behavior: .gemini,
    defaultBaseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
    chatCompletionsPath: "/models",
    modelsPath: "/models",
    authentication: .header(name: "x-goog-api-key"),
    seedModels: [
      .init(
        providerID: geminiID,
        id: "gemini-3.8-flash",
        displayName: "Gemini 3.8 Flash",
        contextWindow: 1_048_576,
        contextWindowKind: .inputOnly,
        maxOutputTokens: 65_536,
        supportedParameters: ["maxOutputTokens", "thinkingConfig", "tools"],
        inputModalities: ["text", "image", "file"]
      )
    ],
    isBuiltIn: true,
    kind: .gemini
  )

  public static let ollama = ProviderDefinition(
    id: ollamaID,
    displayName: "Ollama",
    behavior: .genericOpenAICompatible,
    defaultBaseURL: URL(string: "http://localhost:11434/v1")!,
    modelsPath: "/models",
    authentication: .bearer,
    seedModels: [],
    isBuiltIn: true,
    kind: .ollama
  )

  public static let lmStudio = ProviderDefinition(
    id: lmStudioID,
    displayName: "LM Studio",
    behavior: .genericOpenAICompatible,
    defaultBaseURL: URL(string: "http://localhost:1234/v1")!,
    modelsPath: "/models",
    authentication: .bearer,
    seedModels: [],
    isBuiltIn: true,
    kind: .lmStudio
  )

  public static let all = [
    openAI, xAI, deepSeek, zAI, moonshot, minimax, mistral, openRouter, nvidia, anthropic, gemini,
    ollama, lmStudio,
  ]
}
