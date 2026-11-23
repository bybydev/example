import Foundation
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

  @Test("MiniMax models preserve MiniMax M-series casing and explicit effort")
  func minimaxLabels() {
    let flash = ComposerTargetLabelFormatter.make(
      providerID: BuiltInProviders.minimaxID,
      providerName: "MiniMax",
      modelName: "MiniMax-M3.1-Flash",
      modelID: "MiniMax-M3.1-Flash",
      supportedParameters: ["reasoning_effort"],
      reasoning: .init(enabled: true, effort: .xhigh)
    )
    #expect(flash == "MiniMax M3.1 Flash · X-High")

    let lowercased = ComposerTargetLabelFormatter.make(
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
    let flagship = ComposerTargetLabelFormatter.make(
      providerID: BuiltInProviders.qwenID,
      providerName: "Alibaba Qwen",
      modelName: "qwen4-max",
      modelID: "qwen4-max",
      supportedParameters: ["thinking", "reasoning_effort"],
      reasoning: .init(enabled: true, effort: .xhigh)
    )
    #expect(flagship == "Qwen 4 Max · X-High")

    let flashOff = ComposerTargetLabelFormatter.make(
      providerID: BuiltInProviders.qwenID,
      providerName: "Alibaba Qwen",
      modelName: "qwen3.8-flash",
      modelID: "qwen3.8-flash",
      supportedParameters: ["thinking", "reasoning_effort"],
      reasoning: .init(enabled: false)
    )
    #expect(flashOff == "Qwen 3.8 Flash · Off")

    let coder = ComposerTargetLabelFormatter.make(
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
    let large4 = ComposerTargetLabelFormatter.make(
      providerID: BuiltInProviders.mistralID,
      providerName: "Mistral AI",
      modelName: "Mistral Large 4",
      modelID: "mistral-large-4-0",
      supportedParameters: ["reasoning_effort"],
      reasoning: .init(enabled: true, effort: .high)
    )
    #expect(large4 == "Mistral Large 4 · High")

    let small4Off = ComposerTargetLabelFormatter.make(
      providerID: BuiltInProviders.mistralID,
      providerName: "Mistral AI",
      modelName: "Mistral Small 4",
      modelID: "mistral-small-2603",
      supportedParameters: ["reasoning_effort"],
      reasoning: .init(enabled: false)
    )
    #expect(small4Off == "Mistral Small 4 · Off")

    let devstral = ComposerTargetLabelFormatter.make(
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
    let gptOSS = ComposerTargetLabelFormatter.make(
      providerID: BuiltInProviders.groqID,
      providerName: "Groq",
      modelName: "GPT-OSS 120B",
      modelID: "openai/gpt-oss-120b",
      supportedParameters: ["reasoning_effort"],
      reasoning: .init(enabled: true, effort: .high)
    )
    #expect(gptOSS == "GPT-OSS 120B · High")

    let qwenOff = ComposerTargetLabelFormatter.make(
      providerID: BuiltInProviders.groqID,
      providerName: "Groq",
      modelName: "Qwen 3.8 27B",
      modelID: "qwen/qwen3.8-27b",
      supportedParameters: ["reasoning_effort"],
      reasoning: .init(enabled: false)
    )
    #expect(qwenOff == "Qwen 3.8 27B · Off")

    let llama = ComposerTargetLabelFormatter.make(
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
    let deepSeekOff = ComposerTargetLabelFormatter.make(
      providerID: BuiltInProviders.togetherID,
      providerName: "Together AI",
      modelName: "DeepSeek V4.1 Flash",
      modelID: "deepseek-ai/DeepSeek-V4.1-Flash",
      supportedParameters: ["reasoning"],
      reasoning: .init(enabled: false)
    )
    #expect(deepSeekOff == "DeepSeek V4.1 Flash · Off")

    let kimiHigh = ComposerTargetLabelFormatter.make(
      providerID: BuiltInProviders.togetherID,
      providerName: "Together AI",
      modelName: "Kimi K3.1 Pro",
      modelID: "moonshotai/Kimi-K3.1-Pro",
      supportedParameters: ["reasoning_effort"],
      reasoning: .init(enabled: true, effort: .high)
    )
    #expect(kimiHigh == "Kimi K3.1 Pro · High")

    let customFamily = ComposerTargetLabelFormatter.make(
      providerID: BuiltInProviders.togetherID,
      providerName: "Together AI",
      modelName: "Glimpse 1.0",
      modelID: "elorian-labs/glimpse-1.0",
      supportedParameters: ["tools"],
      reasoning: nil
    )
    #expect(customFamily == "Together · Glimpse 1.0")
  }

  @Test("Hyphenated custom provider name still strips duplicate prefix from normalized model")
  func hyphenatedCustomProviderPrefix() {
    let label = ComposerTargetLabelFormatter.make(
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

  @Test("Auto-scroll only triggers when appending at the end of a draft")
  func scrollToBottomPolicy() {
    #expect(
      ChatComposerLayoutPolicy.shouldScrollToBottomOnDraftChange(
        oldDraft: "hello",
        newDraft: "hello world"
      )
    )
    #expect(
      ChatComposerLayoutPolicy.shouldScrollToBottomOnDraftChange(
        oldDraft: "line 1",
        newDraft: "line 1\n"
      )
    )
    #expect(
      !ChatComposerLayoutPolicy.shouldScrollToBottomOnDraftChange(
        oldDraft: "line 1\nline 2",
        newDraft: "line 1x\nline 2"
      )
    )
    #expect(
      !ChatComposerLayoutPolicy.shouldScrollToBottomOnDraftChange(
        oldDraft: "hello world",
        newDraft: "hello"
      )
    )
  }

  @Test("Attachment validation rejects empty files, duplicates, and count or size overflows")
  func attachmentValidation() {
    func item(_ id: String, bytes: Int) -> ChatAttachment {
      ChatAttachment(
        id: id,
        kind: .file,
        filename: "\(id).txt",
        mimeType: "text/plain",
        data: bytes == 0 ? Data() : Data([0x61]),
        declaredByteCount: bytes
      )
    }

    #expect(
      ChatComposerLayoutPolicy.attachmentValidationError(
        existing: [item("a", bytes: 100)],
        additions: [item("b", bytes: 200)]
      ) == nil
    )

    #expect(
      ChatComposerLayoutPolicy.attachmentValidationError(
        existing: [item("a", bytes: 100)],
        additions: [item("a", bytes: 100)]
      ) == "This attachment is already in the message."
    )

    #expect(
      ChatComposerLayoutPolicy.attachmentValidationError(
        existing: [],
        additions: [item("empty", bytes: 0)]
      ) == "Empty files cannot be attached."
    )

    let eightItems = (1...8).map { item("f\($0)", bytes: 10) }
    #expect(
      ChatComposerLayoutPolicy.attachmentValidationError(
        existing: eightItems,
        additions: [item("f9", bytes: 10)]
      ) == "A message can include at most 8 attachments."
    )

    let overSingle = ChatAttachment(
      id: "big",
      kind: .file,
      filename: "big.bin",
      mimeType: "application/octet-stream",
      data: Data(),
      declaredByteCount: 21 * 1_024 * 1_024
    )
    #expect(
      ChatComposerLayoutPolicy.attachmentValidationError(
        existing: [],
        additions: [overSingle]
      ) == "Each attachment must be no larger than 20 MB."
    )

    let fifteenMB1 = ChatAttachment(
      id: "m1",
      kind: .file,
      filename: "m1.bin",
      mimeType: "application/octet-stream",
      data: Data(),
      declaredByteCount: 15 * 1_024 * 1_024
    )
    let fifteenMB2 = ChatAttachment(
      id: "m2",
      kind: .file,
      filename: "m2.bin",
      mimeType: "application/octet-stream",
      data: Data(),
      declaredByteCount: 15 * 1_024 * 1_024
    )
    let fifteenMB3 = ChatAttachment(
      id: "m3",
      kind: .file,
      filename: "m3.bin",
      mimeType: "application/octet-stream",
      data: Data(),
      declaredByteCount: 15 * 1_024 * 1_024
    )
    #expect(
      ChatComposerLayoutPolicy.attachmentValidationError(
        existing: [fifteenMB1, fifteenMB2],
        additions: [fifteenMB3]
      ) == "Attachments in one message cannot exceed 40 MB total."
    )
  }

  @Test("Imported file reader rejects empty files and folders cleanly")
  func importedFileValidation() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("composer-import-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    do {
      _ = try LibraryImportSupport.readImportedFile(
        at: dir,
        folderErrorMessage: "Folders cannot be attached.",
        rejectEmptyFiles: true
      )
      Issue.record("Expected folder rejection")
    } catch {
      #expect(error.localizedDescription == "Folders cannot be attached.")
    }

    let emptyFile = dir.appendingPathComponent("empty.txt")
    try Data().write(to: emptyFile)
    do {
      _ = try LibraryImportSupport.readImportedFile(
        at: emptyFile,
        folderErrorMessage: "Folders cannot be attached.",
        rejectEmptyFiles: true
      )
      Issue.record("Expected empty file rejection")
    } catch {
      #expect(error.localizedDescription == "empty.txt is empty and cannot be attached.")
    }
  }
}
