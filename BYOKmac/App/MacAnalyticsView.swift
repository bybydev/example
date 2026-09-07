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

enum MacAnalyticsWorkspaceSection: String, CaseIterable, Identifiable {
  case overview = "Overview"
  case conversations = "Conversations"

  var id: String { rawValue }
}

struct MacAnalyticsView: View {
  @State private var analytics: MacAnalyticsModel
  @State private var range: UsageAnalyticsRange = .month
  @State private var section: MacAnalyticsWorkspaceSection = .overview
  @State private var selectedConversationID: String?
  @State private var conversationSearchText = ""
  @AppStorage("byokchat.usage.monthlyBudgetUSD") private var monthlyBudgetUSD = 0.0
  @AppStorage("byokchat.usage.budgetWarningFraction") private var budgetWarningFraction = 0.8

  init(services: BYOKCoreServices) {
    _analytics = State(initialValue: MacAnalyticsModel(services: services))
  }

  private var selectedConversation: ChatConversation? {
    guard let selectedConversationID else { return nil }
    return analytics.conversations.first { $0.id.rawValue == selectedConversationID }
  }

  private var filteredConversations: [ChatConversation] {
    let query = conversationSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return analytics.conversations }
    return analytics.conversations.filter { conversation in
      let title = conversation.title.isEmpty ? "New Chat" : conversation.title
      return title.localizedCaseInsensitiveContains(query)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      workspaceControls
      Divider()

      if analytics.isLoading && !analytics.hasLoaded {
        loadingView
      } else if let conversation = selectedConversation {
        conversationDetail(conversation)
      } else {
        switch section {
        case .overview:
          overview
        case .conversations:
          conversations
        }
      }
    }
    .frame(minWidth: 920, minHeight: 620)
    .background(MacDesignTokens.Colors.canvas)
    .task { await analytics.load() }
    .onChange(of: analytics.conversations.map(\.id.rawValue)) { _, ids in
      if let selectedConversationID, !ids.contains(selectedConversationID) {
        self.selectedConversationID = nil
      }
    }
  }

  private var workspaceControls: some View {
    HStack(spacing: 12) {
      if selectedConversation != nil {
        Button {
          selectedConversationID = nil
          section = .conversations
        } label: {
          Label("Conversations", systemImage: "chevron.left")
        }
        .buttonStyle(.plain)
        .foregroundStyle(MacDesignTokens.Colors.accent)
      } else {
        Picker("Section", selection: $section) {
          ForEach(MacAnalyticsWorkspaceSection.allCases) { value in
            Text(value.rawValue).tag(value)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 260)
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

      Button {
        Task { await analytics.load() }
      } label: {
        Label(analytics.isLoading ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
      }
      .disabled(analytics.isLoading)
    }
    .padding(.horizontal, 16)
    .frame(height: 54)
    .background(MacDesignTokens.Colors.surface.opacity(0.45))
  }

  private var loadingView: some View {
    VStack(spacing: 12) {
      ProgressView()
      Text("Loading local analytics…")
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(MacDesignTokens.Colors.canvas)
  }

  private var overview: some View {
    let snapshot = analytics.snapshot(range: range)
    let month = analytics.snapshot(range: .month)

    return ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        analyticsHeading(
          title: "Usage",
          subtitle: "Local usage and spend for \(range.label.lowercased())."
        )

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

        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 320, maximum: 520), spacing: 12, alignment: .top)],
          alignment: .leading,
          spacing: 12
        ) {
          performanceCard(snapshot.performance)
          reliabilityCard(snapshot.performance)

          if !snapshot.failureBreakdown.isEmpty {
            errorsCard(snapshot)
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

          budgetCard(month.aggregate)
          localAnalyticsCard
        }
      }
      .frame(maxWidth: 980, alignment: .leading)
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .background(MacDesignTokens.Colors.canvas)
  }

  private var conversations: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        analyticsHeading(
          title: "Conversations",
          subtitle: "Inspect usage and reliability for individual chats."
        )

        MacAnalyticsSearchField(
          placeholder: "Search conversations",
          text: $conversationSearchText
        )
        .frame(maxWidth: 420)

        Text("\(filteredConversations.count) conversation\(filteredConversations.count == 1 ? "" : "s")")
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)

        if filteredConversations.isEmpty {
          if conversationSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView(
              "No Conversations",
              systemImage: "bubble.left.and.bubble.right",
              description: Text("Start chatting to see per-conversation analytics here.")
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 70)
          } else {
            ContentUnavailableView.search(text: conversationSearchText)
              .frame(maxWidth: .infinity)
              .padding(.top, 70)
          }
        } else {
          LazyVStack(spacing: 9) {
            ForEach(filteredConversations) { conversation in
              conversationCard(conversation)
            }
          }
        }
      }
      .frame(maxWidth: 860, alignment: .leading)
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .background(MacDesignTokens.Colors.canvas)
  }

  private func conversationCard(_ conversation: ChatConversation) -> some View {
    let snapshot = analytics.conversationSnapshot(conversation, range: range)
    let totalTokens = snapshot.aggregate.inputTokens + snapshot.aggregate.outputTokens
    let title = conversation.title.isEmpty ? "New Chat" : conversation.title

    return Button {
      selectedConversationID = conversation.id.rawValue
    } label: {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .top, spacing: 12) {
          VStack(alignment: .leading, spacing: 3) {
            Text(title)
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(MacDesignTokens.Colors.textPrimary)
              .lineLimit(1)
            Text(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }
          Spacer()
          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }

        HStack(spacing: 16) {
          conversationStat(snapshot.aggregate.modelRequestCount.formatted(), label: "requests")
          conversationStat(macUsageCompactTokens(totalTokens), label: "tokens")
          conversationStat(macUsageAggregateCost(snapshot.aggregate), label: "spend")
          Spacer()
        }
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 10))
      .overlay {
        RoundedRectangle(cornerRadius: 10)
          .stroke(MacDesignTokens.Colors.separator.opacity(0.75), lineWidth: 0.5)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func conversationStat(_ value: String, label: String) -> some View {
    HStack(spacing: 4) {
      Text(value)
        .font(.caption.weight(.semibold))
        .foregroundStyle(MacDesignTokens.Colors.textPrimary)
      Text(label)
        .font(.caption)
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
    }
  }

  private func conversationDetail(_ conversation: ChatConversation) -> some View {
    let snapshot = analytics.conversationSnapshot(conversation, range: range)
    let title = conversation.title.isEmpty ? "New Chat" : conversation.title

    return ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        analyticsHeading(
          title: title,
          subtitle: "Conversation analytics · \(range.label) · updated \(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))"
        )

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

        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 320, maximum: 520), spacing: 12, alignment: .top)],
          alignment: .leading,
          spacing: 12
        ) {
          performanceCard(snapshot.performance)
          reliabilityCard(snapshot.performance)
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
      .frame(maxWidth: 900, alignment: .leading)
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .background(MacDesignTokens.Colors.canvas)
  }

  @ViewBuilder
  private func performanceCard(_ performance: TelemetryPerformanceAggregate) -> some View {
    MacAnalyticsSection(title: "Performance", symbol: hasPerformance(performance) ? "gauge.with.dots.needle.67percent" : "waveform.path.ecg") {
      if hasPerformance(performance) {
        VStack(spacing: 9) {
          MacAnalyticsLabeledRow("Median TTFT", value: macUsageDuration(performance.medianTTFTMilliseconds))
          MacAnalyticsLabeledRow("P95 TTFT", value: macUsageDuration(performance.p95TTFTMilliseconds))
          MacAnalyticsLabeledRow("Median Duration", value: macUsageDuration(performance.medianDurationMilliseconds))
          MacAnalyticsLabeledRow("P95 Duration", value: macUsageDuration(performance.p95DurationMilliseconds))
          MacAnalyticsLabeledRow("Median Speed", value: macUsageRate(performance.medianOutputTokensPerSecond))
        }
      } else {
        Text("Send a few messages to start collecting local performance metrics.")
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
      }
    }
  }

  private func reliabilityCard(_ performance: TelemetryPerformanceAggregate) -> some View {
    MacAnalyticsSection(title: "Reliability", symbol: "checkmark.shield") {
      VStack(spacing: 9) {
        if hasPerformance(performance) {
          MacAnalyticsLabeledRow("Success Rate", value: macUsagePercent(performance.providerSuccessRate))
          MacAnalyticsLabeledRow("Succeeded", value: performance.providerSuccessCount.formatted())
          MacAnalyticsLabeledRow("Failed", value: performance.providerFailureCount.formatted())
          if performance.providerCancelledCount > 0 {
            MacAnalyticsLabeledRow("Cancelled", value: performance.providerCancelledCount.formatted())
          }
          if performance.toolCallCount > 0 {
            Divider()
            MacAnalyticsLabeledRow("Tool Success", value: macUsagePercent(performance.toolSuccessRate))
            MacAnalyticsLabeledRow("Tool Calls", value: performance.toolCallCount.formatted())
          }
          if performance.mcpRequestCount > 0 {
            MacAnalyticsLabeledRow("MCP Requests", value: performance.mcpRequestCount.formatted())
            MacAnalyticsLabeledRow("MCP Failures", value: performance.mcpFailureCount.formatted())
          }
        } else {
          Text("Reliability metrics appear after provider, tool, or MCP requests are recorded.")
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }
      }
    }
  }

  private func errorsCard(_ snapshot: UsageAnalyticsSnapshot) -> some View {
    MacAnalyticsSection(title: "Errors", symbol: "exclamationmark.triangle") {
      VStack(spacing: 0) {
        let failures = Array(snapshot.failureBreakdown.prefix(8))
        ForEach(failures) { failure in
          HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
              Text(macAnalyticsErrorTitle(failure.errorCode))
                .foregroundStyle(MacDesignTokens.Colors.textPrimary)
              Text("\(failure.category.rawValue.capitalized) · \(failure.classification.replacingOccurrences(of: "_", with: " "))")
                .font(.caption)
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
            }
            Spacer()
            Text(failure.count.formatted())
              .monospacedDigit()
              .foregroundStyle(Color.orange)
          }
          .padding(.vertical, 7)

          if failure.id != failures.last?.id {
            Divider()
          }
        }
      }
    }
  }

  private func budgetCard(_ aggregate: ChatUsageAggregate) -> some View {
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
          ProgressView(value: budgetProgress(aggregate))
          MacAnalyticsLabeledRow("This Month", value: macUsageAggregateCost(aggregate))
          if budgetWarningReached(aggregate) {
            Label("Budget warning threshold reached", systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }

        Text("This local warning does not change provider-side spending limits or include API-key usage from other apps.")
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private var localAnalyticsCard: some View {
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

  private func analyticsHeading(title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(.title3.weight(.semibold))
        .foregroundStyle(MacDesignTokens.Colors.textPrimary)
      Text(subtitle)
        .font(.caption)
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
    }
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

struct MacAnalyticsMetric: Identifiable {
  let title: String
  let value: String
  let symbol: String

  var id: String { title }
}

struct MacAnalyticsMetricGrid: View {
  let metrics: [MacAnalyticsMetric]

  private let columns = [
    GridItem(.adaptive(minimum: 135, maximum: 220), spacing: 10, alignment: .top)
  ]

  var body: some View {
    LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
      ForEach(metrics) { metric in
        VStack(alignment: .leading, spacing: 9) {
          HStack(spacing: 6) {
            Image(systemName: metric.symbol)
            Text(metric.title.uppercased())
          }
          .font(.caption2.weight(.semibold))
          .foregroundStyle(MacDesignTokens.Colors.textMuted)

          Text(metric.value)
            .font(.system(size: 20, weight: .semibold, design: .rounded))
            .foregroundStyle(MacDesignTokens.Colors.textPrimary)
            .monospacedDigit()
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .padding(13)
        .background(
          MacDesignTokens.Colors.surface,
          in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 10)
            .stroke(MacDesignTokens.Colors.separator.opacity(0.75), lineWidth: 0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metric.title)
        .accessibilityValue(metric.value)
      }
    }
  }
}

struct MacAnalyticsSection<Content: View>: View {
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
        .foregroundStyle(MacDesignTokens.Colors.textPrimary)
        .accessibilityAddTraits(.isHeader)

      content
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      MacDesignTokens.Colors.surface,
      in: RoundedRectangle(cornerRadius: 10)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(MacDesignTokens.Colors.separator.opacity(0.75), lineWidth: 0.5)
    }
  }
}

struct MacAnalyticsLabeledRow: View {
  let title: String
  let value: String

  init(_ title: String, value: String) {
    self.title = title
    self.value = value
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title)
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
      Spacer(minLength: 20)
      Text(value)
        .foregroundStyle(MacDesignTokens.Colors.textPrimary)
        .monospacedDigit()
        .textSelection(.enabled)
    }
    .font(.system(size: 13))
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
              .foregroundStyle(MacDesignTokens.Colors.textPrimary)
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

struct MacAnalyticsSearchField: View {
  let placeholder: String
  @Binding var text: String

  var body: some View {
    HStack(spacing: 7) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
      TextField(placeholder, text: $text)
        .textFieldStyle(.plain)
      if !text.isEmpty {
        Button { text = "" } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 10)
    .frame(height: 32)
    .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(MacDesignTokens.Colors.separator.opacity(0.75), lineWidth: 0.5)
    }
  }
}

func macUsageDisplayName(_ raw: String) -> String {
  switch raw.lowercased() {
  case "openrouter": "OpenRouter"
  case "deepseek": "DeepSeek"
  case "anthropic": "Anthropic"
  case "gemini": "Gemini"
  case "nvidia": "NVIDIA"
  default: raw
  }
}

func macUsageCompactTokens(_ value: Int) -> String {
  let number = Double(value)
  if value >= 1_000_000 { return String(format: "%.2fM", number / 1_000_000) }
  if value >= 1_000 { return String(format: "%.1fK", number / 1_000) }
  return value.formatted()
}

func macUsageAggregateCost(_ aggregate: ChatUsageAggregate) -> String {
  guard aggregate.hasKnownCost else { return "Unavailable" }
  return (aggregate.hasPartialCost ? "≥" : "~") + macUsageFormatUSD(aggregate.costUSD)
}

func macUsageFormatUSD(_ cost: Decimal) -> String {
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
