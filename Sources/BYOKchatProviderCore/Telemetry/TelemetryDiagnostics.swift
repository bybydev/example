import Foundation

public struct TelemetryLogFilter: Sendable, Equatable {
  public var dataClass: TelemetryDataClass?
  public var category: TelemetryCategory?
  public var severity: TelemetrySeverity?
  public var providerID: ProviderID?
  public var modelID: ModelID?
  public var conversationID: ConversationID?
  public var searchText: String

  public init(
    dataClass: TelemetryDataClass? = nil,
    category: TelemetryCategory? = nil,
    severity: TelemetrySeverity? = nil,
    providerID: ProviderID? = nil,
    modelID: ModelID? = nil,
    conversationID: ConversationID? = nil,
    searchText: String = ""
  ) {
    self.dataClass = dataClass
    self.category = category
    self.severity = severity
    self.providerID = providerID
    self.modelID = modelID
    self.conversationID = conversationID
    self.searchText = searchText
  }

  public func matches(_ event: TelemetryEvent) -> Bool {
    if let dataClass, event.dataClass != dataClass { return false }
    if let category, event.category != category { return false }
    if let severity, event.severity != severity { return false }
    if let providerID, event.providerID != providerID { return false }
    if let modelID, event.modelID != modelID { return false }
    if let conversationID, event.conversationID != conversationID { return false }

    let query = Self.normalizedSearchText(searchText)
    guard !query.isEmpty else { return true }

    var searchable = [
      event.name.rawValue,
      event.dataClass.rawValue,
      event.category.rawValue,
      event.severity.rawValue,
      event.outcome?.rawValue,
      event.providerID?.rawValue,
      event.accountID?.rawValue,
      event.modelID?.rawValue,
      event.conversationID?.rawValue,
      event.messageID?.rawValue,
      event.errorCode,
    ].compactMap { $0 }

    for (key, value) in event.metadata {
      searchable.append(key)
      searchable.append(value)
    }
    return searchable.contains { Self.normalizedSearchText($0).contains(query) }
  }

  private static func normalizedSearchText(_ value: String) -> String {
    value
      .lowercased()
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
      .replacingOccurrences(of: ".", with: " ")
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
  }
}

public enum TelemetryDiagnostics {
  public static func filtered(
    events: [TelemetryEvent],
    filter: TelemetryLogFilter
  ) -> [TelemetryEvent] {
    events.filter(filter.matches)
  }

  public static func exportJSON(
    events: [TelemetryEvent],
    generatedAt: Date = .now
  ) throws -> Data {
    let sanitized = events.map(TelemetryPrivacy.sanitize)
    let envelope = ExportEnvelope(
      generatedAt: generatedAt,
      eventCount: sanitized.count,
      events: sanitized.map(ExportEvent.init)
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(envelope)
  }

  public static func text(for event: TelemetryEvent) -> String {
    let event = TelemetryPrivacy.sanitize(event)
    var lines = [
      ISO8601DateFormatter().string(from: event.timestamp),
      "\(event.severity.rawValue.uppercased()) · \(event.category.rawValue) · \(event.name.rawValue)",
    ]
    if let outcome = event.outcome { lines.append("Outcome: \(outcome.rawValue)") }
    if let providerID = event.providerID { lines.append("Provider: \(providerID.rawValue)") }
    if let modelID = event.modelID { lines.append("Model: \(modelID.rawValue)") }
    if let conversationID = event.conversationID { lines.append("Conversation: \(conversationID.rawValue)") }
    if let messageID = event.messageID { lines.append("Message: \(messageID.rawValue)") }
    if let duration = event.durationMilliseconds { lines.append("Duration: \(format(duration)) ms") }
    if let ttft = event.timeToFirstTokenMilliseconds { lines.append("TTFT: \(format(ttft)) ms") }
    if let status = event.httpStatus { lines.append("HTTP: \(status)") }
    if let errorCode = event.errorCode { lines.append("Error: \(errorCode)") }
    if !event.metadata.isEmpty {
      lines.append("Metadata:")
      for key in event.metadata.keys.sorted() {
        if let value = event.metadata[key] { lines.append("  \(key): \(value)") }
      }
    }
    return lines.joined(separator: "\n")
  }

  private static func format(_ value: Double) -> String {
    String(format: "%.1f", value)
  }
}

private struct ExportEnvelope: Codable {
  var generatedAt: Date
  var eventCount: Int
  var events: [ExportEvent]
}

private struct ExportEvent: Codable {
  var id: String
  var timestamp: Date
  var dataClass: String
  var category: String
  var name: String
  var severity: String
  var outcome: String?
  var deviceID: String?
  var sessionID: String?
  var conversationID: String?
  var messageID: String?
  var providerID: String?
  var accountID: String?
  var modelID: String?
  var durationMilliseconds: Double?
  var timeToFirstTokenMilliseconds: Double?
  var inputTokens: Int?
  var outputTokens: Int?
  var cachedInputTokens: Int?
  var reasoningTokens: Int?
  var modelRequestCount: Int?
  var toolCallCount: Int?
  var httpStatus: Int?
  var errorCode: String?
  var metadata: [String: String]

  init(_ event: TelemetryEvent) {
    id = event.id
    timestamp = event.timestamp
    dataClass = event.dataClass.rawValue
    category = event.category.rawValue
    name = event.name.rawValue
    severity = event.severity.rawValue
    outcome = event.outcome?.rawValue
    deviceID = event.deviceID
    sessionID = event.sessionID
    conversationID = event.conversationID?.rawValue
    messageID = event.messageID?.rawValue
    providerID = event.providerID?.rawValue
    accountID = event.accountID?.rawValue
    modelID = event.modelID?.rawValue
    durationMilliseconds = event.durationMilliseconds
    timeToFirstTokenMilliseconds = event.timeToFirstTokenMilliseconds
    inputTokens = event.inputTokens
    outputTokens = event.outputTokens
    cachedInputTokens = event.cachedInputTokens
    reasoningTokens = event.reasoningTokens
    modelRequestCount = event.modelRequestCount
    toolCallCount = event.toolCallCount
    httpStatus = event.httpStatus
    errorCode = event.errorCode
    metadata = event.metadata
  }
}
