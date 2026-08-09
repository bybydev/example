import Foundation
import Testing

@testable import BYOKchatProviderCore

@Test func builtInRegistryContainsPriorityProviders() async throws {
  let registry = try ProviderRegistry.builtIn()
  let definitions = await registry.allDefinitions()
  #expect(
    Set(definitions.map(\.id))
      == ["openai", "deepseek", "openrouter", "nvidia", "anthropic", "gemini"]
  )
  #expect(definitions.first { $0.id == "anthropic" }?.apiFamily == .anthropicMessages)
  #expect(definitions.first { $0.id == "gemini" }?.apiFamily == .geminiGenerateContent)

  let openAI = try #require(definitions.first { $0.id == "openai" })
  #expect(openAI.defaultBaseURL.absoluteString == "https://api.openai.com/v1")
  #expect(openAI.apiFamily == .openAIChatCompletions)
  #expect(openAI.authentication == .bearer)
  #expect(openAI.modelsPath == "/models")
  #expect(openAI.chatCompletionsPath == "/chat/completions")

  let anthropic = try #require(definitions.first { $0.id == "anthropic" })
  let sonnet = try #require(anthropic.seedModels.first { $0.id == "claude-sonnet-5" })
  #expect(sonnet.contextWindow == 1_000_000)
  #expect(sonnet.maxOutputTokens == 128_000)
  #expect(sonnet.supportedParameters.contains("temperature") == false)

  let gemini = try #require(definitions.first { $0.id == "gemini" })
  let flash = try #require(gemini.seedModels.first { $0.id == "gemini-3.6-flash" })
  #expect(flash.contextWindow == 1_048_576)
  #expect(flash.maxOutputTokens == 65_536)
  #expect(flash.supportedParameters.contains("temperature") == false)
}

@Test func duplicateProviderIsRejected() throws {
  #expect(throws: ProviderError.self) {
    _ = try ProviderRegistry(definitions: [BuiltInProviders.deepSeek, BuiltInProviders.deepSeek])
  }
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
