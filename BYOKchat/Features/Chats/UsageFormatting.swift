import BYOKchatProviderCore
import Foundation

func usageDisplayName(_ raw: String) -> String {
  switch raw.lowercased() {
  case "openrouter": "OpenRouter"
  case "deepseek": "DeepSeek"
  case "anthropic": "Anthropic"
  case "gemini": "Gemini"
  case "nvidia": "NVIDIA"
  default: raw
  }
}

func usageTokenCount(_ value: Int) -> String {
  value.formatted(.number.grouping(.automatic))
}

func usageCompactTokens(_ value: Int) -> String {
  let number = Double(value)
  if value >= 1_000_000 {
    return String(format: "%.2fM", number / 1_000_000)
  }
  if value >= 1_000 {
    return String(format: "%.1fK", number / 1_000)
  }
  return value.formatted()
}

func usagePricePerMillion(_ perToken: Decimal) -> String {
  usageFormatUSD(perToken * Decimal(1_000_000))
}

func usageAggregateCostText(_ aggregate: ChatUsageAggregate) -> String {
  guard aggregate.hasKnownCost else { return "Unavailable" }
  let prefix = aggregate.hasPartialCost ? "≥" : "~"
  return prefix + usageFormatUSD(aggregate.costUSD)
}

func usageFormatUSD(_ cost: Decimal) -> String {
  let value = NSDecimalNumber(decimal: cost).doubleValue
  if abs(value) < 0.001 {
    return String(format: "$%.6f", value)
  }
  if abs(value) < 1 {
    return String(format: "$%.4f", value)
  }
  return String(format: "$%.2f", value)
}

func usageDuration(_ milliseconds: Double?) -> String {
  guard let milliseconds, milliseconds.isFinite, milliseconds >= 0 else { return "—" }
  if milliseconds < 1_000 {
    return "\(Int(milliseconds.rounded())) ms"
  }
  if milliseconds < 10_000 {
    return String(format: "%.2f s", milliseconds / 1_000)
  }
  return String(format: "%.1f s", milliseconds / 1_000)
}

func usageRate(_ value: Double?) -> String {
  guard let value, value.isFinite, value >= 0 else { return "—" }
  return String(format: "%.1f tok/s", value)
}

func usagePercent(_ value: Double?) -> String {
  guard let value, value.isFinite else { return "—" }
  return value.formatted(.percent.precision(.fractionLength(0...1)))
}
