import BYOKchatProviderCore
import Foundation
import Observation

@MainActor
@Observable
final class MacDiagnosticsModel {
  private(set) var statistics = TelemetryStoreStatistics.empty
  private(set) var health = TelemetryRecorderHealth(
    isAvailable: true,
    consecutiveFailureCount: 0,
    lastFailureDescription: nil,
    lastFailureAt: nil
  )
  private(set) var events: [TelemetryEvent] = []
  private(set) var isBusy = false
  var errorMessage: String?

  private let recorder: TelemetryRecorder
  private let configuration = TelemetryStoreConfiguration.default

  init(recorder: TelemetryRecorder) {
    self.recorder = recorder
  }

  var retentionDays: Int {
    Int(configuration.maximumAge / (24 * 60 * 60))
  }

  var maximumEventCount: Int { configuration.maximumEventCount }
  var maximumDatabaseBytes: Int64 { configuration.maximumDatabaseBytes }

  func load() async {
    statistics = await recorder.statistics()
    health = await recorder.health()
    events = await recorder.recentEvents(
      limit: TelemetryStoreConfiguration.maximumRecentEventQueryCount
    )
  }

  func filteredEvents(_ filter: TelemetryLogFilter) -> [TelemetryEvent] {
    TelemetryDiagnostics.filtered(events: events, filter: filter)
  }

  func exportData(events: [TelemetryEvent]) -> Data? {
    do {
      return try TelemetryDiagnostics.exportJSON(events: events)
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func runMaintenance() async {
    await perform {
      await recorder.performMaintenance()
    }
  }

  func retryTelemetry() async {
    await perform {
      await recorder.retryAfterFailure()
      await recorder.performMaintenance()
    }
  }

  func clearDiagnosticLogs() async {
    await perform {
      await recorder.clearDiagnosticLogs()
    }
  }

  func clearAllTelemetry() async {
    await perform {
      await recorder.clearAllTelemetry()
    }
  }

  private func perform(_ operation: () async -> Void) async {
    isBusy = true
    errorMessage = nil
    await operation()
    isBusy = false
    await load()
  }
}
