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
  public static let currentSchemaVersion = 1

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

  deinit {
    if let connection {
      sqlite3_close(connection)
    }
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
      try performMaintenance(referenceDate: event.timestamp)
    }
  }

  public func recentEvents(limit: Int = 500) throws -> [TelemetryEvent] {
    let database = try database()
    let safeLimit = min(max(limit, 1), 5_000)
    let sql = """
      SELECT
        id, timestamp, data_class, category, name, severity, outcome,
        device_id, session_id, conversation_id, message_id,
        provider_id, account_id, model_id,
        duration_ms, ttft_ms,
        input_tokens, output_tokens, cached_input_tokens, reasoning_tokens,
        model_request_count, tool_call_count, http_status, error_code, metadata_json
      FROM telemetry_events
      ORDER BY timestamp DESC
      LIMIT ?;
      """

    let statement = try prepare(sql, on: database)
    defer { sqlite3_finalize(statement) }
    try bind(safeLimit, at: 1, to: statement, on: database)

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
      schemaVersion: try schemaVersion(on: database)
    )
  }

  public func performMaintenance(referenceDate: Date = .now) throws {
    let database = try database()

    if configuration.maximumAge > 0 {
      let cutoff = referenceDate.timeIntervalSince1970 - configuration.maximumAge
      let statement = try prepare(
        "DELETE FROM telemetry_events WHERE timestamp < ?;",
        on: database
      )
      defer { sqlite3_finalize(statement) }
      try bind(cutoff, at: 1, to: statement, on: database)
      try stepDone(statement, on: database, context: "prune by age")
    }

    let count = try eventCount(on: database)
    if count > configuration.maximumEventCount {
      try deleteOldest(
        count: count - configuration.maximumEventCount,
        on: database,
        context: "prune by event count"
      )
    }

    try enforceSizeCap(on: database)
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
      CREATE INDEX IF NOT EXISTS telemetry_events_class_timestamp_idx
        ON telemetry_events(data_class, timestamp);

      PRAGMA user_version = 1;
      """,
      on: database,
      context: "create schema v1"
    )
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

  private func deleteOldest(count: Int, on database: OpaquePointer, context: String) throws {
    guard count > 0 else { return }
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
