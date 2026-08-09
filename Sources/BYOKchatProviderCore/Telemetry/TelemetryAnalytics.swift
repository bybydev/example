import Foundation

public struct TelemetryPerformanceAggregate: Sendable, Equatable {
  public var providerRequestCount: Int
  public var providerSuccessCount: Int
  public var providerFailureCount: Int
  public var providerCancelledCount: Int
  public var medianTTFTMilliseconds: Double?
  public var p95TTFTMilliseconds: Double?
  public var medianDurationMilliseconds: Double?
  public var p95DurationMilliseconds: Double?
  public var medianOutputTokensPerSecond: Double?
  public var toolCallCount: Int
  public var toolSuccessCount: Int
  public var toolFailureCount: Int
  public var toolCancelledCount: Int
  public var mcpRequestCount: Int
  public var mcpFailureCount: Int

  public init(
    providerRequestCount: Int = 0,
    providerSuccessCount: Int = 0,
    providerFailureCount: Int = 0,
    providerCancelledCount: Int = 0,
    medianTTFTMilliseconds: Double? = nil,
    p95TTFTMilliseconds: Double? = nil,
    medianDurationMilliseconds: Double? = nil,
    p95DurationMilliseconds: Double? = nil,
    medianOutputTokensPerSecond: Double? = nil,
    toolCallCount: Int = 0,
    toolSuccessCount: Int = 0,
    toolFailureCount: Int = 0,
    toolCancelledCount: Int = 0,
    mcpRequestCount: Int = 0,
    mcpFailureCount: Int = 0
  ) {
    self.providerRequestCount = providerRequestCount
    self.providerSuccessCount = providerSuccessCount
    self.providerFailureCount = providerFailureCount
    self.providerCancelledCount = providerCancelledCount
    self.medianTTFTMilliseconds = medianTTFTMilliseconds
    self.p95TTFTMilliseconds = p95TTFTMilliseconds
    self.medianDurationMilliseconds = medianDurationMilliseconds
    self.p95DurationMilliseconds = p95DurationMilliseconds
    self.medianOutputTokensPerSecond = medianOutputTokensPerSecond
    self.toolCallCount = toolCallCount
    self.toolSuccessCount = toolSuccessCount
    self.toolFailureCount = toolFailureCount
    self.toolCancelledCount = toolCancelledCount
    self.mcpRequestCount = mcpRequestCount
    self.mcpFailureCount = mcpFailureCount
  }

  public var reliabilitySampleCount: Int {
    providerSuccessCount + providerFailureCount
  }

  public var providerSuccessRate: Double? {
    guard reliabilitySampleCount > 0 else { return nil }
    return Double(providerSuccessCount) / Double(reliabilitySampleCount)
  }

  public var toolSuccessRate: Double? {
    let samples = toolSuccessCount + toolFailureCount
    guard samples > 0 else { return nil }
    return Double(toolSuccessCount) / Double(samples)
  }
}

public struct TelemetryFailureBreakdown: Sendable, Equatable, Identifiable {
  public var category: TelemetryCategory
  public var errorCode: String
  public var classification: String
  public var count: Int

  public var id: String {
    "\(category.rawValue)::\(errorCode)::\(classification)"
  }

  public init(
    category: TelemetryCategory,
    errorCode: String,
    classification: String,
    count: Int
  ) {
    self.category = category
    self.errorCode = errorCode
    self.classification = classification
    self.count = count
  }
}

public enum TelemetryAnalytics {
  public static func aggregate(events: [TelemetryEvent]) -> TelemetryPerformanceAggregate {
    var providerSuccessCount = 0
    var providerFailureCount = 0
    var providerCancelledCount = 0
    var ttftValues: [Double] = []
    var durationValues: [Double] = []
    var speedValues: [Double] = []

    var toolSuccessCount = 0
    var toolFailureCount = 0
    var toolCancelledCount = 0

    var mcpRequestCount = 0
    var mcpFailureCount = 0

    for event in events where event.dataClass == .analytics {
      switch event.name {
      case .providerRequestCompleted:
        providerSuccessCount += 1
        if let value = validMetric(event.timeToFirstTokenMilliseconds) {
          ttftValues.append(value)
        }
        if let value = validMetric(event.durationMilliseconds) {
          durationValues.append(value)
        }
        if let raw = event.metadata["outputTokensPerSecond"],
          let value = Double(raw),
          let value = validMetric(value)
        {
          speedValues.append(value)
        }

      case .providerRequestFailed:
        providerFailureCount += 1
        if let value = validMetric(event.timeToFirstTokenMilliseconds) {
          ttftValues.append(value)
        }
        if let value = validMetric(event.durationMilliseconds) {
          durationValues.append(value)
        }

      case .providerRequestCancelled:
        providerCancelledCount += 1

      case .toolCallCompleted:
        toolSuccessCount += 1

      case .toolCallFailed:
        toolFailureCount += 1

      case .toolCallCancelled:
        toolCancelledCount += 1

      case .mcpRequestCompleted:
        mcpRequestCount += 1

      case .mcpRequestFailed:
        mcpRequestCount += 1
        let classification = event.metadata["classification"]
        if classification != "legacy_fallback" {
          mcpFailureCount += 1
        }

      case .mcpRequestCancelled:
        mcpRequestCount += 1

      default:
        break
      }
    }

    return TelemetryPerformanceAggregate(
      providerRequestCount: providerSuccessCount + providerFailureCount + providerCancelledCount,
      providerSuccessCount: providerSuccessCount,
      providerFailureCount: providerFailureCount,
      providerCancelledCount: providerCancelledCount,
      medianTTFTMilliseconds: percentile(ttftValues, fraction: 0.5),
      p95TTFTMilliseconds: percentile(ttftValues, fraction: 0.95),
      medianDurationMilliseconds: percentile(durationValues, fraction: 0.5),
      p95DurationMilliseconds: percentile(durationValues, fraction: 0.95),
      medianOutputTokensPerSecond: percentile(speedValues, fraction: 0.5),
      toolCallCount: toolSuccessCount + toolFailureCount + toolCancelledCount,
      toolSuccessCount: toolSuccessCount,
      toolFailureCount: toolFailureCount,
      toolCancelledCount: toolCancelledCount,
      mcpRequestCount: mcpRequestCount,
      mcpFailureCount: mcpFailureCount
    )
  }

  public static func failureBreakdown(events: [TelemetryEvent]) -> [TelemetryFailureBreakdown] {
    struct Key: Hashable {
      var category: TelemetryCategory
      var errorCode: String
      var classification: String
    }

    let localChatClassifications: Set<String> = [
      "configuration",
      "context",
      "local",
      "request",
      "storage",
    ]

    var counts: [Key: Int] = [:]
    for event in events where event.dataClass == .analytics && event.outcome == .failure {
      let classification = event.metadata["classification"] ?? "unknown"

      switch event.name {
      case .providerRequestFailed, .toolCallFailed, .purchaseFailed, .syncFailed:
        break
      case .mcpRequestFailed:
        if classification == "legacy_fallback" { continue }
      case .chatTurnFailed:
        guard localChatClassifications.contains(classification) else { continue }
      default:
        continue
      }

      guard let errorCode = event.errorCode, !errorCode.isEmpty else { continue }
      counts[Key(category: event.category, errorCode: errorCode, classification: classification), default: 0] += 1
    }

    return counts.map { key, count in
      TelemetryFailureBreakdown(
        category: key.category,
        errorCode: key.errorCode,
        classification: key.classification,
        count: count
      )
    }
    .sorted { lhs, rhs in
      if lhs.count != rhs.count { return lhs.count > rhs.count }
      if lhs.category.rawValue != rhs.category.rawValue {
        return lhs.category.rawValue < rhs.category.rawValue
      }
      return lhs.errorCode < rhs.errorCode
    }
  }

  private static func validMetric(_ value: Double?) -> Double? {
    guard let value, value.isFinite, value >= 0 else { return nil }
    return value
  }

  private static func percentile(_ values: [Double], fraction: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    guard sorted.count > 1 else { return sorted[0] }

    let clamped = min(max(fraction, 0), 1)
    let position = clamped * Double(sorted.count - 1)
    let lowerIndex = Int(floor(position))
    let upperIndex = Int(ceil(position))
    guard lowerIndex != upperIndex else { return sorted[lowerIndex] }

    let weight = position - Double(lowerIndex)
    return sorted[lowerIndex] * (1 - weight) + sorted[upperIndex] * weight
  }
}
