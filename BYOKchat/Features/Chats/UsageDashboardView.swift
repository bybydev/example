import AppFoundation
import BYOKchatProviderCore
import Foundation
import SwiftUI

struct UsageDashboardView: View {
  let conversations: [ChatConversation]
  let currentConversationID: ConversationID?

  @Environment(\.dismiss) private var dismiss
  @Environment(PurchaseManager.self) private var purchaseManager
  @Environment(AppModel.self) private var model
  @Environment(\.appFoundationTheme) private var theme
  #if DEBUG
  @AppStorage("byokchat.usage.monthlyBudgetUSD") private var monthlyBudgetUSD = 0.0
  @AppStorage("byokchat.usage.budgetWarningFraction") private var budgetWarningFraction = 0.8
  #endif
  @State private var range: UsageRange = .today
  @State private var telemetryEvents: [TelemetryEvent] = []
  @State private var telemetryStatistics = TelemetryStoreStatistics.empty
  @State private var hasLoadedTelemetry = false
  @State private var telemetryUnavailable = false
  @State private var isLoadingTelemetry = false
  @State private var isClearingTelemetry = false
  @State private var confirmClearTelemetry = false
  @State private var showProUpsell = false
  @State private var didTrackOpening = false
  #if DEBUG
  @FocusState private var isBudgetFieldFocused: Bool
  #endif

  init(
    conversations: [ChatConversation],
    currentConversationID: ConversationID? = nil,
    openSidebar: (() -> Void)? = nil
  ) {
    self.conversations = conversations
    self.currentConversationID = currentConversationID
    self.openSidebar = openSidebar
  }

  /// Set when this renders as the app's main screen (drawer Usage
  /// destination): shows a leading sidebar-hamburger button and relies on the
  /// ambient navigation stack. Left nil for the chat ⋯-menu sheet, which keeps
  /// its own stack and a Done button.
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
    let referenceDate = Date.now
    let activeRange = accessibleRange
    let activeTelemetry = telemetryUnavailable ? [] : telemetryEvents
    let filteredEvents = UsageAnalytics.filteredAnalyticsEvents(
      activeTelemetry,
      range: activeRange,
      reference: referenceDate
    )
    let snapshot = UsageAnalytics.snapshot(
      conversations: conversations,
      telemetryEvents: activeTelemetry,
      range: activeRange,
      reference: referenceDate
    )

    return dashboardList(
      snapshot: snapshot,
      filteredEvents: filteredEvents,
      range: activeRange,
      referenceDate: referenceDate
    )
    .scrollContentBackground(.hidden)
    .refreshable {
      await loadTelemetry()
    }
    .foregroundStyle(theme.primaryForegroundColor)
    .background(AppThemeBackground(theme: theme))
    .navigationTitle("Analytics")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        analyticsRangeMenu
      }
      #if DEBUG
      if isBudgetFieldFocused {
        ToolbarItem(placement: .keyboard) {
          Button("Done") { isBudgetFieldFocused = false }
        }
      }
      #endif
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
      Text("Removes locally stored performance and reliability events. Saved chat history, usage, and spend are unaffected.")
    }
  }

  private func dashboardList(
    snapshot: UsageAnalyticsSnapshot,
    filteredEvents: [TelemetryEvent],
    range: UsageRange,
    referenceDate: Date
  ) -> some View {
    List {
      usageSummarySection(snapshot.aggregate, range: range)

      telemetryStatusSections(snapshot: snapshot)

      if let conversation = currentConversation {
        currentConversationSection(
          conversation,
          filteredEvents: filteredEvents,
          range: range,
          referenceDate: referenceDate
        )
      }

      if !snapshot.providerBreakdown.isEmpty {
        providersSection(snapshot.providerBreakdown)
      }

      if !snapshot.modelBreakdown.isEmpty {
        modelsSection(snapshot.modelBreakdown)
      }

      #if DEBUG
      monthlyBudgetSection(referenceDate: referenceDate)
      #endif

      localAnalyticsSection(filteredEventCount: filteredEvents.count)
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

  private func usageSummarySection(_ aggregate: ChatUsageAggregate, range: UsageRange) -> some View {
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
        Button("Retry") { Task { await loadTelemetry(retry: true) } }
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

  private func currentConversationSection(
    _ conversation: ChatConversation,
    filteredEvents: [TelemetryEvent],
    range: UsageRange,
    referenceDate: Date
  ) -> some View {
    let conversationSnapshot = UsageAnalytics.conversationSnapshot(
      conversation: conversation,
      telemetryEvents: filteredEvents,
      range: range,
      reference: referenceDate
    )

    return Section("This conversation") {
      NavigationLink {
        ConversationAnalyticsView(
          conversation: conversation,
          range: range,
          telemetryEvents: filteredEvents,
          telemetryAvailable: !telemetryUnavailable
        )
      } label: {
        conversationSummaryLabel(conversationSnapshot)
      }
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

  private func localAnalyticsSection(filteredEventCount: Int) -> some View {
    Section {
      if telemetryUnavailable {
        LabeledContent("Telemetry", value: "Unavailable")
      } else if !hasLoadedTelemetry {
        LabeledContent("Telemetry events", value: "Loading…")
      } else {
        LabeledContent("Telemetry events", value: filteredEventCount.formatted())
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
      if telemetryStatistics.eventCount > 0 || telemetryUnavailable {
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

  #if DEBUG
  private func monthlyBudgetSection(referenceDate: Date) -> some View {
    let budgetRange: UsageRange = purchaseManager.hasPro ? .month : .today
    let aggregate = ChatBilling.aggregate(
      messages: UsageAnalytics.filteredMessages(
        conversations: conversations,
        range: budgetRange,
        reference: referenceDate
      )
    )

    return Section {
      HStack {
        Text("Budget")
        Spacer()
        Text("$")
          .foregroundStyle(theme.secondaryForegroundColor)
        TextField("0", value: $monthlyBudgetUSD, format: .number.precision(.fractionLength(0...2)))
          .keyboardType(.decimalPad)
          .focused($isBudgetFieldFocused)
          .multilineTextAlignment(.trailing)
          .frame(maxWidth: 100)
      }

      Picker("Warn at", selection: $budgetWarningFraction) {
        Text("50%").tag(0.5)
        Text("75%").tag(0.75)
        Text("80%").tag(0.8)
        Text("90%").tag(0.9)
      }

      if monthlyBudgetUSD > 0 {
        LabeledContent(
          purchaseManager.hasPro ? "This month" : "Today only",
          value: usageAggregateCostText(aggregate)
        )
        if aggregate.assistantMessageCount == 0 {
          Text(purchaseManager.hasPro ? "No saved requests this month." : "No saved requests today.")
        } else if !aggregate.hasKnownCost {
          Label("Budget status unavailable: request costs are unknown.", systemImage: "questionmark.circle")
        } else {
          if !aggregate.hasPartialCost { ProgressView(value: budgetProgress(for: aggregate)) }
          if budgetWarningReached(for: aggregate) {
            Label(budgetWarningText(for: aggregate), systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
          } else if aggregate.hasPartialCost {
            Label("Budget status uncertain: incomplete costs may already exceed the threshold; estimates may differ in either direction.", systemImage: "questionmark.circle")
          }
        }
      }
    } header: {
      Text("Monthly budget")
        .foregroundStyle(theme.secondaryForegroundColor)
    } footer: {
      Text(purchaseManager.hasPro
        ? "The monthly budget warns about saved chat history; it is not a billing ledger. Regenerating, editing, or deleting messages can reduce totals. It excludes API-key usage in other apps and does not change provider spending limits."
        : "Free evaluates this monthly threshold using today's saved usage only. Earlier days are excluded, so warnings may underestimate monthly spending. Upgrade to Pro for a complete month. This does not change provider spending limits.")
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }
  #endif

  private func hasTelemetryActivity(_ performance: TelemetryPerformanceAggregate) -> Bool {
    performance.providerRequestCount > 0 || performance.toolCallCount > 0 || performance.mcpRequestCount > 0
  }

  private var currentConversation: ChatConversation? {
    guard let currentConversationID else { return nil }
    return conversations.first(where: { $0.id == currentConversationID })
  }

  private func conversationSummaryLabel(_ snapshot: ConversationUsageAnalyticsSnapshot) -> some View {
    let aggregate = snapshot.aggregate
    let performance = snapshot.performance
    let hasSavedMessages = aggregate.assistantMessageCount > 0

    return VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("Details")
        Spacer()
        Text(hasSavedMessages || performance.providerRequestCount == 0
          ? usageAggregateCostText(aggregate)
          : "—")
          .foregroundStyle(theme.secondaryForegroundColor)
          .monospacedDigit()
      }
      HStack(spacing: 6) {
        Text(usageRequestCountLabel(hasSavedMessages
          ? aggregate.modelRequestCount
          : performance.providerRequestCount))
        if performance.providerSuccessRate != nil {
          Text("·")
          Text("\(usagePercent(performance.providerSuccessRate)) success")
        }
        if performance.medianTTFTMilliseconds != nil {
          Text("·")
          Text("\(usageDuration(performance.medianTTFTMilliseconds)) TTFT")
        }
      }
      .font(.caption)
      .foregroundStyle(theme.secondaryForegroundColor)
    }
  }

  #if DEBUG
  private func budgetProgress(for aggregate: ChatUsageAggregate) -> Double {
    guard monthlyBudgetUSD > 0 else { return 0 }
    let spent = NSDecimalNumber(decimal: aggregate.costUSD).doubleValue
    return min(max(spent / monthlyBudgetUSD, 0), 1)
  }

  private func budgetWarningReached(for aggregate: ChatUsageAggregate) -> Bool {
    guard monthlyBudgetUSD > 0 else { return false }
    let spent = NSDecimalNumber(decimal: aggregate.costUSD).doubleValue
    return spent >= monthlyBudgetUSD * budgetWarningFraction
  }

  private func budgetWarningText(for aggregate: ChatUsageAggregate) -> String {
    if aggregate.hasPartialCost {
      return aggregate.hasEstimatedCost
        ? "Partial estimate reached the warning threshold"
        : "Known subtotal reached the warning threshold"
    }
    return aggregate.hasEstimatedCost
      ? "Estimated spend reached the warning threshold"
      : "Reported spend reached the warning threshold"
  }
  #endif

  private var telemetryFootnote: String {
    if !purchaseManager.hasPro {
      return "Only today's local telemetry is shown. Historical ranges require Pro. Events are retained on device for up to 30 days by default, and saved chat usage is retained with your messages."
    }
    if telemetryStatistics.analyticsEventCount > telemetryEvents.count {
      let queryLimit = TelemetryStoreConfiguration.maximumRecentEventQueryCount.formatted()
      return "Performance and reliability use the latest \(queryLimit) local analytics events. Raw telemetry is device-local, disposable, and retained for up to 30 days by default. Chat usage and spend remain available from message history."
    }
    return "Performance and reliability are calculated from device-local telemetry retained for up to 30 days by default. Chat usage and spend remain available from message history even if telemetry is cleared."
  }

  private func loadTelemetry(retry: Bool = false) async {
    guard !isLoadingTelemetry else { return }
    isLoadingTelemetry = true
    defer { isLoadingTelemetry = false }
    let recorder = model.telemetryRecorder
    if retry { await recorder.retryAfterFailure() }
    switch await recorder.loadAnalytics(limit: TelemetryStoreConfiguration.maximumRecentEventQueryCount) {
    case .loaded(let events, let statistics):
      telemetryEvents = events
      telemetryStatistics = statistics
      telemetryUnavailable = false
    case .unavailable:
      telemetryEvents = []
      telemetryStatistics = .empty
      telemetryUnavailable = true
    }
    hasLoadedTelemetry = true
  }

  private func clearTelemetry() async {
    guard !isClearingTelemetry else { return }
    isClearingTelemetry = true
    defer { isClearingTelemetry = false }
    await model.telemetryRecorder.clearAllTelemetry()
    await loadTelemetry(retry: true)
  }
}

private struct UsageBreakdownRowView: View {
  let row: UsageBreakdown

  @Environment(\.appFoundationTheme) private var theme

  private var hasSavedMessages: Bool {
    row.aggregate.assistantMessageCount > 0
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 3) {
        Text(row.title)
          .lineLimit(1)

        if hasSavedMessages {
          Text(
            "\(usageCompactTokens(row.aggregate.inputTokens + row.aggregate.outputTokens)) tokens · \(usageRequestCountLabel(row.aggregate.modelRequestCount))"
          )
          .font(.caption)
          .foregroundStyle(theme.secondaryForegroundColor)
        } else if row.performance.providerRequestCount > 0 {
          Text("\(usageRequestCountLabel(row.performance.providerRequestCount)) · no saved messages")
            .font(.caption)
            .foregroundStyle(theme.secondaryForegroundColor)
        }

        if row.performance.providerRequestCount > 0 {
          HStack(spacing: 4) {
            Text("\(usagePercent(row.performance.providerSuccessRate)) success")
            if row.performance.medianTTFTMilliseconds != nil {
              Text("·")
              Text("\(usageDuration(row.performance.medianTTFTMilliseconds)) TTFT")
            }
          }
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
