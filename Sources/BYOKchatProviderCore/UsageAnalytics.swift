import Foundation

public enum UsageAnalyticsRange: String, CaseIterable, Hashable, Identifiable, Sendable {
  case today
  case sevenDays
  case thirtyDays
  case month
  case all

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .today: "Today"
    case .sevenDays: "7D"
    case .thirtyDays: "30D"
    case .month: "Month"
    case .all: "All"
    }
  }

  public func startDate(reference: Date) -> Date? {
    let calendar = Calendar.current
    switch self {
    case .today:
      return calendar.startOfDay(for: reference)
    case .sevenDays:
      return calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: reference))
    case .thirtyDays:
      return calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: reference))
    case .month:
      return calendar.date(from: calendar.dateComponents([.year, .month], from: reference))
    case .all:
      return nil
    }
  }
}

public struct UsageAnalyticsBreakdown: Identifiable, Sendable, Equatable {
  public let id: String
  public let aggregate: ChatUsageAggregate
  public let performance: TelemetryPerformanceAggregate

  public init(
    id: String,
    aggregate: ChatUsageAggregate,
    performance: TelemetryPerformanceAggregate
  ) {
    self.id = id
    self.aggregate = aggregate
    self.performance = performance
  }
}

public struct UsageAnalyticsSnapshot: Sendable, Equatable {
  public let aggregate: ChatUsageAggregate
  public let performance: TelemetryPerformanceAggregate
  public let failureBreakdown: [TelemetryFailureBreakdown]
  public let providerBreakdown: [UsageAnalyticsBreakdown]
  public let modelBreakdown: [UsageAnalyticsBreakdown]

  public init(
    aggregate: ChatUsageAggregate,
    performance: TelemetryPerformanceAggregate,
    failureBreakdown: [TelemetryFailureBreakdown],
    providerBreakdown: [UsageAnalyticsBreakdown],
    modelBreakdown: [UsageAnalyticsBreakdown]
  ) {
    self.aggregate = aggregate
    self.performance = performance
    self.failureBreakdown = failureBreakdown
    self.providerBreakdown = providerBreakdown
    self.modelBreakdown = modelBreakdown
  }
}

public struct ConversationUsageAnalyticsSnapshot: Sendable, Equatable {
  public let aggregate: ChatUsageAggregate
  public let performance: TelemetryPerformanceAggregate

  public init(
    aggregate: ChatUsageAggregate,
    performance: TelemetryPerformanceAggregate
  ) {
    self.aggregate = aggregate
    self.performance = performance
  }
}

public enum UsageAnalytics {
  public static func snapshot(
    conversations: [ChatConversation],
    telemetryEvents: [TelemetryEvent],
    range: UsageAnalyticsRange,
    reference: Date = .now
  ) -> UsageAnalyticsSnapshot {
    let messages = filteredMessages(
      conversations: conversations,
      range: range,
      reference: reference
    )
    let events = filteredAnalyticsEvents(
      telemetryEvents,
      range: range,
      reference: reference
    )

    return UsageAnalyticsSnapshot(
      aggregate: ChatBilling.aggregate(messages: messages),
      performance: TelemetryAnalytics.aggregate(events: events),
      failureBreakdown: TelemetryAnalytics.failureBreakdown(events: events),
      providerBreakdown: breakdown(
        messages: messages,
        events: events,
        messageKey: { $0.providerID?.rawValue },
        eventKey: { $0.providerID?.rawValue }
      ),
      modelBreakdown: breakdown(
        messages: messages,
        events: events,
        messageKey: { $0.modelID?.rawValue },
        eventKey: { $0.modelID?.rawValue }
      )
    )
  }

  public static func conversationSnapshot(
    conversation: ChatConversation,
    telemetryEvents: [TelemetryEvent],
    range: UsageAnalyticsRange,
    reference: Date = .now
  ) -> ConversationUsageAnalyticsSnapshot {
    let startDate = range.startDate(reference: reference)
    let messages = conversation.messages.filter { message in
      guard message.role == .assistant else { return false }
      guard let startDate else { return true }
      return message.updatedAt >= startDate
    }
    let events = filteredAnalyticsEvents(
      telemetryEvents,
      range: range,
      reference: reference
    ).filter { $0.conversationID == conversation.id }

    return ConversationUsageAnalyticsSnapshot(
      aggregate: ChatBilling.aggregate(messages: messages),
      performance: TelemetryAnalytics.aggregate(events: events)
    )
  }

  public static func filteredAnalyticsEvents(
    _ telemetryEvents: [TelemetryEvent],
    range: UsageAnalyticsRange,
    reference: Date = .now
  ) -> [TelemetryEvent] {
    let startDate = range.startDate(reference: reference)
    return telemetryEvents.filter { event in
      guard event.dataClass == .analytics else { return false }
      guard let startDate else { return true }
      return event.timestamp >= startDate
    }
  }

  public static func filteredMessages(
    conversations: [ChatConversation],
    range: UsageAnalyticsRange,
    reference: Date = .now
  ) -> [ChatMessage] {
    let startDate = range.startDate(reference: reference)
    return conversations.flatMap(\.messages).filter { message in
      guard message.role == .assistant else { return false }
      guard let startDate else { return true }
      return message.updatedAt >= startDate
    }
  }

  private static func breakdown(
    messages: [ChatMessage],
    events: [TelemetryEvent],
    messageKey: (ChatMessage) -> String?,
    eventKey: (TelemetryEvent) -> String?
  ) -> [UsageAnalyticsBreakdown] {
    var usageByKey: [String: ChatUsageAggregate] = [:]
    for message in messages {
      guard let key = messageKey(message), !key.isEmpty else { continue }
      var aggregate = usageByKey[key] ?? ChatUsageAggregate()
      aggregate.add(message)
      usageByKey[key] = aggregate
    }

    var eventsByKey: [String: [TelemetryEvent]] = [:]
    for event in events {
      guard let key = eventKey(event), !key.isEmpty else { continue }
      eventsByKey[key, default: []].append(event)
    }

    let keys = Set(usageByKey.keys).union(eventsByKey.keys)
    return keys.map { key in
      UsageAnalyticsBreakdown(
        id: key,
        aggregate: usageByKey[key] ?? ChatUsageAggregate(),
        performance: TelemetryAnalytics.aggregate(events: eventsByKey[key] ?? [])
      )
    }
    .sorted { lhs, rhs in
      if lhs.aggregate.costUSD != rhs.aggregate.costUSD {
        return lhs.aggregate.costUSD > rhs.aggregate.costUSD
      }
      let lhsTokens = lhs.aggregate.inputTokens + lhs.aggregate.outputTokens
      let rhsTokens = rhs.aggregate.inputTokens + rhs.aggregate.outputTokens
      if lhsTokens != rhsTokens { return lhsTokens > rhsTokens }
      return lhs.performance.providerRequestCount > rhs.performance.providerRequestCount
    }
  }
}
