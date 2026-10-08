import Foundation
import Testing

@testable import BYOKchatProviderCore

private enum AnalyticsReadFailure: Error { case expected }

private actor AnalyticsReadFixture: TelemetryAnalyticsReading {
  var failEvents = false
  var failStatistics = false
  var events: [TelemetryEvent] = []
  var statisticsReadCount = 0

  func configure(failEvents: Bool = false, failStatistics: Bool = false, populated: Bool = false) {
    self.failEvents = failEvents
    self.failStatistics = failStatistics
    events = populated ? [.init(dataClass: .analytics, category: .app, name: .appLaunched)] : []
  }
  func recentEvents(limit: Int) throws -> [TelemetryEvent] {
    if failEvents { throw AnalyticsReadFailure.expected }
    return events
  }
  func statistics() throws -> TelemetryStoreStatistics {
    statisticsReadCount += 1
    if failStatistics { throw AnalyticsReadFailure.expected }
    return .empty
  }
}

@Test(arguments: [false, true])
func analyticsLoadFailureIsExplicitBeforeRecorderDisables(statisticsFails: Bool) async {
  let fixture = AnalyticsReadFixture()
  await fixture.configure(failEvents: !statisticsFails, failStatistics: statisticsFails)
  let store = TelemetrySQLiteStore(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
  let recorder = TelemetryRecorder(store: store, analyticsReader: fixture)
  if case .unavailable = await recorder.loadAnalytics() {} else { Issue.record("Read failure appeared successful") }
  let health = await recorder.health()
  #expect(health.isAvailable && health.consecutiveFailureCount == 1)
  #expect(await fixture.statisticsReadCount == (statisticsFails ? 1 : 0))
}

@Test func analyticsRetryActuallyReloadsAndDistinguishesHealthyEmptyAndPopulated() async {
  let fixture = AnalyticsReadFixture()
  await fixture.configure(failEvents: true)
  let store = TelemetrySQLiteStore(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
  let recorder = TelemetryRecorder(store: store, analyticsReader: fixture)
  for _ in 0..<3 { _ = await recorder.loadAnalytics() }
  #expect(!(await recorder.health()).isAvailable)
  await recorder.retryAfterFailure()
  if case .unavailable = await recorder.loadAnalytics() {} else { Issue.record("Reset alone repaired storage") }
  await fixture.configure()
  await recorder.retryAfterFailure()
  if case .loaded(let events, _) = await recorder.loadAnalytics() { #expect(events.isEmpty) }
  else { Issue.record("Healthy empty load was unavailable") }
  await fixture.configure(populated: true)
  if case .loaded(let events, _) = await recorder.loadAnalytics() { #expect(events.count == 1) }
  else { Issue.record("Healthy populated load was unavailable") }
}
