import Foundation
import Testing

@testable import BYOKchatProviderCore

@Test func telemetryPrivacyDropsLocationsAndRedactsFreeformErrorText() {
  let sanitized = TelemetryPrivacy.sanitize(
    TelemetryEvent(
      dataClass: .diagnostic,
      category: .provider,
      name: "provider.privacy_reliability",
      errorCode: "Provider failed at https://private.example.test/path",
      metadata: [
        "endpoint": "https://private.example.test/mcp",
        "requestURL": "https://private.example.test/chat",
        "hostname": "private.example.test",
        "safeTransport": "https",
        "classification": "transport",
      ]
    )
  )

  #expect(sanitized.errorCode == "redacted")
  #expect(sanitized.metadata["endpoint"] == nil)
  #expect(sanitized.metadata["requestURL"] == nil)
  #expect(sanitized.metadata["hostname"] == nil)
  #expect(sanitized.metadata["safeTransport"] == "https")
  #expect(sanitized.metadata["classification"] == "transport")
}

@Test func telemetryPrivacyBoundsMetadataAndPreservesMachineErrorCodes() {
  var metadata: [String: String] = [:]
  for index in 0..<40 {
    metadata["field\(index)"] = String(repeating: "x", count: 400)
  }

  let sanitized = TelemetryPrivacy.sanitize(
    TelemetryEvent(
      dataClass: .analytics,
      category: .provider,
      name: .providerRequestFailed,
      errorCode: "provider_http:429",
      metadata: metadata
    )
  )

  #expect(sanitized.errorCode == "provider_http:429")
  #expect(sanitized.metadata.count == 24)
  #expect(sanitized.metadata.values.allSatisfy { $0.count <= 256 })
}

@Test func telemetryRecorderSerializesConcurrentWritesWithoutLoss() async throws {
  let location = telemetryReliabilityLocation()
  defer { try? FileManager.default.removeItem(at: location.directory) }

  let recorder = TelemetryRecorder(
    databaseURL: location.database,
    configuration: telemetryReliabilityConfiguration(maximumEventCount: 1_000),
    deviceID: "reliability-device",
    sessionID: "reliability-session"
  )

  await withTaskGroup(of: Void.self) { group in
    for index in 0..<250 {
      group.addTask {
        await recorder.record(
          TelemetryEvent(
            dataClass: .analytics,
            category: .provider,
            name: .providerRequestCompleted,
            outcome: .success,
            metadata: ["sequence": String(index)]
          )
        )
      }
    }
  }

  let statistics = await recorder.statistics()
  #expect(statistics.eventCount == 250)
  #expect(statistics.analyticsEventCount == 250)

  let events = await recorder.recentEvents(limit: 500)
  #expect(events.count == 250)
  #expect(Set(events.map(\.id)).count == 250)
  #expect(await recorder.health().isAvailable)
}

@Test func telemetryAutomaticMaintenanceKeepsEventCountBounded() async throws {
  let location = telemetryReliabilityLocation()
  defer { try? FileManager.default.removeItem(at: location.directory) }

  let recorder = TelemetryRecorder(
    databaseURL: location.database,
    configuration: TelemetryStoreConfiguration(
      maximumAge: 100_000,
      maximumEventCount: 40,
      maximumDatabaseBytes: 10 * 1024 * 1024,
      maintenanceInsertInterval: 10,
      pruneBatchSize: 100
    ),
    deviceID: "reliability-device",
    sessionID: "reliability-session"
  )

  for index in 0..<120 {
    await recorder.record(
      TelemetryEvent(
        timestamp: Date.now.addingTimeInterval(Double(index)),
        dataClass: .diagnostic,
        category: .storage,
        name: "storage.retention_test",
        metadata: ["sequence": String(index)]
      )
    )
  }

  let statistics = await recorder.statistics()
  #expect(statistics.eventCount <= 40)
  #expect(statistics.diagnosticEventCount == statistics.eventCount)
  #expect(await recorder.health().isAvailable)
}

@Test func telemetryRecorderCanRecoverAfterFailOpenSessionDisable() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("BYOKchatTelemetryRetry-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

  let blockedParent = root.appendingPathComponent("blocked")
  try Data("not a directory".utf8).write(to: blockedParent)
  let database = blockedParent.appendingPathComponent("telemetry.sqlite")

  let recorder = TelemetryRecorder(
    databaseURL: database,
    configuration: telemetryReliabilityConfiguration(maximumEventCount: 100),
    deviceID: "retry-device",
    sessionID: "retry-session"
  )

  for _ in 0..<3 {
    await recorder.record(
      TelemetryEvent(
        dataClass: .diagnostic,
        category: .storage,
        name: "storage.expected_failure"
      )
    )
  }
  #expect(!(await recorder.health()).isAvailable)

  try FileManager.default.removeItem(at: blockedParent)
  try FileManager.default.createDirectory(at: blockedParent, withIntermediateDirectories: true)

  await recorder.retryAfterFailure()
  await recorder.record(
    TelemetryEvent(
      dataClass: .analytics,
      category: .app,
      name: .appLaunched
    )
  )

  let health = await recorder.health()
  #expect(health.isAvailable)
  #expect(health.consecutiveFailureCount == 0)
  let events = await recorder.recentEvents(limit: 10)
  #expect(events.count == 1)
  #expect(events.first?.name == .appLaunched)
}

private func telemetryReliabilityConfiguration(
  maximumEventCount: Int
) -> TelemetryStoreConfiguration {
  TelemetryStoreConfiguration(
    maximumAge: 30 * 24 * 60 * 60,
    maximumEventCount: maximumEventCount,
    maximumDatabaseBytes: 10 * 1024 * 1024,
    maintenanceInsertInterval: 1_000,
    pruneBatchSize: 100
  )
}

private func telemetryReliabilityLocation() -> (directory: URL, database: URL) {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("BYOKchatTelemetryReliability-\(UUID().uuidString)", isDirectory: true)
  return (
    directory,
    directory.appendingPathComponent("telemetry.sqlite", isDirectory: false)
  )
}
