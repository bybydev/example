import Foundation

public enum BuiltInProviders {
  public static let openAIID: ProviderID = "openai"
  public static let xAIID: ProviderID = "xai"
  public static let deepSeekID: ProviderID = "deepseek"
  public static let zAIID: ProviderID = "zai"
  public static let moonshotID: ProviderID = "moonshot"
  public static let minimaxID: ProviderID = "minimax"
  public static let qwenID: ProviderID = "qwen"
  public static let mistralID: ProviderID = "mistral"
  public static let groqID: ProviderID = "groq"
  public static let togetherID: ProviderID = "together"
  public static let openRouterID: ProviderID = "openrouter"
  public static let nvidiaID: ProviderID = "nvidia"
  public static let ollamaID: ProviderID = "ollama"
  public static let lmStudioID: ProviderID = "lmstudio"
  public static let anthropicID: ProviderID = "anthropic"
  public static let geminiID: ProviderID = "gemini"

  public static var openAI: ProviderDefinition {
    ProviderDefinition(
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
  }

  public static var xAI: ProviderDefinition {
    ProviderDefinition(
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
  }

  public static var deepSeek: ProviderDefinition {
    ProviderDefinition(
      id: deepSeekID,
      displayName: "DeepSeek",
      behavior: .deepSeek,
      defaultBaseURL: URL(string: "https://api.deepseek.com")!,
      modelsPath: "/models",
      authentication: .bearer,
      seedModels: ProviderKind.deepSeek.seedModels,
      isBuiltIn: true,
      kind: .deepSeek
    )
  }

  public static var zAI: ProviderDefinition {
    ProviderDefinition(
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
  }

  public static var moonshot: ProviderDefinition {
    ProviderDefinition(
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
  }

  public static var minimax: ProviderDefinition {
    ProviderDefinition(
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
  }

  public static var qwen: ProviderDefinition {
    ProviderDefinition(
      id: qwenID,
      displayName: "Alibaba Qwen",
      behavior: .qwen,
      defaultBaseURL: URL(string: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1")!,
      modelsPath: nil,
      authentication: .bearer,
      seedModels: ProviderKind.qwen.seedModels,
      isBuiltIn: true,
      kind: .qwen
    )
  }

  public static var mistral: ProviderDefinition {
    ProviderDefinition(
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
  }

  public static var groq: ProviderDefinition {
    ProviderDefinition(
      id: groqID,
      displayName: "Groq",
      behavior: .groq,
      defaultBaseURL: URL(string: "https://api.groq.com/openai/v1")!,
      modelsPath: "/models",
      authentication: .bearer,
      seedModels: ProviderKind.groq.seedModels,
      isBuiltIn: true,
      kind: .groq
    )
  }

  public static var together: ProviderDefinition {
    ProviderDefinition(
      id: togetherID,
      displayName: "Together AI",
      behavior: .together,
      defaultBaseURL: URL(string: "https://api.together.ai/v1")!,
      modelsPath: "/models",
      authentication: .bearer,
      seedModels: ProviderKind.together.seedModels,
      isBuiltIn: true,
      kind: .together
    )
  }

  public static var openRouter: ProviderDefinition {
    ProviderDefinition(
      id: openRouterID,
      displayName: "OpenRouter",
      behavior: .openRouter,
      defaultBaseURL: URL(string: "https://openrouter.ai/api/v1")!,
      modelsPath: "/models",
      authentication: .bearer,
      seedModels: ProviderKind.openRouter.seedModels,
      isBuiltIn: true,
      kind: .openRouter
    )
  }

  public static var nvidia: ProviderDefinition {
    ProviderDefinition(
      id: nvidiaID,
      displayName: "NVIDIA",
      behavior: .nvidia,
      defaultBaseURL: URL(string: "https://integrate.api.nvidia.com/v1")!,
      modelsPath: "/models",
      authentication: .bearer,
      seedModels: ProviderKind.nvidia.seedModels,
      isBuiltIn: true,
      kind: .nvidia
    )
  }

  public static var anthropic: ProviderDefinition {
    ProviderDefinition(
      id: anthropicID,
      displayName: "Anthropic",
      apiFamily: .anthropicMessages,
      behavior: .anthropic,
      defaultBaseURL: URL(string: "https://api.anthropic.com")!,
      chatCompletionsPath: "/v1/messages",
      modelsPath: "/v1/models",
      authentication: .header(name: "x-api-key"),
      seedModels: ProviderKind.anthropic.seedModels,
      isBuiltIn: true,
      kind: .anthropic
    )
  }

  public static var gemini: ProviderDefinition {
    ProviderDefinition(
      id: geminiID,
      displayName: "Gemini",
      apiFamily: .geminiGenerateContent,
      behavior: .gemini,
      defaultBaseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
      chatCompletionsPath: "/models",
      modelsPath: "/models",
      authentication: .header(name: "x-goog-api-key"),
      seedModels: ProviderKind.gemini.seedModels,
      isBuiltIn: true,
      kind: .gemini
    )
  }

  public static var ollama: ProviderDefinition {
    ProviderDefinition(
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
  }

  public static var lmStudio: ProviderDefinition {
    ProviderDefinition(
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
  }

  public static var all: [ProviderDefinition] {
    [
      openAI, xAI, deepSeek, zAI, moonshot, minimax, qwen, mistral, groq, together, openRouter,
      nvidia, anthropic, gemini, ollama, lmStudio,
    ]
  }
}
