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
    modelsPath: "/models",
    authentication: .bearer,
    seedModels: [
      .init(
        providerID: deepSeekID, id: "deepseek-v4-flash", displayName: "DeepSeek V4 Flash",
        contextWindow: 1_000_000, maxOutputTokens: 384_000,
        supportedParameters: [
          "temperature", "top_p", "max_tokens", "thinking", "reasoning_effort",
        ], isSeed: true),
      .init(
        providerID: deepSeekID, id: "deepseek-v4-pro", displayName: "DeepSeek V4 Pro",
        contextWindow: 1_000_000, maxOutputTokens: 384_000,
        supportedParameters: [
          "temperature", "top_p", "max_tokens", "thinking", "reasoning_effort",
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

  public static let all = [deepSeek, openRouter, nvidia]
}
