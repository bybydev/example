import Foundation
import Testing

@testable import BYOKchatProviderCore

@Test func builtInRegistryContainsPriorityProviders() async throws {
  let registry = try ProviderRegistry.builtIn()
  let definitions = await registry.allDefinitions()
  #expect(
    Set(definitions.map(\.id))
      == [
        "openai", "xai", "deepseek", "zai", "moonshot", "minimax", "qwen", "mistral", "groq",
        "openrouter", "nvidia", "anthropic", "gemini", "ollama", "lmstudio",
      ]
  )
  #expect(definitions.first { $0.id == "anthropic" }?.apiFamily == .anthropicMessages)
  #expect(definitions.first { $0.id == "gemini" }?.apiFamily == .geminiGenerateContent)

  let openAI = try #require(definitions.first { $0.id == "openai" })
  #expect(openAI.defaultBaseURL.absoluteString == "https://api.openai.com/v1")
  #expect(openAI.apiFamily == .openAIResponses)
  #expect(openAI.authentication == .bearer)
  #expect(openAI.modelsPath == "/models")
  #expect(openAI.chatCompletionsPath == "/responses")
  #expect(openAI.seedModels.first?.id == "gpt-6.2-astra")
  #expect(openAI.seedModels.contains { $0.id == "gpt-6.2-astra" })
  #expect(openAI.seedModels.contains { $0.id == "gpt-6.2-sol" })
  #expect(openAI.seedModels.contains { $0.id == "gpt-6.1-terra" })
  #expect(openAI.seedModels.contains { $0.id == "gpt-6-luna" })
  #expect(openAI.seedModels.contains { $0.id == "gpt-6.1-sol" })
  #expect(openAI.seedModels.contains { $0.id == "gpt-6-astra" })
  #expect(openAI.seedModels.contains { $0.id == "gpt-5.6-sol" })

  let xAI = try #require(definitions.first { $0.id == "xai" })
  #expect(xAI.defaultBaseURL.absoluteString == "https://api.x.ai/v1")
  #expect(xAI.apiFamily == .openAIResponses)
  #expect(xAI.authentication == .bearer)
  #expect(xAI.modelsPath == "/models")
  #expect(xAI.chatCompletionsPath == "/responses")
  #expect(xAI.kind == .xAI)
  #expect(xAI.seedModels.first?.id == "grok-4.7")
  let grok47 = try #require(xAI.seedModels.first { $0.id == "grok-4.7" })
  #expect(grok47.contextWindow == 500_000)
  let grok43 = try #require(xAI.seedModels.first { $0.id == "grok-4.3" })
  #expect(grok43.contextWindow == 1_000_000)
  #expect(xAI.seedModels.contains { $0.id == "grok-4.6" })
  #expect(xAI.seedModels.contains { $0.id == "grok-4.20-0309-reasoning" })
  #expect(xAI.seedModels.contains { $0.id == "grok-4.20-non-reasoning" })
  #expect(xAI.seedModels.contains { $0.id == "grok-4.20-multi-agent" })
  #expect(xAI.seedModels.contains { $0.id == "grok-4.7" })

  #expect(ProviderKind.catalog.contains(.xAI))
  #expect(ProviderKind.xAI.defaultProviderID == "xai")
  #expect(ProviderKind.xAI.logo == .brand(assetName: "provider.xai"))
  #expect(ProviderKind.xAI.reasoningDefault == .init(enabled: true, effort: .high))

  let deepSeek = try #require(definitions.first { $0.id == "deepseek" })
  #expect(deepSeek.defaultBaseURL.absoluteString == "https://api.deepseek.com")
  #expect(deepSeek.behavior == .deepSeek)
  let deepSeekFlash = try #require(deepSeek.seedModels.first { $0.id == "deepseek-flash" })
  #expect(deepSeekFlash.inputModalities.contains("image"))
  #expect(deepSeekFlash.capabilityEvidence?.facts[.imageInput]?.support == .supported)
  let deepSeekPro = try #require(deepSeek.seedModels.first { $0.id == "deepseek-v4-pro" })
  #expect(!deepSeekPro.inputModalities.contains("image"))
  #expect(deepSeekPro.contextWindow == 1_000_000)
  #expect(deepSeekPro.maxOutputTokens == 384_000)

  let zAI = try #require(definitions.first { $0.id == "zai" })
  #expect(zAI.defaultBaseURL.absoluteString == "https://api.z.ai/api/paas/v4")
  #expect(zAI.apiFamily == .openAIChatCompletions)
  #expect(zAI.behavior == .zAI)
  #expect(zAI.authentication == .bearer)
  #expect(zAI.modelsPath == "/models")
  #expect(zAI.chatCompletionsPath == "/chat/completions")
  #expect(zAI.kind == .zAI)
  #expect(zAI.seedModels.contains { $0.id == "glm-5.3" })
  #expect(zAI.seedModels.contains { $0.id == "glm-5.3-flash" })
  #expect(zAI.seedModels.contains { $0.id == "glm-5.3-flashx" })
  #expect(zAI.seedModels.contains { $0.id == "glm-5.2" })
  #expect(zAI.seedModels.contains { $0.id == "glm-5.1" })
  #expect(zAI.seedModels.contains { $0.id == "glm-5v-turbo" })
  #expect(zAI.seedModels.contains { $0.id == "glm-5-turbo" })
  #expect(zAI.seedModels.contains { $0.id == "glm-5" })
  #expect(zAI.seedModels.contains { $0.id == "glm-4.7" })
  #expect(zAI.seedModels.contains { $0.id == "glm-4.7-flash" })
  let glm53 = try #require(zAI.seedModels.first { $0.id == "glm-5.3" })
  #expect(glm53.contextWindow == 1_000_000)
  #expect(glm53.maxOutputTokens == 128_000)
  let glm53Flash = try #require(zAI.seedModels.first { $0.id == "glm-5.3-flash" })
  #expect(glm53Flash.inputModalities.contains("image"))

  #expect(ProviderKind.catalog.contains(.zAI))
  #expect(ProviderKind.zAI.defaultProviderID == "zai")
  #expect(ProviderKind.zAI.logo == .brand(assetName: "provider.zai"))
  #expect(ProviderKind.zAI.reasoningDefault == nil)

  let moonshot = try #require(definitions.first { $0.id == "moonshot" })
  #expect(moonshot.defaultBaseURL.absoluteString == "https://api.moonshot.ai/v1")
  #expect(moonshot.apiFamily == .openAIChatCompletions)
  #expect(moonshot.behavior == .moonshot)
  #expect(moonshot.authentication == .bearer)
  #expect(moonshot.modelsPath == "/models")
  #expect(moonshot.chatCompletionsPath == "/chat/completions")
  #expect(moonshot.kind == .moonshot)
  #expect(moonshot.seedModels.map(\.id) == ["kimi-k3.1-pro", "kimi-k3.1-pro-highspeed", "kimi-k3"])
  let kimiPro = try #require(moonshot.seedModels.first)
  #expect(kimiPro.id == "kimi-k3.1-pro")
  #expect(kimiPro.contextWindow == 1_048_576)
  #expect(kimiPro.inputModalities.contains("image"))
  #expect(kimiPro.supportedParameters.contains("temperature") == false)

  #expect(ProviderKind.catalog.contains(.moonshot))
  #expect(ProviderKind.moonshot.defaultProviderID == "moonshot")
  #expect(ProviderKind.moonshot.logo == .brand(assetName: "provider.moonshot"))
  #expect(ProviderKind.moonshot.reasoningDefault == nil)

  let minimax = try #require(definitions.first { $0.id == "minimax" })
  #expect(minimax.defaultBaseURL.absoluteString == "https://api.minimax.io/v1")
  #expect(minimax.apiFamily == .openAIChatCompletions)
  #expect(minimax.behavior == .minimax)
  #expect(minimax.authentication == .bearer)
  #expect(minimax.modelsPath == "/models")
  #expect(minimax.chatCompletionsPath == "/chat/completions")
  #expect(minimax.kind == .minimax)
  #expect(minimax.seedModels.map(\.id) == ["MiniMax-M3.1-Flash", "MiniMax-M3"])
  let m31Flash = try #require(minimax.seedModels.first)
  #expect(m31Flash.id == "MiniMax-M3.1-Flash")
  #expect(m31Flash.contextWindow == 1_000_000)
  #expect(m31Flash.maxOutputTokens == 512_000)
  #expect(m31Flash.inputModalities.contains("image"))

  #expect(ProviderKind.catalog.contains(.minimax))
  #expect(ProviderKind.minimax.defaultProviderID == "minimax")
  #expect(ProviderKind.minimax.logo == .brand(assetName: "provider.minimax"))
  #expect(ProviderKind.minimax.reasoningDefault == nil)

  let qwen = try #require(definitions.first { $0.id == "qwen" })
  #expect(
    qwen.defaultBaseURL.absoluteString == "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
  )
  #expect(qwen.apiFamily == .openAIChatCompletions)
  #expect(qwen.behavior == .qwen)
  #expect(qwen.authentication == .bearer)
  #expect(qwen.modelsPath == nil)
  #expect(qwen.chatCompletionsPath == "/chat/completions")
  #expect(qwen.kind == .qwen)
  #expect(!ProviderKind.qwen.supportsDiscovery)
  #expect(
    qwen.seedModels.map(\.id)
      == ["qwen4-max", "qwen3.8-max", "qwen3.8-flash", "qwen3.7-plus", "qwen3-coder-plus"]
  )
  let qwen4Max = try #require(qwen.seedModels.first)
  #expect(qwen4Max.id == "qwen4-max")
  #expect(qwen4Max.contextWindow == 1_000_000)
  #expect(qwen4Max.maxOutputTokens == 393_216)
  #expect(qwen4Max.inputModalities.contains("image"))
  #expect(qwen4Max.supportedParameters.contains("tools"))

  #expect(ProviderKind.catalog.contains(.qwen))
  #expect(ProviderKind.qwen.defaultProviderID == "qwen")
  #expect(ProviderKind.qwen.logo == .brand(assetName: "provider.qwen"))
  #expect(ProviderKind.qwen.reasoningDefault == nil)

  let mistral = try #require(definitions.first { $0.id == "mistral" })
  #expect(mistral.defaultBaseURL.absoluteString == "https://api.mistral.ai/v1")
  #expect(mistral.apiFamily == .openAIChatCompletions)
  #expect(mistral.behavior == .mistral)
  #expect(mistral.authentication == .bearer)
  #expect(mistral.modelsPath == "/models")
  #expect(mistral.chatCompletionsPath == "/chat/completions")
  #expect(mistral.kind == .mistral)
  #expect(
    mistral.seedModels.map(\.id)
      == ["mistral-large-4-0", "mistral-small-2603", "devstral-2512", "codestral-2508"]
  )
  let large4 = try #require(mistral.seedModels.first)
  #expect(large4.id == "mistral-large-4-0")
  #expect(large4.contextWindow == 1_048_576)
  #expect(large4.inputModalities.contains("image"))

  #expect(ProviderKind.catalog.contains(.mistral))
  #expect(ProviderKind.mistral.defaultProviderID == "mistral")
  #expect(ProviderKind.mistral.logo == .brand(assetName: "provider.mistral"))
  #expect(ProviderKind.mistral.reasoningDefault == nil)

  let groq = try #require(definitions.first { $0.id == "groq" })
  #expect(groq.defaultBaseURL.absoluteString == "https://api.groq.com/openai/v1")
  #expect(groq.apiFamily == .openAIChatCompletions)
  #expect(groq.behavior == .groq)
  #expect(groq.authentication == .bearer)
  #expect(groq.modelsPath == "/models")
  #expect(groq.chatCompletionsPath == "/chat/completions")
  #expect(groq.kind == .groq)
  #expect(
    groq.seedModels.map(\.id)
      == ["openai/gpt-oss-120b", "openai/gpt-oss-20b", "qwen/qwen3.8-27b", "llama-3.1-8b-instant"]
  )
  let gptOSS120B = try #require(groq.seedModels.first)
  #expect(gptOSS120B.id == "openai/gpt-oss-120b")
  #expect(gptOSS120B.contextWindow == 131_072)
  #expect(gptOSS120B.maxOutputTokens == 65_536)
  #expect(gptOSS120B.supportedParameters.contains("tools"))
  let qwen38 = try #require(groq.seedModels.first { $0.id == "qwen/qwen3.8-27b" })
  #expect(qwen38.contextWindow == 131_072)
  #expect(qwen38.maxOutputTokens == 16_384)
  #expect(qwen38.inputModalities.contains("image"))

  #expect(ProviderKind.catalog.contains(.groq))
  #expect(ProviderKind.groq.defaultProviderID == "groq")
  #expect(ProviderKind.groq.logo == .brand(assetName: "provider.groq"))
  #expect(ProviderKind.groq.reasoningDefault == nil)

  let nvidia = try #require(definitions.first { $0.id == "nvidia" })
  #expect(nvidia.defaultBaseURL.absoluteString == "https://integrate.api.nvidia.com/v1")
  #expect(nvidia.apiFamily == .openAIChatCompletions)
  #expect(nvidia.behavior == .nvidia)
  #expect(nvidia.authentication == .bearer)
  #expect(nvidia.modelsPath == "/models")
  #expect(nvidia.chatCompletionsPath == "/chat/completions")
  #expect(nvidia.kind == .nvidia)
  #expect(ProviderKind.nvidia.supportsDiscovery)
  let nvFlash = try #require(nvidia.seedModels.first { $0.id == "deepseek-ai/deepseek-v4-flash" })
  #expect(nvFlash.contextWindow == 1_000_000)
  #expect(nvFlash.supportedParameters.contains("tools"))
  #expect(nvFlash.inputModalities.contains("image"))
  #expect(nvFlash.capabilityEvidence?.facts[.imageInput]?.support == .supported)
  let nvNemotron = try #require(
    nvidia.seedModels.first { $0.id == "nvidia/nemotron-3-ultra-550b-a55b" }
  )
  #expect(nvNemotron.contextWindow == 1_000_000)
  #expect(nvNemotron.supportedParameters.contains("tools"))
  #expect(!nvNemotron.inputModalities.contains("image"))
  let nvQwen = try #require(nvidia.seedModels.first { $0.id == "qwen/qwen3.5-122b-a10b" })
  #expect(nvQwen.contextWindow == 262_144)
  #expect(nvQwen.inputModalities.contains("image"))

  #expect(ProviderKind.catalog.contains(.nvidia))
  #expect(ProviderKind.nvidia.defaultProviderID == "nvidia")
  #expect(ProviderKind.nvidia.logo == .brand(assetName: "provider.nvidia"))
  #expect(ProviderKind.nvidia.reasoningDefault == nil)

  let ollama = try #require(definitions.first { $0.id == "ollama" })
  #expect(ollama.defaultBaseURL.absoluteString == "http://localhost:11434/v1")
  #expect(ollama.apiFamily == .openAIChatCompletions)
  #expect(ollama.behavior == .genericOpenAICompatible)
  #expect(ollama.authentication == .bearer)
  #expect(ollama.modelsPath == "/models")
  #expect(ollama.chatCompletionsPath == "/chat/completions")
  #expect(ollama.kind == .ollama)
  #expect(ollama.allowsLocalHTTP)
  #expect(!ollama.requiresCredential)
  #expect(ollama.seedModels.isEmpty)
  #expect(ProviderKind.localAndCustomCatalog == [.ollama, .lmStudio, .openAICompatible])
  #expect(ProviderKind.ollama.logo == .brand(assetName: "provider.ollama"))

  let lmStudio = try #require(definitions.first { $0.id == "lmstudio" })
  #expect(lmStudio.defaultBaseURL.absoluteString == "http://localhost:1234/v1")
  #expect(lmStudio.apiFamily == .openAIChatCompletions)
  #expect(lmStudio.behavior == .genericOpenAICompatible)
  #expect(lmStudio.authentication == .bearer)
  #expect(lmStudio.modelsPath == "/models")
  #expect(lmStudio.chatCompletionsPath == "/chat/completions")
  #expect(lmStudio.kind == .lmStudio)
  #expect(lmStudio.allowsLocalHTTP)
  #expect(!lmStudio.requiresCredential)
  #expect(lmStudio.seedModels.isEmpty)
  #expect(ProviderKind.lmStudio.logo == .brand(assetName: "provider.lmstudio"))

  let anthropic = try #require(definitions.first { $0.id == "anthropic" })
  let sonnet = try #require(anthropic.seedModels.first { $0.id == "claude-sonnet-5-5" })
  #expect(sonnet.contextWindow == 1_000_000)
  #expect(sonnet.maxOutputTokens == 128_000)
  #expect(sonnet.supportedParameters.contains("temperature") == false)
  #expect(
    Set(anthropic.seedModels.map(\.id))
      == [
        "claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5",
        "claude-fable-5-1", "claude-mythos-5-1", "claude-fable-5-2", "claude-mythos-5-2",
      ]
  )

  let gemini = try #require(definitions.first { $0.id == "gemini" })
  let flash = try #require(gemini.seedModels.first { $0.id == "gemini-3.8-flash" })
  #expect(flash.contextWindow == 1_048_576)
  #expect(flash.maxOutputTokens == 65_536)
  #expect(flash.supportedParameters.contains("temperature") == false)
  #expect(
    Set(gemini.seedModels.map(\.id))
      == ["gemini-3.8-flash", "gemini-4-carbon", "gemini-4-argon", "gemini-4-neon", "gemini-4-hydrogen"]
  )
}

@Test func duplicateProviderIsRejected() throws {
  #expect(throws: ProviderError.self) {
    _ = try ProviderRegistry(definitions: [BuiltInProviders.deepSeek, BuiltInProviders.deepSeek])
  }
}

@Test func customProviderCannotReplaceBuiltInRegistryEntry() async throws {
  let registry = try ProviderRegistry.builtIn()
  let customXAI = try CustomProviderFactory.makeOpenAICompatible(
    id: "xai",
    displayName: "Custom xAI",
    baseURL: URL(string: "https://legacy-xai.example.test/v1")!
  )

  await #expect(throws: ProviderError.self) {
    try await registry.replace(customXAI)
  }

  let xAI = try await registry.definition(for: BuiltInProviders.xAIID)
  #expect(xAI.isBuiltIn)
  #expect(xAI.defaultBaseURL == BuiltInProviders.xAI.defaultBaseURL)
}

@Test func nonHTTPSProviderIsRejected() throws {
  let definition = ProviderDefinition(
    id: "unsafe",
    displayName: "Unsafe",
    behavior: .genericOpenAICompatible,
    defaultBaseURL: URL(string: "http://example.com")!
  )
  #expect(throws: ProviderError.self) {
    _ = try ProviderRegistry(definitions: [definition])
  }
}
