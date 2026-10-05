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
    let fixed = ModelCapabilityResolver.reasoningControl(kind: .xAI, modelID: "grok-4.20-0309-reasoning")
    #expect(fixed.choices == [.providerDefault, .on])
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
