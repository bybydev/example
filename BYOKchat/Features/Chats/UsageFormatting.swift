import BYOKchatProviderCore
import Foundation

nonisolated func usageDisplayName(
  _ raw: String,
  accounts: [ProviderAccount] = [],
  fallbackLabel: String? = nil
) -> String {
  let kind = ProviderKind(providerID: ProviderID(rawValue: raw.lowercased()))
  if !kind.displayName.isEmpty {
    return kind.displayName
  }
  if let matched = accounts.first(where: {
    $0.providerID.rawValue.caseInsensitiveCompare(raw) == .orderedSame
  }) {
    let trimmed = matched.label.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { return trimmed }
  }
  if let fallbackLabel {
    let trimmed = fallbackLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { return trimmed }
  }
  if UUID(uuidString: raw) != nil {
    return "Custom Provider"
  }
  return raw
}

nonisolated func usageRequestCountLabel(_ count: Int) -> String {
  count == 1 ? "1 request" : "\(count.formatted()) requests"
}

nonisolated func usageTokenCount(_ value: Int) -> String {
  value.formatted(.number.grouping(.automatic))
}

nonisolated func usageCompactTokens(_ value: Int) -> String {
  let number = Double(value)
  if value >= 999_950 {
    return String(format: "%.2fM", number / 1_000_000)
  }
  if value >= 1_000 {
    return String(format: "%.1fK", number / 1_000)
  }
  return value.formatted()
}

nonisolated func usageCachedTokensWithRate(
  cached: Int,
  input: Int,
  compact: Bool
) -> String {
  let formatted = compact ? usageCompactTokens(cached) : usageTokenCount(cached)
  guard input > 0, cached > 0 else { return formatted }
  let rate = min(max(Double(cached) / Double(input), 0), 1)
  return "\(formatted) (\(usagePercent(rate)))"
}

nonisolated func usageFinishReasonTitle(_ raw: String) -> String {
  let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  switch normalized {
  case "stop", "end_turn", "completed", "complete":
    return "Completed"
  case "length", "max_tokens", "max_output_tokens", "model_length":
    return "Max tokens reached"
  case "tool_calls", "tool_use", "function_call":
    return "Tool calls"
  case "content_filter", "safety", "recitation", "refusal":
    return "Filtered by safety"
  case "pause_turn":
    return "Paused"
  case "stop_sequence":
    return "Stop sequence"
  case "cancelled", "canceled":
    return "Stopped"
  default:
    return usageErrorTitle(normalized)
  }
}

nonisolated func usagePricePerMillion(_ perToken: Decimal) -> String {
  usageFormatUSD(perToken * Decimal(1_000_000))
}

nonisolated func usageAggregateCostText(_ aggregate: ChatUsageAggregate) -> String {
  guard aggregate.assistantMessageCount > 0 else { return "No requests" }
  guard aggregate.hasKnownCost else { return "Unavailable" }
  let prefix = aggregate.isLowerBound ? "≥" : (aggregate.hasEstimatedCost ? "~" : "")
  return prefix + usageFormatUSD(aggregate.costUSD) + (aggregate.hasPartialCost ? " (partial)" : "")
}

nonisolated func usageFormatUSD(_ cost: Decimal) -> String {
  let value = NSDecimalNumber(decimal: cost).doubleValue
  let magnitude = abs(value)
  if magnitude == 0 {
    return "$0.00"
  }
  if magnitude < 0.0009995 {
    return String(format: "$%.6f", value)
  }
  if magnitude < 0.99995 {
    return String(format: "$%.4f", value)
  }
  return String(format: "$%.2f", value)
}

nonisolated func usageDuration(_ milliseconds: Double?) -> String {
  guard let milliseconds, milliseconds.isFinite, milliseconds >= 0 else { return "—" }
  if milliseconds < 999.5 {
    return "\(Int(milliseconds.rounded())) ms"
  }
  if milliseconds < 9_995 {
    return String(format: "%.2f s", milliseconds / 1_000)
  }
  return String(format: "%.1f s", milliseconds / 1_000)
}

nonisolated func usageRate(_ value: Double?) -> String {
  guard let value, value.isFinite, value >= 0 else { return "—" }
  return String(format: "%.1f tok/s", value)
}

nonisolated func usagePercent(_ value: Double?) -> String {
  guard let value, value.isFinite else { return "—" }
  return value.formatted(.percent.precision(.fractionLength(0...1)))
}

nonisolated func usageCategoryTitle(_ category: TelemetryCategory) -> String {
  switch category {
  case .mcp: "MCP"
  default: category.rawValue.capitalized
  }
}

nonisolated func usageErrorTitle(_ raw: String) -> String {
  let acronyms: [String: String] = [
    "http": "HTTP",
    "mcp": "MCP",
    "url": "URL",
    "api": "API",
    "id": "ID",
    "json": "JSON",
    "sse": "SSE",
  ]
  return raw
    .replacingOccurrences(of: "_", with: " ")
    .split(separator: " ")
    .map { part in
      let lower = part.lowercased()
      return acronyms[lower] ?? part.capitalized
    }
    .joined(separator: " ")
}

nonisolated func usageHistoryFootnote(_ aggregate: ChatUsageAggregate) -> String {
  let cost = aggregate.hasPartialCost
    ? "Costs are incomplete: some requests lack usage, pricing, or supported billing details. Estimates may differ from provider charges. "
    : "Calculated costs are estimates; provider-reported costs use the reported billing scope. "
  let scope = aggregate.scopedProviderCostMessageCount > 0
    ? "OpenRouter BYOK subtotals include its account charge; upstream provider spend is excluded. " : ""
  return cost + scope + "Totals come from saved chat history. Regenerating, editing, or deleting messages can reduce them. API-key usage in other apps is excluded."
}
