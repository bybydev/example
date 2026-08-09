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

public actor TelemetryRecorder {
  private static let deviceIDDefaultsKey = "byokchat.telemetry.deviceID"
  private static let maximumConsecutiveFailures = 3

  private let store: TelemetrySQLiteStore
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
    store = TelemetrySQLiteStore(databaseURL: databaseURL, configuration: configuration)
    self.deviceID = deviceID
    self.sessionID = sessionID
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
    return root
      .appendingPathComponent("BYOKchat", isDirectory: true)
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
