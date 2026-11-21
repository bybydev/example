import AppFoundation
import BYOKchatProviderCore
import Foundation
import SwiftUI

struct ConversationAnalyticsView: View {
  let conversation: ChatConversation

  @Environment(\.dismiss) private var dismiss
  @Environment(AppModel.self) private var model
  @Environment(\.appFoundationTheme) private var theme

  @State private var telemetryEvents: [TelemetryEvent] = []
  @State private var hasLoadedTelemetry = false
  @State private var telemetryUnavailable = false
  @State private var isLoadingTelemetry = false
  @State private var didTrackOpening = false

  private var navigationTitleText: String {
    let trimmed = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Chat Analytics" : trimmed
  }

  private var activeModelContextWindow: Int? {
    model.providers.modelsByAccount[conversation.accountID]?
      .first { $0.model.id == conversation.modelID }?
      .model.contextWindow
  }

  var body: some View {
    NavigationStack {
      let activeTelemetry = telemetryUnavailable ? [] : telemetryEvents
      let snapshot = UsageAnalytics.conversationSnapshot(
        conversation: conversation,
        telemetryEvents: activeTelemetry,
        range: .all
      )
      let contextUsage = UsageAnalytics.latestContextUsage(
        conversation: conversation,
        telemetryEvents: activeTelemetry,
        modelContextWindow: activeModelContextWindow
      )

      List {
        usageSection(snapshot.aggregate)

        if let contextUsage {
          contextSection(contextUsage)
        }

        telemetryStatusSections(snapshot: snapshot)

        if snapshot.providerBreakdown.count > 1 {
          providersSection(snapshot.providerBreakdown)
        }

        if snapshot.modelBreakdown.count > 1 {
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
    }
  }

  private func usageSection(_ aggregate: ChatUsageAggregate) -> some View {
    let messageCount = conversation.messages.count
    let replyCount = aggregate.assistantMessageCount

    return Section {
      LabeledContent("Spend", value: usageAggregateCostText(aggregate))
      if messageCount > 0 {
        LabeledContent(
          "Messages",
          value: replyCount > 0
            ? "\(messageCount.formatted()) (\(replyCount.formatted()) \(replyCount == 1 ? "reply" : "replies"))"
            : messageCount.formatted()
        )
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
      Text("Usage")
        .foregroundStyle(theme.secondaryForegroundColor)
    } footer: {
      Text(usageHistoryFootnote(aggregate))
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }

  private func contextSection(_ contextUsage: ConversationContextUsage) -> some View {
    Section {
      if let window = contextUsage.contextWindow, let fill = contextUsage.fillFraction {
        LabeledContent(
          "Latest turn",
          value: "\(usageCompactTokens(contextUsage.usedInputTokens)) / \(usageCompactTokens(window)) (\(usagePercent(fill)))"
        )
        ProgressView(value: fill)
          .tint(fill >= 0.95 ? .red : fill >= 0.8 ? .orange : .accentColor)
      } else {
        LabeledContent("Latest turn input", value: usageCompactTokens(contextUsage.usedInputTokens))
      }

      if contextUsage.omittedMessageCount > 0 {
        Label(
          "\(contextUsage.omittedMessageCount.formatted()) earlier \(contextUsage.omittedMessageCount == 1 ? "message" : "messages") omitted to fit context",
          systemImage: "scissors"
        )
        .font(.footnote)
        .foregroundStyle(.orange)
      }
    } header: {
      Text("Context")
        .foregroundStyle(theme.secondaryForegroundColor)
    } footer: {
      Text(
        contextUsage.isEstimated
          ? "Estimated from the latest built request context."
          : "Based on the latest request's input tokens."
      )
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
          if snapshot.aggregate.assistantMessageCount > 0 {
            ContentUnavailableView(
              "No Recent Performance Data",
              systemImage: "waveform.path.ecg",
              description: Text("Local performance telemetry is retained for up to 30 days. Saved usage and spend above remain available.")
            )
          } else {
            ContentUnavailableView(
              "No Performance Data Yet",
              systemImage: "waveform.path.ecg",
              description: Text("Send a message in this chat to start collecting local performance metrics.")
            )
          }
        }
        .listRowBackground(theme.surfaceColor)
      }
    }
  }

  private func performanceSection(_ performance: TelemetryPerformanceAggregate) -> some View {
    let isSingleRequest = performance.providerRequestCount <= 1
    let showPercentiles = performance.providerRequestCount >= 5

    return Section {
      LabeledContent(
        isSingleRequest ? "TTFT" : "Median TTFT",
        value: usageDuration(performance.medianTTFTMilliseconds)
      )
      if showPercentiles {
        LabeledContent("P95 TTFT", value: usageDuration(performance.p95TTFTMilliseconds))
      }
      LabeledContent(
        isSingleRequest ? "Duration" : "Median duration",
        value: usageDuration(performance.medianDurationMilliseconds)
      )
      if showPercentiles {
        LabeledContent("P95 duration", value: usageDuration(performance.p95DurationMilliseconds))
      }
      LabeledContent(
        isSingleRequest ? "Speed" : "Median speed",
        value: usageRate(performance.medianOutputTokensPerSecond)
      )
    } header: {
      Text("Performance")
        .foregroundStyle(theme.secondaryForegroundColor)
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
    Section {
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
    } header: {
      Text("Tools & MCP")
        .foregroundStyle(theme.secondaryForegroundColor)
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
