import CSQLite
import Foundation

public enum ConversationSearchIndexError: Error, LocalizedError, Sendable, Equatable {
  case sqlite(context: String, code: Int32, message: String)
  case unsupportedSchemaVersion(Int)
  case invalidDatabaseState

  public var errorDescription: String? {
    switch self {
    case .sqlite(let context, let code, let message):
      "Search index SQLite error during \(context) (\(code)): \(message)"
    case .unsupportedSchemaVersion(let version):
      "Unsupported search index schema version: \(version)"
    case .invalidDatabaseState:
      "Search index database could not be opened."
    }
  }
}

public enum ConversationSearchIndexPhase: String, Sendable, Equatable {
  case disabled
  case notBuilt
  case indexing
  case ready
  case stale
  case failed

  public var displayTitle: String {
    switch self {
    case .disabled: "Disabled"
    case .notBuilt: "Not Built"
    case .indexing: "Indexing"
    case .ready: "Ready"
    case .stale: "Stale"
    case .failed: "Failed"
    }
  }
}

public struct ConversationSearchIndexProgress: Sendable, Equatable {
  public var processed: Int
  public var total: Int

  public init(processed: Int, total: Int) {
    self.processed = processed
    self.total = total
  }
}

public struct ConversationSearchIndexStatistics: Sendable, Equatable {
  public var schemaVersion: Int
  public var tokenizer: String
  public var databasePath: String
  public var databaseExists: Bool
  public var isExcludedFromBackup: Bool
  public var databaseBytes: Int64
  public var walBytes: Int64
  public var shmBytes: Int64
  public var indexedConversationCount: Int
  public var indexedDocumentCount: Int
  public var indexedMessageCount: Int
  public var lastRebuildAt: Date?
  public var lastRebuildDurationMilliseconds: Double?
  public var lastIncrementalSyncAt: Date?
  public var lastQueryLatencyMilliseconds: Double?
  public var lastQueryHitCount: Int?
  public var consecutiveFailureCount: Int
  public var lastErrorDescription: String?
  public var lastErrorAt: Date?

  public var totalBytes: Int64 {
    databaseBytes + walBytes + shmBytes
  }

  public init(
    schemaVersion: Int = ConversationSearchIndexStore.currentSchemaVersion,
    tokenizer: String = ConversationSearchIndexStore.tokenizerSpecification,
    databasePath: String = "",
    databaseExists: Bool = false,
    isExcludedFromBackup: Bool = false,
    databaseBytes: Int64 = 0,
    walBytes: Int64 = 0,
    shmBytes: Int64 = 0,
    indexedConversationCount: Int = 0,
    indexedDocumentCount: Int = 0,
    indexedMessageCount: Int = 0,
    lastRebuildAt: Date? = nil,
    lastRebuildDurationMilliseconds: Double? = nil,
    lastIncrementalSyncAt: Date? = nil,
    lastQueryLatencyMilliseconds: Double? = nil,
    lastQueryHitCount: Int? = nil,
    consecutiveFailureCount: Int = 0,
    lastErrorDescription: String? = nil,
    lastErrorAt: Date? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.tokenizer = tokenizer
    self.databasePath = databasePath
    self.databaseExists = databaseExists
    self.isExcludedFromBackup = isExcludedFromBackup
    self.databaseBytes = databaseBytes
    self.walBytes = walBytes
    self.shmBytes = shmBytes
    self.indexedConversationCount = indexedConversationCount
    self.indexedDocumentCount = indexedDocumentCount
    self.indexedMessageCount = indexedMessageCount
    self.lastRebuildAt = lastRebuildAt
    self.lastRebuildDurationMilliseconds = lastRebuildDurationMilliseconds
    self.lastIncrementalSyncAt = lastIncrementalSyncAt
    self.lastQueryLatencyMilliseconds = lastQueryLatencyMilliseconds
    self.lastQueryHitCount = lastQueryHitCount
    self.consecutiveFailureCount = consecutiveFailureCount
    self.lastErrorDescription = lastErrorDescription
    self.lastErrorAt = lastErrorAt
  }
}

public struct ConversationSearchIndexStatus: Sendable, Equatable {
  public var isEnabled: Bool
  public var isConfigured: Bool
  public var phase: ConversationSearchIndexPhase
  public var progress: ConversationSearchIndexProgress?
  public var totalConversationCount: Int
  public var eligibleConversationCount: Int
  public var excludedEmptyChatCount: Int
  public var staleConversationCount: Int
  public var quarantinedShardCount: Int
  public var statistics: ConversationSearchIndexStatistics

  public init(
    isEnabled: Bool,
    isConfigured: Bool,
    phase: ConversationSearchIndexPhase,
    progress: ConversationSearchIndexProgress? = nil,
    totalConversationCount: Int,
    eligibleConversationCount: Int,
    excludedEmptyChatCount: Int,
    staleConversationCount: Int,
    quarantinedShardCount: Int,
    statistics: ConversationSearchIndexStatistics
  ) {
    self.isEnabled = isEnabled
    self.isConfigured = isConfigured
    self.phase = phase
    self.progress = progress
    self.totalConversationCount = totalConversationCount
    self.eligibleConversationCount = eligibleConversationCount
    self.excludedEmptyChatCount = excludedEmptyChatCount
    self.staleConversationCount = staleConversationCount
    self.quarantinedShardCount = quarantinedShardCount
    self.statistics = statistics
  }
}

public struct ConversationSearchQueryResult: Sendable, Equatable {
  public var results: [ConversationSearchResult]
  public var latencyMilliseconds: Double
  public var usedFTSIndex: Bool

  public init(
    results: [ConversationSearchResult],
    latencyMilliseconds: Double,
    usedFTSIndex: Bool
  ) {
    self.results = results
    self.latencyMilliseconds = latencyMilliseconds
    self.usedFTSIndex = usedFTSIndex
  }
}

/// Derived, rebuildable SQLite FTS5 index backed by authoritative JSON
/// conversation shards. Excluded from iCloud Backup and safe to drop/recreate
/// on corruption or schema upgrades.
public actor ConversationSearchIndexStore {
  public static let currentSchemaVersion = 1
  public static let tokenizerSpecification = "unicode61 remove_diacritics 2"
  public static let maxMessageMatchesPerConversation = 4

  private static let metadataLastRebuildAtKey = "last_rebuild_at"
  private static let metadataLastRebuildDurationMsKey = "last_rebuild_duration_ms"
  private static let metadataLastIncrementalSyncAtKey = "last_incremental_sync_at"
  private static let snippetStartMarker = "\u{001E}"
  private static let snippetEndMarker = "\u{001F}"

  public let databaseURL: URL

  private var connection: OpaquePointer?
  private var lastQueryLatencyMilliseconds: Double?
  private var lastQueryHitCount: Int?
  private var consecutiveFailureCount = 0
  private var lastErrorDescription: String?
  private var lastErrorAt: Date?

  public init(databaseURL: URL) {
    self.databaseURL = databaseURL
  }

  public func close() {
    closeConnection()
  }

  /// Returns `conversation_id -> signature` for every indexed conversation
  /// without creating the database file if it does not exist yet.
  public func indexedSignaturesIfPresent() -> [String: String] {
    guard FileManager.default.fileExists(atPath: databaseURL.path) else { return [:] }
    do {
      let db = try database()
      return try readIndexedSignatures(on: db)
    } catch {
      recordFailure(error)
      return [:]
    }
  }

  public func upsertConversations(
    _ items: [(conversation: ChatConversation, signature: String)],
    markIncrementalSync: Bool = true
  ) throws {
    guard !items.isEmpty else { return }
    do {
      let db = try database()
      try execute("BEGIN IMMEDIATE;", on: db, context: "begin upsert batch")
      do {
        for item in items {
          try replaceConversationRows(
            item.conversation,
            signature: item.signature,
            on: db
          )
        }
        if markIncrementalSync {
          try writeMetadata(
            Self.metadataLastIncrementalSyncAtKey,
            value: String(Date.now.timeIntervalSince1970),
            on: db
          )
        }
        try execute("COMMIT;", on: db, context: "commit upsert batch")
      } catch {
        try? execute("ROLLBACK;", on: db, context: "rollback upsert batch")
        throw error
      }
      clearFailureState()
    } catch {
      recordFailure(error)
      throw error
    }
  }

  public func removeConversations(_ ids: [ConversationID]) throws {
    guard !ids.isEmpty else { return }
    guard FileManager.default.fileExists(atPath: databaseURL.path) || connection != nil else {
      return
    }
    do {
      let db = try database()
      try execute("BEGIN IMMEDIATE;", on: db, context: "begin remove conversations")
      do {
        for id in ids {
          try deleteConversationRows(id.rawValue, on: db)
        }
        try writeMetadata(
          Self.metadataLastIncrementalSyncAtKey,
          value: String(Date.now.timeIntervalSince1970),
          on: db
        )
        try execute("COMMIT;", on: db, context: "commit remove conversations")
      } catch {
        try? execute("ROLLBACK;", on: db, context: "rollback remove conversations")
        throw error
      }
      clearFailureState()
    } catch {
      recordFailure(error)
      throw error
    }
  }

  public func resetForRebuild() throws {
    do {
      closeConnection()
      try removeDatabaseFiles()
      _ = try database()
      clearFailureState()
    } catch {
      recordFailure(error)
      throw error
    }
  }

  public func recordRebuildCompleted(durationMilliseconds: Double, at date: Date = .now) throws {
    do {
      let db = try database()
      try execute("BEGIN IMMEDIATE;", on: db, context: "begin rebuild metadata")
      do {
        try writeMetadata(
          Self.metadataLastRebuildAtKey,
          value: String(date.timeIntervalSince1970),
          on: db
        )
        try writeMetadata(
          Self.metadataLastRebuildDurationMsKey,
          value: String(durationMilliseconds),
          on: db
        )
        try writeMetadata(
          Self.metadataLastIncrementalSyncAtKey,
          value: String(date.timeIntervalSince1970),
          on: db
        )
        try execute("COMMIT;", on: db, context: "commit rebuild metadata")
      } catch {
        try? execute("ROLLBACK;", on: db, context: "rollback rebuild metadata")
        throw error
      }
      try? execute("PRAGMA wal_checkpoint(PASSIVE);", on: db, context: "checkpoint after rebuild")
      clearFailureState()
    } catch {
      recordFailure(error)
      throw error
    }
  }

  public func clearIndex() throws {
    closeConnection()
    try removeDatabaseFiles()
    lastQueryLatencyMilliseconds = nil
    lastQueryHitCount = nil
    clearFailureState()
  }

  public func search(
    _ rawQuery: String,
    limit: Int = 100
  ) throws -> ConversationSearchQueryResult {
    let startedAt = ContinuousClock.now
    guard let matchExpression = Self.ftsMatchExpression(for: rawQuery) else {
      return ConversationSearchQueryResult(
        results: [],
        latencyMilliseconds: 0,
        usedFTSIndex: true
      )
    }
    guard FileManager.default.fileExists(atPath: databaseURL.path) || connection != nil else {
      return ConversationSearchQueryResult(
        results: [],
        latencyMilliseconds: 0,
        usedFTSIndex: true
      )
    }

    let safeLimit = max(1, limit)
    let fetchLimit = min(max(safeLimit * 4, 100), 600)

    do {
      let db = try database()
      let sql = """
        SELECT
          conversation_id,
          message_id,
          role,
          updated_at,
          conversation_title,
          snippet(search_documents_fts, 6, '\(Self.snippetStartMarker)', '\(Self.snippetEndMarker)', '…', 24),
          attachment_names,
          bm25(search_documents_fts)
        FROM search_documents_fts
        WHERE search_documents_fts MATCH ?
        ORDER BY
          CASE WHEN role = 'title' THEN 0 ELSE 1 END ASC,
          bm25(search_documents_fts) ASC,
          updated_at DESC
        LIMIT ?;
        """

      let statement = try prepare(sql, on: db)
      defer { sqlite3_finalize(statement) }
      try bind(matchExpression, at: 1, to: statement, on: db)
      try bind(fetchLimit, at: 2, to: statement, on: db)

      let queryTokens = Self.queryTokens(for: rawQuery)
      var results: [ConversationSearchResult] = []
      results.reserveCapacity(min(safeLimit, 32))
      var messageHitsByConversation: [String: Int] = [:]

      while true {
        let stepResult = sqlite3_step(statement)
        if stepResult == SQLITE_DONE { break }
        guard stepResult == SQLITE_ROW else {
          throw sqliteError(db, context: "fts search", code: stepResult)
        }

        guard
          let conversationIDRaw = textColumn(statement, index: 0),
          let roleRaw = textColumn(statement, index: 2),
          let role = ConversationSearchMatchRole(rawValue: roleRaw),
          let title = textColumn(statement, index: 4)
        else { continue }

        let messageIDRaw = textColumn(statement, index: 1) ?? ""
        let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
        let rawBodySnippet = textColumn(statement, index: 5) ?? ""
        let attachmentNames = textColumn(statement, index: 6) ?? ""

        if role != .title {
          let existingHits = messageHitsByConversation[conversationIDRaw, default: 0]
          if existingHits >= Self.maxMessageMatchesPerConversation {
            continue
          }
          messageHitsByConversation[conversationIDRaw] = existingHits + 1
        }

        let snippet: String
        if role == .title {
          snippet = title
        } else if rawBodySnippet.contains(Self.snippetStartMarker) {
          snippet = Self.cleanedSnippet(rawBodySnippet)
        } else if !attachmentNames.isEmpty {
          let matchedFilename = Self.firstMatchingAttachmentName(
            in: attachmentNames,
            tokens: queryTokens
          )
          snippet = "Attachment: \(matchedFilename)"
        } else {
          snippet = Self.cleanedSnippet(rawBodySnippet)
        }

        results.append(
          ConversationSearchResult(
            conversationID: ConversationID(rawValue: conversationIDRaw),
            messageID: messageIDRaw.isEmpty ? nil : ChatMessageID(rawValue: messageIDRaw),
            role: role,
            title: title,
            snippet: snippet,
            updatedAt: updatedAt
          )
        )
        if results.count >= safeLimit { break }
      }

      let elapsed = startedAt.duration(to: .now)
      let latencyMs = Self.milliseconds(from: elapsed)
      lastQueryLatencyMilliseconds = latencyMs
      lastQueryHitCount = results.count
      clearFailureState()
      return ConversationSearchQueryResult(
        results: results,
        latencyMilliseconds: latencyMs,
        usedFTSIndex: true
      )
    } catch {
      recordFailure(error)
      throw error
    }
  }

  public func statistics() -> ConversationSearchIndexStatistics {
    let exists = FileManager.default.fileExists(atPath: databaseURL.path)
    let directory = databaseURL.deletingLastPathComponent()
    let excluded = (try? directory.resourceValues(forKeys: [.isExcludedFromBackupKey]))?
      .isExcludedFromBackup ?? false
    let dbBytes = Self.fileBytes(atPath: databaseURL.path)
    let walBytes = Self.fileBytes(atPath: databaseURL.path + "-wal")
    let shmBytes = Self.fileBytes(atPath: databaseURL.path + "-shm")

    guard exists else {
      return ConversationSearchIndexStatistics(
        schemaVersion: Self.currentSchemaVersion,
        tokenizer: Self.tokenizerSpecification,
        databasePath: databaseURL.path,
        databaseExists: false,
        isExcludedFromBackup: excluded,
        databaseBytes: dbBytes,
        walBytes: walBytes,
        shmBytes: shmBytes,
        indexedConversationCount: 0,
        indexedDocumentCount: 0,
        indexedMessageCount: 0,
        lastRebuildAt: nil,
        lastRebuildDurationMilliseconds: nil,
        lastIncrementalSyncAt: nil,
        lastQueryLatencyMilliseconds: lastQueryLatencyMilliseconds,
        lastQueryHitCount: lastQueryHitCount,
        consecutiveFailureCount: consecutiveFailureCount,
        lastErrorDescription: lastErrorDescription,
        lastErrorAt: lastErrorAt
      )
    }

    do {
      let db = try database()
      let schemaVer = (try? schemaVersion(on: db)) ?? Self.currentSchemaVersion
      let conversationCount = (try? scalarInt("SELECT COUNT(*) FROM indexed_conversations;", on: db)) ?? 0
      let documentCount = (try? scalarInt("SELECT COUNT(*) FROM conversation_doc_rowids;", on: db)) ?? 0
      let messageCount = max(0, documentCount - conversationCount)
      let lastRebuildAt = (try? readMetadata(Self.metadataLastRebuildAtKey, on: db))
        .flatMap(Double.init)
        .map { Date(timeIntervalSince1970: $0) }
      let lastRebuildDuration = (try? readMetadata(Self.metadataLastRebuildDurationMsKey, on: db))
        .flatMap(Double.init)
      let lastSyncAt = (try? readMetadata(Self.metadataLastIncrementalSyncAtKey, on: db))
        .flatMap(Double.init)
        .map { Date(timeIntervalSince1970: $0) }

      return ConversationSearchIndexStatistics(
        schemaVersion: schemaVer,
        tokenizer: Self.tokenizerSpecification,
        databasePath: databaseURL.path,
        databaseExists: true,
        isExcludedFromBackup: excluded,
        databaseBytes: dbBytes,
        walBytes: walBytes,
        shmBytes: shmBytes,
        indexedConversationCount: conversationCount,
        indexedDocumentCount: documentCount,
        indexedMessageCount: messageCount,
        lastRebuildAt: lastRebuildAt,
        lastRebuildDurationMilliseconds: lastRebuildDuration,
        lastIncrementalSyncAt: lastSyncAt,
        lastQueryLatencyMilliseconds: lastQueryLatencyMilliseconds,
        lastQueryHitCount: lastQueryHitCount,
        consecutiveFailureCount: consecutiveFailureCount,
        lastErrorDescription: lastErrorDescription,
        lastErrorAt: lastErrorAt
      )
    } catch {
      recordFailure(error)
      return ConversationSearchIndexStatistics(
        schemaVersion: Self.currentSchemaVersion,
        tokenizer: Self.tokenizerSpecification,
        databasePath: databaseURL.path,
        databaseExists: exists,
        isExcludedFromBackup: excluded,
        databaseBytes: dbBytes,
        walBytes: walBytes,
        shmBytes: shmBytes,
        indexedConversationCount: 0,
        indexedDocumentCount: 0,
        indexedMessageCount: 0,
        lastRebuildAt: nil,
        lastRebuildDurationMilliseconds: nil,
        lastIncrementalSyncAt: nil,
        lastQueryLatencyMilliseconds: lastQueryLatencyMilliseconds,
        lastQueryHitCount: lastQueryHitCount,
        consecutiveFailureCount: consecutiveFailureCount,
        lastErrorDescription: lastErrorDescription,
        lastErrorAt: lastErrorAt
      )
    }
  }

  // MARK: - Query Normalization

  public static func queryTokens(for rawQuery: String) -> [String] {
    var tokens: [String] = []
    var current = ""
    for character in rawQuery {
      if character.isLetter || character.isNumber {
        current.append(character)
      } else if !current.isEmpty {
        tokens.append(current)
        current = ""
      }
    }
    if !current.isEmpty {
      tokens.append(current)
    }
    return tokens
  }

  /// Escapes arbitrary user input into a safe FTS5 MATCH expression with
  /// implicit AND across terms and prefix matching on every token.
  public static func ftsMatchExpression(for rawQuery: String) -> String? {
    let tokens = queryTokens(for: rawQuery)
    guard !tokens.isEmpty else { return nil }
    return tokens.map { token in
      let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
      return "\"\(escaped)\"*"
    }.joined(separator: " ")
  }

  static func isIndexableMessage(_ message: ChatMessage) -> Bool {
    switch message.status {
    case .complete, .cancelled, .interrupted:
      break
    case .pending, .streaming, .failed:
      return false
    }
    let hasBody = !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let hasAttachment = !(message.attachments ?? []).isEmpty
    return hasBody || hasAttachment
  }

  private static func cleanedSnippet(_ raw: String) -> String {
    raw
      .replacingOccurrences(of: snippetStartMarker, with: "")
      .replacingOccurrences(of: snippetEndMarker, with: "")
      .replacingOccurrences(of: "\r\n", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
  }

  private static func firstMatchingAttachmentName(
    in joinedNames: String,
    tokens: [String]
  ) -> String {
    let names = joinedNames.components(separatedBy: "\n").filter { !$0.isEmpty }
    guard !names.isEmpty else { return joinedNames }
    for name in names {
      if tokens.allSatisfy({
        name.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
      }) {
        return name
      }
    }
    for name in names {
      if tokens.contains(where: {
        name.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
      }) {
        return name
      }
    }
    return names[0]
  }

  private static func milliseconds(from duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1_000.0
      + Double(components.attoseconds) / 1_000_000_000_000_000.0
  }

  // MARK: - Internal SQLite Operations

  private func replaceConversationRows(
    _ conversation: ChatConversation,
    signature: String,
    on database: OpaquePointer
  ) throws {
    let conversationID = conversation.id.rawValue
    try deleteConversationRows(conversationID, on: database)

    let insertFTSSQL = """
      INSERT INTO search_documents_fts (
        conversation_id, message_id, role, updated_at, conversation_title,
        title, body, attachment_names
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
      """
    let ftsStmt = try prepare(insertFTSSQL, on: database)
    defer { sqlite3_finalize(ftsStmt) }

    let insertRowIDSQL = """
      INSERT INTO conversation_doc_rowids (conversation_id, doc_rowid)
      VALUES (?, ?);
      """
    let rowIDStmt = try prepare(insertRowIDSQL, on: database)
    defer { sqlite3_finalize(rowIDStmt) }

    // 1. Conversation title row.
    try bind(conversationID, at: 1, to: ftsStmt, on: database)
    try bind("", at: 2, to: ftsStmt, on: database)
    try bind(ConversationSearchMatchRole.title.rawValue, at: 3, to: ftsStmt, on: database)
    try bind(conversation.updatedAt.timeIntervalSince1970, at: 4, to: ftsStmt, on: database)
    try bind(conversation.title, at: 5, to: ftsStmt, on: database)
    try bind(conversation.title, at: 6, to: ftsStmt, on: database)
    try bind("", at: 7, to: ftsStmt, on: database)
    try bind("", at: 8, to: ftsStmt, on: database)
    try stepDone(ftsStmt, on: database, context: "insert title fts row")

    let titleRowID = sqlite3_last_insert_rowid(database)
    try bind(conversationID, at: 1, to: rowIDStmt, on: database)
    try bind(titleRowID, at: 2, to: rowIDStmt, on: database)
    try stepDone(rowIDStmt, on: database, context: "insert title rowid mapping")

    // 2. Indexable message rows (content + attachment filenames; reasoning excluded).
    for message in conversation.messages where Self.isIndexableMessage(message) {
      sqlite3_reset(ftsStmt)
      sqlite3_clear_bindings(ftsStmt)
      sqlite3_reset(rowIDStmt)
      sqlite3_clear_bindings(rowIDStmt)

      let roleValue: ConversationSearchMatchRole = message.role == .user ? .user : .assistant
      let attachmentNames = (message.attachments ?? [])
        .map(\.filename)
        .filter { !$0.isEmpty }
        .joined(separator: "\n")

      try bind(conversationID, at: 1, to: ftsStmt, on: database)
      try bind(message.id.rawValue, at: 2, to: ftsStmt, on: database)
      try bind(roleValue.rawValue, at: 3, to: ftsStmt, on: database)
      try bind(message.updatedAt.timeIntervalSince1970, at: 4, to: ftsStmt, on: database)
      try bind(conversation.title, at: 5, to: ftsStmt, on: database)
      try bind("", at: 6, to: ftsStmt, on: database)
      try bind(message.content, at: 7, to: ftsStmt, on: database)
      try bind(attachmentNames, at: 8, to: ftsStmt, on: database)
      try stepDone(ftsStmt, on: database, context: "insert message fts row")

      let messageRowID = sqlite3_last_insert_rowid(database)
      try bind(conversationID, at: 1, to: rowIDStmt, on: database)
      try bind(messageRowID, at: 2, to: rowIDStmt, on: database)
      try stepDone(rowIDStmt, on: database, context: "insert message rowid mapping")
    }

    // 3. Upsert freshness metadata.
    let metaSQL = """
      INSERT OR REPLACE INTO indexed_conversations (
        conversation_id, title, updated_at, message_count, signature, indexed_at
      ) VALUES (?, ?, ?, ?, ?, ?);
      """
    let metaStmt = try prepare(metaSQL, on: database)
    defer { sqlite3_finalize(metaStmt) }
    try bind(conversationID, at: 1, to: metaStmt, on: database)
    try bind(conversation.title, at: 2, to: metaStmt, on: database)
    try bind(conversation.updatedAt.timeIntervalSince1970, at: 3, to: metaStmt, on: database)
    try bind(conversation.messages.count, at: 4, to: metaStmt, on: database)
    try bind(signature, at: 5, to: metaStmt, on: database)
    try bind(Date.now.timeIntervalSince1970, at: 6, to: metaStmt, on: database)
    try stepDone(metaStmt, on: database, context: "upsert indexed_conversations")
  }

  private func deleteConversationRows(
    _ conversationID: String,
    on database: OpaquePointer
  ) throws {
    let deleteFTSSQL = """
      DELETE FROM search_documents_fts
      WHERE rowid IN (
        SELECT doc_rowid FROM conversation_doc_rowids WHERE conversation_id = ?
      );
      """
    let deleteFTSStmt = try prepare(deleteFTSSQL, on: database)
    defer { sqlite3_finalize(deleteFTSStmt) }
    try bind(conversationID, at: 1, to: deleteFTSStmt, on: database)
    try stepDone(deleteFTSStmt, on: database, context: "delete conversation fts rows")

    let deleteMapStmt = try prepare(
      "DELETE FROM conversation_doc_rowids WHERE conversation_id = ?;",
      on: database
    )
    defer { sqlite3_finalize(deleteMapStmt) }
    try bind(conversationID, at: 1, to: deleteMapStmt, on: database)
    try stepDone(deleteMapStmt, on: database, context: "delete conversation rowid mappings")

    let deleteMetaStmt = try prepare(
      "DELETE FROM indexed_conversations WHERE conversation_id = ?;",
      on: database
    )
    defer { sqlite3_finalize(deleteMetaStmt) }
    try bind(conversationID, at: 1, to: deleteMetaStmt, on: database)
    try stepDone(deleteMetaStmt, on: database, context: "delete indexed conversation metadata")
  }

  private func readIndexedSignatures(on database: OpaquePointer) throws -> [String: String] {
    let statement = try prepare(
      "SELECT conversation_id, signature FROM indexed_conversations;",
      on: database
    )
    defer { sqlite3_finalize(statement) }

    var signatures: [String: String] = [:]
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { break }
      guard result == SQLITE_ROW else {
        throw sqliteError(database, context: "read indexed signatures", code: result)
      }
      if let id = textColumn(statement, index: 0),
        let signature = textColumn(statement, index: 1)
      {
        signatures[id] = signature
      }
    }
    return signatures
  }

  private func readMetadata(_ key: String, on database: OpaquePointer) throws -> String? {
    let statement = try prepare(
      "SELECT value FROM search_index_metadata WHERE key = ?;",
      on: database
    )
    defer { sqlite3_finalize(statement) }
    try bind(key, at: 1, to: statement, on: database)
    let result = sqlite3_step(statement)
    if result == SQLITE_DONE { return nil }
    guard result == SQLITE_ROW else {
      throw sqliteError(database, context: "read search metadata", code: result)
    }
    return textColumn(statement, index: 0)
  }

  private func writeMetadata(
    _ key: String,
    value: String,
    on database: OpaquePointer
  ) throws {
    let statement = try prepare(
      "INSERT OR REPLACE INTO search_index_metadata (key, value) VALUES (?, ?);",
      on: database
    )
    defer { sqlite3_finalize(statement) }
    try bind(key, at: 1, to: statement, on: database)
    try bind(value, at: 2, to: statement, on: database)
    try stepDone(statement, on: database, context: "write search metadata")
  }

  // MARK: - Connection & Schema Management

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
    guard let storeError = error as? ConversationSearchIndexError else { return false }
    switch storeError {
    case .invalidDatabaseState, .unsupportedSchemaVersion:
      return true
    case .sqlite(_, let code, _):
      return code == SQLITE_CORRUPT || code == SQLITE_NOTADB
    }
  }

  private func openConfiguredDatabase() throws -> OpaquePointer {
    try ensureDatabaseDirectory()

    var db: OpaquePointer?
    let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
    let result = sqlite3_open_v2(databaseURL.path, &db, flags, nil)
    guard result == SQLITE_OK, let db else {
      let message = db.map { String(cString: sqlite3_errmsg($0)) }
        ?? "SQLite returned no database handle"
      if let db { sqlite3_close(db) }
      throw ConversationSearchIndexError.sqlite(context: "open", code: result, message: message)
    }

    do {
      sqlite3_busy_timeout(db, 1_500)
      try execute("PRAGMA journal_mode = WAL;", on: db, context: "enable WAL")
      try execute("PRAGMA synchronous = NORMAL;", on: db, context: "set synchronous mode")
      try execute("PRAGMA temp_store = MEMORY;", on: db, context: "set temp store")
      try migrateIfNeeded(on: db)
      try validateSchema(on: db)
      return db
    } catch {
      sqlite3_close(db)
      throw error
    }
  }

  private func migrateIfNeeded(on database: OpaquePointer) throws {
    var version = try schemaVersion(on: database)
    guard version <= Self.currentSchemaVersion else {
      throw ConversationSearchIndexError.unsupportedSchemaVersion(version)
    }

    while version < Self.currentSchemaVersion {
      switch version {
      case 0:
        try createSchemaV1(on: database)
        version = 1
      default:
        throw ConversationSearchIndexError.unsupportedSchemaVersion(version)
      }
    }
  }

  private func createSchemaV1(on database: OpaquePointer) throws {
    try execute(
      """
      CREATE TABLE IF NOT EXISTS indexed_conversations (
        conversation_id TEXT PRIMARY KEY NOT NULL,
        title TEXT NOT NULL,
        updated_at REAL NOT NULL,
        message_count INTEGER NOT NULL,
        signature TEXT NOT NULL,
        indexed_at REAL NOT NULL
      );

      CREATE TABLE IF NOT EXISTS conversation_doc_rowids (
        conversation_id TEXT NOT NULL,
        doc_rowid INTEGER NOT NULL,
        PRIMARY KEY (conversation_id, doc_rowid)
      );

      CREATE TABLE IF NOT EXISTS search_index_metadata (
        key TEXT PRIMARY KEY NOT NULL,
        value TEXT NOT NULL
      );

      CREATE VIRTUAL TABLE IF NOT EXISTS search_documents_fts USING fts5(
        conversation_id UNINDEXED,
        message_id UNINDEXED,
        role UNINDEXED,
        updated_at UNINDEXED,
        conversation_title UNINDEXED,
        title,
        body,
        attachment_names,
        tokenize='\(Self.tokenizerSpecification)'
      );

      PRAGMA user_version = 1;
      """,
      on: database,
      context: "create search index schema v1"
    )
  }

  private func validateSchema(on database: OpaquePointer) throws {
    guard try schemaVersion(on: database) == Self.currentSchemaVersion else {
      throw ConversationSearchIndexError.invalidDatabaseState
    }
    let metaColumns = try tableColumns("indexed_conversations", on: database)
    let mapColumns = try tableColumns("conversation_doc_rowids", on: database)
    let ftsColumns = try tableColumns("search_documents_fts", on: database)
    guard
      metaColumns.contains("signature"),
      mapColumns.contains("doc_rowid"),
      ftsColumns.contains("body"),
      ftsColumns.contains("attachment_names")
    else {
      throw ConversationSearchIndexError.invalidDatabaseState
    }
  }

  private func tableColumns(_ table: String, on database: OpaquePointer) throws -> Set<String> {
    let statement = try prepare("PRAGMA table_info(\(table));", on: database)
    defer { sqlite3_finalize(statement) }
    var columns: Set<String> = []
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { break }
      guard result == SQLITE_ROW else {
        throw sqliteError(database, context: "validate search schema", code: result)
      }
      if let name = textColumn(statement, index: 1) {
        columns.insert(name)
      }
    }
    return columns
  }

  private func schemaVersion(on database: OpaquePointer) throws -> Int {
    try scalarInt("PRAGMA user_version;", on: database)
  }

  private func scalarInt(_ sql: String, on database: OpaquePointer) throws -> Int {
    let statement = try prepare(sql, on: database)
    defer { sqlite3_finalize(statement) }
    let result = sqlite3_step(statement)
    guard result == SQLITE_ROW else {
      throw sqliteError(database, context: "scalar int", code: result)
    }
    return Int(sqlite3_column_int64(statement, 0))
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

  private func closeConnection() {
    guard let connection else { return }
    sqlite3_close(connection)
    self.connection = nil
  }

  private func recordFailure(_ error: any Error) {
    consecutiveFailureCount += 1
    lastErrorDescription = error.localizedDescription
    lastErrorAt = .now
  }

  private func clearFailureState() {
    consecutiveFailureCount = 0
    lastErrorDescription = nil
    lastErrorAt = nil
  }

  private static func fileBytes(atPath path: String) -> Int64 {
    guard
      let attributes = try? FileManager.default.attributesOfItem(atPath: path),
      let size = attributes[.size] as? NSNumber
    else {
      return 0
    }
    return size.int64Value
  }

  // MARK: - Low-Level SQLite Helpers

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
      throw ConversationSearchIndexError.sqlite(context: context, code: result, message: message)
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
    _ value: String,
    at index: Int32,
    to statement: OpaquePointer,
    on database: OpaquePointer
  ) throws {
    let result = value.withCString {
      sqlite3_bind_text(statement, index, $0, -1, searchSQLiteTransientDestructor())
    }
    guard result == SQLITE_OK else {
      throw sqliteError(database, context: "bind text", code: result)
    }
  }

  private func bind(
    _ value: Double,
    at index: Int32,
    to statement: OpaquePointer,
    on database: OpaquePointer
  ) throws {
    let result = sqlite3_bind_double(statement, index, value)
    guard result == SQLITE_OK else {
      throw sqliteError(database, context: "bind double", code: result)
    }
  }

  private func bind(
    _ value: Int,
    at index: Int32,
    to statement: OpaquePointer,
    on database: OpaquePointer
  ) throws {
    let result = sqlite3_bind_int64(statement, index, sqlite3_int64(value))
    guard result == SQLITE_OK else {
      throw sqliteError(database, context: "bind int", code: result)
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

  private func textColumn(_ statement: OpaquePointer, index: Int32) -> String? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL,
      let pointer = sqlite3_column_text(statement, index)
    else {
      return nil
    }
    let cString = UnsafeRawPointer(pointer).assumingMemoryBound(to: CChar.self)
    return String(cString: cString)
  }

  private func sqliteError(
    _ database: OpaquePointer,
    context: String,
    code: Int32
  ) -> ConversationSearchIndexError {
    ConversationSearchIndexError.sqlite(
      context: context,
      code: code,
      message: String(cString: sqlite3_errmsg(database))
    )
  }
}

private func searchSQLiteTransientDestructor() -> sqlite3_destructor_type {
  unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
