import Foundation
import Testing

@testable import BYOKchatProviderCore

@Test func builtInRegistryContainsPriorityProviders() async throws {
  let registry = try ProviderRegistry.builtIn()
  let definitions = await registry.allDefinitions()
  #expect(
    Set(definitions.map(\.id))
      == ["openai", "xai", "deepseek", "openrouter", "nvidia", "anthropic", "gemini"]
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
