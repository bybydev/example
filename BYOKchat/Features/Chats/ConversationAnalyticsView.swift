import AppFoundation
import BYOKchatProviderCore
import SwiftUI

struct ConversationAnalyticsView: View {
  let conversation: ChatConversation
  let range: UsageRange
  let telemetryEvents: [TelemetryEvent]
  var telemetryAvailable: Bool = true

  @Environment(PurchaseManager.self) private var purchaseManager
  @Environment(\.appFoundationTheme) private var theme

  private var accessibleRange: UsageRange {
    range.accessible(hasPro: purchaseManager.hasPro)
  }

  var body: some View {
    let activeRange = accessibleRange
    let snapshot = UsageAnalytics.conversationSnapshot(
      conversation: conversation,
      telemetryEvents: telemetryAvailable ? telemetryEvents : [],
      range: activeRange,
      reference: .now
    )

    List {
      usageSection(snapshot.aggregate, range: activeRange)

      if !telemetryAvailable {
        Section {
          Text("Performance data is unavailable. Saved usage and spend remain available.")
        }
        .listRowBackground(theme.surfaceColor)
      } else {
        if snapshot.performance.hasLatencyOrSpeedMetrics {
          performanceSection(snapshot.performance)
        }
        if snapshot.performance.providerRequestCount > 0 {
          reliabilitySection(snapshot.performance)
        }
        if snapshot.performance.toolCallCount > 0 || snapshot.performance.mcpRequestCount > 0 {
          toolsAndMCPSection(snapshot.performance)
        }
        if !snapshot.failureBreakdown.isEmpty {
          errorsSection(snapshot.failureBreakdown)
        }
      }
    }
    .scrollContentBackground(.hidden)
    .foregroundStyle(theme.primaryForegroundColor)
    .background(AppThemeBackground(theme: theme))
    .navigationTitle(conversation.title)
    .navigationBarTitleDisplayMode(.inline)
  }

  private func usageSection(_ aggregate: ChatUsageAggregate, range: UsageRange) -> some View {
    Section {
      LabeledContent("Range", value: range.label)
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
      Text("Usage")
        .foregroundStyle(theme.secondaryForegroundColor)
    } footer: {
      Text(usageHistoryFootnote(aggregate))
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
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
    Section("Reliability") {
      LabeledContent("Success rate", value: usagePercent(performance.providerSuccessRate))
      LabeledContent("Succeeded", value: performance.providerSuccessCount.formatted())
      LabeledContent("Failed", value: performance.providerFailureCount.formatted())
      if performance.providerCancelledCount > 0 {
        LabeledContent("Cancelled", value: performance.providerCancelledCount.formatted())
      }
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
}
