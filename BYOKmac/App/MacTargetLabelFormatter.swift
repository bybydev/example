import BYOKchatProviderCore
import Foundation

/// Builds the composer model-pill label: provider shorthand (only when the
/// model family alone is ambiguous), a compact model name, and — when the
/// model supports it — a reasoning-effort abbreviation. Mirrors the iOS
/// composer's target chip.
enum MacTargetLabelFormatter {
  private static let recognizableFamilies = [
    "gpt", "claude", "sonnet", "opus", "haiku", "gemini", "deepseek", "qwen",
    "llama", "mistral", "grok", "kimi", "nemotron", "phi", "command r", "minimax",
  ]

  static func make(
    providerID: ProviderID,
    providerName: String,
    modelName: String,
    modelID: String,
    supportedParameters: Set<String>,
    reasoning: ReasoningOptions?,
    capabilities: ResolvedModelCapabilities? = nil
  ) -> String {
    let source = modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? modelID
      : modelName
    let compactModel = compactModelName(source, providerName: providerName)
    let recognitionSource = (source + " " + modelID).lowercased()
    let isRecognizable = recognizableFamilies.contains { recognitionSource.contains($0) }

    var parts: [String] = []
    if !isRecognizable {
      parts.append(shortProviderName(providerID: providerID, displayName: providerName))
    }
    parts.append(compactModel)

    let control = capabilities?.reasoning ?? ModelCapabilityResolver.resolve(
      kind: ProviderKind.allCases.first { $0.defaultProviderID == providerID } ?? .openAICompatible,
      modelID: ModelID(rawValue: modelID)
    ).reasoning
    let label = control.label(for: reasoning)
    if !label.isEmpty { parts.append(label) }

    return parts.filter { !$0.isEmpty }.joined(separator: " · ")
  }

  private static func compactModelName(_ rawValue: String, providerName: String) -> String {
    var value = rawValue
      .replacingOccurrences(of: "_", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    value = collapseWhitespace(value)

    let providerIsModelFamily = recognizableFamilies.contains {
      providerName.lowercased().contains($0)
    }
    if !providerIsModelFamily,
      value.lowercased().hasPrefix(providerName.lowercased() + " ")
    {
      value = String(value.dropFirst(providerName.count))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    let removableVendorPrefixes = [
      "OpenAI",
      "Anthropic",
      "Google DeepMind",
      "Google",
      "Meta AI",
      "Meta",
      "Alibaba",
      "NVIDIA",
    ]

    for prefix in removableVendorPrefixes {
      if value.lowercased().hasPrefix(prefix.lowercased() + " ") {
        value = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        break
      }
    }

    let lower = value.lowercased()
    if lower.hasPrefix("claude ") {
      value = String(value.dropFirst("Claude ".count))
    } else if lower.hasPrefix("deepseek ") {
      let remainder = String(value.dropFirst("DeepSeek ".count))
      let remainderLower = remainder.lowercased()
      if remainderLower.hasPrefix("v")
        || remainderLower.hasPrefix("r")
        || remainderLower.hasPrefix("coder")
        || remainderLower.hasPrefix("reasoner")
      {
        value = remainder
      }
    }

    value = collapseWhitespace(value)
    if value.isEmpty {
      return rawValue.split(separator: "/").last.map(String.init) ?? rawValue
    }
    return value
  }

  private static func shortProviderName(providerID: ProviderID, displayName: String) -> String {
    switch providerID {
    case BuiltInProviders.openRouterID: return "OR"
    case BuiltInProviders.nvidiaID: return "NV"
    case BuiltInProviders.deepSeekID: return "DS"
    case BuiltInProviders.anthropicID: return "Anthropic"
    case BuiltInProviders.geminiID: return "Gemini"
    default:
      let words = displayName
        .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
        .map(String.init)
      if words.count > 1 {
        let initials = words.prefix(3).compactMap(\.first).map(String.init).joined().uppercased()
        if !initials.isEmpty { return initials }
      }
      if displayName.count <= 7 { return displayName }
      return String(displayName.prefix(4))
    }
  }

  private static func collapseWhitespace(_ value: String) -> String {
    value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
}

