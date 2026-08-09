import Foundation
import Testing

@testable import BYOKchatProviderCore

@Test func telemetryAnalyticsAggregatesReliabilityAndPerformance() {
  let events: [TelemetryEvent] = [
    TelemetryEvent(
      dataClass: .analytics,
      category: .provider,
      name: .providerRequestCompleted,
      outcome: .success,
      durationMilliseconds: 1_000,
      timeToFirstTokenMilliseconds: 100,
      metadata: ["outputTokensPerSecond": "20"]
    ),
    TelemetryEvent(
      dataClass: .analytics,
      category: .provider,
      name: .providerRequestCompleted,
      outcome: .success,
      durationMilliseconds: 3_000,
      timeToFirstTokenMilliseconds: 300,
      metadata: ["outputTokensPerSecond": "40"]
    ),
    TelemetryEvent(
      dataClass: .analytics,
      category: .provider,
      name: .providerRequestFailed,
      outcome: .failure,
      durationMilliseconds: 2_000,
      timeToFirstTokenMilliseconds: 200
    ),
    TelemetryEvent(
      dataClass: .analytics,
      category: .provider,
      name: .providerRequestCancelled,
      outcome: .cancelled
    ),
    TelemetryEvent(
      dataClass: .analytics,
      category: .tool,
      name: .toolCallCompleted,
      outcome: .success
    ),
    TelemetryEvent(
      dataClass: .analytics,
      category: .tool,
      name: .toolCallFailed,
      outcome: .failure
    ),
  ]

  let aggregate = TelemetryAnalytics.aggregate(events: events)
  #expect(aggregate.providerRequestCount == 4)
  #expect(aggregate.providerSuccessCount == 2)
  #expect(aggregate.providerFailureCount == 1)
  #expect(aggregate.providerCancelledCount == 1)
  #expect(aggregate.providerSuccessRate == 2.0 / 3.0)
  #expect(aggregate.medianTTFTMilliseconds == 200)
  #expect(aggregate.medianDurationMilliseconds == 2_000)
  #expect(aggregate.p95DurationMilliseconds == 2_900)
  #expect(aggregate.medianOutputTokensPerSecond == 30)
  #expect(aggregate.toolCallCount == 2)
  #expect(aggregate.toolSuccessRate == 0.5)
}

@Test func telemetryAnalyticsExcludesExpectedLegacyFallbackFromMCPFailures() {
  let events: [TelemetryEvent] = [
    TelemetryEvent(
      dataClass: .analytics,
      category: .mcp,
      name: .mcpRequestFailed,
      outcome: .failure,
      errorCode: "legacy_probe",
      metadata: ["classification": "legacy_fallback"]
    ),
    TelemetryEvent(
      dataClass: .analytics,
      category: .mcp,
      name: .mcpRequestFailed,
      outcome: .failure,
      errorCode: "transport",
      metadata: ["classification": "transport"]
    ),
    TelemetryEvent(
      dataClass: .analytics,
      category: .mcp,
      name: .mcpRequestCompleted,
      outcome: .success
    ),
  ]

  let aggregate = TelemetryAnalytics.aggregate(events: events)
  #expect(aggregate.mcpRequestCount == 3)
  #expect(aggregate.mcpFailureCount == 1)

  let failures = TelemetryAnalytics.failureBreakdown(events: events)
  #expect(failures.count == 1)
  #expect(failures.first?.errorCode == "transport")
  #expect(failures.first?.classification == "transport")
}

@Test func telemetryAnalyticsFailureBreakdownGroupsStableErrors() {
  let events: [TelemetryEvent] = [
    TelemetryEvent(
      dataClass: .analytics,
      category: .provider,
      name: .providerRequestFailed,
      outcome: .failure,
      errorCode: "rate_limited",
      metadata: ["classification": "rate_limit"]
    ),
    TelemetryEvent(
      dataClass: .analytics,
      category: .provider,
      name: .providerRequestFailed,
      outcome: .failure,
      errorCode: "rate_limited",
      metadata: ["classification": "rate_limit"]
    ),
    TelemetryEvent(
      dataClass: .analytics,
      category: .tool,
      name: .toolCallFailed,
      outcome: .failure,
      errorCode: "approval_denied",
      metadata: ["classification": "user_decision"]
    ),
  ]

  let failures = TelemetryAnalytics.failureBreakdown(events: events)
  #expect(failures.count == 2)
  #expect(failures.first?.errorCode == "rate_limited")
  #expect(failures.first?.count == 2)
  #expect(failures.last?.errorCode == "approval_denied")
}

@Test func telemetryAnalyticsIgnoresDiagnosticAndInvalidMetricValues() {
  let events: [TelemetryEvent] = [
    TelemetryEvent(
      dataClass: .diagnostic,
      category: .provider,
      name: .providerRequestCompleted,
      outcome: .success,
      durationMilliseconds: 999,
      timeToFirstTokenMilliseconds: 999
    ),
    TelemetryEvent(
      dataClass: .analytics,
      category: .provider,
      name: .providerRequestCompleted,
      outcome: .success,
      durationMilliseconds: -1,
      timeToFirstTokenMilliseconds: -1,
      metadata: ["outputTokensPerSecond": "nan"]
    ),
  ]

  let aggregate = TelemetryAnalytics.aggregate(events: events)
  #expect(aggregate.providerRequestCount == 1)
  #expect(aggregate.medianDurationMilliseconds == nil)
  #expect(aggregate.medianTTFTMilliseconds == nil)
  #expect(aggregate.medianOutputTokensPerSecond == nil)
}
