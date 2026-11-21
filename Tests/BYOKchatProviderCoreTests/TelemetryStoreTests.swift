import Foundation
import Testing

@testable import BYOKchatProviderCore

@Test func telemetryRoundTripsStructuredOperationalData() async throws {
  let location = temporaryTelemetryLocation()
  defer { try? FileManager.default.removeItem(at: location.directory) }

  let recorder = TelemetryRecorder(
    databaseURL: location.database,
    configuration: testConfiguration(),
    deviceID: "device-a",
    sessionID: "session-a"
  )

  await recorder.record(
    TelemetryEvent(
      dataClass: .analytics,
      category: .provider,
      name: .providerRequestCompleted,
      severity: .info,
      outcome: .success,
      conversationID: "conversation-a",
      messageID: "message-a",
      providerID: "openrouter",
      accountID: "account-a",
      modelID: "deepseek/model",
      durationMilliseconds: 820,
      timeToFirstTokenMilliseconds: 210,
      inputTokens: 1_200,
      outputTokens: 350,
      cachedInputTokens: 400,
      reasoningTokens: 90,
      modelRequestCount: 2,
      toolCallCount: 1,
      httpStatus: 200,
      metadata: ["transport": "https", "apiFamily": "openai-compatible"]
    )
  )

  let events = await recorder.recentEvents()
  #expect(events.count == 1)
  let event = try #require(events.first)
  #expect(event.deviceID == "device-a")
  #expect(event.sessionID == "session-a")
  #expect(event.providerID == "openrouter")
  #expect(event.modelID == "deepseek/model")
  #expect(event.durationMilliseconds == 820)
  #expect(event.timeToFirstTokenMilliseconds == 210)
  #expect(event.inputTokens == 1_200)
  #expect(event.outputTokens == 350)
  #expect(event.metadata["transport"] == "https")

  let statistics = await recorder.statistics()
  #expect(statistics.eventCount == 1)
  #expect(statistics.analyticsEventCount == 1)
  #expect(statistics.schemaVersion == TelemetrySQLiteStore.currentSchemaVersion)
}

@Test func telemetrySanitizesSensitiveMetadataBeforePersistence() async throws {
  let location = temporaryTelemetryLocation()
  defer { try? FileManager.default.removeItem(at: location.directory) }

  let store = TelemetrySQLiteStore(
    databaseURL: location.database,
    configuration: testConfiguration()
  )

  try await store.append(
    TelemetryEvent(
      dataClass: .diagnostic,
      category: .provider,
      name: .providerRequestFailed,
      severity: .error,
      outcome: .failure,
      durationMilliseconds: -1,
      httpStatus: 42,
      errorCode: "rate_limited\nprovider response body should not be here",
      metadata: [
        "transport": "https",
        "inputTokens": "400",
        "apiKey": "sk-secret",
        "prompt": "private user text",
        "authorization": "Bearer private",
        "endpoint": "https://example.com/path?token=secret",
      ]
    )
  )

  let event = try #require(try await store.recentEvents(limit: 1).first)
  #expect(event.durationMilliseconds == nil)
  #expect(event.httpStatus == nil)
  #expect(event.errorCode == "rate_limited")
  #expect(event.metadata["transport"] == "https")
  #expect(event.metadata["inputTokens"] == "400")
  #expect(event.metadata["apiKey"] == nil)
  #expect(event.metadata["prompt"] == nil)
  #expect(event.metadata["authorization"] == nil)
  #expect(event.metadata["endpoint"] == nil)

  await store.close()
}

@Test func telemetryMaintenanceCapsAgeAndEventCount() async throws {
  let location = temporaryTelemetryLocation()
  defer { try? FileManager.default.removeItem(at: location.directory) }

  let configuration = TelemetryStoreConfiguration(
    maximumAge: 1_000,
    maximumEventCount: 3,
    maximumDatabaseBytes: 10 * 1024 * 1024,
    maintenanceInsertInterval: 1_000,
    pruneBatchSize: 100
  )
  let store = TelemetrySQLiteStore(databaseURL: location.database, configuration: configuration)
  let reference = Date(timeIntervalSince1970: 10_000)

  for index in 0..<5 {
    try await store.append(
      TelemetryEvent(
        timestamp: reference.addingTimeInterval(Double(index)),
        dataClass: .analytics,
        category: .provider,
        name: .providerRequestCompleted,
        metadata: ["sequence": String(index)]
      )
    )
  }

  try await store.performMaintenance(referenceDate: reference.addingTimeInterval(5))
  let capped = try await store.recentEvents(limit: 10)
  #expect(capped.count == 3)
  #expect(capped.map { $0.metadata["sequence"] } == ["4", "3", "2"])
  await store.close()

  let ageLocation = temporaryTelemetryLocation()
  defer { try? FileManager.default.removeItem(at: ageLocation.directory) }
  let ageStore = TelemetrySQLiteStore(
    databaseURL: ageLocation.database,
    configuration: TelemetryStoreConfiguration(
      maximumAge: 30,
      maximumEventCount: 100,
      maximumDatabaseBytes: 10 * 1024 * 1024,
      maintenanceInsertInterval: 1_000,
      pruneBatchSize: 100
    )
  )

  try await ageStore.append(
    TelemetryEvent(
      timestamp: reference,
      dataClass: .diagnostic,
      category: .chat,
      name: .chatTurnStarted
    )
  )
  try await ageStore.append(
    TelemetryEvent(
      timestamp: reference.addingTimeInterval(90),
      dataClass: .analytics,
      category: .chat,
      name: .chatTurnCompleted
    )
  )
  try await ageStore.performMaintenance(referenceDate: reference.addingTimeInterval(100))

  let ageCapped = try await ageStore.recentEvents(limit: 10)
  #expect(ageCapped.count == 1)
  #expect(ageCapped.first?.name == .chatTurnCompleted)
  await ageStore.close()
}

@Test func telemetrySizeCapPrunesAndCompactsOldEvents() async throws {
  let location = temporaryTelemetryLocation()
  defer { try? FileManager.default.removeItem(at: location.directory) }

  let configuration = TelemetryStoreConfiguration(
    maximumAge: 100_000,
    maximumEventCount: 10_000,
    maximumDatabaseBytes: 1 * 1024 * 1024,
    maintenanceInsertInterval: 10_000,
    pruneBatchSize: 100
  )
  let store = TelemetrySQLiteStore(databaseURL: location.database, configuration: configuration)
  let payload = String(repeating: "x", count: 256)
  let metadata = Dictionary(uniqueKeysWithValues: (0..<24).map { ("field\($0)", payload) })

  for index in 0..<500 {
    try await store.append(
      TelemetryEvent(
        timestamp: Date(timeIntervalSince1970: Double(index)),
        dataClass: .diagnostic,
        category: .provider,
        name: "provider.size_test",
        metadata: metadata
      )
    )
  }

  let before = try await store.statistics()
  #expect(before.databaseBytes > 1 * 1024 * 1024)

  try await store.performMaintenance(referenceDate: Date(timeIntervalSince1970: 600))
  let after = try await store.statistics()
  #expect(after.eventCount < before.eventCount)
  #expect(after.databaseBytes <= 1 * 1024 * 1024)
  await store.close()
}

@Test func telemetrySupportsSeparateDiagnosticAndFullClear() async throws {
  let location = temporaryTelemetryLocation()
  defer { try? FileManager.default.removeItem(at: location.directory) }

  let store = TelemetrySQLiteStore(
    databaseURL: location.database,
    configuration: testConfiguration()
  )

  try await store.append(
    TelemetryEvent(
      dataClass: .analytics,
      category: .provider,
      name: .providerRequestCompleted
    )
  )
  try await store.append(
    TelemetryEvent(
      dataClass: .diagnostic,
      category: .provider,
      name: .providerRequestFailed,
      severity: .error
    )
  )

  try await store.clearDiagnosticLogs()
  var statistics = try await store.statistics()
  #expect(statistics.eventCount == 1)
  #expect(statistics.analyticsEventCount == 1)
  #expect(statistics.diagnosticEventCount == 0)

  try await store.clearAllTelemetry()
  statistics = try await store.statistics()
  #expect(statistics.eventCount == 0)
  #expect(statistics.schemaVersion == TelemetrySQLiteStore.currentSchemaVersion)
  await store.close()
}

@Test func telemetryRecreatesDisposableStoreWhenDatabaseIsCorrupt() async throws {
  let location = temporaryTelemetryLocation()
  defer { try? FileManager.default.removeItem(at: location.directory) }

  try FileManager.default.createDirectory(
    at: location.directory,
    withIntermediateDirectories: true
  )
  try Data("not a sqlite database".utf8).write(to: location.database)

  let recorder = TelemetryRecorder(
    databaseURL: location.database,
    configuration: testConfiguration(),
    deviceID: "device-recovery",
    sessionID: "session-recovery"
  )

  await recorder.record(
    TelemetryEvent(
      dataClass: .analytics,
      category: .app,
      name: .appLaunched
    )
  )

  let events = await recorder.recentEvents(limit: 10)
  #expect(events.count == 1)
  #expect(events.first?.name == .appLaunched)
  let health = await recorder.health()
  #expect(health.isAvailable)
}

@Test func telemetryRecorderFailsOpenWhenStorageCannotBeCreated() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("BYOKchatTelemetryBlocked-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

  let blockingFile = root.appendingPathComponent("not-a-directory")
  try Data("blocked".utf8).write(to: blockingFile)
  let database = blockingFile.appendingPathComponent("telemetry.sqlite")

  let recorder = TelemetryRecorder(
    databaseURL: database,
    configuration: testConfiguration(),
    deviceID: "device-fail-open",
    sessionID: "session-fail-open"
  )

  for _ in 0..<3 {
    await recorder.record(
      TelemetryEvent(
        dataClass: .diagnostic,
        category: .storage,
        name: "storage.test"
      )
    )
  }

  let health = await recorder.health()
  #expect(!health.isAvailable)
  #expect(health.consecutiveFailureCount == 3)
  #expect(await recorder.recentEvents().isEmpty)
}

@Test func loadAnalyticsFiltersAnalyticsClassSoDiagnosticsCannotCrowdItOut() async throws {
  let location = temporaryTelemetryLocation()
  defer { try? FileManager.default.removeItem(at: location.directory) }

  let recorder = TelemetryRecorder(
    databaseURL: location.database,
    configuration: testConfiguration(),
    deviceID: "device-filter",
    sessionID: "session-filter"
  )
  let base = Date(timeIntervalSince1970: 20_000)

  await recorder.record(
    TelemetryEvent(
      timestamp: base,
      dataClass: .analytics,
      category: .provider,
      name: .providerRequestCompleted,
      outcome: .success
    )
  )
  for index in 1...4 {
    await recorder.record(
      TelemetryEvent(
        timestamp: base.addingTimeInterval(Double(index)),
        dataClass: .diagnostic,
        category: .storage,
        name: "storage.diagnostic_noise"
      )
    )
  }

  let loaded = await recorder.loadAnalytics(limit: 2)
  guard case .loaded(let events, let statistics) = loaded else {
    Issue.record("Expected analytics load to succeed")
    return
  }
  #expect(events.count == 1)
  #expect(events.first?.dataClass == .analytics)
  #expect(statistics.analyticsEventCount == 1)
  #expect(statistics.diagnosticEventCount == 4)
  #expect(statistics.eventCount == 5)
}

@Test func telemetryPruneArchivesDailyRollupsAndErrorsWithoutDoubleCounting() async throws {
  let location = temporaryTelemetryLocation()
  defer { try? FileManager.default.removeItem(at: location.directory) }

  let store = TelemetrySQLiteStore(
    databaseURL: location.database,
    configuration: TelemetryStoreConfiguration(
      maximumAge: 30 * 24 * 60 * 60,
      maximumEventCount: 10_000,
      maximumDatabaseBytes: 10 * 1024 * 1024,
      maintenanceInsertInterval: 1_000,
      pruneBatchSize: 100
    )
  )
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  let fortyDaysAgo = now.addingTimeInterval(-40 * 24 * 60 * 60)

  try await store.append(
    TelemetryEvent(
      timestamp: fortyDaysAgo,
      dataClass: .analytics,
      category: .provider,
      name: .providerRequestCompleted,
      outcome: .success,
      providerID: "anthropic",
      modelID: "claude-sonnet-5-5",
      durationMilliseconds: 2_000,
      timeToFirstTokenMilliseconds: 400,
      metadata: ["outputTokensPerSecond": "50.0"]
    )
  )
  try await store.append(
    TelemetryEvent(
      timestamp: fortyDaysAgo.addingTimeInterval(60),
      dataClass: .analytics,
      category: .provider,
      name: .providerRequestFailed,
      severity: .error,
      outcome: .failure,
      providerID: "anthropic",
      modelID: "claude-sonnet-5-5",
      durationMilliseconds: 500,
      errorCode: "rate_limited",
      metadata: ["classification": "http"]
    )
  )
  try await store.append(
    TelemetryEvent(
      timestamp: fortyDaysAgo.addingTimeInterval(120),
      dataClass: .diagnostic,
      category: .storage,
      name: "storage.debug_note"
    )
  )
  try await store.append(
    TelemetryEvent(
      timestamp: now.addingTimeInterval(-60),
      dataClass: .analytics,
      category: .provider,
      name: .providerRequestCompleted,
      outcome: .success,
      providerID: "anthropic",
      modelID: "claude-sonnet-5-5",
      durationMilliseconds: 1_000,
      timeToFirstTokenMilliseconds: 200,
      metadata: ["outputTokensPerSecond": "70.0"]
    )
  )

  try await store.performMaintenance(referenceDate: now)

  let stats = try await store.statistics()
  #expect(stats.eventCount == 1)
  #expect(stats.rollupRowCount == 2)

  let recentEvents = try await store.analyticsEvents(
    since: nil,
    eventNames: TelemetryAnalytics.overviewEventNames
  )
  let rollups = try await store.dailyRollups(since: nil)
  let errorRollups = try await store.dailyErrorRollups(since: nil)
  #expect(recentEvents.count == 1)
  #expect(rollups.count == 1)
  #expect(errorRollups.count == 1)

  let snapshot = UsageAnalytics.snapshot(
    conversations: [],
    telemetryEvents: recentEvents,
    dailyRollups: rollups,
    dailyErrorRollups: errorRollups,
    range: .all,
    reference: now
  )
  #expect(snapshot.performance.providerRequestCount == 3)
  #expect(snapshot.performance.providerSuccessCount == 2)
  #expect(snapshot.performance.providerFailureCount == 1)
  #expect(snapshot.performance.totalDurationMilliseconds == 3_500)
  #expect(snapshot.failureBreakdown.count == 1)
  #expect(snapshot.failureBreakdown.first?.errorCode == "rate_limited")
  #expect(snapshot.failureBreakdown.first?.count == 1)
  #expect(snapshot.providerBreakdown.first?.id == "anthropic")
  #expect(snapshot.providerBreakdown.first?.performance.providerRequestCount == 3)
  #expect(snapshot.modelBreakdown.first?.id == "claude-sonnet-5-5")
  #expect(snapshot.modelBreakdown.first?.performance.providerRequestCount == 3)

  await store.close()
}

@Test func telemetryScopedAndFilteredQueriesAvoidNoiseAndTruncation() async throws {
  let location = temporaryTelemetryLocation()
  defer { try? FileManager.default.removeItem(at: location.directory) }

  let recorder = TelemetryRecorder(
    databaseURL: location.database,
    configuration: testConfiguration(),
    deviceID: "device-scoped",
    sessionID: "session-scoped"
  )
  let base = Date(timeIntervalSince1970: 1_800_000_000)

  await recorder.record(
    TelemetryEvent(
      timestamp: base,
      dataClass: .analytics,
      category: .provider,
      name: .providerRequestCompleted,
      outcome: .success,
      conversationID: "chat-old",
      messageID: "msg-old",
      providerID: "openai",
      modelID: "gpt-6.2-sol",
      durationMilliseconds: 900,
      timeToFirstTokenMilliseconds: 180
    )
  )
  await recorder.record(
    TelemetryEvent(
      timestamp: base.addingTimeInterval(1),
      dataClass: .analytics,
      category: .context,
      name: .contextBuilt,
      conversationID: "chat-old",
      messageID: "msg-old",
      metadata: ["omittedMessageCount": "2", "estimatedInputTokens": "4000"]
    )
  )

  for index in 1...10 {
    await recorder.record(
      TelemetryEvent(
        timestamp: base.addingTimeInterval(Double(10 + index)),
        dataClass: .analytics,
        category: .chat,
        name: .chatTurnStarted,
        conversationID: "chat-new",
        messageID: ChatMessageID(rawValue: "msg-new-\(index)")
      )
    )
  }

  // Overview load filters out lifecycle noise so the real event is never crowded out.
  let overview = await recorder.loadAnalytics(range: .all, reference: base.addingTimeInterval(30), limit: 5)
  guard case .loaded(let overviewEvents, _, _, _) = overview else {
    Issue.record("Expected overview analytics load to succeed")
    return
  }
  #expect(overviewEvents.count == 1)
  #expect(overviewEvents.first?.name == .providerRequestCompleted)

  // Scoped conversation & message queries bypass global traffic completely.
  let scopedChat = await recorder.loadConversationAnalytics(conversationID: "chat-old", limit: 10)
  guard case .loaded(let chatEvents) = scopedChat else {
    Issue.record("Expected conversation analytics load to succeed")
    return
  }
  #expect(chatEvents.count == 2)

  let messageEvents = await recorder.loadMessageAnalytics(messageID: "msg-old")
  #expect(messageEvents.count == 2)
  #expect(UsageAnalytics.messageOmittedContextCount(messageID: "msg-old", telemetryEvents: messageEvents) == 2)
}

private func testConfiguration() -> TelemetryStoreConfiguration {
  TelemetryStoreConfiguration(
    maximumAge: 30 * 24 * 60 * 60,
    maximumEventCount: 10_000,
    maximumDatabaseBytes: 10 * 1024 * 1024,
    maintenanceInsertInterval: 1_000,
    pruneBatchSize: 100
  )
}

private func temporaryTelemetryLocation() -> (directory: URL, database: URL) {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("BYOKchatTelemetryTests-\(UUID().uuidString)", isDirectory: true)
  return (
    directory,
    directory.appendingPathComponent("telemetry.sqlite", isDirectory: false)
  )
}
