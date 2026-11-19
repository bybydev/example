import Foundation
import Testing

@testable import BYOKchatProviderCore

@Test func builtInRegistryContainsPriorityProviders() async throws {
  let registry = try ProviderRegistry.builtIn()
  let definitions = await registry.allDefinitions()
  #expect(
    Set(definitions.map(\.id))
      == ["openai", "xai", "deepseek", "zai", "moonshot", "openrouter", "nvidia", "anthropic", "gemini"]
  )
  #expect(definitions.first { $0.id == "anthropic" }?.apiFamily == .anthropicMessages)
  #expect(definitions.first { $0.id == "gemini" }?.apiFamily == .geminiGenerateContent)

  let openAI = try #require(definitions.first { $0.id == "openai" })
  #expect(openAI.defaultBaseURL.absoluteString == "https://api.openai.com/v1")
  #expect(openAI.apiFamily == .openAIResponses)
  #expect(openAI.authentication == .bearer)
  #expect(openAI.modelsPath == "/models")
  #expect(openAI.chatCompletionsPath == "/responses")
  #expect(openAI.seedModels.contains { $0.id == "gpt-6-astra" })
  #expect(openAI.seedModels.contains { $0.id == "gpt-5.6-sol" })
  #expect(openAI.seedModels.contains { $0.id == "gpt-6.1-sol" })
  #expect(openAI.seedModels.contains { $0.id == "gpt-6-luna" })

  let xAI = try #require(definitions.first { $0.id == "xai" })
  #expect(xAI.defaultBaseURL.absoluteString == "https://api.x.ai/v1")
  #expect(xAI.apiFamily == .openAIResponses)
  #expect(xAI.authentication == .bearer)
  #expect(xAI.modelsPath == "/models")
  #expect(xAI.chatCompletionsPath == "/responses")
  #expect(xAI.kind == .xAI)
  #expect(xAI.seedModels.contains { $0.id == "grok-4.6" })
  #expect(xAI.seedModels.contains { $0.id == "grok-4.20-0309-reasoning" })
  #expect(xAI.seedModels.contains { $0.id == "grok-4.20-non-reasoning" })
  #expect(xAI.seedModels.contains { $0.id == "grok-4.20-multi-agent" })
  #expect(xAI.seedModels.contains { $0.id == "grok-4.7" })

  #expect(ProviderKind.catalog.contains(.xAI))
  #expect(ProviderKind.xAI.defaultProviderID == "xai")
  #expect(ProviderKind.xAI.logo == .brand(assetName: "provider.xai"))
  #expect(ProviderKind.xAI.reasoningDefault == .init(enabled: true, effort: .high))

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

  let anthropic = try #require(definitions.first { $0.id == "anthropic" })
  let sonnet = try #require(anthropic.seedModels.first { $0.id == "claude-sonnet-5-5" })
  #expect(sonnet.contextWindow == 1_000_000)
  #expect(sonnet.maxOutputTokens == 128_000)
  #expect(sonnet.supportedParameters.contains("temperature") == false)

  let gemini = try #require(definitions.first { $0.id == "gemini" })
  let flash = try #require(gemini.seedModels.first { $0.id == "gemini-3.8-flash" })
  #expect(flash.contextWindow == 1_048_576)
  #expect(flash.maxOutputTokens == 65_536)
  #expect(flash.supportedParameters.contains("temperature") == false)
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
