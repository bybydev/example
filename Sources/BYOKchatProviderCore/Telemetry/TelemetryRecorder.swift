import Foundation

public struct TelemetryRecorderHealth: Sendable, Equatable {
  public var isAvailable: Bool
  public var consecutiveFailureCount: Int
  public var lastFailureDescription: String?
  public var lastFailureAt: Date?

  public init(
    isAvailable: Bool,
    consecutiveFailureCount: Int,
    lastFailureDescription: String?,
    lastFailureAt: Date?
  ) {
    self.isAvailable = isAvailable
    self.consecutiveFailureCount = consecutiveFailureCount
    self.lastFailureDescription = lastFailureDescription
    self.lastFailureAt = lastFailureAt
  }
}

/// A successful empty query differs from a failed/unavailable telemetry read.
public enum TelemetryAnalyticsLoadResult: Sendable {
  case loaded(events: [TelemetryEvent], statistics: TelemetryStoreStatistics)
  case unavailable
}

protocol TelemetryAnalyticsReading: Sendable {
  func recentEvents(limit: Int) async throws -> [TelemetryEvent]
  func statistics() async throws -> TelemetryStoreStatistics
}

extension TelemetrySQLiteStore: TelemetryAnalyticsReading {}

public actor TelemetryRecorder {
  public static let shared = TelemetryRecorder()

  private static let deviceIDDefaultsKey = "byokchat.telemetry.deviceID"
  private static let maximumConsecutiveFailures = 3

  private let store: TelemetrySQLiteStore
  private let analyticsReader: any TelemetryAnalyticsReading
  private let deviceID: String
  private let sessionID: String

  private var consecutiveFailureCount = 0
  private var lastFailureDescription: String?
  private var lastFailureAt: Date?
  private var isDisabledForSession = false

  public init(
    databaseURL: URL = TelemetryRecorder.defaultDatabaseURL(),
    configuration: TelemetryStoreConfiguration = .default,
    deviceID: String = TelemetryRecorder.loadOrCreateDeviceID(),
    sessionID: String = UUID().uuidString.lowercased()
  ) {
    let store = TelemetrySQLiteStore(databaseURL: databaseURL, configuration: configuration)
    self.store = store
    self.analyticsReader = store
    self.deviceID = deviceID
    self.sessionID = sessionID
  }

  // Internal injection keeps required-read failure cases deterministic.
  init(store: TelemetrySQLiteStore, analyticsReader: any TelemetryAnalyticsReading) {
    self.store = store
    self.analyticsReader = analyticsReader
    self.deviceID = "test-device"
    self.sessionID = "test-session"
  }

  public func record(_ event: TelemetryEvent) async {
    guard !isDisabledForSession else { return }

    var event = event
    if event.deviceID == nil { event.deviceID = deviceID }
    if event.sessionID == nil { event.sessionID = sessionID }

    do {
      try await store.append(event)
      markSuccess()
    } catch {
      markFailure(error)
    }
  }

  public func performMaintenance(referenceDate: Date = .now) async {
    guard !isDisabledForSession else { return }
    do {
      try await store.performMaintenance(referenceDate: referenceDate)
      markSuccess()
    } catch {
      markFailure(error)
    }
  }

  public func recentEvents(limit: Int = 500) async -> [TelemetryEvent] {
    guard !isDisabledForSession else { return [] }
    do {
      let events = try await store.recentEvents(limit: limit)
      markSuccess()
      return events
    } catch {
      markFailure(error)
      return []
    }
  }

  public func statistics() async -> TelemetryStoreStatistics {
    guard !isDisabledForSession else { return .empty }
    do {
      let statistics = try await store.statistics()
      markSuccess()
      return statistics
    } catch {
      markFailure(error)
      return .empty
    }
  }

  public func loadAnalytics(limit: Int = 500) async -> TelemetryAnalyticsLoadResult {
    guard !isDisabledForSession else { return .unavailable }
    do {
      let events = try await analyticsReader.recentEvents(limit: limit)
      let statistics = try await analyticsReader.statistics()
      // Neither read can mask failure of the other by resetting health.
      markSuccess()
      return .loaded(events: events, statistics: statistics)
    } catch {
      markFailure(error)
      return .unavailable
    }
  }

  public func clearDiagnosticLogs() async {
    do {
      try await store.clearDiagnosticLogs()
      resetFailureState()
    } catch {
      markFailure(error)
    }
  }

  public func clearAllTelemetry() async {
    do {
      try await store.clearAllTelemetry()
      resetFailureState()
    } catch {
      markFailure(error)
    }
  }

  public func health() -> TelemetryRecorderHealth {
    TelemetryRecorderHealth(
      isAvailable: !isDisabledForSession,
      consecutiveFailureCount: consecutiveFailureCount,
      lastFailureDescription: lastFailureDescription,
      lastFailureAt: lastFailureAt
    )
  }

  public func retryAfterFailure() {
    resetFailureState()
  }

  public static func defaultDatabaseURL(fileManager: FileManager = .default) -> URL {
    let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    let namespace = storageNamespace()
    return root
      .appendingPathComponent(namespace, isDirectory: true)
      .appendingPathComponent("Telemetry", isDirectory: true)
      .appendingPathComponent("telemetry.sqlite", isDirectory: false)
  }

  public static func loadOrCreateDeviceID(defaults: UserDefaults = .standard) -> String {
    if let existing = defaults.string(forKey: deviceIDDefaultsKey), !existing.isEmpty {
      return existing
    }
    let value = UUID().uuidString.lowercased()
    defaults.set(value, forKey: deviceIDDefaultsKey)
    return value
  }

  private static func storageNamespace() -> String {
    let raw = Bundle.main.bundleIdentifier
      ?? "BYOKchat-\(ProcessInfo.processInfo.processName)"
    let safe = raw.map { character -> Character in
      if character.isLetter || character.isNumber || character == "." || character == "-" {
        return character
      }
      return "_"
    }
    return String(safe.prefix(160))
  }

  private func markSuccess() {
    consecutiveFailureCount = 0
  }

  private func markFailure(_ error: any Error) {
    consecutiveFailureCount += 1
    lastFailureAt = .now
    lastFailureDescription = String(String(describing: error).prefix(320))
    if consecutiveFailureCount >= Self.maximumConsecutiveFailures {
      isDisabledForSession = true
    }
  }

  private func resetFailureState() {
    consecutiveFailureCount = 0
    lastFailureDescription = nil
    lastFailureAt = nil
    isDisabledForSession = false
  }
}
