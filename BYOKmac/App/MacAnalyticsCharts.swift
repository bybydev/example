import BYOKchatProviderCore
import Charts
import Foundation
import MacAppFoundation
import SwiftUI

// MARK: - Chart Metric & Adaptive Time-Series Model

enum MacAnalyticsChartMetric: String, CaseIterable, Identifiable, Sendable {
  case spend = "Spend"
  case tokens = "Tokens"
  case requests = "Requests"

  var id: String { rawValue }
}

enum MacAnalyticsChartGranularity: String, Equatable, Sendable {
  case hourly
  case daily
  case weekly
  case monthly
  case quarterly

  var singularUnit: String {
    switch self {
    case .hourly: "hour"
    case .daily: "day"
    case .weekly: "week"
    case .monthly: "month"
    case .quarterly: "quarter"
    }
  }

  var pluralUnit: String {
    switch self {
    case .hourly: "hours"
    case .daily: "days"
    case .weekly: "weeks"
    case .monthly: "months"
    case .quarterly: "quarters"
    }
  }

  var averageLabel: String {
    switch self {
    case .hourly: "Hourly avg"
    case .daily: "Daily avg"
    case .weekly: "Weekly avg"
    case .monthly: "Monthly avg"
    case .quarterly: "Quarterly avg"
    }
  }

  var captionLabel: String {
    switch self {
    case .hourly: "By hour"
    case .daily: "By day"
    case .weekly: "By week"
    case .monthly: "By month"
    case .quarterly: "By quarter"
    }
  }
}

struct MacAnalyticsTimeBucket: Identifiable, Equatable, Sendable {
  let index: Int
  let startDate: Date
  let endDate: Date
  let axisLabel: String
  let detailLabel: String
  let costUSD: Double
  let hasKnownCost: Bool
  let totalTokens: Int
  let inputTokens: Int
  let outputTokens: Int
  let cachedInputTokens: Int
  let reasoningTokens: Int
  let requestCount: Int

  var id: Int { index }

  var hasActivity: Bool {
    requestCount > 0 || totalTokens > 0 || costUSD > 0
  }

  func value(for metric: MacAnalyticsChartMetric) -> Double {
    switch metric {
    case .spend:
      max(0, costUSD)
    case .tokens:
      Double(max(0, totalTokens))
    case .requests:
      Double(max(0, requestCount))
    }
  }
}

struct MacAnalyticsTimeSeries: Equatable, Sendable {
  let range: UsageAnalyticsRange
  let granularity: MacAnalyticsChartGranularity
  let buckets: [MacAnalyticsTimeBucket]
  let axisTickIndices: [Int]
  let activeBucketCount: Int

  static let empty = MacAnalyticsTimeSeries(
    range: .today,
    granularity: .hourly,
    buckets: [],
    axisTickIndices: [],
    activeBucketCount: 0
  )

  var hasAnyActivity: Bool {
    activeBucketCount > 0
  }

  var hasKnownSpend: Bool {
    buckets.contains { $0.hasKnownCost && $0.costUSD > 0 }
  }

  func peakBucket(for metric: MacAnalyticsChartMetric) -> MacAnalyticsTimeBucket? {
    buckets
      .filter { $0.value(for: metric) > 0 }
      .max { lhs, rhs in
        let l = lhs.value(for: metric)
        let r = rhs.value(for: metric)
        if l != r { return l < r }
        return lhs.index < rhs.index
      }
  }

  func totalValue(for metric: MacAnalyticsChartMetric) -> Double {
    buckets.reduce(0) { $0 + $1.value(for: metric) }
  }

  func averageValue(for metric: MacAnalyticsChartMetric) -> Double {
    guard !buckets.isEmpty else { return 0 }
    return totalValue(for: metric) / Double(buckets.count)
  }

  func tickLabel(for index: Int) -> String? {
    guard buckets.indices.contains(index) else { return nil }
    return buckets[index].axisLabel
  }
}

// MARK: - Pure Adaptive Time-Series Builder

nonisolated enum MacAnalyticsTimeSeriesBuilder {
  /// Builds an adaptively bucketed time series for any analytics range,
  /// keeping charts crisp and readable even across multi-month or multi-year
  /// "All Time" histories.
  static func build(
    conversations: [ChatConversation],
    range: UsageAnalyticsRange,
    reference: Date = .now,
    calendar: Calendar = .current
  ) -> MacAnalyticsTimeSeries {
    let rangeStart = range.startDate(reference: reference)

    var messages: [ChatMessage] = []
    var earliestDate: Date?
    var latestDate: Date?

    for conversation in conversations {
      for message in conversation.messages {
        guard message.role == .assistant else { continue }
        let timestamp = message.updatedAt
        if let rangeStart, timestamp < rangeStart { continue }
        messages.append(message)
        if let currentMin = earliestDate {
          if timestamp < currentMin { earliestDate = timestamp }
        } else {
          earliestDate = timestamp
        }
        if let currentMax = latestDate {
          if timestamp > currentMax { latestDate = timestamp }
        } else {
          latestDate = timestamp
        }
      }
    }

    let granularity = resolveGranularity(
      range: range,
      earliestDate: earliestDate,
      latestDate: latestDate ?? reference,
      reference: reference,
      calendar: calendar
    )

    let boundaries = buildBoundaries(
      range: range,
      granularity: granularity,
      earliestDate: earliestDate,
      reference: reference,
      calendar: calendar
    )
    guard !boundaries.isEmpty else {
      return MacAnalyticsTimeSeries(
        range: range,
        granularity: granularity,
        buckets: [],
        axisTickIndices: [],
        activeBucketCount: 0
      )
    }

    var aggregates = Array(repeating: ChatUsageAggregate(), count: boundaries.count)
    let bucketStartMap = Dictionary(
      boundaries.enumerated().map { ($0.element.start, $0.offset) },
      uniquingKeysWith: { first, _ in first }
    )

    for message in messages {
      let aligned = bucketStart(for: message.updatedAt, granularity: granularity, calendar: calendar)
      if let idx = bucketStartMap[aligned] {
        aggregates[idx].add(message)
      } else if let idx = boundaries.firstIndex(where: {
        message.updatedAt >= $0.start && message.updatedAt < $0.end
      }) {
        aggregates[idx].add(message)
      }
    }

    let spansMultipleYears: Bool = {
      guard let first = boundaries.first?.start, let last = boundaries.last?.start else { return false }
      return calendar.component(.year, from: first) != calendar.component(.year, from: last)
    }()

    var buckets: [MacAnalyticsTimeBucket] = []
    buckets.reserveCapacity(boundaries.count)
    var activeCount = 0

    for (index, boundary) in boundaries.enumerated() {
      let agg = aggregates[index]
      let costUSD = agg.hasKnownCost ? NSDecimalNumber(decimal: agg.costUSD).doubleValue : 0
      let bucket = MacAnalyticsTimeBucket(
        index: index,
        startDate: boundary.start,
        endDate: boundary.end,
        axisLabel: formatAxisLabel(
          start: boundary.start,
          granularity: granularity,
          range: range,
          spansMultipleYears: spansMultipleYears,
          calendar: calendar
        ),
        detailLabel: formatDetailLabel(
          start: boundary.start,
          end: boundary.end,
          granularity: granularity,
          spansMultipleYears: spansMultipleYears,
          calendar: calendar
        ),
        costUSD: costUSD,
        hasKnownCost: agg.hasKnownCost,
        totalTokens: agg.totalTokens,
        inputTokens: agg.inputTokens,
        outputTokens: agg.outputTokens,
        cachedInputTokens: agg.cachedInputTokens,
        reasoningTokens: agg.reasoningTokens,
        requestCount: agg.modelRequestCount
      )
      if bucket.hasActivity {
        activeCount += 1
      }
      buckets.append(bucket)
    }

    let ticks = axisTickIndices(count: buckets.count, granularity: granularity)
    return MacAnalyticsTimeSeries(
      range: range,
      granularity: granularity,
      buckets: buckets,
      axisTickIndices: ticks,
      activeBucketCount: activeCount
    )
  }

  static func resolveGranularity(
    range: UsageAnalyticsRange,
    earliestDate: Date?,
    latestDate: Date,
    reference: Date,
    calendar: Calendar = .current
  ) -> MacAnalyticsChartGranularity {
    switch range {
    case .today:
      return .hourly
    case .sevenDays, .thirtyDays, .month:
      return .daily
    case .all:
      guard let earliestDate else { return .daily }
      let end = max(latestDate, reference)
      let startDay = calendar.startOfDay(for: earliestDate)
      let endDay = calendar.startOfDay(for: end)
      let daySpan = max(0, calendar.dateComponents([.day], from: startDay, to: endDay).day ?? 0) + 1
      if daySpan <= 1 {
        return .hourly
      }
      if daySpan <= 45 {
        return .daily
      }
      if daySpan <= 180 {
        return .weekly
      }
      if daySpan <= 730 {
        return .monthly
      }
      return .quarterly
    }
  }

  static func axisTickIndices(
    count: Int,
    granularity: MacAnalyticsChartGranularity
  ) -> [Int] {
    guard count > 0 else { return [] }
    if count <= 7 {
      return Array(0..<count)
    }
    if granularity == .hourly && count == 24 {
      return [0, 6, 12, 18, 23]
    }

    let targetTickCount = min(6, count)
    let step = Double(count - 1) / Double(targetTickCount - 1)
    var indices: [Int] = []
    indices.reserveCapacity(targetTickCount)
    for i in 0..<targetTickCount {
      let candidate = Int((Double(i) * step).rounded())
      if indices.last != candidate {
        indices.append(candidate)
      }
    }
    if indices.last != count - 1 {
      indices[indices.count - 1] = count - 1
    }
    return indices
  }

  private struct BucketBoundary {
    let start: Date
    let end: Date
  }

  private static func buildBoundaries(
    range: UsageAnalyticsRange,
    granularity: MacAnalyticsChartGranularity,
    earliestDate: Date?,
    reference: Date,
    calendar: Calendar
  ) -> [BucketBoundary] {
    let startAnchor: Date
    let endAnchor: Date

    switch range {
    case .today:
      startAnchor = calendar.startOfDay(for: reference)
      endAnchor = calendar.date(byAdding: .hour, value: 23, to: startAnchor) ?? reference
    case .sevenDays:
      let todayStart = calendar.startOfDay(for: reference)
      startAnchor = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
      endAnchor = todayStart
    case .thirtyDays:
      let todayStart = calendar.startOfDay(for: reference)
      startAnchor = calendar.date(byAdding: .day, value: -29, to: todayStart) ?? todayStart
      endAnchor = todayStart
    case .month:
      let monthStart = calendar.date(
        from: calendar.dateComponents([.year, .month], from: reference)
      ) ?? calendar.startOfDay(for: reference)
      startAnchor = monthStart
      endAnchor = calendar.startOfDay(for: reference)
    case .all:
      let todayStart = calendar.startOfDay(for: reference)
      if let earliestDate {
        if granularity == .hourly {
          startAnchor = calendar.startOfDay(for: earliestDate)
          endAnchor = calendar.date(byAdding: .hour, value: 23, to: startAnchor) ?? reference
        } else {
          startAnchor = bucketStart(for: earliestDate, granularity: granularity, calendar: calendar)
          endAnchor = bucketStart(for: max(earliestDate, todayStart), granularity: granularity, calendar: calendar)
        }
      } else {
        startAnchor = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
        endAnchor = todayStart
      }
    }

    var boundaries: [BucketBoundary] = []
    var cursor = bucketStart(for: startAnchor, granularity: granularity, calendar: calendar)
    let alignedEnd = bucketStart(for: endAnchor, granularity: granularity, calendar: calendar)

    // Safety cap prevents runaway loops on pathological timestamps (e.g. epoch 1970).
    let maxBuckets = 60
    while cursor <= alignedEnd, boundaries.count < maxBuckets {
      let next = nextBucketStart(after: cursor, granularity: granularity, calendar: calendar)
      guard next > cursor else { break }
      boundaries.append(BucketBoundary(start: cursor, end: next))
      cursor = next
    }
    return boundaries
  }

  private static func bucketStart(
    for date: Date,
    granularity: MacAnalyticsChartGranularity,
    calendar: Calendar
  ) -> Date {
    switch granularity {
    case .hourly:
      let comps = calendar.dateComponents([.year, .month, .day, .hour], from: date)
      return calendar.date(from: comps) ?? date
    case .daily:
      return calendar.startOfDay(for: date)
    case .weekly:
      let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
      return calendar.date(from: comps) ?? calendar.startOfDay(for: date)
    case .monthly:
      let comps = calendar.dateComponents([.year, .month], from: date)
      return calendar.date(from: comps) ?? calendar.startOfDay(for: date)
    case .quarterly:
      let year = calendar.component(.year, from: date)
      let month = calendar.component(.month, from: date)
      let quarterStartMonth = ((month - 1) / 3) * 3 + 1
      let comps = DateComponents(year: year, month: quarterStartMonth, day: 1)
      return calendar.date(from: comps) ?? calendar.startOfDay(for: date)
    }
  }

  private static func nextBucketStart(
    after start: Date,
    granularity: MacAnalyticsChartGranularity,
    calendar: Calendar
  ) -> Date {
    switch granularity {
    case .hourly:
      calendar.date(byAdding: .hour, value: 1, to: start) ?? start.addingTimeInterval(3_600)
    case .daily:
      calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
    case .weekly:
      calendar.date(byAdding: .weekOfYear, value: 1, to: start) ?? start.addingTimeInterval(7 * 86_400)
    case .monthly:
      calendar.date(byAdding: .month, value: 1, to: start) ?? start.addingTimeInterval(30 * 86_400)
    case .quarterly:
      calendar.date(byAdding: .month, value: 3, to: start) ?? start.addingTimeInterval(90 * 86_400)
    }
  }

  private static func formatAxisLabel(
    start: Date,
    granularity: MacAnalyticsChartGranularity,
    range: UsageAnalyticsRange,
    spansMultipleYears: Bool,
    calendar: Calendar
  ) -> String {
    switch granularity {
    case .hourly:
      return start.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)))
    case .daily:
      if range == .sevenDays {
        return start.formatted(.dateTime.weekday(.abbreviated))
      }
      return start.formatted(.dateTime.month(.abbreviated).day())
    case .weekly:
      return start.formatted(.dateTime.month(.abbreviated).day())
    case .monthly:
      if spansMultipleYears {
        return start.formatted(.dateTime.month(.abbreviated).year(.twoDigits))
      }
      return start.formatted(.dateTime.month(.abbreviated))
    case .quarterly:
      let quarter = ((calendar.component(.month, from: start) - 1) / 3) + 1
      let yearSuffix = calendar.component(.year, from: start) % 100
      return String(format: "Q%d '%02d", quarter, yearSuffix)
    }
  }

  private static func formatDetailLabel(
    start: Date,
    end: Date,
    granularity: MacAnalyticsChartGranularity,
    spansMultipleYears: Bool,
    calendar: Calendar
  ) -> String {
    switch granularity {
    case .hourly:
      let startHour = start.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)))
      let endHour = end.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)))
      return "\(startHour)–\(endHour)"
    case .daily:
      if spansMultipleYears {
        return start.formatted(.dateTime.month(.abbreviated).day().year())
      }
      return start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    case .weekly:
      let inclusiveEnd = calendar.date(byAdding: .day, value: -1, to: end) ?? end
      let startText = start.formatted(.dateTime.month(.abbreviated).day())
      let endText = inclusiveEnd.formatted(.dateTime.month(.abbreviated).day())
      return "\(startText)–\(endText)"
    case .monthly:
      return start.formatted(.dateTime.month(.wide).year())
    case .quarterly:
      let quarter = ((calendar.component(.month, from: start) - 1) / 3) + 1
      let year = calendar.component(.year, from: start)
      return "Q\(quarter) \(year)"
    }
  }
}

// MARK: - Interactive Activity Trend Chart Card

struct MacAnalyticsActivityChartCard: View {
  let series: MacAnalyticsTimeSeries
  @Binding var metric: MacAnalyticsChartMetric

  @Environment(\.macAppTheme) private var theme
  @State private var hoveredIndex: Int?

  private var hoveredBucket: MacAnalyticsTimeBucket? {
    guard let hoveredIndex, series.buckets.indices.contains(hoveredIndex) else { return nil }
    return series.buckets[hoveredIndex]
  }

  private var chartYMax: Double {
    let peak = series.peakBucket(for: metric)?.value(for: metric) ?? 0
    return peak > 0 ? peak * 1.16 : 1
  }

  private var chartColor: Color {
    switch metric {
    case .spend: theme.accent
    case .tokens: Color.teal
    case .requests: Color.indigo
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      headerRow

      if series.buckets.isEmpty || !series.hasAnyActivity {
        emptyChartState
      } else {
        chartBody
        footerSummaryStrip
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      theme.surface,
      in: RoundedRectangle(cornerRadius: 10, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(theme.border, lineWidth: 1)
    }
    .onChange(of: series.buckets.count) { _, _ in
      hoveredIndex = nil
    }
  }

  private var headerRow: some View {
    HStack(alignment: .center, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Image(systemName: "chart.bar.xaxis")
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(theme.accent)
          Text("Activity")
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(theme.textPrimary)
          Text("· \(series.granularity.captionLabel)")
            .font(.caption)
            .foregroundStyle(theme.textMuted)
        }

        if let bucket = hoveredBucket {
          Text(hoverSummary(for: bucket))
            .font(.caption.monospacedDigit())
            .foregroundStyle(theme.accent)
            .lineLimit(1)
        } else {
          Text(defaultSubtitle)
            .font(.caption)
            .foregroundStyle(theme.textSecondary)
            .lineLimit(1)
        }
      }

      Spacer(minLength: 8)

      HStack(spacing: 2) {
        ForEach(MacAnalyticsChartMetric.allCases) { option in
          let isSelected = metric == option
          Button {
            metric = option
          } label: {
            Text(option.rawValue)
              .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
              .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
              .padding(.horizontal, 9)
              .frame(height: 24)
              .background(
                isSelected ? theme.surfaceRaised : Color.clear,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
              )
              .overlay {
                if isSelected {
                  RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(theme.border, lineWidth: 0.75)
                }
              }
          }
          .buttonStyle(.plain)
        }
      }
      .padding(2)
      .background(
        theme.canvas.opacity(0.85),
        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .strokeBorder(theme.border.opacity(0.8), lineWidth: 0.75)
      }
    }
  }

  private var chartBody: some View {
    let domainEnd = Double(max(0, series.buckets.count - 1)) + 0.5
    let tickValues = series.axisTickIndices.map(Double.init)

    return GeometryReader { outer in
      let estimatedPlotWidth = max(120, outer.size.width - 48)
      let slotWidth = estimatedPlotWidth / CGFloat(max(1, series.buckets.count))
      let barWidth = max(4, min(26, slotWidth * 0.62))

      Chart {
        ForEach(series.buckets) { bucket in
          let value = bucket.value(for: metric)
          let isHighlighted = hoveredIndex == bucket.index
          let isDimmed = hoveredIndex != nil && !isHighlighted

          BarMark(
            x: .value("Period", Double(bucket.index)),
            y: .value(metric.rawValue, value),
            width: .fixed(barWidth)
          )
          .foregroundStyle(
            LinearGradient(
              colors: [
                chartColor.opacity(isDimmed ? 0.30 : (isHighlighted ? 1.0 : 0.92)),
                chartColor.opacity(isDimmed ? 0.14 : (isHighlighted ? 0.72 : 0.48)),
              ],
              startPoint: .top,
              endPoint: .bottom
            )
          )
          .cornerRadius(barWidth < 10 ? 2.5 : 4)
        }

        if let hoveredBucket {
          RuleMark(x: .value("Selected", Double(hoveredBucket.index)))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .foregroundStyle(theme.textMuted.opacity(0.55))
        }
      }
      .chartXScale(domain: -0.5 ... domainEnd)
      .chartYScale(domain: 0 ... chartYMax)
      .chartXAxis {
        AxisMarks(values: tickValues) { value in
          AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
            .foregroundStyle(theme.separator.opacity(0.45))
          if let raw = value.as(Double.self),
            let label = series.tickLabel(for: Int(raw.rounded()))
          {
            AxisValueLabel {
              Text(label)
                .font(.system(size: 10))
                .foregroundStyle(theme.textMuted)
            }
          }
        }
      }
      .chartYAxis {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
          AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
            .foregroundStyle(theme.separator.opacity(0.5))
          if let number = value.as(Double.self) {
            AxisValueLabel {
              Text(formatYAxisValue(number))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(theme.textMuted)
            }
          }
        }
      }
      .chartOverlay { proxy in
        GeometryReader { geometry in
          Color.clear
            .contentShape(Rectangle())
            .onContinuousHover { phase in
              switch phase {
              case .active(let location):
                guard let plotFrame = proxy.plotFrame else {
                  hoveredIndex = nil
                  return
                }
                let frame = geometry[plotFrame]
                let plotX = location.x - frame.origin.x
                guard plotX >= 0, plotX <= frame.width,
                  let rawValue = proxy.value(atX: plotX, as: Double.self)
                else {
                  hoveredIndex = nil
                  return
                }
                let clamped = min(max(Int(rawValue.rounded()), 0), series.buckets.count - 1)
                hoveredIndex = clamped
              case .ended:
                hoveredIndex = nil
              }
            }
        }
      }
    }
    .frame(height: 158)
  }

  private var footerSummaryStrip: some View {
    HStack(spacing: 14) {
      if let peak = series.peakBucket(for: metric) {
        footerStat(
          label: "Peak",
          value: "\(formatMetricValue(peak.value(for: metric))) (\(peak.detailLabel))"
        )
      }

      footerStat(
        label: series.granularity.averageLabel,
        value: formatMetricValue(series.averageValue(for: metric))
      )

      Spacer(minLength: 8)

      Text(
        "\(series.activeBucketCount) / \(series.buckets.count) active \(series.buckets.count == 1 ? series.granularity.singularUnit : series.granularity.pluralUnit)"
      )
      .font(.caption.monospacedDigit())
      .foregroundStyle(theme.textMuted)
    }
    .padding(.top, 2)
  }

  private func footerStat(label: String, value: String) -> some View {
    HStack(spacing: 4) {
      Text(label)
        .font(.caption)
        .foregroundStyle(theme.textMuted)
      Text(value)
        .font(.caption.weight(.medium).monospacedDigit())
        .foregroundStyle(theme.textPrimary)
        .lineLimit(1)
    }
  }

  private var emptyChartState: some View {
    VStack(spacing: 6) {
      Image(systemName: "chart.bar")
        .font(.system(size: 20, weight: .regular))
        .foregroundStyle(theme.textMuted.opacity(0.75))
      Text("No activity recorded in this range yet")
        .font(.callout.weight(.medium))
        .foregroundStyle(theme.textSecondary)
      Text("Send a message to see \(metric.rawValue.lowercased()) trends over time.")
        .font(.caption)
        .foregroundStyle(theme.textMuted)
    }
    .frame(maxWidth: .infinity)
    .frame(height: 158)
  }

  private var defaultSubtitle: String {
    if metric == .spend && !series.hasKnownSpend && series.hasAnyActivity {
      return "Hover bars to inspect · switch to Tokens or Requests when pricing is unavailable"
    }
    return "Hover any bar to inspect exact period totals"
  }

  private func hoverSummary(for bucket: MacAnalyticsTimeBucket) -> String {
    var parts = [bucket.detailLabel]
    if bucket.hasKnownCost {
      parts.append(macUsageFormatUSD(Decimal(bucket.costUSD)))
    }
    parts.append("\(macUsageCompactTokens(bucket.totalTokens)) tok")
    parts.append(macUsageRequestCountLabel(bucket.requestCount))
    return parts.joined(separator: " · ")
  }

  private func formatYAxisValue(_ value: Double) -> String {
    switch metric {
    case .spend:
      if value == 0 { return "$0" }
      if value < 0.01 { return String(format: "$%.3f", value) }
      if value < 1 { return String(format: "$%.2f", value) }
      if value < 100 { return String(format: "$%.1f", value) }
      return String(format: "$%.0f", value)
    case .tokens:
      return macUsageCompactTokens(Int(value.rounded()))
    case .requests:
      return Int(value.rounded()).formatted()
    }
  }

  private func formatMetricValue(_ value: Double) -> String {
    switch metric {
    case .spend:
      return macUsageFormatUSD(Decimal(value))
    case .tokens:
      return macUsageCompactTokens(Int(value.rounded()))
    case .requests:
      return value < 10 && value.truncatingRemainder(dividingBy: 1) != 0
        ? String(format: "%.1f", value)
        : Int(value.rounded()).formatted()
    }
  }
}

// MARK: - Stacked Proportional Bar & Palette

struct MacAnalyticsBarSegment: Identifiable {
  let id: String
  let label: String
  let value: Double
  let color: Color
}

struct MacAnalyticsProportionalBar: View {
  let segments: [MacAnalyticsBarSegment]
  var height: CGFloat = 8

  @Environment(\.macAppTheme) private var theme

  private var total: Double {
    segments.reduce(0) { $0 + max(0, $1.value) }
  }

  var body: some View {
    let nonZero = segments.filter { $0.value > 0 }
    GeometryReader { proxy in
      let usableTotal = total
      if usableTotal > 0, !nonZero.isEmpty {
        let gap: CGFloat = 1.5
        let totalSpacing = CGFloat(max(0, nonZero.count - 1)) * gap
        let availableWidth = max(0, proxy.size.width - totalSpacing)
        HStack(spacing: gap) {
          ForEach(nonZero) { segment in
            let fraction = segment.value / usableTotal
            RoundedRectangle(cornerRadius: height / 2, style: .continuous)
              .fill(segment.color)
              .frame(width: max(0, availableWidth * fraction))
          }
        }
      } else {
        Capsule(style: .continuous)
          .fill(theme.separator.opacity(0.45))
      }
    }
    .frame(height: height)
    .clipShape(Capsule(style: .continuous))
  }
}

enum MacAnalyticsPalette {
  @MainActor
  static func color(at index: Int, accent: Color) -> Color {
    let palette: [Color] = [
      accent,
      Color.teal,
      Color.indigo,
      Color.orange,
      Color.pink,
      Color.mint,
    ]
    return palette[index % palette.count]
  }
}
