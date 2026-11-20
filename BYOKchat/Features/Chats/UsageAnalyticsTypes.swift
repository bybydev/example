import BYOKchatProviderCore
import Foundation

struct UsageBreakdown: Identifiable {
  let id: String
  let title: String
  let aggregate: ChatUsageAggregate
  let performance: TelemetryPerformanceAggregate
}

/// Both platforms share date-range access and filtering semantics.
typealias UsageRange = UsageAnalyticsRange
