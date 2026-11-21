import AppFoundation
import BYOKchatProviderCore
import Foundation
import SwiftUI

struct ConversationAnalyticsView: View {
  let conversation: ChatConversation

  @Environment(\.dismiss) private var dismiss
  @Environment(PurchaseManager.self) private var purchaseManager
  @Environment(AppModel.self) private var model
  @Environment(\.appFoundationTheme) private var theme

  // Pro users see the entire conversation by default and can narrow by date range.
  // Free users are strictly clamped to Today via accessibleRange.
  @State private var range: UsageRange = .all
  @State private var telemetryEvents: [TelemetryEvent] = []
  @State private var hasLoadedTelemetry = false
  @State private var telemetryUnavailable = false
  @State private var isLoadingTelemetry = false
  @State private var showProUpsell = false
  @State private var didTrackOpening = false

  private var accessibleRange: UsageRange {
    range.accessible(hasPro: purchaseManager.hasPro)
  }

  private var navigationTitleText: String {
    let trimmed = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Chat Analytics" : trimmed
  }

  var body: some View {
    NavigationStack {
      let referenceDate = Date.now
      let activeRange = accessibleRange
      let activeTelemetry = telemetryUnavailable ? [] : telemetryEvents
      let snapshot = UsageAnalytics.conversationSnapshot(
        conversation: conversation,
        telemetryEvents: activeTelemetry,
        range: activeRange,
        reference: referenceDate
      )

      List {
        usageSection(snapshot.aggregate, range: activeRange)

        telemetryStatusSections(snapshot: snapshot)

        if snapshot.providerBreakdown.count > 1 {
          providersSection(snapshot.providerBreakdown)
        }

        if !snapshot.modelBreakdown.isEmpty {
          modelsSection(snapshot.modelBreakdown)
        }
      }
      .listStyle(.insetGrouped)
      .scrollContentBackground(.hidden)
      .refreshable {
        await loadTelemetry()
      }
      .foregroundStyle(theme.primaryForegroundColor)
      .background(AppThemeBackground(theme: theme))
      .navigationTitle(navigationTitleText)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          analyticsRangeMenu
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .task {
        if !didTrackOpening {
          didTrackOpening = true
          BYOKAppAnalytics.track(.featureOpened, dimension: .analytics)
        }
        await loadTelemetry()
      }
      .onChange(of: purchaseManager.hasPro) { _, hasPro in
        if !hasPro { range = .today }
      }
      .sheet(isPresented: $showProUpsell) {
        BYOKProUpsellFlow(feature: .analytics)
      }
    }
  }

  private var analyticsRangeMenu: some View {
    Menu {
      ForEach(UsageRange.allCases) { value in
        rangeMenuButton(for: value)
      }
    } label: {
      Text(accessibleRange.label)
    }
    .menuIndicator(.hidden)
    .accessibilityLabel("Analytics date range, \(accessibleRange.label)")
    .accessibilityHint("Choose the analytics date range.")
  }

  private func rangeMenuButton(for value: UsageRange) -> some View {
    let locked = value.requiresPro && !purchaseManager.hasPro
    let selected = accessibleRange == value

    return Button {
      if locked {
        showProUpsell = true
      } else if accessibleRange != value {
        range = value
        BYOKAppAnalytics.track(.analyticsRangeSelected, dimension: .init(range: value))
      }
    } label: {
      if locked {
        Label(value.label, systemImage: "lock.fill")
      } else if selected {
        Label(value.label, systemImage: "checkmark")
      } else {
        Text(value.label)
      }
    }
    .accessibilityLabel(locked ? "\(value.label), locked, requires BYOK Pro" : value.label)
    .accessibilityHint(locked
      ? "Open BYOK Pro to unlock historical analytics."
      : "Show analytics for \(value.label).")
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private func usageSection(_ aggregate: ChatUsageAggregate, range: UsageRange) -> some View {
    Section {
      LabeledContent("Spend", value: usageAggregateCostText(aggregate))
      LabeledContent("Model requests", value: aggregate.modelRequestCount.formatted())
      LabeledContent("Input", value: usageCompactTokens(aggregate.inputTokens))
      LabeledContent("Output", value: usageCompactTokens(aggregate.outputTokens))
      if aggregate.cachedInputTokens > 0 {
        LabeledContent("Cached input", value: usageCompactTokens(aggregate.cachedInputTokens))
      }
      if aggregate.reasoningTokens > 0 {
        LabeledContent("Reasoning", value: usageCompactTokens(aggregate.reasoningTokens))
      }
      if aggregate.toolCallCount > 0 {
        LabeledContent("Tool calls", value: aggregate.toolCallCount.formatted())
      }
    } header: {
      Text("Usage · \(range.label)")
        .foregroundStyle(theme.secondaryForegroundColor)
    } footer: {
      Text(usageHistoryFootnote(aggregate))
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }

  @ViewBuilder
  private func telemetryStatusSections(snapshot: ConversationUsageAnalyticsSnapshot) -> some View {
    let performance = snapshot.performance
    let hasActivity = hasTelemetryActivity(performance)

    if telemetryUnavailable {
      Section {
        ContentUnavailableView(
          "Performance Data Unavailable",
          systemImage: "exclamationmark.triangle",
          description: Text("Local telemetry could not be read. Saved usage and spend remain available.")
        )
        Button("Retry") { Task { await loadTelemetry(retry: true) } }
          .disabled(isLoadingTelemetry)
      }
      .listRowBackground(theme.surfaceColor)
    } else if !hasLoadedTelemetry {
      Section {
        HStack(spacing: 10) {
          ProgressView()
          Text("Loading performance data…")
            .foregroundStyle(theme.secondaryForegroundColor)
        }
      }
      .listRowBackground(theme.surfaceColor)
    } else {
      if performance.hasLatencyOrSpeedMetrics {
        performanceSection(performance)
      }
      if performance.providerRequestCount > 0 {
        reliabilitySection(performance)
      }
      if performance.toolCallCount > 0 || performance.mcpRequestCount > 0 {
        toolsAndMCPSection(performance)
      }
      if !snapshot.failureBreakdown.isEmpty {
        errorsSection(snapshot.failureBreakdown)
      }
      if !hasActivity && snapshot.failureBreakdown.isEmpty {
        Section {
          ContentUnavailableView(
            "No Performance Data Yet",
            systemImage: "waveform.path.ecg",
            description: Text("No local performance metrics are stored for this conversation in the selected range.")
          )
        }
        .listRowBackground(theme.surfaceColor)
      }
    }
  }

  private func performanceSection(_ performance: TelemetryPerformanceAggregate) -> some View {
    Section("Performance") {
      LabeledContent("Median TTFT", value: usageDuration(performance.medianTTFTMilliseconds))
      LabeledContent("P95 TTFT", value: usageDuration(performance.p95TTFTMilliseconds))
      LabeledContent("Median duration", value: usageDuration(performance.medianDurationMilliseconds))
      LabeledContent("P95 duration", value: usageDuration(performance.p95DurationMilliseconds))
      LabeledContent("Median speed", value: usageRate(performance.medianOutputTokensPerSecond))
    }
    .listRowBackground(theme.surfaceColor)
  }

  private func reliabilitySection(_ performance: TelemetryPerformanceAggregate) -> some View {
    Section {
      LabeledContent("Success rate", value: usagePercent(performance.providerSuccessRate))
      LabeledContent("Succeeded", value: performance.providerSuccessCount.formatted())
      LabeledContent("Failed", value: performance.providerFailureCount.formatted())
      if performance.providerCancelledCount > 0 {
        LabeledContent("Cancelled", value: performance.providerCancelledCount.formatted())
      }
    } header: {
      Text("Reliability")
        .foregroundStyle(theme.secondaryForegroundColor)
    } footer: {
      Text("Provider success rate excludes user cancellations.")
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }

  private func toolsAndMCPSection(_ performance: TelemetryPerformanceAggregate) -> some View {
    Section("Tools & MCP") {
      if performance.toolCallCount > 0 {
        LabeledContent("Tool calls", value: performance.toolCallCount.formatted())
        LabeledContent("Tool success", value: usagePercent(performance.toolSuccessRate))
        if performance.toolFailureCount > 0 {
          LabeledContent("Tool failures", value: performance.toolFailureCount.formatted())
        }
        if performance.toolCancelledCount > 0 {
          LabeledContent("Tool cancelled", value: performance.toolCancelledCount.formatted())
        }
      }
      if performance.mcpRequestCount > 0 {
        LabeledContent("MCP requests", value: performance.mcpRequestCount.formatted())
        LabeledContent("MCP failures", value: performance.mcpFailureCount.formatted())
      }
    }
    .listRowBackground(theme.surfaceColor)
  }

  private func errorsSection(_ failures: [TelemetryFailureBreakdown]) -> some View {
    Section {
      ForEach(Array(failures.prefix(8))) { failure in
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 2) {
            Text(usageErrorTitle(failure.errorCode))
              .lineLimit(1)
            Text(
              "\(usageCategoryTitle(failure.category)) · \(failure.classification.replacingOccurrences(of: "_", with: " "))"
            )
            .font(.caption)
            .foregroundStyle(theme.secondaryForegroundColor)
          }
          Spacer(minLength: 12)
          Text(failure.count.formatted())
            .foregroundStyle(theme.secondaryForegroundColor)
            .monospacedDigit()
        }
      }
    } header: {
      Text("Errors")
        .foregroundStyle(theme.secondaryForegroundColor)
    } footer: {
      Text("Only stable, privacy-safe error codes are shown. Provider response text and request content are never stored in analytics.")
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }

  private func providersSection(_ rows: [UsageAnalyticsBreakdown]) -> some View {
    let accounts = model.providers.accounts
    return Section("Providers") {
      ForEach(rows) { item in
        UsageBreakdownRowView(
          row: UsageBreakdown(
            id: item.id,
            title: usageDisplayName(item.id, accounts: accounts),
            aggregate: item.aggregate,
            performance: item.performance
          )
        )
      }
    }
    .listRowBackground(theme.surfaceColor)
  }

  private func modelsSection(_ rows: [UsageAnalyticsBreakdown]) -> some View {
    Section("Models") {
      ForEach(rows) { item in
        UsageBreakdownRowView(
          row: UsageBreakdown(
            id: item.id,
            title: item.id,
            aggregate: item.aggregate,
            performance: item.performance
          )
        )
      }
    }
    .listRowBackground(theme.surfaceColor)
  }

  private func hasTelemetryActivity(_ performance: TelemetryPerformanceAggregate) -> Bool {
    performance.providerRequestCount > 0 || performance.toolCallCount > 0 || performance.mcpRequestCount > 0
  }

  private func loadTelemetry(retry: Bool = false) async {
    guard !isLoadingTelemetry else { return }
    isLoadingTelemetry = true
    defer { isLoadingTelemetry = false }
    let recorder = model.telemetryRecorder
    if retry { await recorder.retryAfterFailure() }
    switch await recorder.loadAnalytics(limit: TelemetryStoreConfiguration.maximumRecentEventQueryCount) {
    case .loaded(let events, _):
      telemetryEvents = events
      telemetryUnavailable = false
    case .unavailable:
      telemetryEvents = []
      telemetryUnavailable = true
    }
    hasLoadedTelemetry = true
  }
}
