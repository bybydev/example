import Testing

@testable import BYOKchat
import BYOKchatProviderCore

@Suite("Composer target labels")
struct ComposerTargetLabelFormatterTests {
  @Test("Omits provider for recognizable DeepSeek family")
  func deepSeekLabel() {
    let label = ComposerTargetLabelFormatter.make(
      providerID: BuiltInProviders.deepSeekID,
      providerName: "DeepSeek",
      modelName: "DeepSeek V4 Flash",
      modelID: "deepseek-v4-flash",
      supportedParameters: ["thinking", "reasoning_effort"],
      reasoning: .init(enabled: true, effort: .high)
    )

    #expect(label == "V4 Flash · High")
  }

  @Test("Keeps Gemini family name while dropping redundant provider metadata")
  func geminiLabel() {
    let label = ComposerTargetLabelFormatter.make(
      providerID: BuiltInProviders.geminiID,
      providerName: "Gemini",
      modelName: "Gemini 2.5 Pro",
      modelID: "gemini-2.5-pro",
      supportedParameters: ["thinking"],
      reasoning: .init(enabled: true, effort: .medium)
    )

    #expect(label == "Gemini 2.5 Pro · Med")
  }

  @Test("Uses model family instead of Anthropic provider name")
  func claudeLabel() {
    let label = ComposerTargetLabelFormatter.make(
      providerID: BuiltInProviders.anthropicID,
      providerName: "Anthropic",
      modelName: "Claude Sonnet 5",
      modelID: "claude-sonnet-5",
      supportedParameters: ["thinking", "effort"],
      reasoning: .init(enabled: true, effort: .high)
    )

    #expect(label == "Sonnet 5 · High")
  }

  @Test("Adds provider shorthand when model family is ambiguous")
  func ambiguousOpenRouterLabel() {
    let label = ComposerTargetLabelFormatter.make(
      providerID: BuiltInProviders.openRouterID,
      providerName: "OpenRouter",
      modelName: "Nova 3.1",
      modelID: "vendor/nova-3.1",
      supportedParameters: ["reasoning"],
      reasoning: nil
    )

    #expect(label == "OR · Nova 3.1 · Off")
  }
}
