import BYOKchatProviderCore
import Foundation

struct UsageBreakdown: Identifiable {
  let id: String
  let title: String
  let aggregate: ChatUsageAggregate
  let performance: TelemetryPerformanceAggregate
}

enum UsageRange: String, CaseIterable, Identifiable {
  case today
  case sevenDays
  case thirtyDays
  case month
  case all

  var id: String { rawValue }

  /// Analytics capabilities are identical for Free and Pro; only historical
  /// date ranges require Pro. Always use the accessible range for calculations,
  /// even if a stale UI selection outlives a subscription.
  var requiresPro: Bool { self != .today }

  func accessible(hasPro: Bool) -> UsageRange {
    hasPro ? self : .today
  }

  var label: String {
    switch self {
    case .today: "Today"
    case .sevenDays: "7D"
    case .thirtyDays: "30D"
    case .month: "Month"
    case .all: "All"
    }
  }

  func startDate(reference: Date) -> Date? {
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

struct ConversationAnalyticsSnapshot {
  let aggregate: ChatUsageAggregate
  let performance: TelemetryPerformanceAggregate
}
