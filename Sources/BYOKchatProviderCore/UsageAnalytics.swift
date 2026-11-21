import Foundation

public enum UsageAnalyticsRange: String, CaseIterable, Hashable, Identifiable, Sendable {
  case today
  case sevenDays
  case thirtyDays
  case month
  case all

  public var id: String { rawValue }

  /// All metrics are free for Today; historical ranges require Pro.
  public var requiresPro: Bool { self != .today }

  /// Clamp stale selections when an entitlement changes.
  public func accessible(hasPro: Bool) -> UsageAnalyticsRange {
    hasPro ? self : .today
  }

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

public struct ConversationUsageBreakdown: Identifiable, Sendable, Equatable {
  public let id: ConversationID
  public let title: String
  public let aggregate: ChatUsageAggregate
  public let performance: TelemetryPerformanceAggregate

  public init(
    id: ConversationID,
    title: String,
    aggregate: ChatUsageAggregate,
    performance: TelemetryPerformanceAggregate
  ) {
    self.id = id
    self.title = title
    self.aggregate = aggregate
    self.performance = performance
  }
}

public struct ConversationContextUsage: Sendable, Equatable {
  public let usedInputTokens: Int
  public let contextWindow: Int?
  public let omittedMessageCount: Int
  public let isEstimated: Bool

  public init(
    usedInputTokens: Int,
    contextWindow: Int?,
    omittedMessageCount: Int = 0,
    isEstimated: Bool = false
  ) {
    self.usedInputTokens = usedInputTokens
    self.contextWindow = contextWindow
    self.omittedMessageCount = omittedMessageCount
    self.isEstimated = isEstimated
  }

  public var fillFraction: Double? {
    guard let contextWindow, contextWindow > 0 else { return nil }
    return min(max(Double(usedInputTokens) / Double(contextWindow), 0), 1)
  }
}

public struct UsageAnalyticsSnapshot: Sendable, Equatable {
  public let aggregate: ChatUsageAggregate
  public let performance: TelemetryPerformanceAggregate
  public let failureBreakdown: [TelemetryFailureBreakdown]
  public let providerBreakdown: [UsageAnalyticsBreakdown]
  public let modelBreakdown: [UsageAnalyticsBreakdown]
  public let activeConversationCount: Int
  public let conversationBreakdown: [ConversationUsageBreakdown]

  public init(
    aggregate: ChatUsageAggregate,
    performance: TelemetryPerformanceAggregate,
    failureBreakdown: [TelemetryFailureBreakdown],
    providerBreakdown: [UsageAnalyticsBreakdown],
    modelBreakdown: [UsageAnalyticsBreakdown],
    activeConversationCount: Int = 0,
    conversationBreakdown: [ConversationUsageBreakdown] = []
  ) {
    self.aggregate = aggregate
    self.performance = performance
    self.failureBreakdown = failureBreakdown
    self.providerBreakdown = providerBreakdown
    self.modelBreakdown = modelBreakdown
    self.activeConversationCount = activeConversationCount
    self.conversationBreakdown = conversationBreakdown
  }
}

public struct ConversationUsageAnalyticsSnapshot: Sendable, Equatable {
  public let aggregate: ChatUsageAggregate
  public let performance: TelemetryPerformanceAggregate
  public let failureBreakdown: [TelemetryFailureBreakdown]
  public let providerBreakdown: [UsageAnalyticsBreakdown]
  public let modelBreakdown: [UsageAnalyticsBreakdown]

  public init(
    aggregate: ChatUsageAggregate,
    performance: TelemetryPerformanceAggregate,
    failureBreakdown: [TelemetryFailureBreakdown] = [],
    providerBreakdown: [UsageAnalyticsBreakdown] = [],
    modelBreakdown: [UsageAnalyticsBreakdown] = []
  ) {
    self.aggregate = aggregate
    self.performance = performance
    self.failureBreakdown = failureBreakdown
    self.providerBreakdown = providerBreakdown
    self.modelBreakdown = modelBreakdown
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

    let startDate = range.startDate(reference: reference)
    let eventsByConversation = Dictionary(grouping: events.compactMap { event -> (ConversationID, TelemetryEvent)? in
      guard let conversationID = event.conversationID else { return nil }
      return (conversationID, event)
    }, by: \.0).mapValues { $0.map(\.1) }

    let conversationsInRange: [ConversationUsageBreakdown] = conversations.compactMap { conversation in
      let convMessages = conversation.messages.filter { message in
        guard message.role == .assistant else { return false }
        guard let startDate else { return true }
        return message.updatedAt >= startDate
      }
      let aggregate = ChatBilling.aggregate(messages: convMessages)
      let performance = TelemetryAnalytics.aggregate(events: eventsByConversation[conversation.id] ?? [])
      guard aggregate.assistantMessageCount > 0 || performance.providerRequestCount > 0 else {
        return nil
      }
      let trimmedTitle = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
      return ConversationUsageBreakdown(
        id: conversation.id,
        title: trimmedTitle.isEmpty ? "Untitled Chat" : trimmedTitle,
        aggregate: aggregate,
        performance: performance
      )
    }
    .sorted { lhs, rhs in
      if lhs.aggregate.costUSD != rhs.aggregate.costUSD {
        return lhs.aggregate.costUSD > rhs.aggregate.costUSD
      }
      if lhs.aggregate.totalTokens != rhs.aggregate.totalTokens {
        return lhs.aggregate.totalTokens > rhs.aggregate.totalTokens
      }
      if lhs.performance.providerRequestCount != rhs.performance.providerRequestCount {
        return lhs.performance.providerRequestCount > rhs.performance.providerRequestCount
      }
      if lhs.title != rhs.title {
        return lhs.title < rhs.title
      }
      return lhs.id.rawValue < rhs.id.rawValue
    }

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
      ),
      activeConversationCount: conversationsInRange.count,
      conversationBreakdown: conversationsInRange
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

  public static func messagePerformance(
    messageID: ChatMessageID,
    telemetryEvents: [TelemetryEvent],
    range: UsageAnalyticsRange,
    reference: Date = .now
  ) -> TelemetryPerformanceAggregate {
    let events = filteredAnalyticsEvents(
      telemetryEvents,
      range: range,
      reference: reference
    ).filter { $0.messageID == messageID }
    return TelemetryAnalytics.aggregate(events: events)
  }

  public static func latestContextUsage(
    conversation: ChatConversation,
    telemetryEvents: [TelemetryEvent],
    modelContextWindow: Int? = nil
  ) -> ConversationContextUsage? {
    let latestAssistant = conversation.messages.last { message in
      guard message.role == .assistant else { return false }
      let billing = ChatBilling.snapshot(for: message)
      let lastRequestInput = billing.requests.last?.usage?.inputTokens ?? message.usage?.inputTokens ?? 0
      return lastRequestInput > 0
    }
    let actualInputTokens: Int? = latestAssistant.flatMap { message in
      let billing = ChatBilling.snapshot(for: message)
      if let lastRequestInput = billing.requests.last?.usage?.inputTokens, lastRequestInput > 0 {
        return lastRequestInput
      }
      if let usageInput = message.usage?.inputTokens, usageInput > 0 {
        return usageInput
      }
      return nil
    }

    let latestContextEvent = telemetryEvents
      .filter { event in
        event.dataClass == .analytics
          && event.name == .contextBuilt
          && event.conversationID == conversation.id
      }
      .max { lhs, rhs in lhs.timestamp < rhs.timestamp }

    let telemetryEstimatedInput = latestContextEvent?.metadata["estimatedInputTokens"]
      .flatMap { Int($0) }
      .flatMap { $0 > 0 ? $0 : nil }
    let telemetryContextWindow = latestContextEvent?.metadata["contextWindow"]
      .flatMap { Int($0) }
      .flatMap { $0 > 0 ? $0 : nil }

    let contextEventMatchesLatestTurn: Bool = {
      guard let latestContextEvent else { return false }
      guard let latestAssistant else { return true }
      return latestContextEvent.messageID == latestAssistant.id
    }()
    let omittedCount = contextEventMatchesLatestTurn
      ? max(0, latestContextEvent?.metadata["omittedMessageCount"].flatMap { Int($0) } ?? 0)
      : 0

    let effectiveWindow = modelContextWindow.flatMap { $0 > 0 ? $0 : nil } ?? telemetryContextWindow

    if let actualInputTokens {
      return ConversationContextUsage(
        usedInputTokens: actualInputTokens,
        contextWindow: effectiveWindow,
        omittedMessageCount: omittedCount,
        isEstimated: false
      )
    }
    if let telemetryEstimatedInput {
      return ConversationContextUsage(
        usedInputTokens: telemetryEstimatedInput,
        contextWindow: effectiveWindow,
        omittedMessageCount: omittedCount,
        isEstimated: true
      )
    }
    return nil
  }

  public static func messageOmittedContextCount(
    messageID: ChatMessageID,
    telemetryEvents: [TelemetryEvent]
  ) -> Int {
    telemetryEvents
      .filter { event in
        event.dataClass == .analytics
          && event.name == .contextBuilt
          && event.messageID == messageID
      }
      .compactMap { $0.metadata["omittedMessageCount"].flatMap { Int($0) } }
      .max() ?? 0
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
    return keys.compactMap { key -> UsageAnalyticsBreakdown? in
      let aggregate = usageByKey[key] ?? ChatUsageAggregate()
      let performance = TelemetryAnalytics.aggregate(events: eventsByKey[key] ?? [])
      guard aggregate.assistantMessageCount > 0 || performance.providerRequestCount > 0 else {
        return nil
      }
      return UsageAnalyticsBreakdown(
        id: key,
        aggregate: aggregate,
        performance: performance
      )
    }
    .sorted { lhs, rhs in
      if lhs.aggregate.costUSD != rhs.aggregate.costUSD {
        return lhs.aggregate.costUSD > rhs.aggregate.costUSD
      }
      let lhsTokens = lhs.aggregate.inputTokens + lhs.aggregate.outputTokens
      let rhsTokens = rhs.aggregate.inputTokens + rhs.aggregate.outputTokens
      if lhsTokens != rhsTokens { return lhsTokens > rhsTokens }
      if lhs.performance.providerRequestCount != rhs.performance.providerRequestCount {
        return lhs.performance.providerRequestCount > rhs.performance.providerRequestCount
      }
      return lhs.id < rhs.id
    }
  }
}
