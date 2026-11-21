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
  public var totalDurationMilliseconds: Double?
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
    mcpFailureCount: Int = 0,
    totalDurationMilliseconds: Double? = nil
  ) {
    self.providerRequestCount = providerRequestCount
    self.providerSuccessCount = providerSuccessCount
    self.providerFailureCount = providerFailureCount
    self.providerCancelledCount = providerCancelledCount
    self.medianTTFTMilliseconds = medianTTFTMilliseconds
    self.p95TTFTMilliseconds = p95TTFTMilliseconds
    self.medianDurationMilliseconds = medianDurationMilliseconds
    self.p95DurationMilliseconds = p95DurationMilliseconds
    self.totalDurationMilliseconds = totalDurationMilliseconds
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

  public var hasLatencyOrSpeedMetrics: Bool {
    medianTTFTMilliseconds != nil
      || p95TTFTMilliseconds != nil
      || medianDurationMilliseconds != nil
      || p95DurationMilliseconds != nil
      || totalDurationMilliseconds != nil
      || medianOutputTokensPerSecond != nil
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

public struct TelemetryDailyRollup: Sendable, Equatable {
  public var dayStart: Date
  public var providerID: String?
  public var modelID: String?
  public var providerSuccessCount: Int
  public var providerFailureCount: Int
  public var providerCancelledCount: Int
  public var ttftSumMilliseconds: Double
  public var ttftCount: Int
  public var durationSumMilliseconds: Double
  public var durationCount: Int
  public var speedSum: Double
  public var speedCount: Int
  public var toolSuccessCount: Int
  public var toolFailureCount: Int
  public var toolCancelledCount: Int
  public var mcpRequestCount: Int
  public var mcpFailureCount: Int

  public init(
    dayStart: Date,
    providerID: String? = nil,
    modelID: String? = nil,
    providerSuccessCount: Int = 0,
    providerFailureCount: Int = 0,
    providerCancelledCount: Int = 0,
    ttftSumMilliseconds: Double = 0,
    ttftCount: Int = 0,
    durationSumMilliseconds: Double = 0,
    durationCount: Int = 0,
    speedSum: Double = 0,
    speedCount: Int = 0,
    toolSuccessCount: Int = 0,
    toolFailureCount: Int = 0,
    toolCancelledCount: Int = 0,
    mcpRequestCount: Int = 0,
    mcpFailureCount: Int = 0
  ) {
    self.dayStart = dayStart
    self.providerID = providerID
    self.modelID = modelID
    self.providerSuccessCount = providerSuccessCount
    self.providerFailureCount = providerFailureCount
    self.providerCancelledCount = providerCancelledCount
    self.ttftSumMilliseconds = ttftSumMilliseconds
    self.ttftCount = ttftCount
    self.durationSumMilliseconds = durationSumMilliseconds
    self.durationCount = durationCount
    self.speedSum = speedSum
    self.speedCount = speedCount
    self.toolSuccessCount = toolSuccessCount
    self.toolFailureCount = toolFailureCount
    self.toolCancelledCount = toolCancelledCount
    self.mcpRequestCount = mcpRequestCount
    self.mcpFailureCount = mcpFailureCount
  }

  public var providerRequestCount: Int {
    providerSuccessCount + providerFailureCount + providerCancelledCount
  }
}

public struct TelemetryDailyErrorRollup: Sendable, Equatable {
  public var dayStart: Date
  public var category: TelemetryCategory
  public var errorCode: String
  public var classification: String
  public var count: Int

  public init(
    dayStart: Date,
    category: TelemetryCategory,
    errorCode: String,
    classification: String,
    count: Int
  ) {
    self.dayStart = dayStart
    self.category = category
    self.errorCode = errorCode
    self.classification = classification
    self.count = count
  }
}

public enum TelemetryAnalytics {
  /// Event names actually aggregated in app-wide analytics overview screens.
  public static let overviewEventNames: [TelemetryEventName] = [
    .providerRequestCompleted,
    .providerRequestFailed,
    .providerRequestCancelled,
    .toolCallCompleted,
    .toolCallFailed,
    .toolCallCancelled,
    .mcpRequestCompleted,
    .mcpRequestFailed,
    .mcpRequestCancelled,
    .chatTurnFailed,
    .purchaseFailed,
    .syncFailed,
  ]

  /// Event names aggregated in per-conversation and per-message analytics screens.
  public static let scopedEventNames: [TelemetryEventName] = overviewEventNames + [
    .contextBuilt,
  ]

  public static func aggregate(events: [TelemetryEvent]) -> TelemetryPerformanceAggregate {
    aggregate(events: events, rollups: [])
  }

  public static func aggregate(
    events: [TelemetryEvent],
    rollups: [TelemetryDailyRollup]
  ) -> TelemetryPerformanceAggregate {
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
        if !isExpectedMCPLegacyFallback(event) {
          mcpFailureCount += 1
        }

      case .mcpRequestCancelled:
        mcpRequestCount += 1

      default:
        break
      }
    }

    var rollupTTFTSum = 0.0
    var rollupTTFTCount = 0
    var rollupDurationSum = 0.0
    var rollupDurationCount = 0
    var rollupSpeedSum = 0.0
    var rollupSpeedCount = 0

    for rollup in rollups {
      providerSuccessCount += rollup.providerSuccessCount
      providerFailureCount += rollup.providerFailureCount
      providerCancelledCount += rollup.providerCancelledCount
      toolSuccessCount += rollup.toolSuccessCount
      toolFailureCount += rollup.toolFailureCount
      toolCancelledCount += rollup.toolCancelledCount
      mcpRequestCount += rollup.mcpRequestCount
      mcpFailureCount += rollup.mcpFailureCount
      if rollup.ttftCount > 0, rollup.ttftSumMilliseconds.isFinite, rollup.ttftSumMilliseconds >= 0 {
        rollupTTFTSum += rollup.ttftSumMilliseconds
        rollupTTFTCount += rollup.ttftCount
      }
      if rollup.durationCount > 0, rollup.durationSumMilliseconds.isFinite, rollup.durationSumMilliseconds >= 0 {
        rollupDurationSum += rollup.durationSumMilliseconds
        rollupDurationCount += rollup.durationCount
      }
      if rollup.speedCount > 0, rollup.speedSum.isFinite, rollup.speedSum >= 0 {
        rollupSpeedSum += rollup.speedSum
        rollupSpeedCount += rollup.speedCount
      }
    }

    let rawDurationSum = durationValues.reduce(0, +)
    let totalDurationCount = durationValues.count + rollupDurationCount

    return TelemetryPerformanceAggregate(
      providerRequestCount: providerSuccessCount + providerFailureCount + providerCancelledCount,
      providerSuccessCount: providerSuccessCount,
      providerFailureCount: providerFailureCount,
      providerCancelledCount: providerCancelledCount,
      medianTTFTMilliseconds: combinedMetric(
        rawValues: ttftValues,
        rollupSum: rollupTTFTSum,
        rollupCount: rollupTTFTCount
      ),
      p95TTFTMilliseconds: percentile(ttftValues, fraction: 0.95),
      medianDurationMilliseconds: combinedMetric(
        rawValues: durationValues,
        rollupSum: rollupDurationSum,
        rollupCount: rollupDurationCount
      ),
      p95DurationMilliseconds: percentile(durationValues, fraction: 0.95),
      medianOutputTokensPerSecond: combinedMetric(
        rawValues: speedValues,
        rollupSum: rollupSpeedSum,
        rollupCount: rollupSpeedCount
      ),
      toolCallCount: toolSuccessCount + toolFailureCount + toolCancelledCount,
      toolSuccessCount: toolSuccessCount,
      toolFailureCount: toolFailureCount,
      toolCancelledCount: toolCancelledCount,
      mcpRequestCount: mcpRequestCount,
      mcpFailureCount: mcpFailureCount,
      totalDurationMilliseconds: totalDurationCount > 0 ? (rawDurationSum + rollupDurationSum) : nil
    )
  }

  public static func failureBreakdown(events: [TelemetryEvent]) -> [TelemetryFailureBreakdown] {
    failureBreakdown(events: events, errorRollups: [])
  }

  public static func failureBreakdown(
    events: [TelemetryEvent],
    errorRollups: [TelemetryDailyErrorRollup]
  ) -> [TelemetryFailureBreakdown] {
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
        if isExpectedMCPLegacyFallback(event) { continue }
      case .chatTurnFailed:
        guard localChatClassifications.contains(classification) else { continue }
      default:
        continue
      }

      guard let errorCode = event.errorCode, !errorCode.isEmpty else { continue }
      counts[Key(category: event.category, errorCode: errorCode, classification: classification), default: 0] += 1
    }

    for rollup in errorRollups where rollup.count > 0 && !rollup.errorCode.isEmpty {
      let key = Key(
        category: rollup.category,
        errorCode: rollup.errorCode,
        classification: rollup.classification
      )
      counts[key, default: 0] += rollup.count
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
      if lhs.errorCode != rhs.errorCode { return lhs.errorCode < rhs.errorCode }
      return lhs.classification < rhs.classification
    }
  }

  static func isExpectedMCPLegacyFallback(_ event: TelemetryEvent) -> Bool {
    if event.metadata["expectedFallback"] == "true" { return true }
    if event.errorCode == "legacy_probe_fallback" { return true }
    let classification = event.metadata["classification"]
    return classification == "legacy_fallback" || classification == "protocol_fallback"
  }

  static func isArchivedFailureEvent(_ event: TelemetryEvent) -> (category: TelemetryCategory, errorCode: String, classification: String)? {
    guard event.dataClass == .analytics, event.outcome == .failure,
      let errorCode = event.errorCode, !errorCode.isEmpty
    else { return nil }
    let classification = event.metadata["classification"] ?? "unknown"
    let localChatClassifications: Set<String> = [
      "configuration", "context", "local", "request", "storage",
    ]
    switch event.name {
    case .providerRequestFailed, .toolCallFailed, .purchaseFailed, .syncFailed:
      return (event.category, errorCode, classification)
    case .mcpRequestFailed:
      return isExpectedMCPLegacyFallback(event) ? nil : (event.category, errorCode, classification)
    case .chatTurnFailed:
      return localChatClassifications.contains(classification)
        ? (event.category, errorCode, classification) : nil
    default:
      return nil
    }
  }

  private static func combinedMetric(
    rawValues: [Double],
    rollupSum: Double,
    rollupCount: Int
  ) -> Double? {
    let rawCount = rawValues.count
    let totalCount = rawCount + rollupCount
    guard totalCount > 0 else { return nil }
    if rollupCount == 0 {
      return percentile(rawValues, fraction: 0.5)
    }
    if rawCount == 0 {
      return rollupSum / Double(rollupCount)
    }
    let rawRepresentative = percentile(rawValues, fraction: 0.5) ?? 0
    return (rawRepresentative * Double(rawCount) + rollupSum) / Double(totalCount)
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
