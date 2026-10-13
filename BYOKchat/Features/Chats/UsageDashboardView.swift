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
    List {
      usageSummarySection

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
      } else if hasPerformanceData {
        performanceSection
        reliabilitySection
        if !failureBreakdown.isEmpty {
          failureSection
        }
      } else if hasLoadedTelemetry {
        Section {
          ContentUnavailableView(
            "No Performance Data Yet",
            systemImage: "waveform.path.ecg",
            description: Text("Send a few messages to start collecting local performance metrics.")
          )
        }
        .listRowBackground(theme.surfaceColor)
      }

      if let conversation = currentConversation {
        Section("This conversation") {
          NavigationLink {
            ConversationAnalyticsView(
              conversation: conversation,
              range: accessibleRange,
              telemetryEvents: filteredTelemetryEvents,
              telemetryAvailable: !telemetryUnavailable
            )
          } label: {
            conversationSummaryLabel(conversation)
          }
        }
        .listRowBackground(theme.surfaceColor)
      }

      if !providerBreakdown.isEmpty {
        Section("Providers") {
          ForEach(providerBreakdown) { row in
            UsageBreakdownRowView(row: row)
          }
        }
        .listRowBackground(theme.surfaceColor)
      }

      if !modelBreakdown.isEmpty {
        Section("Models") {
          ForEach(modelBreakdown) { row in
            UsageBreakdownRowView(row: row)
          }
        }
        .listRowBackground(theme.surfaceColor)
      }

      #if DEBUG
      monthlyBudgetSection
      #endif

      Section {
        if telemetryUnavailable {
          LabeledContent("Telemetry", value: "Unavailable")
        } else {
          LabeledContent("Telemetry events", value: filteredTelemetryEvents.count.formatted())
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
      } header: {
        Text("Local analytics")
          .foregroundStyle(theme.secondaryForegroundColor)
      } footer: {
        Text(telemetryFootnote)
          .foregroundStyle(theme.secondaryForegroundColor)
      }
      .listRowBackground(theme.surfaceColor)

    }
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

  private var usageSummarySection: some View {
    Section {
      LabeledContent("Spend", value: usageAggregateCostText(filteredAggregate))
      LabeledContent("Model requests", value: filteredAggregate.modelRequestCount.formatted())
      LabeledContent("Input", value: usageCompactTokens(filteredAggregate.inputTokens))
      LabeledContent("Output", value: usageCompactTokens(filteredAggregate.outputTokens))
      if filteredAggregate.cachedInputTokens > 0 {
        LabeledContent("Cached input", value: usageCompactTokens(filteredAggregate.cachedInputTokens))
      }
      if filteredAggregate.reasoningTokens > 0 {
        LabeledContent("Reasoning", value: usageCompactTokens(filteredAggregate.reasoningTokens))
      }
      if filteredAggregate.toolCallCount > 0 {
        LabeledContent("Tool calls", value: filteredAggregate.toolCallCount.formatted())
      }
    } header: {
      Text("Usage · \(accessibleRange.label)")
        .foregroundStyle(theme.secondaryForegroundColor)
    } footer: {
      Text(usageHistoryFootnote(filteredAggregate))
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }

  private var performanceSection: some View {
    Section("Performance") {
      LabeledContent("Median TTFT", value: usageDuration(performance.medianTTFTMilliseconds))
      LabeledContent("P95 TTFT", value: usageDuration(performance.p95TTFTMilliseconds))
      LabeledContent("Median duration", value: usageDuration(performance.medianDurationMilliseconds))
      LabeledContent("P95 duration", value: usageDuration(performance.p95DurationMilliseconds))
      LabeledContent("Median speed", value: usageRate(performance.medianOutputTokensPerSecond))
    }
    .listRowBackground(theme.surfaceColor)
  }

  private var reliabilitySection: some View {
    Section {
      LabeledContent("Success rate", value: usagePercent(performance.providerSuccessRate))
      LabeledContent("Succeeded", value: performance.providerSuccessCount.formatted())
      LabeledContent("Failed", value: performance.providerFailureCount.formatted())
      if performance.providerCancelledCount > 0 {
        LabeledContent("Cancelled", value: performance.providerCancelledCount.formatted())
      }
      if performance.toolCallCount > 0 {
        LabeledContent("Tool success", value: usagePercent(performance.toolSuccessRate))
        LabeledContent("Tool calls", value: performance.toolCallCount.formatted())
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

  private var failureSection: some View {
    Section {
      ForEach(Array(failureBreakdown.prefix(8))) { failure in
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 2) {
            Text(errorTitle(failure.errorCode))
              .lineLimit(1)
            Text("\(failure.category.rawValue.capitalized) · \(failure.classification.replacingOccurrences(of: "_", with: " "))")
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

  #if DEBUG
  private var monthlyBudgetSection: some View {
    Section {
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
        LabeledContent(purchaseManager.hasPro ? "This month" : "Today only", value: usageAggregateCostText(budgetAggregate))
        if budgetAggregate.assistantMessageCount == 0 {
          Text(purchaseManager.hasPro ? "No saved requests this month." : "No saved requests today.")
        } else if !budgetAggregate.hasKnownCost {
          Label("Budget status unavailable: request costs are unknown.", systemImage: "questionmark.circle")
        } else {
          if !budgetAggregate.hasPartialCost { ProgressView(value: budgetProgress) }
          if budgetWarningReached {
            Label(budgetWarningText, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
          } else if budgetAggregate.hasPartialCost {
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

  private var filteredMessages: [ChatMessage] {
    messages(since: accessibleRange.startDate(reference: .now))
  }

  private var filteredAggregate: ChatUsageAggregate {
    ChatBilling.aggregate(messages: filteredMessages)
  }

  private var filteredTelemetryEvents: [TelemetryEvent] {
    guard !telemetryUnavailable else { return [] }
    let startDate = accessibleRange.startDate(reference: .now)
    return telemetryEvents.filter { event in
      guard event.dataClass == .analytics else { return false }
      guard let startDate else { return true }
      return event.timestamp >= startDate
    }
  }

  private var performance: TelemetryPerformanceAggregate {
    TelemetryAnalytics.aggregate(events: filteredTelemetryEvents)
  }

  private var failureBreakdown: [TelemetryFailureBreakdown] {
    TelemetryAnalytics.failureBreakdown(events: filteredTelemetryEvents)
  }

  private var hasPerformanceData: Bool {
    performance.providerRequestCount > 0 || performance.toolCallCount > 0 || performance.mcpRequestCount > 0
  }

  private var currentConversation: ChatConversation? {
    guard let currentConversationID else { return nil }
    return conversations.first(where: { $0.id == currentConversationID })
  }

  #if DEBUG
  /// Budget thresholds remain monthly. Without Pro, only today's portion of
  /// the month can be evaluated; never read or display earlier days.
  private var budgetAggregate: ChatUsageAggregate {
    let budgetRange: UsageRange = purchaseManager.hasPro ? .month : .today
    return ChatBilling.aggregate(messages: messages(since: budgetRange.startDate(reference: .now)))
  }
  #endif

  private var providerBreakdown: [UsageBreakdown] {
    breakdown(
      messageKey: { $0.providerID?.rawValue },
      eventKey: { $0.providerID?.rawValue },
      title: usageDisplayName
    )
  }

  private var modelBreakdown: [UsageBreakdown] {
    breakdown(
      messageKey: { $0.modelID?.rawValue },
      eventKey: { $0.modelID?.rawValue },
      title: { $0 }
    )
  }

  private func breakdown(
    messageKey: (ChatMessage) -> String?,
    eventKey: (TelemetryEvent) -> String?,
    title: (String) -> String
  ) -> [UsageBreakdown] {
    var usageByKey: [String: ChatUsageAggregate] = [:]
    for message in filteredMessages where message.role == .assistant {
      guard let key = messageKey(message), !key.isEmpty else { continue }
      var aggregate = usageByKey[key] ?? ChatUsageAggregate()
      aggregate.add(message)
      usageByKey[key] = aggregate
    }

    var eventsByKey: [String: [TelemetryEvent]] = [:]
    for event in filteredTelemetryEvents {
      guard let key = eventKey(event), !key.isEmpty else { continue }
      eventsByKey[key, default: []].append(event)
    }

    let keys = Set(usageByKey.keys).union(eventsByKey.keys)
    return keys.map { key in
      UsageBreakdown(
        id: key,
        title: title(key),
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

  private func messages(since startDate: Date?) -> [ChatMessage] {
    conversations.flatMap(\.messages).filter { message in
      guard message.role == .assistant else { return false }
      guard let startDate else { return true }
      return message.updatedAt >= startDate
    }
  }

  private func conversationSummaryLabel(_ conversation: ChatConversation) -> some View {
    let startDate = accessibleRange.startDate(reference: .now)
    let messages = conversation.messages.filter { message in
      guard message.role == .assistant else { return false }
      guard let startDate else { return true }
      return message.updatedAt >= startDate
    }
    let aggregate = ChatBilling.aggregate(messages: messages)
    let events = filteredTelemetryEvents.filter { $0.conversationID == conversation.id }
    let performance = TelemetryAnalytics.aggregate(events: events)

    return VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("Details")
        Spacer()
        Text(usageAggregateCostText(aggregate))
          .foregroundStyle(theme.secondaryForegroundColor)
          .monospacedDigit()
      }
      HStack(spacing: 6) {
        Text("\(aggregate.modelRequestCount.formatted()) requests")
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
  private var budgetProgress: Double {
    guard monthlyBudgetUSD > 0 else { return 0 }
    let spent = NSDecimalNumber(decimal: budgetAggregate.costUSD).doubleValue
    return min(max(spent / monthlyBudgetUSD, 0), 1)
  }

  private var budgetWarningReached: Bool {
    guard monthlyBudgetUSD > 0 else { return false }
    let spent = NSDecimalNumber(decimal: budgetAggregate.costUSD).doubleValue
    return spent >= monthlyBudgetUSD * budgetWarningFraction
  }

  private var budgetWarningText: String {
    let aggregate = budgetAggregate
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
    if telemetryStatistics.eventCount > telemetryEvents.count {
      let queryLimit = TelemetryStoreConfiguration.maximumRecentEventQueryCount.formatted()
      return "Performance and reliability use the latest \(queryLimit) local telemetry events. Raw telemetry is device-local, disposable, and retained for up to 30 days by default. Chat usage and spend remain available from message history."
    }
    return "Performance and reliability are calculated from device-local telemetry retained for up to 30 days by default. Chat usage and spend remain available from message history even if telemetry is cleared."
  }

  private func errorTitle(_ raw: String) -> String {
    raw.replacingOccurrences(of: "_", with: " ")
      .split(separator: " ")
      .map { $0.capitalized }
      .joined(separator: " ")
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
}

private struct UsageBreakdownRowView: View {
  let row: UsageBreakdown

  @Environment(\.appFoundationTheme) private var theme

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 3) {
        Text(row.title)
          .lineLimit(1)

        Text("\(usageCompactTokens(row.aggregate.inputTokens + row.aggregate.outputTokens)) tokens · \(row.aggregate.modelRequestCount.formatted()) requests")
          .font(.caption)
          .foregroundStyle(theme.secondaryForegroundColor)

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
      Text(usageAggregateCostText(row.aggregate))
        .foregroundStyle(theme.secondaryForegroundColor)
        .monospacedDigit()
    }
  }
}
