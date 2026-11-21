import Foundation

public struct TelemetryStoreConfiguration: Sendable, Equatable {
  public static let maximumRecentEventQueryCount = 5_000

  public var maximumAge: TimeInterval
  public var maximumEventCount: Int
  public var maximumDatabaseBytes: Int64
  public var maintenanceInsertInterval: Int
  public var pruneBatchSize: Int

  public init(
    maximumAge: TimeInterval = 30 * 24 * 60 * 60,
    maximumEventCount: Int = 100_000,
    maximumDatabaseBytes: Int64 = 50 * 1024 * 1024,
    maintenanceInsertInterval: Int = 250,
    pruneBatchSize: Int = 2_000
  ) {
    self.maximumAge = max(0, maximumAge)
    self.maximumEventCount = max(1, maximumEventCount)
    self.maximumDatabaseBytes = max(1 * 1024 * 1024, maximumDatabaseBytes)
    self.maintenanceInsertInterval = max(1, maintenanceInsertInterval)
    self.pruneBatchSize = max(100, pruneBatchSize)
  }

  public static let `default` = TelemetryStoreConfiguration()
}

public struct TelemetryStoreStatistics: Sendable, Equatable {
  public var eventCount: Int
  public var diagnosticEventCount: Int
  public var analyticsEventCount: Int
  public var databaseBytes: Int64
  public var oldestEventAt: Date?
  public var newestEventAt: Date?
  public var schemaVersion: Int
  public var rollupRowCount: Int

  public init(
    eventCount: Int,
    diagnosticEventCount: Int,
    analyticsEventCount: Int,
    databaseBytes: Int64,
    oldestEventAt: Date?,
    newestEventAt: Date?,
    schemaVersion: Int,
    rollupRowCount: Int = 0
  ) {
    self.eventCount = eventCount
    self.diagnosticEventCount = diagnosticEventCount
    self.analyticsEventCount = analyticsEventCount
    self.databaseBytes = databaseBytes
    self.oldestEventAt = oldestEventAt
    self.newestEventAt = newestEventAt
    self.schemaVersion = schemaVersion
    self.rollupRowCount = rollupRowCount
  }

  public static let empty = TelemetryStoreStatistics(
    eventCount: 0,
    diagnosticEventCount: 0,
    analyticsEventCount: 0,
    databaseBytes: 0,
    oldestEventAt: nil,
    newestEventAt: nil,
    schemaVersion: 0,
    rollupRowCount: 0
  )
}
