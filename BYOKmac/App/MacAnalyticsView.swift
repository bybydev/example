import BYOKchatProviderCore
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class MacAnalyticsModel {
  private(set) var conversations: [ChatConversation] = []
  private(set) var telemetryEvents: [TelemetryEvent] = []
  private(set) var statistics = TelemetryStoreStatistics.empty
  private(set) var isLoading = false
  private(set) var hasLoaded = false

  private let services: BYOKCoreServices

  init(services: BYOKCoreServices) {
    self.services = services
  }

  func load() async {
    guard !isLoading else { return }
    isLoading = true
    defer {
      isLoading = false
      hasLoaded = true
    }

    let loadedConversations = await services.conversationStore.allConversations()
    let loadedEvents = await services.telemetryRecorder.recentEvents(
      limit: TelemetryStoreConfiguration.maximumRecentEventQueryCount
    )
    let loadedStatistics = await services.telemetryRecorder.statistics()

    conversations = loadedConversations.sorted { lhs, rhs in
      if lhs.updatedAt == rhs.updatedAt { return lhs.id.rawValue > rhs.id.rawValue }
      return lhs.updatedAt > rhs.updatedAt
    }
    telemetryEvents = loadedEvents
    statistics = loadedStatistics
  }

  func snapshot(range: UsageAnalyticsRange, reference: Date = .now) -> UsageAnalyticsSnapshot {
    UsageAnalytics.snapshot(
      conversations: conversations,
      telemetryEvents: telemetryEvents,
      range: range,
      reference: reference
    )
  }

  func conversationSnapshot(
    _ conversation: ChatConversation,
    range: UsageAnalyticsRange,
    reference: Date = .now
  ) -> ConversationUsageAnalyticsSnapshot {
    UsageAnalytics.conversationSnapshot(
      conversation: conversation,
      telemetryEvents: telemetryEvents,
      range: range,
      reference: reference
    )
  }
}

private enum MacAnalyticsSelection: Hashable {
  case overview
  case conversation(String)
}

struct MacAnalyticsView: View {
  @State private var analytics: MacAnalyticsModel
  @State private var range: UsageAnalyticsRange = .month
  @State private var selection: MacAnalyticsSelection = .overview
  @AppStorage("byokchat.usage.monthlyBudgetUSD") private var monthlyBudgetUSD = 0.0
  @AppStorage("byokchat.usage.budgetWarningFraction") private var budgetWarningFraction = 0.8

  @Environment(\.dismiss) private var dismiss

  init(services: BYOKCoreServices) {
    _analytics = State(initialValue: MacAnalyticsModel(services: services))
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()

      NavigationSplitView {
        sidebar
      } detail: {
        detail
      }
    }
    .frame(minWidth: 940, minHeight: 660)
    .background(MacDesignTokens.Colors.canvas)
    .task { await analytics.load() }
  }

  private var header: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Analytics")
          .font(.headline)
        Text("Local usage, cost, performance, and reliability")
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
      }

      Spacer()

      Picker("Range", selection: $range) {
        ForEach(UsageAnalyticsRange.allCases) { value in
          Text(value.label).tag(value)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(width: 320)
      .accessibilityLabel("Analytics range")

      Button("Refresh", systemImage: "arrow.clockwise") {
        Task { await analytics.load() }
      }
      .disabled(analytics.isLoading)

      Button("Done") { dismiss() }
        .keyboardShortcut(.cancelAction)
    }
    .padding(16)
  }

  private var sidebar: some View {
    List(selection: $selection) {
      Section {
        Label("Overview", systemImage: "chart.xyaxis.line")
          .tag(MacAnalyticsSelection.overview)
      }

      Section("Conversations") {
        ForEach(analytics.conversations) { conversation in
          VStack(alignment: .leading, spacing: 2) {
            Text(conversation.title.isEmpty ? "New Chat" : conversation.title)
              .lineLimit(1)
            Text(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
          .tag(MacAnalyticsSelection.conversation(conversation.id.rawValue))
        }
      }
    }
    .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 320)
  }

  @ViewBuilder
  private var detail: some View {
    if analytics.isLoading && !analytics.hasLoaded {
      VStack(spacing: 12) {
        ProgressView()
        Text("Loading local analytics…")
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(MacDesignTokens.Colors.canvas)
    } else {
      switch selection {
      case .overview:
        overview
      case .conversation(let rawID):
        if let conversation = analytics.conversations.first(where: { $0.id.rawValue == rawID }) {
          conversationDetail(conversation)
        } else {
          ContentUnavailableView("Conversation Unavailable", systemImage: "bubble.left")
        }
      }
    }
  }

  private var overview: some View {
    let snapshot = analytics.snapshot(range: range)
    let month = analytics.snapshot(range: .month)

    return ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        MacAnalyticsMetricGrid(
          metrics: [
            .init(title: "Spend", value: macUsageAggregateCost(snapshot.aggregate), symbol: "dollarsign.circle"),
            .init(title: "Model Requests", value: snapshot.aggregate.modelRequestCount.formatted(), symbol: "arrow.up.arrow.down"),
            .init(title: "Input", value: macUsageCompactTokens(snapshot.aggregate.inputTokens), symbol: "arrow.down.left"),
            .init(title: "Output", value: macUsageCompactTokens(snapshot.aggregate.outputTokens), symbol: "arrow.up.right"),
            .init(title: "Cached Input", value: macUsageCompactTokens(snapshot.aggregate.cachedInputTokens), symbol: "bolt.horizontal.circle"),
            .init(title: "Reasoning", value: macUsageCompactTokens(snapshot.aggregate.reasoningTokens), symbol: "brain"),
            .init(title: "Tool Calls", value: snapshot.aggregate.toolCallCount.formatted(), symbol: "wrench.and.screwdriver")
          ]
        )

        if snapshot.aggregate.hasPartialCost {
          Label(
            "Spend is partial because some responses do not expose known pricing.",
            systemImage: "info.circle"
          )
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }

        if hasPerformance(snapshot.performance) {
          MacAnalyticsSection(title: "Performance", symbol: "gauge.with.dots.needle.67percent") {
            MacAnalyticsMetricGrid(
              metrics: [
                .init(title: "Median TTFT", value: macUsageDuration(snapshot.performance.medianTTFTMilliseconds), symbol: "timer"),
                .init(title: "P95 TTFT", value: macUsageDuration(snapshot.performance.p95TTFTMilliseconds), symbol: "timer.circle"),
                .init(title: "Median Duration", value: macUsageDuration(snapshot.performance.medianDurationMilliseconds), symbol: "clock"),
                .init(title: "P95 Duration", value: macUsageDuration(snapshot.performance.p95DurationMilliseconds), symbol: "clock.badge.exclamationmark"),
                .init(title: "Median Speed", value: macUsageRate(snapshot.performance.medianOutputTokensPerSecond), symbol: "speedometer")
              ]
            )
          }

          MacAnalyticsSection(title: "Reliability", symbol: "checkmark.shield") {
            VStack(spacing: 9) {
              MacAnalyticsLabeledRow("Success Rate", value: macUsagePercent(snapshot.performance.providerSuccessRate))
              MacAnalyticsLabeledRow("Succeeded", value: snapshot.performance.providerSuccessCount.formatted())
              MacAnalyticsLabeledRow("Failed", value: snapshot.performance.providerFailureCount.formatted())
              if snapshot.performance.providerCancelledCount > 0 {
                MacAnalyticsLabeledRow("Cancelled", value: snapshot.performance.providerCancelledCount.formatted())
              }
              if snapshot.performance.toolCallCount > 0 {
                Divider()
                MacAnalyticsLabeledRow("Tool Success", value: macUsagePercent(snapshot.performance.toolSuccessRate))
                MacAnalyticsLabeledRow("Tool Calls", value: snapshot.performance.toolCallCount.formatted())
              }
              if snapshot.performance.mcpRequestCount > 0 {
                MacAnalyticsLabeledRow("MCP Requests", value: snapshot.performance.mcpRequestCount.formatted())
                MacAnalyticsLabeledRow("MCP Failures", value: snapshot.performance.mcpFailureCount.formatted())
              }
            }
          }
        } else if analytics.hasLoaded {
          MacAnalyticsSection(title: "Performance", symbol: "waveform.path.ecg") {
            Text("Send a few messages to start collecting local performance metrics.")
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }
        }

        if !snapshot.failureBreakdown.isEmpty {
          MacAnalyticsSection(title: "Errors", symbol: "exclamationmark.triangle") {
            VStack(spacing: 0) {
              let failures = Array(snapshot.failureBreakdown.prefix(8))
              ForEach(failures) { failure in
                HStack(alignment: .firstTextBaseline) {
                  VStack(alignment: .leading, spacing: 2) {
                    Text(macAnalyticsErrorTitle(failure.errorCode))
                    Text("\(failure.category.rawValue.capitalized) · \(failure.classification.replacingOccurrences(of: "_", with: " "))")
                      .font(.caption)
                      .foregroundStyle(MacDesignTokens.Colors.textMuted)
                  }
                  Spacer()
                  Text(failure.count.formatted())
                    .monospacedDigit()
                    .foregroundStyle(MacDesignTokens.Colors.textMuted)
                }
                .padding(.vertical, 7)

                if failure.id != failures.last?.id {
                  Divider()
                }
              }
            }
          }
        }

        if !snapshot.providerBreakdown.isEmpty {
          MacAnalyticsSection(title: "Providers", symbol: "server.rack") {
            MacAnalyticsBreakdownList(
              rows: snapshot.providerBreakdown,
              displayName: macUsageDisplayName
            )
          }
        }

        if !snapshot.modelBreakdown.isEmpty {
          MacAnalyticsSection(title: "Models", symbol: "cpu") {
            MacAnalyticsBreakdownList(
              rows: snapshot.modelBreakdown,
              displayName: { $0 }
            )
          }
        }

        MacAnalyticsSection(title: "Monthly Budget", symbol: "gauge.with.needle") {
          VStack(spacing: 10) {
            HStack {
              Text("Budget")
              Spacer()
              Text("$")
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
              TextField(
                "0",
                value: $monthlyBudgetUSD,
                format: .number.precision(.fractionLength(0...2))
              )
              .multilineTextAlignment(.trailing)
              .frame(width: 100)
            }

            Picker("Warn at", selection: $budgetWarningFraction) {
              Text("50%").tag(0.5)
              Text("75%").tag(0.75)
              Text("80%").tag(0.8)
              Text("90%").tag(0.9)
            }

            if monthlyBudgetUSD > 0 {
              ProgressView(value: budgetProgress(month.aggregate))
              MacAnalyticsLabeledRow("This Month", value: macUsageAggregateCost(month.aggregate))
              if budgetWarningReached(month.aggregate) {
                Label("Budget warning threshold reached", systemImage: "exclamationmark.triangle.fill")
                  .foregroundStyle(.orange)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
            }

            Text("This is a local BYOKchat warning. It does not change provider-side spending limits or include API-key usage from other apps.")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }

        MacAnalyticsSection(title: "Local Analytics", symbol: "internaldrive") {
          VStack(spacing: 9) {
            MacAnalyticsLabeledRow("Telemetry Events", value: analytics.statistics.analyticsEventCount.formatted())
            if analytics.statistics.databaseBytes > 0 {
              MacAnalyticsLabeledRow(
                "Local Database",
                value: ByteCountFormatter.string(
                  fromByteCount: analytics.statistics.databaseBytes,
                  countStyle: .file
                )
              )
            }
            Text(telemetryFootnote)
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
      .frame(maxWidth: 860, alignment: .leading)
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .background(MacDesignTokens.Colors.canvas)
  }

  private func conversationDetail(_ conversation: ChatConversation) -> some View {
    let snapshot = analytics.conversationSnapshot(conversation, range: range)

    return ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 4) {
          Text(conversation.title.isEmpty ? "New Chat" : conversation.title)
            .font(.title2.weight(.semibold))
          Text("Conversation analytics · \(range.label)")
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }

        MacAnalyticsMetricGrid(
          metrics: [
            .init(title: "Spend", value: macUsageAggregateCost(snapshot.aggregate), symbol: "dollarsign.circle"),
            .init(title: "Requests", value: snapshot.aggregate.modelRequestCount.formatted(), symbol: "arrow.up.arrow.down"),
            .init(title: "Input", value: macUsageCompactTokens(snapshot.aggregate.inputTokens), symbol: "arrow.down.left"),
            .init(title: "Output", value: macUsageCompactTokens(snapshot.aggregate.outputTokens), symbol: "arrow.up.right"),
            .init(title: "Cached Input", value: macUsageCompactTokens(snapshot.aggregate.cachedInputTokens), symbol: "bolt.horizontal.circle"),
            .init(title: "Reasoning", value: macUsageCompactTokens(snapshot.aggregate.reasoningTokens), symbol: "brain"),
            .init(title: "Tool Calls", value: snapshot.aggregate.toolCallCount.formatted(), symbol: "wrench.and.screwdriver")
          ]
        )

        if hasPerformance(snapshot.performance) {
          MacAnalyticsSection(title: "Performance", symbol: "gauge.with.dots.needle.67percent") {
            VStack(spacing: 9) {
              MacAnalyticsLabeledRow("Median TTFT", value: macUsageDuration(snapshot.performance.medianTTFTMilliseconds))
              MacAnalyticsLabeledRow("P95 TTFT", value: macUsageDuration(snapshot.performance.p95TTFTMilliseconds))
              MacAnalyticsLabeledRow("Median Duration", value: macUsageDuration(snapshot.performance.medianDurationMilliseconds))
              MacAnalyticsLabeledRow("P95 Duration", value: macUsageDuration(snapshot.performance.p95DurationMilliseconds))
              MacAnalyticsLabeledRow("Median Speed", value: macUsageRate(snapshot.performance.medianOutputTokensPerSecond))
            }
          }

          MacAnalyticsSection(title: "Reliability", symbol: "checkmark.shield") {
            VStack(spacing: 9) {
              MacAnalyticsLabeledRow("Success Rate", value: macUsagePercent(snapshot.performance.providerSuccessRate))
              MacAnalyticsLabeledRow("Succeeded", value: snapshot.performance.providerSuccessCount.formatted())
              MacAnalyticsLabeledRow("Failed", value: snapshot.performance.providerFailureCount.formatted())
              if snapshot.performance.providerCancelledCount > 0 {
                MacAnalyticsLabeledRow("Cancelled", value: snapshot.performance.providerCancelledCount.formatted())
              }
              if snapshot.performance.toolCallCount > 0 {
                Divider()
                MacAnalyticsLabeledRow("Tool Success", value: macUsagePercent(snapshot.performance.toolSuccessRate))
                MacAnalyticsLabeledRow("Tool Calls", value: snapshot.performance.toolCallCount.formatted())
              }
              if snapshot.performance.mcpRequestCount > 0 {
                MacAnalyticsLabeledRow("MCP Requests", value: snapshot.performance.mcpRequestCount.formatted())
                MacAnalyticsLabeledRow("MCP Failures", value: snapshot.performance.mcpFailureCount.formatted())
              }
            }
          }
        }

        if snapshot.aggregate.hasPartialCost {
          Label(
            "Spend is partial because some responses do not expose known pricing.",
            systemImage: "info.circle"
          )
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }
      }
      .frame(maxWidth: 760, alignment: .leading)
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .background(MacDesignTokens.Colors.canvas)
  }

  private var telemetryFootnote: String {
    if analytics.statistics.eventCount > analytics.telemetryEvents.count {
      let limit = TelemetryStoreConfiguration.maximumRecentEventQueryCount.formatted()
      return "Performance and reliability use the latest \(limit) local telemetry events. Usage and spend are reconstructed from persisted conversation history and remain available if telemetry is cleared."
    }
    return "Performance and reliability come from device-local telemetry retained for up to 30 days by default. Usage and spend are reconstructed from persisted conversation history."
  }

  private func hasPerformance(_ performance: TelemetryPerformanceAggregate) -> Bool {
    performance.providerRequestCount > 0 || performance.toolCallCount > 0 || performance.mcpRequestCount > 0
  }

  private func budgetProgress(_ aggregate: ChatUsageAggregate) -> Double {
    guard monthlyBudgetUSD > 0 else { return 0 }
    let spent = NSDecimalNumber(decimal: aggregate.costUSD).doubleValue
    return min(max(spent / monthlyBudgetUSD, 0), 1)
  }

  private func budgetWarningReached(_ aggregate: ChatUsageAggregate) -> Bool {
    guard monthlyBudgetUSD > 0 else { return false }
    let spent = NSDecimalNumber(decimal: aggregate.costUSD).doubleValue
    return spent >= monthlyBudgetUSD * budgetWarningFraction
  }
}

private struct MacAnalyticsMetric: Identifiable {
  let title: String
  let value: String
  let symbol: String

  var id: String { title }
}

private struct MacAnalyticsMetricGrid: View {
  let metrics: [MacAnalyticsMetric]

  private let columns = [
    GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12, alignment: .top)
  ]

  var body: some View {
    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
      ForEach(metrics) { metric in
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 6) {
            Image(systemName: metric.symbol)
            Text(metric.title)
          }
          .font(.caption.weight(.medium))
          .foregroundStyle(MacDesignTokens.Colors.textMuted)

          Text(metric.value)
            .font(.system(size: 20, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
          MacDesignTokens.Colors.surface,
          in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.large)
        )
        .overlay {
          RoundedRectangle(cornerRadius: MacDesignTokens.Radius.large)
            .stroke(MacDesignTokens.Colors.separator, lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metric.title)
        .accessibilityValue(metric.value)
      }
    }
  }
}

private struct MacAnalyticsSection<Content: View>: View {
  let title: String
  let symbol: String
  let content: Content

  init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.symbol = symbol
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(title, systemImage: symbol)
        .font(.headline)
        .accessibilityAddTraits(.isHeader)

      content
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(16)
    .background(
      MacDesignTokens.Colors.surface,
      in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.large)
    )
    .overlay {
      RoundedRectangle(cornerRadius: MacDesignTokens.Radius.large)
        .stroke(MacDesignTokens.Colors.separator, lineWidth: 1)
    }
  }
}

private struct MacAnalyticsLabeledRow: View {
  let title: String
  let value: String

  init(_ title: String, value: String) {
    self.title = title
    self.value = value
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title)
      Spacer(minLength: 20)
      Text(value)
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
        .monospacedDigit()
        .textSelection(.enabled)
    }
  }
}

private struct MacAnalyticsBreakdownList: View {
  let rows: [UsageAnalyticsBreakdown]
  let displayName: (String) -> String

  var body: some View {
    VStack(spacing: 0) {
      ForEach(rows) { row in
        HStack(alignment: .top, spacing: 16) {
          VStack(alignment: .leading, spacing: 3) {
            Text(displayName(row.id))
              .fontWeight(.medium)
              .lineLimit(1)
            Text("\(macUsageCompactTokens(row.aggregate.inputTokens + row.aggregate.outputTokens)) tokens · \(row.aggregate.modelRequestCount.formatted()) requests")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }

          Spacer(minLength: 20)

          VStack(alignment: .trailing, spacing: 3) {
            Text(macUsageAggregateCost(row.aggregate))
              .monospacedDigit()
            if row.performance.providerSuccessRate != nil {
              Text("\(macUsagePercent(row.performance.providerSuccessRate)) success")
                .font(.caption)
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
            }
          }
        }
        .padding(.vertical, 8)

        if row.id != rows.last?.id {
          Divider()
        }
      }
    }
  }
}

private func macUsageDisplayName(_ raw: String) -> String {
  switch raw.lowercased() {
  case "openrouter": "OpenRouter"
  case "deepseek": "DeepSeek"
  case "anthropic": "Anthropic"
  case "gemini": "Gemini"
  case "nvidia": "NVIDIA"
  default: raw
  }
}

private func macUsageCompactTokens(_ value: Int) -> String {
  let number = Double(value)
  if value >= 1_000_000 { return String(format: "%.2fM", number / 1_000_000) }
  if value >= 1_000 { return String(format: "%.1fK", number / 1_000) }
  return value.formatted()
}

private func macUsageAggregateCost(_ aggregate: ChatUsageAggregate) -> String {
  guard aggregate.hasKnownCost else { return "Unavailable" }
  return (aggregate.hasPartialCost ? "≥" : "~") + macUsageFormatUSD(aggregate.costUSD)
}

private func macUsageFormatUSD(_ cost: Decimal) -> String {
  let value = NSDecimalNumber(decimal: cost).doubleValue
  if abs(value) < 0.001 { return String(format: "$%.6f", value) }
  if abs(value) < 1 { return String(format: "$%.4f", value) }
  return String(format: "$%.2f", value)
}

private func macUsageDuration(_ milliseconds: Double?) -> String {
  guard let milliseconds, milliseconds.isFinite, milliseconds >= 0 else { return "—" }
  if milliseconds < 1_000 { return "\(Int(milliseconds.rounded())) ms" }
  if milliseconds < 10_000 { return String(format: "%.2f s", milliseconds / 1_000) }
  return String(format: "%.1f s", milliseconds / 1_000)
}

private func macUsageRate(_ value: Double?) -> String {
  guard let value, value.isFinite, value >= 0 else { return "—" }
  return String(format: "%.1f tok/s", value)
}

private func macUsagePercent(_ value: Double?) -> String {
  guard let value, value.isFinite else { return "—" }
  return value.formatted(.percent.precision(.fractionLength(0...1)))
}

private func macAnalyticsErrorTitle(_ raw: String) -> String {
  raw.replacingOccurrences(of: "_", with: " ")
    .split(separator: " ")
    .map { $0.capitalized }
    .joined(separator: " ")
}
