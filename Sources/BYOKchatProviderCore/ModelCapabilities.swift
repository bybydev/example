import Foundation

public enum CapabilitySupport: String, Codable, Hashable, Sendable {
  case supported, unsupported, unknown
}

public enum ModelCapability: String, Codable, CaseIterable, Hashable, Sendable {
  case textInput, textOutput, imageInput, imageOutput, audioInput, audioOutput, fileInput, tools, reasoning
}

public enum CapabilitySource: Int, Codable, Hashable, Sendable {
  case unknown = 0, inference, catalog, adapter, discovery
}

public struct CapabilityFact: Codable, Hashable, Sendable {
  public var support: CapabilitySupport
  public var source: CapabilitySource
  public init(_ support: CapabilitySupport, source: CapabilitySource) {
    self.support = support
    self.source = source
  }
}

/// Only facts actually supplied by a catalog belong here. Inference is resolved separately.
public struct ModelCapabilityEvidence: Codable, Hashable, Sendable {
  public var facts: [ModelCapability: CapabilityFact] = [:]
  public var reasoningControl: ModelReasoningControl?
  public var contextWindowSource: CapabilitySource?
  public var maxOutputTokensSource: CapabilitySource?
  public init() {}

  public mutating func set(_ capability: ModelCapability, supported: Bool?, source: CapabilitySource) {
    guard let supported, source.rawValue >= (facts[capability]?.source.rawValue ?? 0) else { return }
    facts[capability] = .init(supported ? .supported : .unsupported, source: source)
  }

  /// Supply an exhaustive list only when the upstream field was actually present.
  public mutating func modalities(_ values: [String]?, input: Bool, exhaustive: Bool = true) {
    guard let values else { return }
    let normalizedModalities = Set(values.map { $0.lowercased() })
    let pairs: [(String, ModelCapability)] = input
      ? [("text", .textInput), ("image", .imageInput), ("audio", .audioInput), ("file", .fileInput)]
      : [("text", .textOutput), ("image", .imageOutput), ("audio", .audioOutput)]
    for (name, capability) in pairs where exhaustive || normalizedModalities.contains(name) {
      set(capability, supported: normalizedModalities.contains(name), source: .discovery)
    }
  }

  public mutating func parameters(_ values: [String]?, exhaustive: Bool = true) {
    guard let values else { return }
    let parameterNames = Set(values)
    let tools = parameterNames.contains("tools")
    let reasoning = !parameterNames.isDisjoint(with: [
      "reasoning", "thinking", "reasoning_effort", "thinkingConfig", "effort",
    ])
    set(.tools, supported: exhaustive || tools ? tools : nil, source: .discovery)
    set(.reasoning, supported: exhaustive || reasoning ? reasoning : nil, source: .discovery)
  }

  public func merging(_ incoming: Self) -> Self {
    var result = self
    for (key, value) in incoming.facts {
      if value.source.rawValue >= (result.facts[key]?.source.rawValue ?? 0) {
        result.facts[key] = value
      }
    }
    if let control = incoming.reasoningControl,
      control.source.rawValue >= (result.reasoningControl?.source.rawValue ?? 0) {
      result.reasoningControl = control
    }
    if let source = incoming.contextWindowSource, source.rawValue >= (contextWindowSource?.rawValue ?? 0) {
      result.contextWindowSource = source
    }
    if let source = incoming.maxOutputTokensSource, source.rawValue >= (maxOutputTokensSource?.rawValue ?? 0) {
      result.maxOutputTokensSource = source
    }
    return result
  }
}

public enum ReasoningChoice: Hashable, Sendable {
  case providerDefault, off, on, effort(ReasoningEffort), budget
  public var title: String {
    switch self {
    case .providerDefault: "Default"
    case .off: "Off"
    case .on: "On"
    case .effort(let effort): effort.title
    case .budget: "Token Budget"
    }
  }
}

public struct ReasoningBudgetControl: Codable, Hashable, Sendable {
  public var minimum: Int
  public var maximum: Int?
  public var defaultTokens: Int
  public var allowsAutomatic: Bool
  public init(minimum: Int, maximum: Int?, defaultTokens: Int, allowsAutomatic: Bool = false) {
    self.minimum = minimum
    self.maximum = maximum
    self.defaultTokens = defaultTokens
    self.allowsAutomatic = allowsAutomatic
  }
}

public struct ModelReasoningControl: Codable, Hashable, Sendable {
  public enum Kind: String, Codable, Hashable, Sendable { case unknown, unsupported, fixed, efforts, budget }
  public var kind: Kind
  public var efforts: [ReasoningEffort]
  public var defaultEffort: ReasoningEffort?
  public var allowsOff: Bool
  public var offWireValue: String?
  public var budget: ReasoningBudgetControl?
  /// Optional for backward-compatible decoding of persisted control metadata.
  public var combinesEffortAndBudget: Bool?
  public var source: CapabilitySource

  public init(
    kind: Kind = .unknown, efforts: [ReasoningEffort] = [], defaultEffort: ReasoningEffort? = nil,
    allowsOff: Bool = false, offWireValue: String? = nil,
    budget: ReasoningBudgetControl? = nil, combinesEffortAndBudget: Bool? = nil,
    source: CapabilitySource = .unknown
  ) {
    self.kind = kind
    self.efforts = efforts
    self.defaultEffort = defaultEffort
    self.allowsOff = allowsOff
    self.offWireValue = offWireValue
    self.budget = budget
    self.combinesEffortAndBudget = combinesEffortAndBudget
    self.source = source
  }

  public var choices: [ReasoningChoice] {
    guard kind != .unknown, kind != .unsupported else { return [] }
    var result: [ReasoningChoice] = [.providerDefault]
    if allowsOff { result.append(.off) }
    result += efforts.map(ReasoningChoice.effort)
    if budget != nil { result.append(.budget) }
    if kind == .fixed { result.append(.on) }
    return result
  }

  /// Invalid saved or staged selections fall back to provider Default; nil never means Off.
  public func normalize(_ options: ReasoningOptions?) -> ReasoningOptions? {
    guard var options, kind != .unknown, kind != .unsupported else { return nil }
    if options.enabled == false {
      return allowsOff ? .init(enabled: false, excludeFromResponse: options.excludeFromResponse) : nil
    }
    if let effort = options.effort, !efforts.contains(effort) { return nil }
    if let tokens = options.maxTokens {
      guard let budget, (tokens == -1 && budget.allowsAutomatic)
        || (tokens >= budget.minimum && tokens <= (budget.maximum ?? Int.max)) else { return nil }
      if combinesEffortAndBudget != true { options.effort = nil }
    }
    if kind == .budget, options.maxTokens == nil {
      guard let budget else { return nil }
      options.maxTokens = budget.defaultTokens
    }
    if kind == .efforts, options.effort == nil, options.maxTokens == nil {
      guard let defaultEffort else { return nil }
      options.effort = defaultEffort
    }
    options.enabled = true
    return options
  }

  public func budgetValidationMessage(_ options: ReasoningOptions?, outputLimit: Int? = nil) -> String? {
    guard options?.enabled != false, let tokens = options?.maxTokens else { return nil }
    guard let budget else { return "This model does not support a thinking token budget." }
    if tokens == -1, budget.allowsAutomatic { return nil }
    if tokens < budget.minimum { return "Use at least \(budget.minimum) thinking tokens." }
    if let maximum = budget.maximum, tokens > maximum { return "Use at most \(maximum) thinking tokens." }
    if let outputLimit, tokens >= outputLimit { return "The thinking budget must be below \(outputLimit) output tokens." }
    return nil
  }

  public func choice(for options: ReasoningOptions?) -> ReasoningChoice {
    if combinesEffortAndBudget == true, options?.enabled != false,
      let effort = options?.effort, efforts.contains(effort) { return .effort(effort) }
    if options?.enabled != false, options?.maxTokens != nil, budget != nil { return .budget }
    guard let options = normalize(options) else { return .providerDefault }
    if options.enabled == false { return .off }
    if options.maxTokens != nil { return .budget }
    if let effort = options.effort { return .effort(effort) }
    return .on
  }

  public func options(for choice: ReasoningChoice, preserving previous: ReasoningOptions?) -> ReasoningOptions? {
    let exclude = previous?.excludeFromResponse ?? false
    switch choice {
    case .providerDefault: return nil
    case .off: return normalize(.init(enabled: false, excludeFromResponse: exclude))
    case .on: return normalize(.init(enabled: true, excludeFromResponse: exclude))
    case .effort(let effort):
      return normalize(.init(enabled: true, effort: effort,
        maxTokens: combinesEffortAndBudget == true ? previous?.maxTokens : nil, excludeFromResponse: exclude))
    case .budget:
      return normalize(.init(enabled: true, effort: combinesEffortAndBudget == true ? previous?.effort : nil,
        maxTokens: previous?.maxTokens ?? budget?.defaultTokens,
        excludeFromResponse: exclude))
    }
  }

  public func label(for options: ReasoningOptions?) -> String {
    if kind == .unknown || kind == .unsupported { return "" }
    guard let options = normalize(options) else {
      return defaultEffort.map { "Default (\($0.title))" } ?? "Default"
    }
    if options.enabled == false { return "Off" }
    if let tokens = options.maxTokens {
      let budgetLabel = tokens == -1 ? "Auto Budget" : "\(tokens) tokens"
      if combinesEffortAndBudget == true, let effort = options.effort { return "\(effort.title) · \(budgetLabel)" }
      return budgetLabel
    }
    return options.effort?.title ?? "On"
  }
}

public struct ResolvedModelCapabilities: Sendable, Equatable {
  public var facts: [ModelCapability: CapabilityFact]
  public var reasoning: ModelReasoningControl
  public var contextWindow: Int?
  public var contextWindowKind: ProviderContextWindowKind
  public var maxOutputTokens: Int?
  public var contextWindowSource: CapabilitySource
  public var maxOutputTokensSource: CapabilitySource
  public subscript(_ capability: ModelCapability) -> CapabilitySupport {
    facts[capability]?.support ?? .unknown
  }
}

public enum ModelCapabilityResolver {
  public static func resolve(kind: ProviderKind, modelID: ModelID, model: ProviderModel? = nil) -> ResolvedModelCapabilities {
    var facts: [ModelCapability: CapabilityFact] = [:]
    func add(_ key: ModelCapability, _ support: CapabilitySupport, _ source: CapabilitySource) {
      guard support != .unknown else { return }
      if source.rawValue >= (facts[key]?.source.rawValue ?? 0) { facts[key] = .init(support, source: source) }
    }
    // Legacy sets can establish hints of positive support, never exhaustive negatives.
    if let model {
      for (name, key) in [("text", ModelCapability.textInput), ("image", .imageInput),
        ("audio", .audioInput), ("file", .fileInput)] where model.inputModalities.contains(name) {
        add(key, .supported, .inference)
      }
      for (name, key) in [("text", ModelCapability.textOutput), ("image", .imageOutput),
        ("audio", .audioOutput)] where model.outputModalities.contains(name) { add(key, .supported, .inference) }
      if model.supportedParameters.contains("tools") { add(.tools, .supported, .inference) }
      if !model.supportedParameters.isDisjoint(with: ["reasoning", "thinking", "reasoning_effort", "thinkingConfig", "effort"]) {
        add(.reasoning, .supported, .inference)
      }
    }
    if let seed = kind.seedModels.first(where: { $0.id == modelID }) {
      for (name, key) in [("text", ModelCapability.textInput), ("image", .imageInput),
        ("audio", .audioInput), ("file", .fileInput)] where seed.inputModalities.contains(name) {
        add(key, .supported, .catalog)
      }
      if seed.supportedParameters.contains("tools") { add(.tools, .supported, .catalog) }
    }
    var reasoning = reasoningControl(kind: kind, modelID: modelID)
    if reasoning.kind != .unknown {
      add(.reasoning, reasoning.kind == .unsupported ? .unsupported : .supported, reasoning.source)
    }
    for (key, fact) in model?.capabilityEvidence?.facts ?? [:] { add(key, fact.support, fact.source) }
    if let explicit = model?.capabilityEvidence?.reasoningControl,
      explicit.source.rawValue >= reasoning.source.rawValue {
      reasoning = explicit
      if explicit.kind != .unknown {
        add(.reasoning, explicit.kind == .unsupported ? .unsupported : .supported, explicit.source)
      }
    }
    if facts[.reasoning]?.support == .unsupported { reasoning = .init(kind: .unsupported) }
    if kind == .nvidia || kind == .ollama || kind == .lmStudio || kind == .openAICompatible {
      // These adapters have no verified configurable reasoning wire contract.
      // A native-looking model name or imported control metadata cannot add one.
      reasoning = .init(kind: facts[.reasoning]?.support == .unsupported ? .unsupported : .unknown)
    }
    // Adapter route limitations remain hard boundaries against live model support.
    // These chat adapters decode text and tools, not generated media.
    facts[.imageOutput] = .init(.unsupported, source: .adapter)
    facts[.audioOutput] = .init(.unsupported, source: .adapter)
    if kind != .gemini { facts[.audioInput] = .init(.unsupported, source: .adapter) }
    let seed = kind.seedModels.first(where: { $0.id == modelID })
    if var budget = reasoning.budget, let maximum = model?.maxOutputTokens ?? seed?.maxOutputTokens {
      budget.maximum = min(budget.maximum ?? Int.max, max(0, maximum - (kind == .anthropic ? 1 : 0)))
      if let maximum = budget.maximum, maximum >= budget.minimum {
        if budget.defaultTokens != -1 { budget.defaultTokens = min(budget.defaultTokens, maximum) }
        reasoning.budget = budget
      } else {
        // No valid explicit budget remains; retain provider Default.
        reasoning = .init(source: reasoning.source)
      }
    }
    return .init(
      facts: facts, reasoning: reasoning,
      contextWindow: model?.contextWindow ?? seed?.contextWindow,
      contextWindowKind: model?.contextWindowKind ?? kind.contextWindowKind,
      maxOutputTokens: model?.maxOutputTokens ?? seed?.maxOutputTokens,
      contextWindowSource: model?.capabilityEvidence?.contextWindowSource ?? (model?.contextWindow != nil ? .inference : seed?.contextWindow != nil ? .catalog : .unknown),
      maxOutputTokensSource: model?.capabilityEvidence?.maxOutputTokensSource ?? (model?.maxOutputTokens != nil ? .inference : seed?.maxOutputTokens != nil ? .catalog : .unknown)
    )
  }

  /// API-scoped rules. Unknown model families never receive a guessed control ladder.
  public static func reasoningControl(kind: ProviderKind, modelID: ModelID) -> ModelReasoningControl {
    let id = modelID.rawValue.lowercased().replacingOccurrences(of: "_", with: "-")
    func efforts(_ values: [ReasoningEffort], defaultEffort value: ReasoningEffort? = .medium,
      off: String? = nil) -> ModelReasoningControl {
      .init(kind: .efforts, efforts: values, defaultEffort: value, allowsOff: off != nil,
        offWireValue: off, source: .adapter)
    }
    switch kind {
    case .openai:
      if id.hasPrefix("gpt-6") {
        if id.contains("terra") || id.contains("luna") {
          return efforts([.low, .medium, .high, .xhigh, .max], off: "none")
        }
        return efforts([.low, .medium, .high, .xhigh, .max])
      }
      if id.hasPrefix("gpt-5.6") { return efforts([.low, .medium, .high, .xhigh, .max], off: "none") }
      if id.hasPrefix("gpt-5.5") || id.hasPrefix("gpt-5.4") || id.hasPrefix("gpt-5.2") {
        if id.contains("pro") { return efforts([.medium, .high, .xhigh], defaultEffort: nil) }
        return efforts([.low, .medium, .high, .xhigh], defaultEffort: id.hasPrefix("gpt-5.5") ? .medium : nil, off: "none")
      }
      if id.hasPrefix("gpt-5.1") {
        if id.contains("codex-max") { return efforts([.medium, .high, .xhigh]) }
        if id.contains("codex") { return efforts([.low, .medium, .high]) }
        return efforts([.low, .medium, .high], defaultEffort: nil, off: "none")
      }
      if id.hasPrefix("gpt-5-pro") { return .init(kind: .fixed, defaultEffort: .high, source: .adapter) }
      if id == "gpt-5" || id.hasPrefix("gpt-5-") { return efforts([.minimal, .low, .medium, .high]) }
      if id.hasPrefix("o1-mini") || id.hasPrefix("o1-preview") || id.hasPrefix("o1-pro") {
        return .init(kind: .fixed, source: .adapter)
      }
      if id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("o4") || id.hasPrefix("codex-") {
        return efforts([.low, .medium, .high])
      }
      if id.hasPrefix("gpt-4") || id.hasPrefix("chatgpt-4") { return .init(kind: .unsupported, source: .adapter) }
    case .deepSeek:
      if id.hasPrefix("deepseek-v4") || id == "deepseek-flash" || id == "deepseek-pro" {
        return efforts([.low, .high, .max], defaultEffort: .high, off: "disabled")
      }
    case .zAI:
      if id.hasPrefix("glm-5.3") {
        return efforts([.low, .high, .max], defaultEffort: .max)
      }
      if id.hasPrefix("glm-5.2") {
        return efforts([.low, .high, .max], defaultEffort: .max, off: "disabled")
      }
      if id.hasPrefix("glm-5") || id.hasPrefix("glm-4.7")
        || id.hasPrefix("glm-4.6") || id.hasPrefix("glm-4.5")
      {
        return .init(kind: .fixed, allowsOff: true, offWireValue: "disabled", source: .adapter)
      }
    case .moonshot:
      if id.hasPrefix("kimi-k3") {
        return efforts([.low, .high, .max], defaultEffort: .max)
      }
      if id.hasPrefix("kimi-k2.6") || id.hasPrefix("kimi-k2.5") {
        return efforts([.low, .high, .max], defaultEffort: .high, off: "disabled")
      }
      if id.hasPrefix("kimi-k2-thinking") {
        return .init(kind: .fixed, source: .adapter)
      }
    case .minimax:
      if id.hasPrefix("minimax-m3.1") {
        return efforts([.low, .medium, .high, .xhigh, .max], defaultEffort: .max)
      }
      if id == "minimax-m3" || id.hasPrefix("minimax-m3-") {
        return .init(kind: .fixed, allowsOff: true, offWireValue: "disabled", source: .adapter)
      }
    case .mistral:
      if id.hasPrefix("mistral-large-4") {
        return efforts([.low, .medium, .high], defaultEffort: .high)
      }
      if id.hasPrefix("mistral-small-2603") || id.hasPrefix("mistral-small-4")
        || id.hasPrefix("mistral-medium-3-5") || id.hasPrefix("mistral-medium-3.5")
      {
        return efforts([.high], defaultEffort: nil, off: "none")
      }
      if id.hasPrefix("magistral") {
        return .init(kind: .fixed, source: .adapter)
      }
    case .gemini:
      if id.contains("image") || id.contains("tts") || id.contains("live")
        || id.contains("transcribe")
      {
        return .init()
      }
      if id.hasPrefix("gemini-4-hydrogen") || id.hasPrefix("gemini-4-neon") {
        return efforts([.low, .medium, .high, .xhigh], defaultEffort: .high)
      }
      if id.hasPrefix("gemini-4") {
        return efforts([.low, .medium, .high], defaultEffort: .medium)
      }
      if id.hasPrefix("gemini-3-pro") { return efforts([.low, .high], defaultEffort: .high) }
      if id.hasPrefix("gemini-3.1-pro") { return efforts([.low, .medium, .high], defaultEffort: .high) }
      if id.hasPrefix("gemini-3.8-flash") || id.hasPrefix("gemini-3.7-flash") {
        return efforts([.low, .medium, .high])
      }
      if id.hasPrefix("gemini-3.1-flash-lite") { return efforts([.minimal, .low, .medium, .high], defaultEffort: .minimal) }
      if id.hasPrefix("gemini-3-flash") { return efforts([.minimal, .low, .medium, .high], defaultEffort: .high) }
      if id.hasPrefix("gemini-3.5-flash-lite") { return efforts([.minimal, .low, .medium, .high], defaultEffort: .minimal) }
      if id.hasPrefix("gemini-3.6-flash") || id.hasPrefix("gemini-3.5-flash") {
        return efforts([.minimal, .low, .medium, .high])
      }
      if id.hasPrefix("gemini-2.5") {
        let pro = id.contains("pro")
        return .init(kind: .budget, allowsOff: !pro, offWireValue: pro ? nil : "0",
          budget: .init(minimum: pro ? 128 : id.contains("lite") ? 512 : 1, maximum: pro ? 32_768 : 24_576,
            defaultTokens: -1, allowsAutomatic: true), source: .adapter)
      }
      if id.hasPrefix("gemini-2.0") || id.hasPrefix("gemini-1") { return .init(kind: .unsupported, source: .adapter) }
    case .anthropic:
      if id.hasPrefix("claude-haiku-5") {
        return efforts([.low, .medium, .high, .xhigh, .max], defaultEffort: .medium, off: "disabled")
      }
      let v5 = id.hasPrefix("claude-opus-5") || id.hasPrefix("claude-sonnet-5")
        || id.hasPrefix("claude-fable-5") || id.hasPrefix("claude-mythos-5")
      if v5 {
        let mandatory = id.contains("5.5") || id.contains("5-5") || id.contains("fable") || id.contains("mythos")
        return efforts([.low, .medium, .high, .xhigh, .max],
          defaultEffort: id.contains("opus-5.5") || id.contains("opus-5-5") ? .medium : .high,
          off: mandatory ? nil : "disabled")
      }
      if id.contains("opus-4-7") || id.contains("opus-4.7") || id.contains("opus-4-8") || id.contains("opus-4.8") {
        return efforts([.low, .medium, .high, .xhigh, .max], defaultEffort: .high, off: "disabled")
      }
      if id.contains("4-6") || id.contains("4.6") { return efforts([.low, .medium, .high, .max], defaultEffort: .high, off: "disabled") }
      if id.contains("opus-4-5") || id.contains("opus-4.5") {
        return .init(kind: .budget, efforts: [.low, .medium, .high], defaultEffort: .high,
          allowsOff: true, offWireValue: "disabled",
          budget: .init(minimum: 1_024, maximum: nil, defaultTokens: 2_048),
          combinesEffortAndBudget: true, source: .adapter)
      }
      if id.contains("claude-3-7") || id.contains("claude-3.7") || id.contains("claude-sonnet-4")
        || id.contains("claude-opus-4") || id.contains("claude-haiku-4") {
        return .init(kind: .budget, allowsOff: true, offWireValue: "disabled",
          budget: .init(minimum: 1_024, maximum: nil, defaultTokens: 2_048), source: .adapter)
      }
      if id.hasPrefix("claude-3") { return .init(kind: .unsupported, source: .adapter) }
    case .xAI:
      if id.contains("non-reasoning") { return .init(kind: .unsupported, source: .adapter) }
      if id.hasPrefix("grok-4.7") || id.hasPrefix("grok-4.6") || id.hasPrefix("grok-4.20-multi-agent") {
        return efforts([.low, .medium, .high, .xhigh], defaultEffort: .high)
      }
      if id.hasPrefix("grok-4.5") { return efforts([.low, .medium, .high], defaultEffort: .high) }
      if id.hasPrefix("grok-4.3") {
        return efforts([.low, .medium, .high, .xhigh], defaultEffort: .low, off: "none")
      }
      if id.hasPrefix("grok-3-mini") {
        return efforts([.low, .high], defaultEffort: .low, off: "none")
      }
      if id.hasPrefix("grok-4.20")
        || id.hasPrefix("grok-4-fast")
        || id.hasPrefix("grok-4-1-fast")
        || id.hasPrefix("grok-4-0709")
        || id == "grok-4"
        || id.hasPrefix("grok-code-fast")
      {
        return .init(kind: .fixed, source: .adapter)
      }
      if id == "grok-3" || id.hasPrefix("grok-3-") {
        return .init(kind: .unsupported, source: .adapter)
      }
    case .openRouter, .nvidia, .ollama, .lmStudio, .openAICompatible:
      // A parameter name does not establish the routed/custom model's valid values.
      break
    }
    return .init()
  }
}

extension ProviderDefinition {
  var capabilityKind: ProviderKind {
    if let kind { return kind }
    switch behavior {
    case .deepSeek: return .deepSeek
    case .zAI: return .zAI
    case .moonshot: return .moonshot
    case .minimax: return .minimax
    case .mistral: return .mistral
    case .openRouter: return .openRouter
    case .nvidia: return .nvidia
    case .anthropic: return .anthropic
    case .gemini: return .gemini
    case .genericOpenAICompatible:
      if id == BuiltInProviders.openAIID { return .openai }
      if id == BuiltInProviders.xAIID { return .xAI }
      if id == BuiltInProviders.ollamaID { return .ollama }
      if id == BuiltInProviders.lmStudioID { return .lmStudio }
      return .openAICompatible
    }
  }
}

extension ProviderModel {
  func withCatalogEvidence() -> ProviderModel {
    var result = self
    var evidence = capabilityEvidence ?? .init()
    for (name, key) in [("text", ModelCapability.textInput), ("image", .imageInput),
      ("audio", .audioInput), ("file", .fileInput)] where inputModalities.contains(name) {
      evidence.set(key, supported: true, source: .catalog)
    }
    for (name, key) in [("text", ModelCapability.textOutput), ("image", .imageOutput),
      ("audio", .audioOutput)] where outputModalities.contains(name) {
      evidence.set(key, supported: true, source: .catalog)
    }
    if supportedParameters.contains("tools") { evidence.set(.tools, supported: true, source: .catalog) }
    if !supportedParameters.isDisjoint(with: ["reasoning", "thinking", "reasoning_effort", "thinkingConfig", "effort"]) {
      evidence.set(.reasoning, supported: true, source: .catalog)
    }
    if contextWindow != nil { evidence.contextWindowSource = .catalog }
    if maxOutputTokens != nil { evidence.maxOutputTokensSource = .catalog }
    result.capabilityEvidence = evidence
    return result
  }

  /// Merges optional facts independently; explicit negative discovery facts survive seed fallback.
  public func mergingCapabilities(from fallback: ProviderModel) -> ProviderModel {
    var result = self
    if result.displayName.isEmpty { result.displayName = fallback.displayName }
    if result.contextWindow == nil || (capabilityEvidence?.contextWindowSource?.rawValue ?? 0)
      < (fallback.capabilityEvidence?.contextWindowSource?.rawValue ?? 0) {
      result.contextWindow = fallback.contextWindow
      result.contextWindowKind = fallback.contextWindowKind
    }
    if result.contextWindowKind == nil { result.contextWindowKind = fallback.contextWindowKind }
    if result.maxOutputTokens == nil || (capabilityEvidence?.maxOutputTokensSource?.rawValue ?? 0)
      < (fallback.capabilityEvidence?.maxOutputTokensSource?.rawValue ?? 0) {
      result.maxOutputTokens = fallback.maxOutputTokens
    }
    if result.promptPricePerToken == nil { result.promptPricePerToken = fallback.promptPricePerToken }
    if result.completionPricePerToken == nil { result.completionPricePerToken = fallback.completionPricePerToken }
    var incomingEvidence = capabilityEvidence ?? .init()
    var fallbackEvidence = fallback.capabilityEvidence ?? .init()
    if contextWindow == nil { incomingEvidence.contextWindowSource = nil }
    if maxOutputTokens == nil { incomingEvidence.maxOutputTokensSource = nil }
    if fallback.contextWindow == nil { fallbackEvidence.contextWindowSource = nil }
    if fallback.maxOutputTokens == nil { fallbackEvidence.maxOutputTokensSource = nil }
    result.capabilityEvidence = fallbackEvidence.merging(incomingEvidence)
    // Legacy presentation fields are reconstructed from evidence rather than unioning authoritative negatives away.
    result.supportedParameters.formUnion(fallback.supportedParameters)
    result.inputModalities.formUnion(fallback.inputModalities)
    result.outputModalities.formUnion(fallback.outputModalities)
    func update(_ values: inout Set<String>, _ name: String, supported: Bool) {
      if supported { values.insert(name) } else { values.remove(name) }
    }
    for (key, fact) in result.capabilityEvidence?.facts ?? [:] where fact.support != .unknown {
      let supported = fact.support == .supported
      switch key {
      case .tools: update(&result.supportedParameters, "tools", supported: supported)
      case .reasoning:
        let names: Set<String> = ["reasoning", "thinking", "reasoning_effort", "thinkingConfig", "effort"]
        if !supported { result.supportedParameters.subtract(names) }
        else if result.supportedParameters.isDisjoint(with: names) { result.supportedParameters.insert("reasoning") }
      case .textInput: update(&result.inputModalities, "text", supported: supported)
      case .imageInput: update(&result.inputModalities, "image", supported: supported)
      case .audioInput: update(&result.inputModalities, "audio", supported: supported)
      case .fileInput: update(&result.inputModalities, "file", supported: supported)
      case .textOutput: update(&result.outputModalities, "text", supported: supported)
      case .imageOutput: update(&result.outputModalities, "image", supported: supported)
      case .audioOutput: update(&result.outputModalities, "audio", supported: supported)
      }
    }
    return result
  }
}
