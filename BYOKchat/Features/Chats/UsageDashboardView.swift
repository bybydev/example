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
  @AppStorage("byokchat.usage.monthlyBudgetUSD") private var monthlyBudgetUSD = 0.0
  @AppStorage("byokchat.usage.budgetWarningFraction") private var budgetWarningFraction = 0.8
  @State private var range: UsageRange = .month
  @State private var telemetryEvents: [TelemetryEvent] = []
  @State private var telemetryStatistics = TelemetryStoreStatistics.empty
  @State private var hasLoadedTelemetry = false
  @State private var showProUpsell = false

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
      if purchaseManager.hasPro {
        Section {
          Picker("Range", selection: $range) {
            ForEach(UsageRange.allCases) { value in
              Text(value.label).tag(value)
            }
          }
          .pickerStyle(.segmented)
        }
        .listRowBackground(theme.surfaceColor)
      }

      usageSummarySection

      if purchaseManager.hasPro {
        if hasPerformanceData {
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
                range: range,
                telemetryEvents: filteredTelemetryEvents
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

        monthlyBudgetSection

        Section {
          LabeledContent("Telemetry events", value: telemetryStatistics.analyticsEventCount.formatted())
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
      } else {
        advancedUpsellSection
      }
    }
    .scrollContentBackground(.hidden)
    .foregroundStyle(theme.primaryForegroundColor)
    .background(AppThemeBackground(theme: theme))
    .navigationTitle("Analytics")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
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
      if purchaseManager.hasPro {
        await loadTelemetry()
      }
    }
    .onChange(of: purchaseManager.hasPro) { _, hasPro in
      if hasPro {
        Task { await loadTelemetry() }
      } else {
        range = .month
      }
    }
    .refreshable {
      if purchaseManager.hasPro {
        await loadTelemetry()
      }
    }
    .sheet(isPresented: $showProUpsell) {
      BYOKProUpsellFlow(feature: .analytics)
    }
  }

  private var usageSummarySection: some View {
    Section {
      LabeledContent("Spend", value: usageAggregateCostText(filteredAggregate))
      LabeledContent("Model requests", value: filteredAggregate.modelRequestCount.formatted())
      LabeledContent("Input", value: usageCompactTokens(filteredAggregate.inputTokens))
      LabeledContent("Output", value: usageCompactTokens(filteredAggregate.outputTokens))
      if purchaseManager.hasPro, filteredAggregate.cachedInputTokens > 0 {
        LabeledContent("Cached input", value: usageCompactTokens(filteredAggregate.cachedInputTokens))
      }
      if purchaseManager.hasPro, filteredAggregate.reasoningTokens > 0 {
        LabeledContent("Reasoning", value: usageCompactTokens(filteredAggregate.reasoningTokens))
      }
      if purchaseManager.hasPro, filteredAggregate.toolCallCount > 0 {
        LabeledContent("Tool calls", value: filteredAggregate.toolCallCount.formatted())
      }
    } header: {
      Text(purchaseManager.hasPro ? "Usage" : "Basic Usage · This Month")
        .foregroundStyle(theme.secondaryForegroundColor)
    } footer: {
      if filteredAggregate.hasPartialCost {
        Text("Spend is partial because some models did not expose pricing. Usage and spend are reconstructed from persisted assistant messages.")
          .foregroundStyle(theme.secondaryForegroundColor)
      } else if purchaseManager.hasPro {
        Text("Usage and spend come from persisted chat history. Only requests made by BYOKchat are included.")
          .foregroundStyle(theme.secondaryForegroundColor)
      } else {
        Text("Basic analytics includes monthly spend, requests, input tokens, and output tokens.")
          .foregroundStyle(theme.secondaryForegroundColor)
      }
    }
    .listRowBackground(theme.surfaceColor)
  }

  private var advancedUpsellSection: some View {
    Section {
      Button {
        showProUpsell = true
      } label: {
        VStack(alignment: .leading, spacing: 6) {
          Label("Advanced Analytics", systemImage: "crown.fill")
            .font(.body.weight(.semibold))
          Text("Unlock time ranges, TTFT and speed, reliability, errors, provider/model breakdowns, per-chat details, and monthly budgets.")
            .font(.caption)
            .foregroundStyle(theme.secondaryForegroundColor)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
      }
    } footer: {
      Text("Upgrade to Pro for deeper local analytics. Your chat content and provider credentials remain private.")
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

  private var monthlyBudgetSection: some View {
    Section {
      HStack {
        Text("Budget")
        Spacer()
        Text("$")
          .foregroundStyle(theme.secondaryForegroundColor)
        TextField("0", value: $monthlyBudgetUSD, format: .number.precision(.fractionLength(0...2)))
          .keyboardType(.decimalPad)
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
        ProgressView(value: budgetProgress)
        LabeledContent("This month", value: usageAggregateCostText(currentMonthAggregate))
        if budgetWarningReached {
          Label("Budget warning threshold reached", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
        }
      }
    } header: {
      Text("Monthly budget")
        .foregroundStyle(theme.secondaryForegroundColor)
    } footer: {
      Text("The budget is a local BYOKchat warning. It does not include API-key usage from other apps and does not change provider-side spending limits.")
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }

  private var filteredMessages: [ChatMessage] {
    messages(since: range.startDate(reference: .now))
  }

  private var filteredAggregate: ChatUsageAggregate {
    ChatBilling.aggregate(messages: filteredMessages)
  }

  private var filteredTelemetryEvents: [TelemetryEvent] {
    let startDate = range.startDate(reference: .now)
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

  private var currentMonthAggregate: ChatUsageAggregate {
    ChatBilling.aggregate(messages: messages(since: UsageRange.month.startDate(reference: .now)))
  }

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
    let startDate = range.startDate(reference: .now)
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

  private var budgetProgress: Double {
    guard monthlyBudgetUSD > 0 else { return 0 }
    let spent = NSDecimalNumber(decimal: currentMonthAggregate.costUSD).doubleValue
    return min(max(spent / monthlyBudgetUSD, 0), 1)
  }

  private var budgetWarningReached: Bool {
    guard monthlyBudgetUSD > 0 else { return false }
    let spent = NSDecimalNumber(decimal: currentMonthAggregate.costUSD).doubleValue
    return spent >= monthlyBudgetUSD * budgetWarningFraction
  }

  private var telemetryFootnote: String {
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

  private func loadTelemetry() async {
    let recorder = model.telemetryRecorder
    let events = await recorder.recentEvents(
      limit: TelemetryStoreConfiguration.maximumRecentEventQueryCount
    )
    let statistics = await recorder.statistics()
    telemetryEvents = events
    telemetryStatistics = statistics
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
