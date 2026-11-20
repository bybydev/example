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
  #expect(abs((aggregate.p95DurationMilliseconds ?? 0) - 2_900) < 0.001)
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

@Test func telemetryAnalyticsFailureBreakdownUsesCanonicalEvents() {
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
      category: .chat,
      name: .chatTurnFailed,
      outcome: .failure,
      errorCode: "rate_limited",
      metadata: ["classification": "rate_limit"]
    ),
    TelemetryEvent(
      dataClass: .analytics,
      category: .chat,
      name: .chatTurnFailed,
      outcome: .failure,
      errorCode: "context_window_exceeded",
      metadata: ["classification": "context"]
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
  #expect(failures.count == 3)
  #expect(failures.contains(where: { $0.errorCode == "rate_limited" && $0.count == 1 }))
  #expect(failures.contains(where: { $0.errorCode == "context_window_exceeded" && $0.count == 1 }))
  #expect(failures.contains(where: { $0.errorCode == "approval_denied" && $0.count == 1 }))
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
  #expect(!aggregate.hasLatencyOrSpeedMetrics)
}

@Test func telemetryAnalyticsExcludesMCPTransportProtocolFallbackAndTieBreaksDeterministically() {
  let events: [TelemetryEvent] = [
    TelemetryEvent(
      dataClass: .analytics,
      category: .mcp,
      name: .mcpRequestFailed,
      outcome: .failure,
      httpStatus: 501,
      errorCode: "legacy_probe_fallback",
      metadata: ["classification": "protocol_fallback", "expectedFallback": "true"]
    ),
    TelemetryEvent(
      dataClass: .analytics,
      category: .mcp,
      name: .mcpRequestCompleted,
      outcome: .success
    ),
    TelemetryEvent(
      dataClass: .analytics,
      category: .tool,
      name: .toolCallFailed,
      outcome: .failure,
      errorCode: "shared_code",
      metadata: ["classification": "z_class"]
    ),
    TelemetryEvent(
      dataClass: .analytics,
      category: .tool,
      name: .toolCallFailed,
      outcome: .failure,
      errorCode: "shared_code",
      metadata: ["classification": "a_class"]
    ),
  ]

  let aggregate = TelemetryAnalytics.aggregate(events: events)
  #expect(aggregate.mcpRequestCount == 2)
  #expect(aggregate.mcpFailureCount == 0)
  #expect(!aggregate.hasLatencyOrSpeedMetrics)

  let failures = TelemetryAnalytics.failureBreakdown(events: events)
  #expect(failures.count == 2)
  #expect(failures.map(\.classification) == ["a_class", "z_class"])
}

@Test func singleChunkBurstDoesNotReportInflatedTokensPerSecond() async throws {
  let location = FileManager.default.temporaryDirectory
    .appendingPathComponent("BYOKchatSingleChunkSpeed-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: location) }
  let recorder = TelemetryRecorder(
    databaseURL: location.appendingPathComponent("telemetry.sqlite"),
    deviceID: "speed-device",
    sessionID: "speed-session"
  )
  let telemetry = ChatRuntimeTelemetry(recorder: recorder)
  let conversation = ChatConversation(
    id: "speed-chat",
    title: "Speed",
    providerID: "openai",
    accountID: "oai",
    modelID: "gpt-6.2-astra"
  )
  telemetry.providerRequestCompleted(
    conversation: conversation,
    messageID: "msg-1",
    requestIndex: 1,
    response: ProviderResponse(
      text: "Hello world",
      providerID: "openai",
      accountID: "oai",
      modelID: "gpt-6.2-astra"
    ),
    usage: ProviderUsage(inputTokens: 10, outputTokens: 50),
    durationMilliseconds: 1_000,
    timeToFirstTokenMilliseconds: 999.8
  )

  var completed: TelemetryEvent?
  for _ in 0..<100 {
    let events = await recorder.recentEvents(limit: 10)
    if let match = events.first(where: { $0.name == .providerRequestCompleted }) {
      completed = match
      break
    }
    try? await Task.sleep(for: .milliseconds(10))
  }
  let event = try #require(completed)
  let speed = try #require(event.metadata["outputTokensPerSecond"].flatMap(Double.init))
  #expect(abs(speed - 50.0) < 0.5)
}
