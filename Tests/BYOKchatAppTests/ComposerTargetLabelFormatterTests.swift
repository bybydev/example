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
      reasoning: .init(enabled: true, maxTokens: 1_024)
    )

    #expect(label == "Gemini 2.5 Pro · 1024 tokens")
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

    #expect(label == "OR · Nova 3.1")
  }

  @Test("Provider Default is distinct from explicit Off")
  func providerDefaultAndOffLabels() {
    func label(_ options: ReasoningOptions?) -> String {
      ComposerTargetLabelFormatter.make(providerID: "openai", providerName: "OpenAI",
        modelName: "GPT-5.6 Sol", modelID: "gpt-5.6-sol", supportedParameters: ["reasoning"],
        reasoning: options)
    }
    #expect(label(nil).hasSuffix("Default (Medium)"))
    #expect(label(.init(enabled: false)).hasSuffix("Off"))
    #expect(label(.init(enabled: true, effort: .xhigh)).hasSuffix("Extra High"))
  }
}

@Suite("Composer layout policy")
struct ChatComposerLayoutPolicyTests {
  @Test("Compact is only idle, unfocused, empty, and attachment-free")
  func completeStateMatrix() {
    let activities: [ChatComposerActivity] = [.idle, .generating, .creating]

    for isFocused in [false, true] {
      for draftIsEmpty in [false, true] {
        for hasAttachments in [false, true] {
          for activity in activities {
            let actual = ChatComposerLayoutPolicy.shouldUseCompact(
              isFocused: isFocused,
              draftIsEmpty: draftIsEmpty,
              hasAttachments: hasAttachments,
              activity: activity
            )
            let expected =
              !isFocused
              && draftIsEmpty
              && !hasAttachments
              && activity == .idle

            #expect(actual == expected)
          }
        }
      }
    }
  }

  @Test("Text viewport caps at six lines without attachments and three with attachments")
  func visibleTextLineCaps() {
    #expect(ChatComposerLayoutPolicy.visibleTextLineCap(hasAttachments: false) == 6)
    #expect(ChatComposerLayoutPolicy.visibleTextLineCap(hasAttachments: true) == 3)
  }
}
