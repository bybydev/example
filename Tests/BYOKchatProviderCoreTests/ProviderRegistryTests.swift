import Foundation
import Testing

@testable import BYOKchatProviderCore

@Test func builtInRegistryContainsPriorityProviders() async throws {
  let registry = try ProviderRegistry.builtIn()
  let definitions = await registry.allDefinitions()
  #expect(
    Set(definitions.map(\.id))
      == ["deepseek", "openrouter", "nvidia", "anthropic", "gemini"]
  )
  #expect(definitions.first { $0.id == "anthropic" }?.apiFamily == .anthropicMessages)
  #expect(definitions.first { $0.id == "gemini" }?.apiFamily == .geminiGenerateContent)
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
