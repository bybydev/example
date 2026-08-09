import Foundation

public enum TelemetryDataClass: String, Codable, Sendable, CaseIterable {
  case analytics
  case diagnostic
}

public enum TelemetryCategory: String, Codable, Sendable, CaseIterable {
  case app
  case chat
  case context
  case provider
  case tool
  case mcp
  case purchase
  case sync
  case storage
}

public enum TelemetrySeverity: String, Codable, Sendable, CaseIterable {
  case debug
  case info
  case notice
  case warning
  case error
}

public enum TelemetryOutcome: String, Codable, Sendable, CaseIterable {
  case success
  case failure
  case cancelled
  case interrupted
}

public struct TelemetryEventName: RawRepresentable, Hashable, Codable, Sendable,
  ExpressibleByStringLiteral, CustomStringConvertible
{
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(stringLiteral value: String) {
    self.rawValue = value
  }

  public var description: String { rawValue }

  public static let appLaunched: Self = "app.launched"

  public static let chatTurnStarted: Self = "chat.turn.started"
  public static let chatTurnCompleted: Self = "chat.turn.completed"
  public static let chatTurnFailed: Self = "chat.turn.failed"
  public static let chatTurnCancelled: Self = "chat.turn.cancelled"
  public static let chatTurnInterrupted: Self = "chat.turn.interrupted"

  public static let contextBuilt: Self = "context.built"

  public static let providerRequestStarted: Self = "provider.request.started"
  public static let providerFirstToken: Self = "provider.first_token"
  public static let providerRequestCompleted: Self = "provider.request.completed"
  public static let providerRequestFailed: Self = "provider.request.failed"
  public static let providerRequestCancelled: Self = "provider.request.cancelled"

  public static let toolCallStarted: Self = "tool.call.started"
  public static let toolCallCompleted: Self = "tool.call.completed"
  public static let toolCallFailed: Self = "tool.call.failed"

  public static let mcpRequestStarted: Self = "mcp.request.started"
  public static let mcpRequestCompleted: Self = "mcp.request.completed"
  public static let mcpRequestFailed: Self = "mcp.request.failed"

  public static let purchaseStarted: Self = "purchase.started"
  public static let purchaseCompleted: Self = "purchase.completed"
  public static let purchaseFailed: Self = "purchase.failed"

  public static let syncStarted: Self = "sync.started"
  public static let syncCompleted: Self = "sync.completed"
  public static let syncFailed: Self = "sync.failed"
}

public struct TelemetryEvent: Sendable, Equatable, Identifiable {
  public var id: String
  public var timestamp: Date
  public var dataClass: TelemetryDataClass
  public var category: TelemetryCategory
  public var name: TelemetryEventName
  public var severity: TelemetrySeverity
  public var outcome: TelemetryOutcome?

  public var deviceID: String?
  public var sessionID: String?
  public var conversationID: ConversationID?
  public var messageID: ChatMessageID?
  public var providerID: ProviderID?
  public var accountID: ProviderAccountID?
  public var modelID: ModelID?

  public var durationMilliseconds: Double?
  public var timeToFirstTokenMilliseconds: Double?
  public var inputTokens: Int?
  public var outputTokens: Int?
  public var cachedInputTokens: Int?
  public var reasoningTokens: Int?
  public var modelRequestCount: Int?
  public var toolCallCount: Int?
  public var httpStatus: Int?
  public var errorCode: String?
  public var metadata: [String: String]

  public init(
    id: String = UUID().uuidString.lowercased(),
    timestamp: Date = .now,
    dataClass: TelemetryDataClass,
    category: TelemetryCategory,
    name: TelemetryEventName,
    severity: TelemetrySeverity = .info,
    outcome: TelemetryOutcome? = nil,
    deviceID: String? = nil,
    sessionID: String? = nil,
    conversationID: ConversationID? = nil,
    messageID: ChatMessageID? = nil,
    providerID: ProviderID? = nil,
    accountID: ProviderAccountID? = nil,
    modelID: ModelID? = nil,
    durationMilliseconds: Double? = nil,
    timeToFirstTokenMilliseconds: Double? = nil,
    inputTokens: Int? = nil,
    outputTokens: Int? = nil,
    cachedInputTokens: Int? = nil,
    reasoningTokens: Int? = nil,
    modelRequestCount: Int? = nil,
    toolCallCount: Int? = nil,
    httpStatus: Int? = nil,
    errorCode: String? = nil,
    metadata: [String: String] = [:]
  ) {
    self.id = id
    self.timestamp = timestamp
    self.dataClass = dataClass
    self.category = category
    self.name = name
    self.severity = severity
    self.outcome = outcome
    self.deviceID = deviceID
    self.sessionID = sessionID
    self.conversationID = conversationID
    self.messageID = messageID
    self.providerID = providerID
    self.accountID = accountID
    self.modelID = modelID
    self.durationMilliseconds = durationMilliseconds
    self.timeToFirstTokenMilliseconds = timeToFirstTokenMilliseconds
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.cachedInputTokens = cachedInputTokens
    self.reasoningTokens = reasoningTokens
    self.modelRequestCount = modelRequestCount
    self.toolCallCount = toolCallCount
    self.httpStatus = httpStatus
    self.errorCode = errorCode
    self.metadata = metadata
  }
}
