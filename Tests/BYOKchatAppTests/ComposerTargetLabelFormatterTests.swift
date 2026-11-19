import Testing

@testable import BYOKchat
import BYOKchatProviderCore

@Suite("Composer target labels")
struct ComposerTargetLabelFormatterTests {
  @Test("Hyphenated DeepSeek model ID shows its family and version, not Default")
  func deepSeekHyphenated() {
    let label = ComposerTargetLabelFormatter.make(
      providerID: BuiltInProviders.deepSeekID,
      providerName: "DeepSeek",
      modelName: "DeepSeek-V4.1-Flash",
      modelID: "deepseek-v4.1-flash",
      supportedParameters: ["thinking", "reasoning_effort"],
      reasoning: nil
    )
    #expect(label == "DS V4.1 Flash")
  }

  @Test("Keeps explicit effort on the compressed DeepSeek label")
  func deepSeekLabel() {
    let label = ComposerTargetLabelFormatter.make(
      providerID: BuiltInProviders.deepSeekID,
      providerName: "DeepSeek",
      modelName: "DeepSeek V4 Flash",
      modelID: "deepseek-v4-flash",
      supportedParameters: ["thinking", "reasoning_effort"],
      reasoning: .init(enabled: true, effort: .high)
    )
    #expect(label == "DS V4 Flash · High")
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
    #expect(label == "Gemini 2.5 Pro · 1K")
  }

  @Test("Direct Anthropic abbreviates the Claude family but preserves Sonnet")
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

  @Test("OpenRouter keeps the model's real vendor instead of an unhelpful router prefix")
  func aggregatorVendorLabel() {
    let label = ComposerTargetLabelFormatter.make(
      providerID: BuiltInProviders.openRouterID,
      providerName: "OpenRouter",
      modelName: "anthropic/claude-sonnet-4.5",
      modelID: "anthropic/claude-sonnet-4.5",
      supportedParameters: [],
      reasoning: nil
    )
    #expect(label == "Claude Sonnet 4.5")
  }

  @Test("OpenRouter DeepSeek models preserve the model vendor rather than using DS")
  func aggregatorDeepSeekLabel() {
    let label = ComposerTargetLabelFormatter.make(
      providerID: BuiltInProviders.openRouterID,
      providerName: "OpenRouter",
      modelName: "deepseek/deepseek-v4.1-flash",
      modelID: "deepseek/deepseek-v4.1-flash",
      supportedParameters: [],
      reasoning: nil
    )
    #expect(label == "DeepSeek V4.1 Flash")
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

  @Test("Custom provider metadata is replaced by initials")
  func customProviderLabel() {
    let label = ComposerTargetLabelFormatter.make(
      providerID: "my-custom-provider",
      providerName: "My Lab",
      modelName: "My Lab - Aster 2",
      modelID: "aster-2",
      supportedParameters: [],
      reasoning: nil
    )
    #expect(label == "ML · Aster 2")
  }

  @Test("Only explicit reasoning options occupy composer width")
  func providerDefaultAndOffLabels() {
    func label(_ options: ReasoningOptions?) -> String {
      ComposerTargetLabelFormatter.make(
        providerID: BuiltInProviders.openAIID,
        providerName: "OpenAI",
        modelName: "GPT-5.6 Sol",
        modelID: "gpt-5.6-sol",
        supportedParameters: ["reasoning"],
        reasoning: options
      )
    }
    #expect(label(nil) == "GPT-5.6 Sol")
    #expect(label(.init(enabled: false)) == "GPT-5.6 Sol · Off")
    #expect(label(.init(enabled: true, effort: .medium)) == "GPT-5.6 Sol · Med")
    #expect(label(.init(enabled: true, effort: .xhigh)) == "GPT-5.6 Sol · X-High")
  }

  @Test("OpenAI o-series model names are recognized without provider repetition")
  func oSeriesModelLabel() {
    let label = ComposerTargetLabelFormatter.make(
      providerID: BuiltInProviders.openAIID,
      providerName: "OpenAI",
      modelName: "o4-mini",
      modelID: "o4-mini",
      supportedParameters: [],
      reasoning: nil
    )
    #expect(label == "o4 Mini")
  }

  @Test("Unknown vendor prefix isn't guessed from a substring")
  func unknownModelNameKeepsProvider() {
    let label = ComposerTargetLabelFormatter.make(
      providerID: "private-endpoint",
      providerName: "Private Endpoint",
      modelName: "supergptish-large",
      modelID: "supergptish-large",
      supportedParameters: [],
      reasoning: nil
    )
    #expect(label == "PE · supergptish large")
  }

  @Test("Z.ai GLM models preserve GLM casing and explicit effort")
  func zAILabels() {
    let flagship = ComposerTargetLabelFormatter.make(
      providerID: BuiltInProviders.zAIID,
      providerName: "Z.ai",
      modelName: "glm-5.3-flash",
      modelID: "glm-5.3-flash",
      supportedParameters: ["thinking", "reasoning_effort"],
      reasoning: .init(enabled: true, effort: .high)
    )
    #expect(flagship == "GLM-5.3 Flash · High")

    let vision = ComposerTargetLabelFormatter.make(
      providerID: BuiltInProviders.zAIID,
      providerName: "Z.ai",
      modelName: "glm-5v-turbo",
      modelID: "glm-5v-turbo",
      supportedParameters: ["thinking"],
      reasoning: nil
    )
    #expect(vision == "GLM-5V Turbo")
  }

  @Test("Moonshot AI Kimi models preserve K-series casing and explicit effort")
  func moonshotLabels() {
    let pro = ComposerTargetLabelFormatter.make(
      providerID: BuiltInProviders.moonshotID,
      providerName: "Moonshot AI",
      modelName: "kimi-k3.1-pro",
      modelID: "kimi-k3.1-pro",
      supportedParameters: ["reasoning_effort"],
      reasoning: .init(enabled: true, effort: .high)
    )
    #expect(pro == "Kimi K3.1 Pro · High")

    let highspeed = ComposerTargetLabelFormatter.make(
      providerID: BuiltInProviders.moonshotID,
      providerName: "Moonshot AI",
      modelName: "kimi-k3.1-pro-highspeed",
      modelID: "kimi-k3.1-pro-highspeed",
      supportedParameters: ["reasoning_effort"],
      reasoning: nil
    )
    #expect(highspeed == "Kimi K3.1 Pro Highspeed")
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
