import AppFoundation
import BYOKchatProviderCore
import Foundation
import SwiftUI

struct UsageDashboardView: View {
  let conversations: [ChatConversation]

  @Environment(\.dismiss) private var dismiss
  @Environment(PurchaseManager.self) private var purchaseManager
  @Environment(AppModel.self) private var model
  @Environment(\.appFoundationTheme) private var theme
  @State private var range: UsageRange = .today
  @State private var telemetryEvents: [TelemetryEvent] = []
  @State private var telemetryStatistics = TelemetryStoreStatistics.empty
  @State private var snapshot = UsageAnalyticsSnapshot(
    aggregate: ChatUsageAggregate(),
    performance: TelemetryPerformanceAggregate(),
    failureBreakdown: [],
    providerBreakdown: [],
    modelBreakdown: []
  )
  @State private var hasLoadedTelemetry = false
  @State private var telemetryUnavailable = false
  @State private var isLoadingTelemetry = false
  @State private var isClearingTelemetry = false
  @State private var confirmClearTelemetry = false
  @State private var showProUpsell = false
  @State private var didTrackOpening = false

  private struct DashboardReloadKey: Equatable {
    let range: UsageRange
    let conversationCount: Int
    let totalMessageCount: Int
    let latestConversationUpdate: Date?
  }

  private var reloadKey: DashboardReloadKey {
    DashboardReloadKey(
      range: accessibleRange,
      conversationCount: conversations.count,
      totalMessageCount: conversations.reduce(0) { $0 + $1.messages.count },
      latestConversationUpdate: conversations.map(\.updatedAt).max()
    )
  }

  init(
    conversations: [ChatConversation],
    openSidebar: (() -> Void)? = nil
  ) {
    self.conversations = conversations
    self.openSidebar = openSidebar
  }

  /// Set when this renders as the app's main screen (drawer Analytics
  /// destination): shows a leading sidebar-hamburger button and relies on the
  /// ambient navigation stack. When nil, wraps itself in a NavigationStack with
  /// a Done button.
  var openSidebar: (() -> Void)? = nil

  var body: some View {
    Group {
      if openSidebar != nil {
        dashboard
      } else {
        NavigationStack {
          dashboard
        }
      }
    }
  }

  private var dashboard: some View {
    let activeRange = accessibleRange

    return dashboardList(
      snapshot: snapshot,
      filteredEventCount: telemetryUnavailable ? 0 : telemetryEvents.count,
      range: activeRange
    )
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .refreshable {
      await loadAndCompute(retry: false)
    }
    .foregroundStyle(theme.primaryForegroundColor)
    .background(AppThemeBackground(theme: theme))
    .navigationTitle("Analytics")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        analyticsRangeMenu
      }
      if openSidebar != nil {
        ToolbarItem(placement: .cancellationAction) {
          Button("Open Sidebar", systemImage: "text.alignleft") { openSidebar?() }
            .labelStyle(.iconOnly)
            .accessibilityLabel("Open sidebar")
        }
      } else {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .task(id: reloadKey) {
      if !didTrackOpening {
        didTrackOpening = true
        BYOKAppAnalytics.track(.featureOpened, dimension: .analytics)
      }
      await loadAndCompute(retry: false)
    }
    .onChange(of: purchaseManager.hasPro) { _, hasPro in
      if !hasPro { range = .today }
    }
    .sheet(isPresented: $showProUpsell) {
      BYOKProUpsellFlow(feature: .analytics)
    }
    .confirmationDialog(
      "Clear local telemetry?",
      isPresented: $confirmClearTelemetry,
      titleVisibility: .visible
    ) {
      Button("Clear Local Telemetry", role: .destructive) {
        Task { await clearTelemetry() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Removes locally stored performance and reliability events and daily rollups. Saved chat history, usage, and spend are unaffected.")
    }
  }

  private func dashboardList(
    snapshot: UsageAnalyticsSnapshot,
    filteredEventCount: Int,
    range: UsageRange
  ) -> some View {
    List {
      usageSummarySection(
        snapshot.aggregate,
        activeConversationCount: snapshot.activeConversationCount,
        range: range
      )

      telemetryStatusSections(snapshot: snapshot)

      if !snapshot.providerBreakdown.isEmpty {
        providersSection(snapshot.providerBreakdown)
      }

      if !snapshot.modelBreakdown.isEmpty {
        modelsSection(snapshot.modelBreakdown)
      }

      if !snapshot.conversationBreakdown.isEmpty {
        topChatsSection(snapshot.conversationBreakdown)
      }

      localAnalyticsSection(filteredEventCount: filteredEventCount)
    }
  }

  /// This value, not the raw picker state, drives all aggregates and details.
  /// It prevents stale selections from exposing history after Pro expires.
  private var accessibleRange: UsageRange {
    range.accessible(hasPro: purchaseManager.hasPro)
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

  /// Locked ranges remain actionable upgrade entries in the native menu.
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

  private func usageSummarySection(
    _ aggregate: ChatUsageAggregate,
    activeConversationCount: Int,
    range: UsageRange
  ) -> some View {
    Section {
      LabeledContent("Spend", value: usageAggregateCostText(aggregate))
      if activeConversationCount > 0 {
        LabeledContent("Chats", value: activeConversationCount.formatted())
      }
      LabeledContent("Model requests", value: aggregate.modelRequestCount.formatted())
      if aggregate.totalTokens > 0 {
        LabeledContent("Total tokens", value: usageCompactTokens(aggregate.totalTokens))
      }
      LabeledContent("Input", value: usageCompactTokens(aggregate.inputTokens))
      LabeledContent("Output", value: usageCompactTokens(aggregate.outputTokens))
      if aggregate.cachedInputTokens > 0 {
        LabeledContent(
          "Cached input",
          value: usageCachedTokensWithRate(
            cached: aggregate.cachedInputTokens,
            input: aggregate.inputTokens,
            compact: true
          )
        )
      }
      if aggregate.cacheWriteTokens > 0 {
        LabeledContent("Cache write", value: usageCompactTokens(aggregate.cacheWriteTokens))
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
  private func telemetryStatusSections(snapshot: UsageAnalyticsSnapshot) -> some View {
    let performance = snapshot.performance
    let hasActivity = hasTelemetryActivity(performance)

    if telemetryUnavailable {
      Section {
        ContentUnavailableView(
          "Performance Data Unavailable",
          systemImage: "exclamationmark.triangle",
          description: Text("Local telemetry could not be read. Saved usage and spend remain available.")
        )
        Button("Retry") { Task { await loadAndCompute(retry: true) } }
          .disabled(isLoadingTelemetry || isClearingTelemetry)
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
      if hasActivity {
        reliabilitySection(performance)
      }
      if !snapshot.failureBreakdown.isEmpty {
        failureSection(snapshot.failureBreakdown)
      }
      if !hasActivity && snapshot.failureBreakdown.isEmpty {
        Section {
          ContentUnavailableView(
            "No Performance Data Yet",
            systemImage: "waveform.path.ecg",
            description: Text("Send a few messages to start collecting local performance metrics.")
          )
        }
        .listRowBackground(theme.surfaceColor)
      }
    }
  }

  private func performanceSection(_ performance: TelemetryPerformanceAggregate) -> some View {
    Section {
      LabeledContent("Median TTFT", value: usageDuration(performance.medianTTFTMilliseconds))
      if performance.p95TTFTMilliseconds != nil {
        LabeledContent("P95 TTFT", value: usageDuration(performance.p95TTFTMilliseconds))
      }
      LabeledContent("Median duration", value: usageDuration(performance.medianDurationMilliseconds))
      if performance.p95DurationMilliseconds != nil {
        LabeledContent("P95 duration", value: usageDuration(performance.p95DurationMilliseconds))
      }
      LabeledContent("Median speed", value: usageRate(performance.medianOutputTokensPerSecond))
    } header: {
      Text("Performance")
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }

  private func reliabilitySection(_ performance: TelemetryPerformanceAggregate) -> some View {
    Section {
      if performance.providerRequestCount > 0 {
        LabeledContent("Success rate", value: usagePercent(performance.providerSuccessRate))
        LabeledContent("Succeeded", value: performance.providerSuccessCount.formatted())
        LabeledContent("Failed", value: performance.providerFailureCount.formatted())
        if performance.providerCancelledCount > 0 {
          LabeledContent("Cancelled", value: performance.providerCancelledCount.formatted())
        }
      }
      if performance.toolCallCount > 0 {
        LabeledContent("Tool success", value: usagePercent(performance.toolSuccessRate))
        LabeledContent("Tool calls", value: performance.toolCallCount.formatted())
        if performance.toolCancelledCount > 0 {
          LabeledContent("Tool cancelled", value: performance.toolCancelledCount.formatted())
        }
      }
      if performance.mcpRequestCount > 0 {
        LabeledContent("MCP requests", value: performance.mcpRequestCount.formatted())
        LabeledContent("MCP failures", value: performance.mcpFailureCount.formatted())
      }
    } header: {
      Text("Reliability")
        .foregroundStyle(theme.secondaryForegroundColor)
    } footer: {
      Text("Provider success rate excludes user cancellations. Expected MCP legacy-protocol fallback is not counted as an MCP failure.")
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }

  private func failureSection(_ failures: [TelemetryFailureBreakdown]) -> some View {
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
    return Section {
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
    } header: {
      Text("Providers")
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }

  private func modelsSection(_ rows: [UsageAnalyticsBreakdown]) -> some View {
    Section {
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
    } header: {
      Text("Models")
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }

  private func topChatsSection(_ rows: [ConversationUsageBreakdown]) -> some View {
    Section {
      ForEach(Array(rows.prefix(5))) { item in
        UsageBreakdownRowView(
          row: UsageBreakdown(
            id: item.id.rawValue,
            title: item.title,
            aggregate: item.aggregate,
            performance: item.performance
          )
        )
      }
    } header: {
      Text("Top Chats")
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }

  private func localAnalyticsSection(filteredEventCount: Int) -> some View {
    Section {
      if telemetryUnavailable {
        LabeledContent("Telemetry", value: "Unavailable")
      } else if !hasLoadedTelemetry {
        LabeledContent("Telemetry events", value: "Loading…")
      } else {
        LabeledContent("Telemetry events", value: filteredEventCount.formatted())
        if telemetryStatistics.rollupRowCount > 0 {
          LabeledContent("Daily rollups", value: telemetryStatistics.rollupRowCount.formatted())
        }
      }
      if telemetryStatistics.databaseBytes > 0 {
        LabeledContent(
          "Local database",
          value: ByteCountFormatter.string(
            fromByteCount: telemetryStatistics.databaseBytes,
            countStyle: .file
          )
        )
      }
      if telemetryStatistics.eventCount > 0 || telemetryStatistics.rollupRowCount > 0 || telemetryUnavailable {
        Button("Clear Local Telemetry", role: .destructive) {
          confirmClearTelemetry = true
        }
        .disabled(isLoadingTelemetry || isClearingTelemetry)
      }
    } header: {
      Text("Local analytics")
        .foregroundStyle(theme.secondaryForegroundColor)
    } footer: {
      Text(telemetryFootnote)
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }

  private func hasTelemetryActivity(_ performance: TelemetryPerformanceAggregate) -> Bool {
    performance.providerRequestCount > 0 || performance.toolCallCount > 0 || performance.mcpRequestCount > 0
  }

  private var telemetryFootnote: String {
    if !purchaseManager.hasPro {
      return "Only today's local telemetry is shown. Historical ranges require Pro. Detailed events are kept for up to 30 days and summarized into lightweight daily rollups for long-term history."
    }
    if telemetryEvents.count >= TelemetryStoreConfiguration.maximumRecentEventQueryCount {
      let queryLimit = TelemetryStoreConfiguration.maximumRecentEventQueryCount.formatted()
      return "Recent performance uses up to \(queryLimit) detailed events in this range plus archived daily rollups. Raw telemetry is device-local, and saved chat usage remains available from message history."
    }
    return "Detailed telemetry is kept on device for up to 30 days and automatically summarized into daily rollups before pruning. Chat usage and spend remain available from message history even if telemetry is cleared."
  }

  private func loadAndCompute(retry: Bool) async {
    isLoadingTelemetry = true
    defer { isLoadingTelemetry = false }

    let activeRange = accessibleRange
    let referenceDate = Date.now
    let conversationsSnapshot = conversations
    let recorder = model.telemetryRecorder
    if retry { await recorder.retryAfterFailure() }

    let loadedEvents: [TelemetryEvent]
    let loadedRollups: [TelemetryDailyRollup]
    let loadedErrorRollups: [TelemetryDailyErrorRollup]
    let loadedStatistics: TelemetryStoreStatistics
    let unavailable: Bool

    switch await recorder.loadAnalytics(
      range: activeRange,
      reference: referenceDate,
      limit: TelemetryStoreConfiguration.maximumRecentEventQueryCount
    ) {
    case .loaded(let events, let rollups, let errorRollups, let statistics):
      loadedEvents = events
      loadedRollups = rollups
      loadedErrorRollups = errorRollups
      loadedStatistics = statistics
      unavailable = false
    case .unavailable:
      loadedEvents = []
      loadedRollups = []
      loadedErrorRollups = []
      loadedStatistics = .empty
      unavailable = true
    }

    guard !Task.isCancelled else { return }

    let computed = await Task.detached(priority: .userInitiated) {
      UsageAnalytics.snapshot(
        conversations: conversationsSnapshot,
        telemetryEvents: loadedEvents,
        dailyRollups: loadedRollups,
        dailyErrorRollups: loadedErrorRollups,
        range: activeRange,
        reference: referenceDate
      )
    }.value

    guard !Task.isCancelled else { return }

    telemetryEvents = loadedEvents
    telemetryStatistics = loadedStatistics
    telemetryUnavailable = unavailable
    snapshot = computed
    hasLoadedTelemetry = true
  }

  private func clearTelemetry() async {
    guard !isClearingTelemetry else { return }
    isClearingTelemetry = true
    defer { isClearingTelemetry = false }
    await model.telemetryRecorder.clearAllTelemetry()
    await loadAndCompute(retry: true)
  }
}

struct UsageBreakdownRowView: View {
  let row: UsageBreakdown

  @Environment(\.appFoundationTheme) private var theme

  private var hasSavedMessages: Bool {
    row.aggregate.assistantMessageCount > 0
  }

  private var performanceSummaryLine: String? {
    guard row.performance.providerRequestCount > 0 else { return nil }
    var parts = ["\(usagePercent(row.performance.providerSuccessRate)) success"]
    if let ttft = row.performance.medianTTFTMilliseconds {
      parts.append("\(usageDuration(ttft)) TTFT")
    }
    if let speed = row.performance.medianOutputTokensPerSecond {
      parts.append(usageRate(speed))
    }
    return parts.joined(separator: " · ")
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 3) {
        Text(row.title)
          .lineLimit(1)

        if hasSavedMessages {
          Text(
            "\(usageCompactTokens(row.aggregate.totalTokens)) tokens · \(usageRequestCountLabel(row.aggregate.modelRequestCount))"
          )
          .font(.caption)
          .foregroundStyle(theme.secondaryForegroundColor)
        } else if row.performance.providerRequestCount > 0 {
          Text("\(usageRequestCountLabel(row.performance.providerRequestCount)) · no saved messages")
            .font(.caption)
            .foregroundStyle(theme.secondaryForegroundColor)
        }

        if let performanceSummaryLine {
          Text(performanceSummaryLine)
            .font(.caption2)
            .foregroundStyle(theme.secondaryForegroundColor.opacity(0.72))
        }
      }
      Spacer(minLength: 12)
      Text(hasSavedMessages || row.performance.providerRequestCount == 0
        ? usageAggregateCostText(row.aggregate)
        : "—")
        .foregroundStyle(theme.secondaryForegroundColor)
        .monospacedDigit()
    }
  }
}
