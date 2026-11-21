import CSQLite
import Foundation

public enum TelemetryStoreError: Error, Sendable, CustomStringConvertible {
  case sqlite(context: String, code: Int32, message: String)
  case unsupportedSchemaVersion(Int)
  case invalidDatabaseState

  public var description: String {
    switch self {
    case .sqlite(let context, let code, let message):
      "Telemetry SQLite error during \(context) (\(code)): \(message)"
    case .unsupportedSchemaVersion(let version):
      "Unsupported telemetry schema version: \(version)"
    case .invalidDatabaseState:
      "Telemetry database could not be opened."
    }
  }
}

public actor TelemetrySQLiteStore {
  public static let currentSchemaVersion = 2

  private static let requiredEventColumns: Set<String> = [
    "id",
    "timestamp",
    "data_class",
    "category",
    "name",
    "severity",
    "outcome",
    "device_id",
    "session_id",
    "conversation_id",
    "message_id",
    "provider_id",
    "account_id",
    "model_id",
    "duration_ms",
    "ttft_ms",
    "input_tokens",
    "output_tokens",
    "cached_input_tokens",
    "reasoning_tokens",
    "model_request_count",
    "tool_call_count",
    "http_status",
    "error_code",
    "metadata_json",
  ]

  private let databaseURL: URL
  private let configuration: TelemetryStoreConfiguration
  private var connection: OpaquePointer?
  private var insertsSinceMaintenance = 0

  public init(
    databaseURL: URL,
    configuration: TelemetryStoreConfiguration = .default
  ) {
    self.databaseURL = databaseURL
    self.configuration = configuration
  }

  public func append(_ event: TelemetryEvent) throws {
    let database = try database()
    let event = TelemetryPrivacy.sanitize(event)
    let sql = """
      INSERT OR REPLACE INTO telemetry_events (
        id, timestamp, data_class, category, name, severity, outcome,
        device_id, session_id, conversation_id, message_id,
        provider_id, account_id, model_id,
        duration_ms, ttft_ms,
        input_tokens, output_tokens, cached_input_tokens, reasoning_tokens,
        model_request_count, tool_call_count, http_status, error_code, metadata_json
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      """

    let statement = try prepare(sql, on: database)
    defer { sqlite3_finalize(statement) }

    try bind(event.id, at: 1, to: statement, on: database)
    try bind(event.timestamp.timeIntervalSince1970, at: 2, to: statement, on: database)
    try bind(event.dataClass.rawValue, at: 3, to: statement, on: database)
    try bind(event.category.rawValue, at: 4, to: statement, on: database)
    try bind(event.name.rawValue, at: 5, to: statement, on: database)
    try bind(event.severity.rawValue, at: 6, to: statement, on: database)
    try bind(event.outcome?.rawValue, at: 7, to: statement, on: database)
    try bind(event.deviceID, at: 8, to: statement, on: database)
    try bind(event.sessionID, at: 9, to: statement, on: database)
    try bind(event.conversationID?.rawValue, at: 10, to: statement, on: database)
    try bind(event.messageID?.rawValue, at: 11, to: statement, on: database)
    try bind(event.providerID?.rawValue, at: 12, to: statement, on: database)
    try bind(event.accountID?.rawValue, at: 13, to: statement, on: database)
    try bind(event.modelID?.rawValue, at: 14, to: statement, on: database)
    try bind(event.durationMilliseconds, at: 15, to: statement, on: database)
    try bind(event.timeToFirstTokenMilliseconds, at: 16, to: statement, on: database)
    try bind(event.inputTokens, at: 17, to: statement, on: database)
    try bind(event.outputTokens, at: 18, to: statement, on: database)
    try bind(event.cachedInputTokens, at: 19, to: statement, on: database)
    try bind(event.reasoningTokens, at: 20, to: statement, on: database)
    try bind(event.modelRequestCount, at: 21, to: statement, on: database)
    try bind(event.toolCallCount, at: 22, to: statement, on: database)
    try bind(event.httpStatus, at: 23, to: statement, on: database)
    try bind(event.errorCode, at: 24, to: statement, on: database)
    try bind(try metadataJSON(event.metadata), at: 25, to: statement, on: database)

    try stepDone(statement, on: database, context: "insert")

    insertsSinceMaintenance += 1
    if insertsSinceMaintenance >= configuration.maintenanceInsertInterval {
      insertsSinceMaintenance = 0
      // Maintenance runs after the event is committed; a failed compaction or
      // prune must not turn a successful insert into a recorder failure loop.
      try? performMaintenance(referenceDate: .now)
    }
  }

  public func recentEvents(limit: Int = 500) throws -> [TelemetryEvent] {
    try recentEvents(dataClass: nil, limit: limit)
  }

  public func recentAnalyticsEvents(limit: Int = 500) throws -> [TelemetryEvent] {
    try recentEvents(dataClass: .analytics, limit: limit)
  }

  public func analyticsEvents(
    since startDate: Date? = nil,
    eventNames: [TelemetryEventName]? = nil,
    limit: Int = TelemetryStoreConfiguration.maximumRecentEventQueryCount
  ) throws -> [TelemetryEvent] {
    let database = try database()
    let safeLimit = min(
      max(limit, 1),
      TelemetryStoreConfiguration.maximumRecentEventQueryCount
    )

    var clauses = ["data_class = 'analytics'"]
    if startDate != nil {
      clauses.append("timestamp >= ?")
    }
    let filteredNames = eventNames?.filter { !$0.rawValue.isEmpty } ?? []
    if !filteredNames.isEmpty {
      let placeholders = Array(repeating: "?", count: filteredNames.count).joined(separator: ", ")
      clauses.append("name IN (\(placeholders))")
    }

    let sql = """
      SELECT
        id, timestamp, data_class, category, name, severity, outcome,
        device_id, session_id, conversation_id, message_id,
        provider_id, account_id, model_id,
        duration_ms, ttft_ms,
        input_tokens, output_tokens, cached_input_tokens, reasoning_tokens,
        model_request_count, tool_call_count, http_status, error_code, metadata_json
      FROM telemetry_events
      WHERE \(clauses.joined(separator: " AND "))
      ORDER BY timestamp DESC
      LIMIT ?;
      """

    let statement = try prepare(sql, on: database)
    defer { sqlite3_finalize(statement) }

    var bindIndex: Int32 = 1
    if let startDate {
      try bind(startDate.timeIntervalSince1970, at: bindIndex, to: statement, on: database)
      bindIndex += 1
    }
    for name in filteredNames {
      try bind(name.rawValue, at: bindIndex, to: statement, on: database)
      bindIndex += 1
    }
    try bind(safeLimit, at: bindIndex, to: statement, on: database)

    return try collectEvents(from: statement, on: database, context: "query analytics events")
  }

  public func analyticsEvents(
    forConversationID conversationID: ConversationID,
    limit: Int = TelemetryStoreConfiguration.maximumRecentEventQueryCount
  ) throws -> [TelemetryEvent] {
    let database = try database()
    let safeLimit = min(
      max(limit, 1),
      TelemetryStoreConfiguration.maximumRecentEventQueryCount
    )
    let sql = """
      SELECT
        id, timestamp, data_class, category, name, severity, outcome,
        device_id, session_id, conversation_id, message_id,
        provider_id, account_id, model_id,
        duration_ms, ttft_ms,
        input_tokens, output_tokens, cached_input_tokens, reasoning_tokens,
        model_request_count, tool_call_count, http_status, error_code, metadata_json
      FROM telemetry_events
      WHERE conversation_id = ? AND data_class = 'analytics'
      ORDER BY timestamp DESC
      LIMIT ?;
      """
    let statement = try prepare(sql, on: database)
    defer { sqlite3_finalize(statement) }
    try bind(conversationID.rawValue, at: 1, to: statement, on: database)
    try bind(safeLimit, at: 2, to: statement, on: database)
    return try collectEvents(from: statement, on: database, context: "query conversation analytics")
  }

  public func analyticsEvents(
    forMessageID messageID: ChatMessageID,
    limit: Int = 200
  ) throws -> [TelemetryEvent] {
    let database = try database()
    let safeLimit = min(
      max(limit, 1),
      TelemetryStoreConfiguration.maximumRecentEventQueryCount
    )
    let sql = """
      SELECT
        id, timestamp, data_class, category, name, severity, outcome,
        device_id, session_id, conversation_id, message_id,
        provider_id, account_id, model_id,
        duration_ms, ttft_ms,
        input_tokens, output_tokens, cached_input_tokens, reasoning_tokens,
        model_request_count, tool_call_count, http_status, error_code, metadata_json
      FROM telemetry_events
      WHERE message_id = ? AND data_class = 'analytics'
      ORDER BY timestamp DESC
      LIMIT ?;
      """
    let statement = try prepare(sql, on: database)
    defer { sqlite3_finalize(statement) }
    try bind(messageID.rawValue, at: 1, to: statement, on: database)
    try bind(safeLimit, at: 2, to: statement, on: database)
    return try collectEvents(from: statement, on: database, context: "query message analytics")
  }

  public func dailyRollups(since startDate: Date? = nil) throws -> [TelemetryDailyRollup] {
    let database = try database()
    let whereClause = startDate != nil ? "WHERE day_epoch >= ?\n      " : ""
    let sql = """
      SELECT
        day_epoch, provider_id, model_id,
        provider_success_count, provider_failure_count, provider_cancelled_count,
        ttft_sum_ms, ttft_count,
        duration_sum_ms, duration_count,
        speed_sum, speed_count,
        tool_success_count, tool_failure_count, tool_cancelled_count,
        mcp_request_count, mcp_failure_count
      FROM telemetry_daily_rollups
      \(whereClause)ORDER BY day_epoch DESC;
      """
    let statement = try prepare(sql, on: database)
    defer { sqlite3_finalize(statement) }
    if let startDate {
      try bind(Self.dayEpoch(for: startDate), at: 1, to: statement, on: database)
    }

    var rollups: [TelemetryDailyRollup] = []
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { break }
      guard result == SQLITE_ROW else {
        throw sqliteError(database, context: "query daily rollups", code: result)
      }
      let dayEpoch = sqlite3_column_int64(statement, 0)
      let rawProvider = textColumn(statement, index: 1) ?? ""
      let rawModel = textColumn(statement, index: 2) ?? ""
      rollups.append(
        TelemetryDailyRollup(
          dayStart: Date(timeIntervalSince1970: TimeInterval(dayEpoch)),
          providerID: rawProvider.isEmpty ? nil : rawProvider,
          modelID: rawModel.isEmpty ? nil : rawModel,
          providerSuccessCount: Int(sqlite3_column_int64(statement, 3)),
          providerFailureCount: Int(sqlite3_column_int64(statement, 4)),
          providerCancelledCount: Int(sqlite3_column_int64(statement, 5)),
          ttftSumMilliseconds: sqlite3_column_double(statement, 6),
          ttftCount: Int(sqlite3_column_int64(statement, 7)),
          durationSumMilliseconds: sqlite3_column_double(statement, 8),
          durationCount: Int(sqlite3_column_int64(statement, 9)),
          speedSum: sqlite3_column_double(statement, 10),
          speedCount: Int(sqlite3_column_int64(statement, 11)),
          toolSuccessCount: Int(sqlite3_column_int64(statement, 12)),
          toolFailureCount: Int(sqlite3_column_int64(statement, 13)),
          toolCancelledCount: Int(sqlite3_column_int64(statement, 14)),
          mcpRequestCount: Int(sqlite3_column_int64(statement, 15)),
          mcpFailureCount: Int(sqlite3_column_int64(statement, 16))
        )
      )
    }
    return rollups
  }

  public func dailyErrorRollups(since startDate: Date? = nil) throws -> [TelemetryDailyErrorRollup] {
    let database = try database()
    let whereClause = startDate != nil ? "WHERE day_epoch >= ?\n      " : ""
    let sql = """
      SELECT day_epoch, category, error_code, classification, count
      FROM telemetry_daily_error_rollups
      \(whereClause)ORDER BY day_epoch DESC;
      """
    let statement = try prepare(sql, on: database)
    defer { sqlite3_finalize(statement) }
    if let startDate {
      try bind(Self.dayEpoch(for: startDate), at: 1, to: statement, on: database)
    }

    var rollups: [TelemetryDailyErrorRollup] = []
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { break }
      guard result == SQLITE_ROW else {
        throw sqliteError(database, context: "query daily error rollups", code: result)
      }
      guard
        let categoryRaw = textColumn(statement, index: 1),
        let category = TelemetryCategory(rawValue: categoryRaw),
        let errorCode = textColumn(statement, index: 2),
        let classification = textColumn(statement, index: 3)
      else { continue }
      let dayEpoch = sqlite3_column_int64(statement, 0)
      rollups.append(
        TelemetryDailyErrorRollup(
          dayStart: Date(timeIntervalSince1970: TimeInterval(dayEpoch)),
          category: category,
          errorCode: errorCode,
          classification: classification,
          count: Int(sqlite3_column_int64(statement, 4))
        )
      )
    }
    return rollups
  }

  public func recentEvents(
    dataClass: TelemetryDataClass?,
    limit: Int = 500
  ) throws -> [TelemetryEvent] {
    let database = try database()
    let safeLimit = min(
      max(limit, 1),
      TelemetryStoreConfiguration.maximumRecentEventQueryCount
    )
    let whereClause = dataClass != nil ? "WHERE data_class = ?\n      " : ""
    let sql = """
      SELECT
        id, timestamp, data_class, category, name, severity, outcome,
        device_id, session_id, conversation_id, message_id,
        provider_id, account_id, model_id,
        duration_ms, ttft_ms,
        input_tokens, output_tokens, cached_input_tokens, reasoning_tokens,
        model_request_count, tool_call_count, http_status, error_code, metadata_json
      FROM telemetry_events
      \(whereClause)ORDER BY timestamp DESC
      LIMIT ?;
      """

    let statement = try prepare(sql, on: database)
    defer { sqlite3_finalize(statement) }
    if let dataClass {
      try bind(dataClass.rawValue, at: 1, to: statement, on: database)
      try bind(safeLimit, at: 2, to: statement, on: database)
    } else {
      try bind(safeLimit, at: 1, to: statement, on: database)
    }

    var events: [TelemetryEvent] = []
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { break }
      guard result == SQLITE_ROW else {
        throw sqliteError(database, context: "query recent events", code: result)
      }
      if let event = decodeEvent(from: statement) {
        events.append(event)
      }
    }
    return events
  }

  public func statistics() throws -> TelemetryStoreStatistics {
    let database = try database()
    let sql = """
      SELECT
        COUNT(*),
        COALESCE(SUM(CASE WHEN data_class = 'diagnostic' THEN 1 ELSE 0 END), 0),
        COALESCE(SUM(CASE WHEN data_class = 'analytics' THEN 1 ELSE 0 END), 0),
        MIN(timestamp),
        MAX(timestamp)
      FROM telemetry_events;
      """
    let statement = try prepare(sql, on: database)
    defer { sqlite3_finalize(statement) }

    let result = sqlite3_step(statement)
    guard result == SQLITE_ROW else {
      throw sqliteError(database, context: "read statistics", code: result)
    }

    return TelemetryStoreStatistics(
      eventCount: Int(sqlite3_column_int64(statement, 0)),
      diagnosticEventCount: Int(sqlite3_column_int64(statement, 1)),
      analyticsEventCount: Int(sqlite3_column_int64(statement, 2)),
      databaseBytes: databaseFootprintBytes(),
      oldestEventAt: dateColumn(statement, index: 3),
      newestEventAt: dateColumn(statement, index: 4),
      schemaVersion: try schemaVersion(on: database),
      rollupRowCount: try rollupCount(on: database)
    )
  }

  public func performMaintenance(referenceDate: Date = .now) throws {
    let database = try database()
    var didDelete = false

    if configuration.maximumAge > 0 {
      let cutoff = referenceDate.timeIntervalSince1970 - configuration.maximumAge
      if try archiveAndDeleteExpiredEvents(olderThan: cutoff, on: database) {
        didDelete = true
      }
    }

    let count = try eventCount(on: database)
    if count > configuration.maximumEventCount {
      try deleteOldest(
        count: count - configuration.maximumEventCount,
        on: database,
        context: "prune by event count"
      )
      didDelete = true
    }

    try enforceSizeCap(on: database)
    if didDelete {
      try? execute("PRAGMA wal_checkpoint(PASSIVE);", on: database, context: "checkpoint after maintenance")
    }
    insertsSinceMaintenance = 0
  }

  public func clearDiagnosticLogs() throws {
    let database = try database()
    try execute(
      "DELETE FROM telemetry_events WHERE data_class = 'diagnostic';",
      on: database,
      context: "clear diagnostic logs"
    )
    insertsSinceMaintenance = 0
  }

  public func clearAllTelemetry() throws {
    closeConnection()
    try removeDatabaseFiles()
    _ = try database()
    insertsSinceMaintenance = 0
  }

  public func close() {
    closeConnection()
  }

  private func database() throws -> OpaquePointer {
    if let connection { return connection }

    do {
      let opened = try openConfiguredDatabase()
      connection = opened
      return opened
    } catch {
      closeConnection()
      guard isRecoverableByRecreation(error) else {
        throw error
      }
      try? removeDatabaseFiles()

      do {
        let recovered = try openConfiguredDatabase()
        connection = recovered
        return recovered
      } catch {
        closeConnection()
        throw error
      }
    }
  }

  private func isRecoverableByRecreation(_ error: any Error) -> Bool {
    guard let storeError = error as? TelemetryStoreError else { return false }
    switch storeError {
    case .invalidDatabaseState, .unsupportedSchemaVersion:
      return true
    case .sqlite(_, let code, _):
      return code == SQLITE_CORRUPT || code == SQLITE_NOTADB
    }
  }

  private func openConfiguredDatabase() throws -> OpaquePointer {
    try ensureDatabaseDirectory()

    var database: OpaquePointer?
    let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
    let result = sqlite3_open_v2(databaseURL.path, &database, flags, nil)
    guard result == SQLITE_OK, let database else {
      let message = database.map { String(cString: sqlite3_errmsg($0)) }
        ?? "SQLite returned no database handle"
      if let database { sqlite3_close(database) }
      throw TelemetryStoreError.sqlite(context: "open", code: result, message: message)
    }

    do {
      sqlite3_busy_timeout(database, 1_500)
      try execute("PRAGMA journal_mode = WAL;", on: database, context: "enable WAL")
      try execute("PRAGMA synchronous = NORMAL;", on: database, context: "set synchronous mode")
      try execute("PRAGMA temp_store = MEMORY;", on: database, context: "set temp store")
      try migrateIfNeeded(on: database)
      try ensureIndexes(on: database)
      try validateSchema(on: database)
      return database
    } catch {
      sqlite3_close(database)
      throw error
    }
  }

  private func migrateIfNeeded(on database: OpaquePointer) throws {
    var version = try schemaVersion(on: database)
    guard version <= Self.currentSchemaVersion else {
      throw TelemetryStoreError.unsupportedSchemaVersion(version)
    }

    while version < Self.currentSchemaVersion {
      switch version {
      case 0:
        try createSchemaV1(on: database)
        version = 1
      case 1:
        try migrateV1ToV2(on: database)
        version = 2
      default:
        throw TelemetryStoreError.unsupportedSchemaVersion(version)
      }
    }
  }

  private func createSchemaV1(on database: OpaquePointer) throws {
    try execute(
      """
      CREATE TABLE IF NOT EXISTS telemetry_events (
        id TEXT PRIMARY KEY NOT NULL,
        timestamp REAL NOT NULL,
        data_class TEXT NOT NULL,
        category TEXT NOT NULL,
        name TEXT NOT NULL,
        severity TEXT NOT NULL,
        outcome TEXT,
        device_id TEXT,
        session_id TEXT,
        conversation_id TEXT,
        message_id TEXT,
        provider_id TEXT,
        account_id TEXT,
        model_id TEXT,
        duration_ms REAL,
        ttft_ms REAL,
        input_tokens INTEGER,
        output_tokens INTEGER,
        cached_input_tokens INTEGER,
        reasoning_tokens INTEGER,
        model_request_count INTEGER,
        tool_call_count INTEGER,
        http_status INTEGER,
        error_code TEXT,
        metadata_json TEXT NOT NULL DEFAULT '{}'
      );

      PRAGMA user_version = 1;
      """,
      on: database,
      context: "create schema v1"
    )
  }

  private func migrateV1ToV2(on database: OpaquePointer) throws {
    try execute(
      """
      CREATE TABLE IF NOT EXISTS telemetry_daily_rollups (
        day_epoch INTEGER NOT NULL,
        provider_id TEXT NOT NULL DEFAULT '',
        model_id TEXT NOT NULL DEFAULT '',
        provider_success_count INTEGER NOT NULL DEFAULT 0,
        provider_failure_count INTEGER NOT NULL DEFAULT 0,
        provider_cancelled_count INTEGER NOT NULL DEFAULT 0,
        ttft_sum_ms REAL NOT NULL DEFAULT 0,
        ttft_count INTEGER NOT NULL DEFAULT 0,
        duration_sum_ms REAL NOT NULL DEFAULT 0,
        duration_count INTEGER NOT NULL DEFAULT 0,
        speed_sum REAL NOT NULL DEFAULT 0,
        speed_count INTEGER NOT NULL DEFAULT 0,
        tool_success_count INTEGER NOT NULL DEFAULT 0,
        tool_failure_count INTEGER NOT NULL DEFAULT 0,
        tool_cancelled_count INTEGER NOT NULL DEFAULT 0,
        mcp_request_count INTEGER NOT NULL DEFAULT 0,
        mcp_failure_count INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (day_epoch, provider_id, model_id)
      );

      CREATE TABLE IF NOT EXISTS telemetry_daily_error_rollups (
        day_epoch INTEGER NOT NULL,
        category TEXT NOT NULL,
        error_code TEXT NOT NULL,
        classification TEXT NOT NULL,
        count INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (day_epoch, category, error_code, classification)
      );

      PRAGMA user_version = 2;
      """,
      on: database,
      context: "migrate schema v1 to v2"
    )
  }

  private func ensureIndexes(on database: OpaquePointer) throws {
    try execute(
      """
      CREATE INDEX IF NOT EXISTS telemetry_events_timestamp_idx
        ON telemetry_events(timestamp);
      CREATE INDEX IF NOT EXISTS telemetry_events_category_timestamp_idx
        ON telemetry_events(category, timestamp);
      CREATE INDEX IF NOT EXISTS telemetry_events_provider_timestamp_idx
        ON telemetry_events(provider_id, timestamp);
      CREATE INDEX IF NOT EXISTS telemetry_events_model_timestamp_idx
        ON telemetry_events(model_id, timestamp);
      CREATE INDEX IF NOT EXISTS telemetry_events_conversation_timestamp_idx
        ON telemetry_events(conversation_id, timestamp);
      CREATE INDEX IF NOT EXISTS telemetry_events_message_timestamp_idx
        ON telemetry_events(message_id, timestamp);
      CREATE INDEX IF NOT EXISTS telemetry_events_class_timestamp_idx
        ON telemetry_events(data_class, timestamp);
      CREATE INDEX IF NOT EXISTS telemetry_events_class_name_timestamp_idx
        ON telemetry_events(data_class, name, timestamp);
      CREATE INDEX IF NOT EXISTS telemetry_daily_rollups_day_idx
        ON telemetry_daily_rollups(day_epoch);
      CREATE INDEX IF NOT EXISTS telemetry_daily_error_rollups_day_idx
        ON telemetry_daily_error_rollups(day_epoch);
      """,
      on: database,
      context: "ensure telemetry indexes"
    )
  }

  private func validateSchema(on database: OpaquePointer) throws {
    guard try schemaVersion(on: database) == Self.currentSchemaVersion else {
      throw TelemetryStoreError.invalidDatabaseState
    }

    let columns = try tableColumns("telemetry_events", on: database)
    guard Self.requiredEventColumns.isSubset(of: columns) else {
      throw TelemetryStoreError.invalidDatabaseState
    }

    let rollupColumns = try tableColumns("telemetry_daily_rollups", on: database)
    let errorRollupColumns = try tableColumns("telemetry_daily_error_rollups", on: database)
    guard !rollupColumns.isEmpty, !errorRollupColumns.isEmpty else {
      throw TelemetryStoreError.invalidDatabaseState
    }
  }

  private func tableColumns(_ table: String, on database: OpaquePointer) throws -> Set<String> {
    let statement = try prepare("PRAGMA table_info(\(table));", on: database)
    defer { sqlite3_finalize(statement) }

    var columns = Set<String>()
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { break }
      guard result == SQLITE_ROW else {
        throw sqliteError(database, context: "validate telemetry schema", code: result)
      }
      if let columnName = textColumn(statement, index: 1) {
        columns.insert(columnName)
      }
    }
    return columns
  }

  private func enforceSizeCap(on database: OpaquePointer) throws {
    guard databaseFootprintBytes() > configuration.maximumDatabaseBytes else { return }

    try execute("PRAGMA wal_checkpoint(TRUNCATE);", on: database, context: "checkpoint telemetry WAL")
    guard databaseFootprintBytes() > configuration.maximumDatabaseBytes else { return }

    let targetBytes = Int64(Double(configuration.maximumDatabaseBytes) * 0.80)
    var attempts = 0

    while databaseFootprintBytes() > targetBytes, attempts < 3 {
      let count = try eventCount(on: database)
      guard count > 0 else { break }

      let currentBytes = max(databaseFootprintBytes(), 1)
      let keepFraction = min(max(Double(targetBytes) / Double(currentBytes), 0.10), 0.95)
      let estimatedDelete = Int(ceil(Double(count) * (1 - keepFraction)))
      let deleteCount = min(count, max(configuration.pruneBatchSize, estimatedDelete))
      try deleteOldest(count: deleteCount, on: database, context: "prune by database size")

      try execute("PRAGMA wal_checkpoint(TRUNCATE);", on: database, context: "checkpoint after size prune")
      try execute("VACUUM;", on: database, context: "compact telemetry database")
      attempts += 1
    }
  }

  private func archiveAndDeleteExpiredEvents(
    olderThan cutoff: Double,
    on database: OpaquePointer
  ) throws -> Bool {
    try execute("BEGIN IMMEDIATE;", on: database, context: "begin age prune")
    do {
      let selectSQL = """
        SELECT
          id, timestamp, data_class, category, name, severity, outcome,
          device_id, session_id, conversation_id, message_id,
          provider_id, account_id, model_id,
          duration_ms, ttft_ms,
          input_tokens, output_tokens, cached_input_tokens, reasoning_tokens,
          model_request_count, tool_call_count, http_status, error_code, metadata_json
        FROM telemetry_events
        WHERE timestamp < ? AND data_class = 'analytics';
        """
      let selectStmt = try prepare(selectSQL, on: database)
      defer { sqlite3_finalize(selectStmt) }
      try bind(cutoff, at: 1, to: selectStmt, on: database)
      let expiringAnalytics = try collectEvents(from: selectStmt, on: database, context: "select expiring analytics")
      if !expiringAnalytics.isEmpty {
        try archiveAnalyticsEvents(expiringAnalytics, on: database)
      }

      let deleteStmt = try prepare(
        "DELETE FROM telemetry_events WHERE timestamp < ?;",
        on: database
      )
      defer { sqlite3_finalize(deleteStmt) }
      try bind(cutoff, at: 1, to: deleteStmt, on: database)
      try stepDone(deleteStmt, on: database, context: "prune by age")
      let deleted = sqlite3_changes(database) > 0

      try execute("COMMIT;", on: database, context: "commit age prune")
      return deleted
    } catch {
      try? execute("ROLLBACK;", on: database, context: "rollback age prune")
      throw error
    }
  }

  private func deleteOldest(count: Int, on database: OpaquePointer, context: String) throws {
    guard count > 0 else { return }
    try execute("BEGIN IMMEDIATE;", on: database, context: "begin oldest prune")
    do {
      let selectSQL = """
        SELECT
          id, timestamp, data_class, category, name, severity, outcome,
          device_id, session_id, conversation_id, message_id,
          provider_id, account_id, model_id,
          duration_ms, ttft_ms,
          input_tokens, output_tokens, cached_input_tokens, reasoning_tokens,
          model_request_count, tool_call_count, http_status, error_code, metadata_json
        FROM telemetry_events
        ORDER BY timestamp ASC
        LIMIT ?;
        """
      let selectStmt = try prepare(selectSQL, on: database)
      defer { sqlite3_finalize(selectStmt) }
      try bind(count, at: 1, to: selectStmt, on: database)
      let oldestEvents = try collectEvents(from: selectStmt, on: database, context: "select oldest events")
      let analyticsEvents = oldestEvents.filter { $0.dataClass == .analytics }
      if !analyticsEvents.isEmpty {
        try archiveAnalyticsEvents(analyticsEvents, on: database)
      }

      let statement = try prepare(
        """
        DELETE FROM telemetry_events
        WHERE id IN (
          SELECT id FROM telemetry_events
          ORDER BY timestamp ASC
          LIMIT ?
        );
        """,
        on: database
      )
      defer { sqlite3_finalize(statement) }
      try bind(count, at: 1, to: statement, on: database)
      try stepDone(statement, on: database, context: context)

      try execute("COMMIT;", on: database, context: "commit oldest prune")
    } catch {
      try? execute("ROLLBACK;", on: database, context: "rollback oldest prune")
      throw error
    }
  }

  private func archiveAnalyticsEvents(
    _ events: [TelemetryEvent],
    on database: OpaquePointer
  ) throws {
    struct RollupKey: Hashable {
      let dayEpoch: Int64
      let providerID: String
      let modelID: String
    }
    struct RollupAccumulator {
      var providerSuccessCount = 0
      var providerFailureCount = 0
      var providerCancelledCount = 0
      var ttftSum = 0.0
      var ttftCount = 0
      var durationSum = 0.0
      var durationCount = 0
      var speedSum = 0.0
      var speedCount = 0
      var toolSuccessCount = 0
      var toolFailureCount = 0
      var toolCancelledCount = 0
      var mcpRequestCount = 0
      var mcpFailureCount = 0

      var hasActivity: Bool {
        providerSuccessCount > 0 || providerFailureCount > 0 || providerCancelledCount > 0
          || toolSuccessCount > 0 || toolFailureCount > 0 || toolCancelledCount > 0
          || mcpRequestCount > 0
      }
    }
    struct ErrorKey: Hashable {
      let dayEpoch: Int64
      let category: String
      let errorCode: String
      let classification: String
    }

    var rollups: [RollupKey: RollupAccumulator] = [:]
    var errors: [ErrorKey: Int] = [:]

    for event in events where event.dataClass == .analytics {
      let dayEpoch = Self.dayEpoch(for: event.timestamp)
      let key = RollupKey(
        dayEpoch: dayEpoch,
        providerID: event.providerID?.rawValue ?? "",
        modelID: event.modelID?.rawValue ?? ""
      )
      var acc = rollups[key] ?? RollupAccumulator()

      switch event.name {
      case .providerRequestCompleted:
        acc.providerSuccessCount += 1
        if let ttft = event.timeToFirstTokenMilliseconds, ttft.isFinite, ttft >= 0 {
          acc.ttftSum += ttft
          acc.ttftCount += 1
        }
        if let duration = event.durationMilliseconds, duration.isFinite, duration >= 0 {
          acc.durationSum += duration
          acc.durationCount += 1
        }
        if let raw = event.metadata["outputTokensPerSecond"],
          let speed = Double(raw), speed.isFinite, speed >= 0
        {
          acc.speedSum += speed
          acc.speedCount += 1
        }
      case .providerRequestFailed:
        acc.providerFailureCount += 1
        if let ttft = event.timeToFirstTokenMilliseconds, ttft.isFinite, ttft >= 0 {
          acc.ttftSum += ttft
          acc.ttftCount += 1
        }
        if let duration = event.durationMilliseconds, duration.isFinite, duration >= 0 {
          acc.durationSum += duration
          acc.durationCount += 1
        }
      case .providerRequestCancelled:
        acc.providerCancelledCount += 1
      case .toolCallCompleted:
        acc.toolSuccessCount += 1
      case .toolCallFailed:
        acc.toolFailureCount += 1
      case .toolCallCancelled:
        acc.toolCancelledCount += 1
      case .mcpRequestCompleted:
        acc.mcpRequestCount += 1
      case .mcpRequestFailed:
        acc.mcpRequestCount += 1
        if !TelemetryAnalytics.isExpectedMCPLegacyFallback(event) {
          acc.mcpFailureCount += 1
        }
      case .mcpRequestCancelled:
        acc.mcpRequestCount += 1
      default:
        break
      }

      if acc.hasActivity {
        rollups[key] = acc
      }

      if let failure = TelemetryAnalytics.isArchivedFailureEvent(event) {
        let errorKey = ErrorKey(
          dayEpoch: dayEpoch,
          category: failure.category.rawValue,
          errorCode: failure.errorCode,
          classification: failure.classification
        )
        errors[errorKey, default: 0] += 1
      }
    }

    if !rollups.isEmpty {
      let upsertSQL = """
        INSERT INTO telemetry_daily_rollups (
          day_epoch, provider_id, model_id,
          provider_success_count, provider_failure_count, provider_cancelled_count,
          ttft_sum_ms, ttft_count,
          duration_sum_ms, duration_count,
          speed_sum, speed_count,
          tool_success_count, tool_failure_count, tool_cancelled_count,
          mcp_request_count, mcp_failure_count
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(day_epoch, provider_id, model_id) DO UPDATE SET
          provider_success_count = provider_success_count + excluded.provider_success_count,
          provider_failure_count = provider_failure_count + excluded.provider_failure_count,
          provider_cancelled_count = provider_cancelled_count + excluded.provider_cancelled_count,
          ttft_sum_ms = ttft_sum_ms + excluded.ttft_sum_ms,
          ttft_count = ttft_count + excluded.ttft_count,
          duration_sum_ms = duration_sum_ms + excluded.duration_sum_ms,
          duration_count = duration_count + excluded.duration_count,
          speed_sum = speed_sum + excluded.speed_sum,
          speed_count = speed_count + excluded.speed_count,
          tool_success_count = tool_success_count + excluded.tool_success_count,
          tool_failure_count = tool_failure_count + excluded.tool_failure_count,
          tool_cancelled_count = tool_cancelled_count + excluded.tool_cancelled_count,
          mcp_request_count = mcp_request_count + excluded.mcp_request_count,
          mcp_failure_count = mcp_failure_count + excluded.mcp_failure_count;
        """
      let statement = try prepare(upsertSQL, on: database)
      defer { sqlite3_finalize(statement) }

      for (key, acc) in rollups {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        try bind(key.dayEpoch, at: 1, to: statement, on: database)
        try bind(key.providerID, at: 2, to: statement, on: database)
        try bind(key.modelID, at: 3, to: statement, on: database)
        try bind(acc.providerSuccessCount, at: 4, to: statement, on: database)
        try bind(acc.providerFailureCount, at: 5, to: statement, on: database)
        try bind(acc.providerCancelledCount, at: 6, to: statement, on: database)
        try bind(acc.ttftSum, at: 7, to: statement, on: database)
        try bind(acc.ttftCount, at: 8, to: statement, on: database)
        try bind(acc.durationSum, at: 9, to: statement, on: database)
        try bind(acc.durationCount, at: 10, to: statement, on: database)
        try bind(acc.speedSum, at: 11, to: statement, on: database)
        try bind(acc.speedCount, at: 12, to: statement, on: database)
        try bind(acc.toolSuccessCount, at: 13, to: statement, on: database)
        try bind(acc.toolFailureCount, at: 14, to: statement, on: database)
        try bind(acc.toolCancelledCount, at: 15, to: statement, on: database)
        try bind(acc.mcpRequestCount, at: 16, to: statement, on: database)
        try bind(acc.mcpFailureCount, at: 17, to: statement, on: database)
        try stepDone(statement, on: database, context: "upsert daily rollup")
      }
    }

    if !errors.isEmpty {
      let upsertErrorSQL = """
        INSERT INTO telemetry_daily_error_rollups (
          day_epoch, category, error_code, classification, count
        ) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(day_epoch, category, error_code, classification) DO UPDATE SET
          count = count + excluded.count;
        """
      let statement = try prepare(upsertErrorSQL, on: database)
      defer { sqlite3_finalize(statement) }

      for (key, count) in errors {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        try bind(key.dayEpoch, at: 1, to: statement, on: database)
        try bind(key.category, at: 2, to: statement, on: database)
        try bind(key.errorCode, at: 3, to: statement, on: database)
        try bind(key.classification, at: 4, to: statement, on: database)
        try bind(count, at: 5, to: statement, on: database)
        try stepDone(statement, on: database, context: "upsert daily error rollup")
      }
    }
  }

  private func collectEvents(
    from statement: OpaquePointer,
    on database: OpaquePointer,
    context: String
  ) throws -> [TelemetryEvent] {
    var events: [TelemetryEvent] = []
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { break }
      guard result == SQLITE_ROW else {
        throw sqliteError(database, context: context, code: result)
      }
      if let event = decodeEvent(from: statement) {
        events.append(event)
      }
    }
    return events
  }

  private func rollupCount(on database: OpaquePointer) throws -> Int {
    let statement = try prepare(
      "SELECT (SELECT COUNT(*) FROM telemetry_daily_rollups) + (SELECT COUNT(*) FROM telemetry_daily_error_rollups);",
      on: database
    )
    defer { sqlite3_finalize(statement) }
    let result = sqlite3_step(statement)
    guard result == SQLITE_ROW else {
      throw sqliteError(database, context: "count daily rollups", code: result)
    }
    return Int(sqlite3_column_int64(statement, 0))
  }

  private static func dayEpoch(for date: Date) -> Int64 {
    Int64(floor(date.timeIntervalSince1970 / 86_400.0)) * 86_400
  }

  private func eventCount(on database: OpaquePointer) throws -> Int {
    let statement = try prepare("SELECT COUNT(*) FROM telemetry_events;", on: database)
    defer { sqlite3_finalize(statement) }
    let result = sqlite3_step(statement)
    guard result == SQLITE_ROW else {
      throw sqliteError(database, context: "count events", code: result)
    }
    return Int(sqlite3_column_int64(statement, 0))
  }

  private func schemaVersion(on database: OpaquePointer) throws -> Int {
    let statement = try prepare("PRAGMA user_version;", on: database)
    defer { sqlite3_finalize(statement) }
    let result = sqlite3_step(statement)
    guard result == SQLITE_ROW else {
      throw sqliteError(database, context: "read schema version", code: result)
    }
    return Int(sqlite3_column_int(statement, 0))
  }

  private func decodeEvent(from statement: OpaquePointer) -> TelemetryEvent? {
    guard
      let id = textColumn(statement, index: 0),
      let dataClassRaw = textColumn(statement, index: 2),
      let dataClass = TelemetryDataClass(rawValue: dataClassRaw),
      let categoryRaw = textColumn(statement, index: 3),
      let category = TelemetryCategory(rawValue: categoryRaw),
      let name = textColumn(statement, index: 4),
      let severityRaw = textColumn(statement, index: 5),
      let severity = TelemetrySeverity(rawValue: severityRaw)
    else {
      return nil
    }

    let metadata: [String: String]
    if let json = textColumn(statement, index: 24),
      let data = json.data(using: .utf8),
      let decoded = try? JSONDecoder().decode([String: String].self, from: data)
    {
      metadata = decoded
    } else {
      metadata = [:]
    }

    return TelemetryEvent(
      id: id,
      timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
      dataClass: dataClass,
      category: category,
      name: TelemetryEventName(rawValue: name),
      severity: severity,
      outcome: textColumn(statement, index: 6).flatMap(TelemetryOutcome.init(rawValue:)),
      deviceID: textColumn(statement, index: 7),
      sessionID: textColumn(statement, index: 8),
      conversationID: textColumn(statement, index: 9).map(ConversationID.init(rawValue:)),
      messageID: textColumn(statement, index: 10).map(ChatMessageID.init(rawValue:)),
      providerID: textColumn(statement, index: 11).map(ProviderID.init(rawValue:)),
      accountID: textColumn(statement, index: 12).map(ProviderAccountID.init(rawValue:)),
      modelID: textColumn(statement, index: 13).map(ModelID.init(rawValue:)),
      durationMilliseconds: doubleColumn(statement, index: 14),
      timeToFirstTokenMilliseconds: doubleColumn(statement, index: 15),
      inputTokens: intColumn(statement, index: 16),
      outputTokens: intColumn(statement, index: 17),
      cachedInputTokens: intColumn(statement, index: 18),
      reasoningTokens: intColumn(statement, index: 19),
      modelRequestCount: intColumn(statement, index: 20),
      toolCallCount: intColumn(statement, index: 21),
      httpStatus: intColumn(statement, index: 22),
      errorCode: textColumn(statement, index: 23),
      metadata: metadata
    )
  }

  private func ensureDatabaseDirectory() throws {
    var directory = databaseURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? directory.setResourceValues(values)
  }

  private func removeDatabaseFiles() throws {
    for path in [databaseURL.path, databaseURL.path + "-wal", databaseURL.path + "-shm"] {
      if FileManager.default.fileExists(atPath: path) {
        try FileManager.default.removeItem(atPath: path)
      }
    }
  }

  private func databaseFootprintBytes() -> Int64 {
    [databaseURL.path, databaseURL.path + "-wal", databaseURL.path + "-shm"].reduce(0) {
      partial, path in
      guard
        let attributes = try? FileManager.default.attributesOfItem(atPath: path),
        let size = attributes[.size] as? NSNumber
      else {
        return partial
      }
      return partial + size.int64Value
    }
  }

  private func closeConnection() {
    guard let connection else { return }
    sqlite3_close(connection)
    self.connection = nil
  }

  private func execute(
    _ sql: String,
    on database: OpaquePointer,
    context: String
  ) throws {
    var errorMessage: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
    guard result == SQLITE_OK else {
      let message = errorMessage.map { String(cString: $0) }
        ?? String(cString: sqlite3_errmsg(database))
      if let errorMessage { sqlite3_free(errorMessage) }
      throw TelemetryStoreError.sqlite(context: context, code: result, message: message)
    }
  }

  private func prepare(_ sql: String, on database: OpaquePointer) throws -> OpaquePointer {
    var statement: OpaquePointer?
    let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
    guard result == SQLITE_OK, let statement else {
      throw sqliteError(database, context: "prepare statement", code: result)
    }
    return statement
  }

  private func stepDone(
    _ statement: OpaquePointer,
    on database: OpaquePointer,
    context: String
  ) throws {
    let result = sqlite3_step(statement)
    guard result == SQLITE_DONE else {
      throw sqliteError(database, context: context, code: result)
    }
  }

  private func bind(
    _ value: String?,
    at index: Int32,
    to statement: OpaquePointer,
    on database: OpaquePointer
  ) throws {
    let result: Int32
    if let value {
      result = value.withCString {
        sqlite3_bind_text(statement, index, $0, -1, sqliteTransientDestructor())
      }
    } else {
      result = sqlite3_bind_null(statement, index)
    }
    guard result == SQLITE_OK else {
      throw sqliteError(database, context: "bind text", code: result)
    }
  }

  private func bind(
    _ value: Double?,
    at index: Int32,
    to statement: OpaquePointer,
    on database: OpaquePointer
  ) throws {
    let result = value.map { sqlite3_bind_double(statement, index, $0) }
      ?? sqlite3_bind_null(statement, index)
    guard result == SQLITE_OK else {
      throw sqliteError(database, context: "bind double", code: result)
    }
  }

  private func bind(
    _ value: Int?,
    at index: Int32,
    to statement: OpaquePointer,
    on database: OpaquePointer
  ) throws {
    let result = value.map { sqlite3_bind_int64(statement, index, sqlite3_int64($0)) }
      ?? sqlite3_bind_null(statement, index)
    guard result == SQLITE_OK else {
      throw sqliteError(database, context: "bind integer", code: result)
    }
  }

  private func bind(
    _ value: Int64,
    at index: Int32,
    to statement: OpaquePointer,
    on database: OpaquePointer
  ) throws {
    let result = sqlite3_bind_int64(statement, index, value)
    guard result == SQLITE_OK else {
      throw sqliteError(database, context: "bind int64", code: result)
    }
  }

  private func metadataJSON(_ metadata: [String: String]) throws -> String {
    let data = try JSONEncoder().encode(metadata)
    return String(data: data, encoding: .utf8) ?? "{}"
  }

  private func textColumn(_ statement: OpaquePointer, index: Int32) -> String? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL,
      let pointer = sqlite3_column_text(statement, index)
    else {
      return nil
    }
    let cString = UnsafeRawPointer(pointer).assumingMemoryBound(to: CChar.self)
    return String(cString: cString)
  }

  private func intColumn(_ statement: OpaquePointer, index: Int32) -> Int? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    return Int(sqlite3_column_int64(statement, index))
  }

  private func doubleColumn(_ statement: OpaquePointer, index: Int32) -> Double? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    return sqlite3_column_double(statement, index)
  }

  private func dateColumn(_ statement: OpaquePointer, index: Int32) -> Date? {
    guard let value = doubleColumn(statement, index: index) else { return nil }
    return Date(timeIntervalSince1970: value)
  }

  private func sqliteError(
    _ database: OpaquePointer,
    context: String,
    code: Int32
  ) -> TelemetryStoreError {
    TelemetryStoreError.sqlite(
      context: context,
      code: code,
      message: String(cString: sqlite3_errmsg(database))
    )
  }
}

private func sqliteTransientDestructor() -> sqlite3_destructor_type {
  unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
