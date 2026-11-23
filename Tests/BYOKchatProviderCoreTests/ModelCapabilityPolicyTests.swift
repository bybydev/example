import Foundation
import Testing

@testable import BYOKchatProviderCore

@Suite("Shared model capability policy")
struct ModelCapabilityPolicyTests {
  @Test("Explicit discovery negatives survive seeds, legacy sets, and weaker inference")
  func negativeEvidenceAndRefresh() {
    var evidence = ModelCapabilityEvidence()
    evidence.set(.imageInput, supported: false, source: .discovery)
    evidence.set(.tools, supported: false, source: .discovery)
    evidence.set(.imageInput, supported: true, source: .inference)
    let live = ProviderModel(providerID: "openai", id: "gpt-5.6-sol", displayName: "Live",
      capabilityEvidence: evidence)
    let seed = ProviderKind.openai.seedModels.first { $0.id == live.id }!
    let merged = live.mergingCapabilities(from: seed)
    let resolved = ModelCapabilityResolver.resolve(kind: .openai, modelID: live.id, model: merged)
    #expect(resolved[.imageInput] == .unsupported)
    #expect(resolved[.tools] == .unsupported)
    #expect(resolved.facts[.imageInput]?.source == .discovery)
    #expect(resolved[.fileInput] == .supported)
    #expect(resolved.contextWindowSource == .catalog)
    #expect(!merged.inputModalities.contains("image"))
    #expect(!merged.supportedParameters.contains("tools"))

    var refreshed = live
    refreshed.capabilityEvidence?.set(.imageInput, supported: true, source: .discovery)
    let updated = refreshed.mergingCapabilities(from: merged)
    #expect(ModelCapabilityResolver.resolve(kind: .openai, modelID: live.id, model: updated)[.imageInput] == .supported)
  }

  @Test("Missing fields stay unknown and non-exhaustive lists supply only positive hints")
  func partialEvidence() {
    var evidence = ModelCapabilityEvidence()
    evidence.modalities(nil, input: true)
    evidence.parameters(nil)
    #expect(evidence.facts.isEmpty)
    evidence.modalities(["text"], input: true, exhaustive: false)
    evidence.parameters(["temperature"], exhaustive: false)
    #expect(evidence.facts[.textInput]?.support == .supported)
    #expect(evidence.facts[.imageInput] == nil)
    #expect(evidence.facts[.tools] == nil)
    evidence.modalities(["text"], input: true)
    #expect(evidence.facts[.imageInput]?.support == .unsupported)
  }

  @Test("Evidence persists without making old workspaces authoritative")
  func persistenceCompatibility() throws {
    let legacy = ProviderModel(providerID: "custom", id: "local", displayName: "Local")
    let bytes = try JSONEncoder.providerEncoder.encode(legacy)
    let decoded = try JSONDecoder.provider.decode(ProviderModel.self, from: bytes)
    #expect(decoded.capabilityEvidence == nil)
    let capabilities = ModelCapabilityResolver.resolve(kind: .openAICompatible, modelID: decoded.id, model: decoded)
    #expect(capabilities[.imageInput] == .unknown)
    #expect(capabilities.facts[.textInput]?.source == .inference)

    var withEvidence = legacy
    var evidence = ModelCapabilityEvidence()
    evidence.set(.tools, supported: false, source: .discovery)
    withEvidence.capabilityEvidence = evidence
    let encoded = try JSONEncoder.providerEncoder.encode(withEvidence)
    #expect(try JSONDecoder.provider.decode(ProviderModel.self, from: encoded) == withEvidence)
  }

  @Test("Model-specific choices preserve semantics during target changes")
  func reasoningSelection() {
    let openAI = ModelCapabilityResolver.reasoningControl(kind: .openai, modelID: "gpt-5.6-sol")
    #expect(openAI.normalize(nil) == nil)
    #expect(openAI.choice(for: nil) == .providerDefault)
    #expect(openAI.choice(for: .init(enabled: false)) == .off)
    #expect(openAI.choices.contains(.effort(.xhigh)))
    #expect(openAI.choices.contains(.effort(.max)))
    let selected = openAI.options(for: .effort(.xhigh), preserving: .init(excludeFromResponse: true))
    #expect(selected?.effort == .xhigh)
    #expect(selected?.excludeFromResponse == true)
    let grok = ModelCapabilityResolver.reasoningControl(kind: .xAI, modelID: "grok-4.6")
    #expect(grok.normalize(selected) == selected)
    #expect(grok.normalize(.init(enabled: true, effort: .max)) == nil)
    #expect(!grok.choices.contains(.off))
    #expect(grok.normalize(.init(enabled: false)) == nil)
    let pro = ModelCapabilityResolver.reasoningControl(kind: .gemini, modelID: "gemini-3-pro-preview")
    #expect(pro.normalize(.init(enabled: true, effort: .medium)) == nil)
    #expect(pro.label(for: nil) == "Default (High)")

    let gemini4Carbon = ModelCapabilityResolver.reasoningControl(kind: .gemini, modelID: "gemini-4-carbon")
    #expect(gemini4Carbon.choices == [.providerDefault, .effort(.low), .effort(.medium), .effort(.high)])
    #expect(gemini4Carbon.label(for: nil) == "Default (Medium)")
    #expect(gemini4Carbon.normalize(.init(enabled: false)) == nil)
    #expect(gemini4Carbon.normalize(.init(enabled: true, effort: .xhigh)) == nil)
    #expect(gemini4Carbon.normalize(.init(enabled: true, effort: .high))?.effort == .high)

    let gemini4Argon = ModelCapabilityResolver.reasoningControl(kind: .gemini, modelID: "gemini-4-argon")
    #expect(gemini4Argon.choices == [.providerDefault, .effort(.low), .effort(.medium), .effort(.high)])
    #expect(gemini4Argon.label(for: nil) == "Default (Medium)")

    let gemini4Hydrogen = ModelCapabilityResolver.reasoningControl(kind: .gemini, modelID: "gemini-4-hydrogen")
    #expect(
      gemini4Hydrogen.choices
        == [.providerDefault, .effort(.low), .effort(.medium), .effort(.high), .effort(.xhigh)]
    )
    #expect(gemini4Hydrogen.label(for: nil) == "Default (High)")
    #expect(gemini4Hydrogen.normalize(.init(enabled: true, effort: .minimal)) == nil)
    #expect(gemini4Hydrogen.normalize(.init(enabled: true, effort: .xhigh))?.effort == .xhigh)

    let gemini4Neon = ModelCapabilityResolver.reasoningControl(kind: .gemini, modelID: "gemini-4-neon")
    #expect(
      gemini4Neon.choices
        == [.providerDefault, .effort(.low), .effort(.medium), .effort(.high), .effort(.xhigh)]
    )
    #expect(gemini4Neon.label(for: nil) == "Default (High)")

    let geminiImage = ModelCapabilityResolver.reasoningControl(kind: .gemini, modelID: "gemini-3-pro-image-preview")
    #expect(geminiImage.kind == .unknown)
    #expect(geminiImage.choices.isEmpty)
    let fixed = ModelCapabilityResolver.reasoningControl(kind: .xAI, modelID: "grok-4.20-0309-reasoning")
    #expect(fixed.choices == [.providerDefault, .on])

    let glm53 = ModelCapabilityResolver.reasoningControl(kind: .zAI, modelID: "glm-5.3")
    #expect(glm53.choices == [.providerDefault, .effort(.low), .effort(.high), .effort(.max)])
    #expect(glm53.label(for: nil) == "Default (Max)")
    #expect(glm53.normalize(.init(enabled: false)) == nil)
    #expect(glm53.normalize(.init(enabled: true, effort: .medium)) == nil)
    #expect(glm53.normalize(.init(enabled: true, effort: .low))?.effort == .low)

    let glm53Flash = ModelCapabilityResolver.reasoningControl(kind: .zAI, modelID: "glm-5.3-flash")
    #expect(!glm53Flash.choices.contains(.off))
    #expect(glm53Flash.efforts == [.low, .high, .max])

    let glm52 = ModelCapabilityResolver.reasoningControl(kind: .zAI, modelID: "glm-5.2")
    #expect(glm52.choices == [.providerDefault, .off, .effort(.low), .effort(.high), .effort(.max)])
    #expect(glm52.normalize(.init(enabled: false))?.enabled == false)

    let glm51 = ModelCapabilityResolver.reasoningControl(kind: .zAI, modelID: "glm-5.1")
    #expect(glm51.choices == [.providerDefault, .off, .on])
    #expect(glm51.normalize(.init(enabled: true, effort: .high)) == nil)
    #expect(glm51.normalize(.init(enabled: false))?.enabled == false)

    let kimiK31 = ModelCapabilityResolver.reasoningControl(kind: .moonshot, modelID: "kimi-k3.1-pro")
    #expect(kimiK31.choices == [.providerDefault, .effort(.low), .effort(.high), .effort(.max)])
    #expect(kimiK31.label(for: nil) == "Default (Max)")
    #expect(kimiK31.normalize(.init(enabled: false)) == nil)
    #expect(kimiK31.normalize(.init(enabled: true, effort: .medium)) == nil)
    #expect(kimiK31.normalize(.init(enabled: true, effort: .low))?.effort == .low)

    let kimiK3 = ModelCapabilityResolver.reasoningControl(kind: .moonshot, modelID: "kimi-k3")
    #expect(!kimiK3.choices.contains(.off))
    #expect(kimiK3.efforts == [.low, .high, .max])

    let kimiK25 = ModelCapabilityResolver.reasoningControl(kind: .moonshot, modelID: "kimi-k2.5")
    #expect(kimiK25.choices == [.providerDefault, .off, .effort(.low), .effort(.high), .effort(.max)])
    #expect(kimiK25.normalize(.init(enabled: false))?.enabled == false)

    let m31Flash = ModelCapabilityResolver.reasoningControl(kind: .minimax, modelID: "MiniMax-M3.1-Flash")
    #expect(
      m31Flash.choices
        == [.providerDefault, .effort(.low), .effort(.medium), .effort(.high), .effort(.xhigh), .effort(.max)]
    )
    #expect(m31Flash.label(for: nil) == "Default (Max)")
    #expect(m31Flash.normalize(.init(enabled: false)) == nil)
    #expect(m31Flash.normalize(.init(enabled: true, effort: .xhigh))?.effort == .xhigh)

    let m3 = ModelCapabilityResolver.reasoningControl(kind: .minimax, modelID: "MiniMax-M3")
    #expect(m3.choices == [.providerDefault, .off, .on])
    #expect(m3.normalize(.init(enabled: false))?.enabled == false)
    #expect(m3.normalize(.init(enabled: true, effort: .high)) == nil)

    let qwen4Max = ModelCapabilityResolver.reasoningControl(kind: .qwen, modelID: "qwen4-max")
    #expect(
      qwen4Max.choices == [.providerDefault, .off, .effort(.low), .effort(.high), .effort(.xhigh)]
    )
    #expect(qwen4Max.label(for: nil) == "Default (High)")
    #expect(qwen4Max.normalize(.init(enabled: false))?.enabled == false)
    #expect(qwen4Max.normalize(.init(enabled: true, effort: .xhigh))?.effort == .xhigh)
    #expect(qwen4Max.normalize(.init(enabled: true, effort: .medium)) == nil)

    let qwen38Flash = ModelCapabilityResolver.reasoningControl(kind: .qwen, modelID: "qwen3.8-flash")
    #expect(
      qwen38Flash.choices
        == [.providerDefault, .off, .effort(.low), .effort(.medium), .effort(.high), .effort(.xhigh)]
    )
    #expect(qwen38Flash.label(for: nil) == "Default (Extra High)")
    #expect(qwen38Flash.normalize(.init(enabled: false))?.enabled == false)

    let qwenCoder = ModelCapabilityResolver.reasoningControl(kind: .qwen, modelID: "qwen3-coder-plus")
    #expect(qwenCoder.kind == .unsupported)
    #expect(qwenCoder.choices.isEmpty)

    let large4 = ModelCapabilityResolver.reasoningControl(kind: .mistral, modelID: "mistral-large-4-0")
    #expect(large4.choices == [.providerDefault, .effort(.low), .effort(.medium), .effort(.high)])
    #expect(large4.label(for: nil) == "Default (High)")
    #expect(large4.normalize(.init(enabled: false)) == nil)
    #expect(large4.normalize(.init(enabled: true, effort: .medium))?.effort == .medium)

    let small4 = ModelCapabilityResolver.reasoningControl(kind: .mistral, modelID: "mistral-small-2603")
    #expect(small4.choices == [.providerDefault, .off, .effort(.high)])
    #expect(small4.normalize(.init(enabled: false))?.enabled == false)
    #expect(small4.normalize(.init(enabled: true, effort: .medium)) == nil)
    #expect(small4.normalize(.init(enabled: true, effort: .high))?.effort == .high)

    let magistral = ModelCapabilityResolver.reasoningControl(kind: .mistral, modelID: "magistral-medium-2509")
    #expect(magistral.choices == [.providerDefault, .on])

    let groqGPTOSS = ModelCapabilityResolver.reasoningControl(kind: .groq, modelID: "openai/gpt-oss-120b")
    #expect(groqGPTOSS.choices == [.providerDefault, .effort(.low), .effort(.medium), .effort(.high)])
    #expect(groqGPTOSS.label(for: nil) == "Default (Medium)")
    #expect(groqGPTOSS.normalize(.init(enabled: false)) == nil)
    #expect(groqGPTOSS.normalize(.init(enabled: true, effort: .high))?.effort == .high)

    let groqQwen38 = ModelCapabilityResolver.reasoningControl(kind: .groq, modelID: "qwen/qwen3.8-27b")
    #expect(groqQwen38.choices == [.providerDefault, .off, .effort(.low), .effort(.medium), .effort(.high)])
    #expect(groqQwen38.normalize(.init(enabled: false))?.enabled == false)
    #expect(groqQwen38.normalize(.init(enabled: true, effort: .low))?.effort == .low)

    let groqLlama = ModelCapabilityResolver.reasoningControl(kind: .groq, modelID: "llama-3.1-8b-instant")
    #expect(groqLlama.kind == .unsupported)
    #expect(groqLlama.choices.isEmpty)

    let haiku55 = ModelCapabilityResolver.reasoningControl(kind: .anthropic, modelID: "claude-haiku-5-5")
    #expect(
      haiku55.choices
        == [.providerDefault, .off, .effort(.low), .effort(.medium), .effort(.high), .effort(.xhigh), .effort(.max)]
    )
    #expect(haiku55.label(for: nil) == "Default (Medium)")
    let haikuOff = haiku55.normalize(.init(enabled: false, effort: .max))
    #expect(haikuOff?.enabled == false)
    #expect(haikuOff?.effort == nil)
    #expect(haiku55.normalize(.init(enabled: true, effort: .xhigh))?.effort == .xhigh)

    let astra62 = ModelCapabilityResolver.reasoningControl(kind: .openai, modelID: "gpt-6.2-astra")
    #expect(
      astra62.choices
        == [.providerDefault, .effort(.low), .effort(.medium), .effort(.high), .effort(.xhigh), .effort(.max)]
    )
    #expect(astra62.normalize(.init(enabled: false)) == nil)

    let sol62 = ModelCapabilityResolver.reasoningControl(kind: .openai, modelID: "gpt-6.2-sol")
    #expect(!sol62.choices.contains(.off))
    #expect(sol62.efforts == [.low, .medium, .high, .xhigh, .max])

    let terra61 = ModelCapabilityResolver.reasoningControl(kind: .openai, modelID: "gpt-6.1-terra")
    #expect(
      terra61.choices
        == [.providerDefault, .off, .effort(.low), .effort(.medium), .effort(.high), .effort(.xhigh), .effort(.max)]
    )
    #expect(terra61.offWireValue == "none")
    #expect(terra61.normalize(.init(enabled: false))?.enabled == false)

    let luna6 = ModelCapabilityResolver.reasoningControl(kind: .openai, modelID: "gpt-6-luna")
    #expect(luna6.choices.contains(.off))
    #expect(luna6.offWireValue == "none")

    let codexMini = ModelCapabilityResolver.reasoningControl(kind: .openai, modelID: "codex-mini-latest")
    #expect(codexMini.choices == [.providerDefault, .effort(.low), .effort(.medium), .effort(.high)])
    #expect(codexMini.normalize(.init(enabled: false)) == nil)

    let grok43 = ModelCapabilityResolver.reasoningControl(kind: .xAI, modelID: "grok-4.3")
    #expect(
      grok43.choices
        == [.providerDefault, .off, .effort(.low), .effort(.medium), .effort(.high), .effort(.xhigh)]
    )
    #expect(grok43.label(for: nil) == "Default (Low)")
    #expect(grok43.normalize(.init(enabled: false))?.enabled == false)

    let grok3Mini = ModelCapabilityResolver.reasoningControl(kind: .xAI, modelID: "grok-3-mini")
    #expect(grok3Mini.choices == [.providerDefault, .off, .effort(.low), .effort(.high)])

    let grok4FastReasoning = ModelCapabilityResolver.reasoningControl(kind: .xAI, modelID: "grok-4-fast-reasoning")
    #expect(grok4FastReasoning.kind == .fixed)

    let grok4FastNonReasoning = ModelCapabilityResolver.reasoningControl(
      kind: .xAI, modelID: "grok-4-fast-non-reasoning"
    )
    #expect(grok4FastNonReasoning.kind == .unsupported)

    let grok3 = ModelCapabilityResolver.reasoningControl(kind: .xAI, modelID: "grok-3")
    #expect(grok3.kind == .unsupported)

    let deepSeekFlash = ModelCapabilityResolver.reasoningControl(kind: .deepSeek, modelID: "deepseek-flash")
    #expect(
      deepSeekFlash.choices
        == [.providerDefault, .off, .effort(.low), .effort(.high), .effort(.max)]
    )
    #expect(deepSeekFlash.label(for: nil) == "Default (High)")
    #expect(deepSeekFlash.normalize(.init(enabled: false))?.enabled == false)
    #expect(deepSeekFlash.normalize(.init(enabled: true, effort: .low))?.effort == .low)
    #expect(deepSeekFlash.normalize(.init(enabled: true, effort: .medium)) == nil)

    let deepSeekPro = ModelCapabilityResolver.reasoningControl(kind: .deepSeek, modelID: "deepseek-v4-pro")
    #expect(
      deepSeekPro.choices
        == [.providerDefault, .off, .effort(.low), .effort(.high), .effort(.max)]
    )
    #expect(deepSeekPro.normalize(.init(enabled: true, effort: .low))?.effort == .low)
    #expect(deepSeekPro.normalize(.init(enabled: false))?.enabled == false)

    let openRouterFree = ModelCapabilityResolver.reasoningControl(kind: .openRouter, modelID: "openrouter/free")
    #expect(
      openRouterFree.choices
        == [.providerDefault, .effort(.low), .effort(.medium), .effort(.high)]
    )
    #expect(openRouterFree.normalize(.init(enabled: false)) == nil)
    #expect(openRouterFree.normalize(.init(enabled: true, effort: .high))?.effort == .high)

    let openRouterUnknown = ModelCapabilityResolver.reasoningControl(kind: .openRouter, modelID: "vendor/custom")
    #expect(openRouterUnknown.kind == .unknown)
  }

  @Test("Native names on custom endpoints do not invent reasoning controls")
  func customAndAdapterBoundaries() {
    var evidence = ModelCapabilityEvidence()
    evidence.set(.audioInput, supported: true, source: .discovery)
    evidence.set(.imageOutput, supported: true, source: .discovery)
    let model = ProviderModel(providerID: "custom", id: "gpt-5.6-sol", displayName: "Local",
      supportedParameters: ["reasoning"], capabilityEvidence: evidence)
    let custom = ModelCapabilityResolver.resolve(kind: .openAICompatible, modelID: model.id, model: model)
    #expect(custom.reasoning.kind == .unknown)
    #expect(custom.reasoning.choices.isEmpty)
    #expect(custom[.audioInput] == .unsupported)
    #expect(custom[.imageOutput] == .unsupported)
    #expect(model.capabilityEvidence?.facts[.audioInput]?.support == .supported)
  }

  @Test("Budgets support automatic thinking and respect model and output limits")
  func budgetConstraints() throws {
    let flash = ModelCapabilityResolver.reasoningControl(kind: .gemini, modelID: "gemini-2.5-flash")
    #expect(flash.normalize(.init(enabled: true, maxTokens: -1))?.maxTokens == -1)
    #expect(flash.normalize(.init(enabled: true, maxTokens: 24_577)) == nil)
    #expect(flash.budgetValidationMessage(.init(enabled: true, maxTokens: 0)) != nil)
    #expect(flash.choice(for: .init(enabled: true, maxTokens: 0)) == .budget)
    let pro = ModelCapabilityResolver.reasoningControl(kind: .gemini, modelID: "gemini-2.5-pro")
    #expect(!pro.choices.contains(.off))
    let model = ProviderModel(providerID: "anthropic", id: "claude-3-7-sonnet", displayName: "Claude",
      contextWindow: 200_000, contextWindowKind: .inputOnly, maxOutputTokens: 2_048)
    let resolved = ModelCapabilityResolver.resolve(kind: .anthropic, modelID: model.id, model: model)
    #expect(resolved.contextWindowKind == .inputOnly)
    #expect(resolved.reasoning.budget?.maximum == 2_047)
    #expect(resolved.reasoning.options(for: .budget, preserving: nil)?.maxTokens == 2_047)
    #expect(resolved.reasoning.budgetValidationMessage(.init(enabled: true, maxTokens: 1_024), outputLimit: 1_024) != nil)
    #expect(throws: ProviderError.self) {
      _ = try ModelRequestPolicy.prepare(.init(model: model.id, messages: [.init(role: .user, content: "Hello")],
        options: .init(maxOutputTokens: 1_024, reasoning: .init(enabled: true, maxTokens: 1_024)),
        capabilities: resolved), kind: .anthropic)
    }
  }

  @Test("Opus 4.5 supports an effort and thinking budget together")
  func combinedEffortAndBudget() {
    let control = ModelCapabilityResolver.reasoningControl(kind: .anthropic, modelID: "claude-opus-4-5")
    let selection = control.options(for: .effort(.medium), preserving: .init(enabled: true, maxTokens: 1_500))
    #expect(selection?.effort == .medium)
    #expect(selection?.maxTokens == 1_500)
    #expect(control.choice(for: selection) == .effort(.medium))
    #expect(control.label(for: selection) == "Medium · 1500 tokens")

    let budgetOnly = control.options(for: .budget, preserving: selection)
    #expect(budgetOnly?.effort == nil)
    #expect(budgetOnly?.maxTokens == 1_500)
    #expect(control.choice(for: budgetOnly) == .budget)
    #expect(control.label(for: budgetOnly) == "1500 tokens")
  }

  @Test("Unsupported historical tools project into text without modifying their stored payloads")
  func toolHistoryProjection() throws {
    var evidence = ModelCapabilityEvidence()
    evidence.set(.tools, supported: false, source: .discovery)
    let model = ProviderModel(providerID: "custom", id: "text-only", displayName: "Text", capabilityEvidence: evidence)
    let capabilities = ModelCapabilityResolver.resolve(kind: .openAICompatible, modelID: model.id, model: model)
    let call = ChatToolCall(id: "call", name: "weather", arguments: .object(["city": .string("Hanoi")]))
    let result = ChatToolResult(callID: "call", name: "weather", content: .string("Sunny"))
    let messages: [ProviderMessage] = [
      .init(role: .user, content: "Weather?"),
      .init(role: .assistant, content: "", toolCalls: [call],
        toolContinuation: .init(apiFamily: .openAIResponses, payload: .array([.string("opaque")]))),
      .init(role: .tool, content: "", toolResults: [result]),
      .init(role: .assistant, content: "Sunny today."),
      .init(role: .user, content: "Hello"),
    ]
    let original = ProviderRequest(model: model.id, messages: messages,
      tools: [.init(name: "weather", description: "Weather")], capabilities: capabilities)
    let prepared = try ModelRequestPolicy.prepare(original, kind: .openAICompatible)
    #expect(prepared.tools.isEmpty)
    #expect(prepared.messages.allSatisfy { $0.role != .tool && $0.toolCalls == nil && $0.toolResults == nil && $0.toolContinuation == nil })
    #expect(prepared.messages[1].content.contains("weather"))
    #expect(prepared.messages[2].content.contains("Sunny"))
    #expect(original.messages[1].toolCalls == [call])
    #expect(original.messages[2].toolResults == [result])
    #expect(original.tools.count == 1)
  }

  @Test("History omits incompatible attachments while the current turn is rejected")
  func attachmentProjection() throws {
    var evidence = ModelCapabilityEvidence()
    evidence.set(.imageInput, supported: false, source: .discovery)
    evidence.set(.fileInput, supported: false, source: .discovery)
    let model = ProviderModel(providerID: "custom", id: "text", displayName: "Text", capabilityEvidence: evidence)
    let capabilities = ModelCapabilityResolver.resolve(kind: .openAICompatible, modelID: model.id, model: model)
    let image = ChatAttachment(kind: .image, filename: "photo.png", mimeType: "image/png", data: Data([1]))
    let text = ChatAttachment(kind: .file, filename: "notes.txt", mimeType: "text/plain", data: Data("notes".utf8))
    let history: [ProviderMessage] = [
      .init(role: .user, content: "Describe", attachments: [image]),
      .init(role: .assistant, content: "A photo."),
      .init(role: .user, content: "Hello", attachments: [text]),
    ]
    let projected = try ModelRequestPolicy.project(messages: history, kind: .openAICompatible, capabilities: capabilities)
    #expect(projected[0].attachments == nil)
    #expect(projected[0].content.contains("photo.png"))
    #expect(projected.last?.attachments == [text])
    #expect(history[0].attachments == [image])
    #expect(throws: ProviderError.self) {
      _ = try ModelRequestPolicy.project(messages: [.init(role: .user, content: "Describe", attachments: [image])],
        kind: .openAICompatible, capabilities: capabilities)
    }
    let unknown = ModelCapabilityResolver.resolve(kind: .openAICompatible, modelID: "unknown")
    try ModelRequestPolicy.validateAttachments([image], kind: .openAICompatible, capabilities: unknown)
    let svg = ChatAttachment(kind: .image, filename: "diagram.svg", mimeType: "image/svg+xml", data: Data([1]))
    #expect(ModelRequestPolicy.attachmentError(svg, kind: .openai, capabilities: unknown) != nil)
    let largeAnthropicImage = ChatAttachment(
      kind: .image,
      filename: "huge.png",
      mimeType: "image/png",
      data: Data(repeating: 0, count: 5 * 1_024 * 1_024 + 1)
    )
    #expect(
      ModelRequestPolicy.attachmentError(largeAnthropicImage, kind: .anthropic, capabilities: unknown) != nil
    )
  }

  @Test("Unsupported tool definitions are removed before context budgeting")
  func contextBudgetDoesNotCountUnsupportedTools() throws {
    var evidence = ModelCapabilityEvidence()
    evidence.set(.tools, supported: false, source: .discovery)
    let model = ProviderModel(providerID: "custom", id: "text", displayName: "Text", capabilityEvidence: evidence)
    let capabilities = ModelCapabilityResolver.resolve(kind: .openAICompatible, modelID: model.id, model: model)
    let conversation = ChatConversation(providerID: "custom", accountID: "account", modelID: model.id,
      messages: [.init(role: .user, content: "Hello", status: .complete)])
    let context = try ChatContextBuilder.build(conversation: conversation, contextWindow: 2_000,
      reservedOutputTokens: 64, tools: [.init(name: "huge_tool", description: String(repeating: "Schema ", count: 20_000))],
      capabilities: capabilities, providerKind: .openAICompatible)
    #expect(context.messages.last?.content == "Hello")
    #expect(conversation.messages.last?.content == "Hello")
  }
}
