import Foundation

public enum BuiltInProviders {
  public static let deepSeekID: ProviderID = "deepseek"
  public static let openRouterID: ProviderID = "openrouter"
  public static let nvidiaID: ProviderID = "nvidia"

  public static let deepSeek = ProviderDefinition(
    id: deepSeekID,
    displayName: "DeepSeek",
    behavior: .deepSeek,
    defaultBaseURL: URL(string: "https://api.deepseek.com")!,
    chatCompletionsPath: "/chat/completions",
    modelsPath: "/models",
    seedModels: [
      ProviderModel(
        providerID: deepSeekID,
        id: "deepseek-v4-flash",
        displayName: "DeepSeek V4 Flash",
        contextWindow: 1_000_000,
        maxOutputTokens: 384_000,
        supportedParameters: [
          "temperature", "top_p", "max_tokens", "thinking", "reasoning_effort",
        ],
        isSeed: true
      ),
      ProviderModel(
        providerID: deepSeekID,
        id: "deepseek-v4-pro",
        displayName: "DeepSeek V4 Pro",
        contextWindow: 1_000_000,
        maxOutputTokens: 384_000,
        supportedParameters: [
          "temperature", "top_p", "max_tokens", "thinking", "reasoning_effort",
        ],
        isSeed: true
      ),
    ]
  )

  public static let openRouter = ProviderDefinition(
    id: openRouterID,
    displayName: "OpenRouter",
    behavior: .openRouter,
    defaultBaseURL: URL(string: "https://openrouter.ai/api/v1")!,
    chatCompletionsPath: "/chat/completions",
    modelsPath: "/models",
    seedModels: [
      ProviderModel(
        providerID: openRouterID,
        id: "openrouter/free",
        displayName: "OpenRouter Free",
        supportedParameters: ["temperature", "top_p", "max_tokens", "reasoning"],
        isSeed: true
      )
    ]
  )

  public static let nvidia = ProviderDefinition(
    id: nvidiaID,
    displayName: "NVIDIA",
    behavior: .nvidia,
    defaultBaseURL: URL(string: "https://integrate.api.nvidia.com/v1")!,
    chatCompletionsPath: "/chat/completions",
    modelsPath: nil,
    seedModels: [
      ProviderModel(
        providerID: nvidiaID,
        id: "deepseek-ai/deepseek-v4-flash",
        displayName: "DeepSeek V4 Flash",
        supportedParameters: ["temperature", "top_p", "max_tokens"],
        isSeed: true
      ),
      ProviderModel(
        providerID: nvidiaID,
        id: "deepseek-ai/deepseek-v4-pro",
        displayName: "DeepSeek V4 Pro",
        supportedParameters: ["temperature", "top_p", "max_tokens"],
        isSeed: true
      ),
      ProviderModel(
        providerID: nvidiaID,
        id: "nvidia/nemotron-3-ultra-550b-a55b",
        displayName: "Nemotron 3 Ultra 550B",
        supportedParameters: ["temperature", "top_p", "max_tokens"],
        isSeed: true
      ),
      ProviderModel(
        providerID: nvidiaID,
        id: "qwen/qwen3.5-122b-a10b",
        displayName: "Qwen 3.5 122B A10B",
        supportedParameters: ["temperature", "top_p", "max_tokens"],
        isSeed: true
      ),
    ]
  )

  public static let all: [ProviderDefinition] = [deepSeek, openRouter, nvidia]
}
