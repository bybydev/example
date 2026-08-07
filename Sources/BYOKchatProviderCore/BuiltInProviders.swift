import Foundation

public enum BuiltInProviders {
  public static let deepSeekID: ProviderID = "deepseek"
  public static let openRouterID: ProviderID = "openrouter"
  public static let nvidiaID: ProviderID = "nvidia"
  public static let anthropicID: ProviderID = "anthropic"
  public static let geminiID: ProviderID = "gemini"

  public static let deepSeek = ProviderDefinition(
    id: deepSeekID,
    displayName: "DeepSeek",
    behavior: .deepSeek,
    defaultBaseURL: URL(string: "https://api.deepseek.com")!,
    modelsPath: "/models",
    authentication: .bearer,
    seedModels: [
      .init(
        providerID: deepSeekID, id: "deepseek-v4-flash", displayName: "DeepSeek V4 Flash",
        contextWindow: 1_000_000, maxOutputTokens: 384_000,
        supportedParameters: [
          "temperature", "top_p", "max_tokens", "thinking", "reasoning_effort", "tools",
        ], isSeed: true),
      .init(
        providerID: deepSeekID, id: "deepseek-v4-pro", displayName: "DeepSeek V4 Pro",
        contextWindow: 1_000_000, maxOutputTokens: 384_000,
        supportedParameters: [
          "temperature", "top_p", "max_tokens", "thinking", "reasoning_effort", "tools",
        ], isSeed: true),
    ],
    isBuiltIn: true
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
        supportedParameters: ["temperature", "top_p", "max_tokens", "reasoning"], isSeed: true)
    ],
    isBuiltIn: true
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
        supportedParameters: ["temperature", "top_p", "max_tokens"], isSeed: true),
      .init(
        providerID: nvidiaID, id: "deepseek-ai/deepseek-v4-pro", displayName: "DeepSeek V4 Pro",
        supportedParameters: ["temperature", "top_p", "max_tokens"], isSeed: true),
      .init(
        providerID: nvidiaID, id: "nvidia/nemotron-3-ultra-550b-a55b",
        displayName: "Nemotron 3 Ultra 550B",
        supportedParameters: ["temperature", "top_p", "max_tokens"], isSeed: true),
      .init(
        providerID: nvidiaID, id: "qwen/qwen3.5-122b-a10b", displayName: "Qwen 3.5 122B A10B",
        supportedParameters: ["temperature", "top_p", "max_tokens"], isSeed: true),
    ],
    isBuiltIn: true
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
        id: "claude-sonnet-5",
        displayName: "Claude Sonnet 5",
        contextWindow: 1_000_000,
        maxOutputTokens: 128_000,
        supportedParameters: ["max_tokens", "thinking", "effort", "tools"],
        inputModalities: ["text", "image", "file"],
        isSeed: true
      ),
      .init(
        providerID: anthropicID,
        id: "claude-opus-5",
        displayName: "Claude Opus 5",
        contextWindow: 1_000_000,
        maxOutputTokens: 128_000,
        supportedParameters: ["max_tokens", "thinking", "effort", "tools"],
        inputModalities: ["text", "image", "file"],
        isSeed: true
      ),
    ],
    isBuiltIn: true
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
        id: "gemini-3.6-flash",
        displayName: "Gemini 3.6 Flash",
        contextWindow: 1_048_576,
        maxOutputTokens: 65_536,
        supportedParameters: ["maxOutputTokens", "thinkingConfig", "tools"],
        inputModalities: ["text", "image", "file"],
        isSeed: true
      )
    ],
    isBuiltIn: true
  )

  public static let all = [deepSeek, openRouter, nvidia, anthropic, gemini]
}
