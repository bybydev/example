import Foundation
import Testing

@testable import BYOKmac
import BYOKchatProviderCore

@Suite("macOS composer target labels")
struct MacTargetLabelFormatterTests {
  @Test("Hyphenated DeepSeek model ID shows its family and version, not Default")
  func deepSeekHyphenated() {
    let label = MacTargetLabelFormatter.make(
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
    let label = MacTargetLabelFormatter.make(
      providerID: BuiltInProviders.deepSeekID,
      providerName: "DeepSeek",
      modelName: "DeepSeek V4 Flash",
      modelID: "deepseek-v4-flash",
      supportedParameters: ["thinking", "reasoning_effort"],
      reasoning: .init(enabled: true, effort: .high)
    )
    #expect(label == "DS V4 Flash · High")
  }

  @Test("Keeps Gemini family name with compact budget and Auto")
  func geminiLabel() {
    let budgetLabel = MacTargetLabelFormatter.make(
      providerID: BuiltInProviders.geminiID,
      providerName: "Gemini",
      modelName: "Gemini 2.5 Pro",
      modelID: "gemini-2.5-pro",
      supportedParameters: ["thinking"],
      reasoning: .init(enabled: true, maxTokens: 4_000)
    )
    #expect(budgetLabel == "Gemini 2.5 Pro · 4K")

    let autoLabel = MacTargetLabelFormatter.make(
      providerID: BuiltInProviders.geminiID,
      providerName: "Gemini",
      modelName: "Gemini 2.5 Pro",
      modelID: "gemini-2.5-pro",
      supportedParameters: ["thinking"],
      reasoning: .init(enabled: true, maxTokens: -1)
    )
    #expect(autoLabel == "Gemini 2.5 Pro · Auto")
  }

  @Test("Direct Anthropic abbreviates the Claude family but preserves Sonnet")
  func claudeLabel() {
    let label = MacTargetLabelFormatter.make(
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
    let label = MacTargetLabelFormatter.make(
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
    let label = MacTargetLabelFormatter.make(
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
    let label = MacTargetLabelFormatter.make(
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
    let label = MacTargetLabelFormatter.make(
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
      MacTargetLabelFormatter.make(
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
    let label = MacTargetLabelFormatter.make(
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
    let label = MacTargetLabelFormatter.make(
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
    let flagship = MacTargetLabelFormatter.make(
      providerID: BuiltInProviders.zAIID,
      providerName: "Z.ai",
      modelName: "glm-5.3-flash",
      modelID: "glm-5.3-flash",
      supportedParameters: ["thinking", "reasoning_effort"],
      reasoning: .init(enabled: true, effort: .high)
    )
    #expect(flagship == "GLM-5.3 Flash · High")

    let vision = MacTargetLabelFormatter.make(
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
    let pro = MacTargetLabelFormatter.make(
      providerID: BuiltInProviders.moonshotID,
      providerName: "Moonshot AI",
      modelName: "kimi-k3.1-pro",
      modelID: "kimi-k3.1-pro",
      supportedParameters: ["reasoning_effort"],
      reasoning: .init(enabled: true, effort: .high)
    )
    #expect(pro == "Kimi K3.1 Pro · High")

    let highspeed = MacTargetLabelFormatter.make(
      providerID: BuiltInProviders.moonshotID,
      providerName: "Moonshot AI",
      modelName: "kimi-k3.1-pro-highspeed",
      modelID: "kimi-k3.1-pro-highspeed",
      supportedParameters: ["reasoning_effort"],
      reasoning: nil
    )
    #expect(highspeed == "Kimi K3.1 Pro Highspeed")
  }

  @Test("MiniMax models preserve MiniMax M-series casing and explicit effort")
  func minimaxLabels() {
    let flash = MacTargetLabelFormatter.make(
      providerID: BuiltInProviders.minimaxID,
      providerName: "MiniMax",
      modelName: "MiniMax-M3.1-Flash",
      modelID: "MiniMax-M3.1-Flash",
      supportedParameters: ["reasoning_effort"],
      reasoning: .init(enabled: true, effort: .xhigh)
    )
    #expect(flash == "MiniMax M3.1 Flash · X-High")

    let lowercased = MacTargetLabelFormatter.make(
      providerID: BuiltInProviders.minimaxID,
      providerName: "MiniMax",
      modelName: "minimax-m3",
      modelID: "MiniMax-M3",
      supportedParameters: ["thinking"],
      reasoning: .init(enabled: false)
    )
    #expect(lowercased == "MiniMax M3 · Off")
  }

  @Test("Alibaba Qwen models preserve Qwen casing and explicit effort")
  func qwenLabels() {
    let flagship = MacTargetLabelFormatter.make(
      providerID: BuiltInProviders.qwenID,
      providerName: "Alibaba Qwen",
      modelName: "qwen4-max",
      modelID: "qwen4-max",
      supportedParameters: ["thinking", "reasoning_effort"],
      reasoning: .init(enabled: true, effort: .xhigh)
    )
    #expect(flagship == "Qwen 4 Max · X-High")

    let flashOff = MacTargetLabelFormatter.make(
      providerID: BuiltInProviders.qwenID,
      providerName: "Alibaba Qwen",
      modelName: "qwen3.8-flash",
      modelID: "qwen3.8-flash",
      supportedParameters: ["thinking", "reasoning_effort"],
      reasoning: .init(enabled: false)
    )
    #expect(flashOff == "Qwen 3.8 Flash · Off")

    let coder = MacTargetLabelFormatter.make(
      providerID: BuiltInProviders.qwenID,
      providerName: "Alibaba Qwen",
      modelName: "qwen3-coder-plus",
      modelID: "qwen3-coder-plus",
      supportedParameters: ["tools"],
      reasoning: nil
    )
    #expect(coder == "Qwen 3 Coder Plus")
  }

  @Test("Mistral AI models preserve family names and explicit effort")
  func mistralLabels() {
    let large4 = MacTargetLabelFormatter.make(
      providerID: BuiltInProviders.mistralID,
      providerName: "Mistral AI",
      modelName: "Mistral Large 4",
      modelID: "mistral-large-4-0",
      supportedParameters: ["reasoning_effort"],
      reasoning: .init(enabled: true, effort: .high)
    )
    #expect(large4 == "Mistral Large 4 · High")

    let small4Off = MacTargetLabelFormatter.make(
      providerID: BuiltInProviders.mistralID,
      providerName: "Mistral AI",
      modelName: "Mistral Small 4",
      modelID: "mistral-small-2603",
      supportedParameters: ["reasoning_effort"],
      reasoning: .init(enabled: false)
    )
    #expect(small4Off == "Mistral Small 4 · Off")

    let devstral = MacTargetLabelFormatter.make(
      providerID: BuiltInProviders.mistralID,
      providerName: "Mistral AI",
      modelName: "Devstral 2",
      modelID: "devstral-2512",
      supportedParameters: ["tools"],
      reasoning: nil
    )
    #expect(devstral == "Devstral 2")
  }

  @Test("Groq models preserve GPT-OSS, Qwen, and Llama labels with explicit effort")
  func groqLabels() {
    let gptOSS = MacTargetLabelFormatter.make(
      providerID: BuiltInProviders.groqID,
      providerName: "Groq",
      modelName: "GPT-OSS 120B",
      modelID: "openai/gpt-oss-120b",
      supportedParameters: ["reasoning_effort"],
      reasoning: .init(enabled: true, effort: .high)
    )
    #expect(gptOSS == "GPT-OSS 120B · High")

    let qwenOff = MacTargetLabelFormatter.make(
      providerID: BuiltInProviders.groqID,
      providerName: "Groq",
      modelName: "Qwen 3.8 27B",
      modelID: "qwen/qwen3.8-27b",
      supportedParameters: ["reasoning_effort"],
      reasoning: .init(enabled: false)
    )
    #expect(qwenOff == "Qwen 3.8 27B · Off")

    let llama = MacTargetLabelFormatter.make(
      providerID: BuiltInProviders.groqID,
      providerName: "Groq",
      modelName: "Llama 3.1 8B Instant",
      modelID: "llama-3.1-8b-instant",
      supportedParameters: ["tools"],
      reasoning: nil
    )
    #expect(llama == "Llama 3.1 8B Instant")
  }

  @Test("Together AI models preserve vendor families and explicit reasoning choices")
  func togetherLabels() {
    let deepSeekOff = MacTargetLabelFormatter.make(
      providerID: BuiltInProviders.togetherID,
      providerName: "Together AI",
      modelName: "DeepSeek V4.1 Flash",
      modelID: "deepseek-ai/DeepSeek-V4.1-Flash",
      supportedParameters: ["reasoning"],
      reasoning: .init(enabled: false)
    )
    #expect(deepSeekOff == "DeepSeek V4.1 Flash · Off")

    let kimiHigh = MacTargetLabelFormatter.make(
      providerID: BuiltInProviders.togetherID,
      providerName: "Together AI",
      modelName: "Kimi K3.1 Pro",
      modelID: "moonshotai/Kimi-K3.1-Pro",
      supportedParameters: ["reasoning_effort"],
      reasoning: .init(enabled: true, effort: .high)
    )
    #expect(kimiHigh == "Kimi K3.1 Pro · High")

    let customFamily = MacTargetLabelFormatter.make(
      providerID: BuiltInProviders.togetherID,
      providerName: "Together AI",
      modelName: "Glimpse 1.0",
      modelID: "elorian-labs/glimpse-1.0",
      supportedParameters: ["tools"],
      reasoning: nil
    )
    #expect(customFamily == "Together · Glimpse 1.0")
  }

  @Test("Fireworks AI models normalize p-decimal slugs and explicit reasoning choices")
  func fireworksLabels() {
    let deepSeekOff = MacTargetLabelFormatter.make(
      providerID: BuiltInProviders.fireworksID,
      providerName: "Fireworks AI",
      modelName: "accounts/fireworks/models/deepseek-v4p1-flash",
      modelID: "accounts/fireworks/models/deepseek-v4p1-flash",
      supportedParameters: ["reasoning_effort"],
      reasoning: .init(enabled: false)
    )
    #expect(deepSeekOff == "DeepSeek V4.1 Flash · Off")

    let kimiHigh = MacTargetLabelFormatter.make(
      providerID: BuiltInProviders.fireworksID,
      providerName: "Fireworks AI",
      modelName: "accounts/fireworks/models/kimi-k3p1-pro",
      modelID: "accounts/fireworks/models/kimi-k3p1-pro",
      supportedParameters: ["reasoning_effort"],
      reasoning: .init(enabled: true, effort: .high)
    )
    #expect(kimiHigh == "Kimi K3.1 Pro · High")

    let customFamily = MacTargetLabelFormatter.make(
      providerID: BuiltInProviders.fireworksID,
      providerName: "Fireworks AI",
      modelName: "Glimpse 1.0",
      modelID: "accounts/fireworks/models/glimpse-1p0",
      supportedParameters: ["tools"],
      reasoning: nil
    )
    #expect(customFamily == "Fireworks · Glimpse 1.0")
  }

  @Test("Local providers preserve Ollama and LM Studio short names for custom models")
  func localProviderShortNames() {
    let ollama = MacTargetLabelFormatter.make(
      providerID: BuiltInProviders.ollamaID,
      providerName: "Ollama",
      modelName: "my-local-model",
      modelID: "my-local-model",
      supportedParameters: [],
      reasoning: nil
    )
    #expect(ollama == "Ollama · my local model")

    let lmStudio = MacTargetLabelFormatter.make(
      providerID: BuiltInProviders.lmStudioID,
      providerName: "LM Studio",
      modelName: "my-local-model",
      modelID: "my-local-model",
      supportedParameters: [],
      reasoning: nil
    )
    #expect(lmStudio == "LM Studio · my local model")
  }

  @Test("Hyphenated custom provider name still strips duplicate prefix from normalized model")
  func hyphenatedCustomProviderPrefix() {
    let label = MacTargetLabelFormatter.make(
      providerID: "my-lab",
      providerName: "My-Lab",
      modelName: "My-Lab - Aster 2",
      modelID: "aster-2",
      supportedParameters: [],
      reasoning: nil
    )
    #expect(label == "ML · Aster 2")
  }
}
