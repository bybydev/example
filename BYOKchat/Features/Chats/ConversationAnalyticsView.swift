import AppFoundation
import BYOKchatProviderCore
import SwiftUI

struct ConversationAnalyticsView: View {
  let conversation: ChatConversation
  let range: UsageRange
  let telemetryEvents: [TelemetryEvent]
  var telemetryAvailable: Bool = true

  @Environment(PurchaseManager.self) private var purchaseManager

  private var accessibleRange: UsageRange {
    range.accessible(hasPro: purchaseManager.hasPro)
  }

  private var messages: [ChatMessage] {
    let startDate = accessibleRange.startDate(reference: .now)
    return conversation.messages.filter { message in
      guard message.role == .assistant else { return false }
      guard let startDate else { return true }
      return message.updatedAt >= startDate
    }
  }

  private var aggregate: ChatUsageAggregate {
    ChatBilling.aggregate(messages: messages)
  }

  private var performance: TelemetryPerformanceAggregate {
    let startDate = accessibleRange.startDate(reference: .now)
    return TelemetryAnalytics.aggregate(
      events: telemetryEvents.filter { event in
        guard event.conversationID == conversation.id, event.dataClass == .analytics else { return false }
        guard let startDate else { return true }
        return event.timestamp >= startDate
      }
    )
  }

  @Environment(\.appFoundationTheme) private var theme

  var body: some View {
    List {
      Section {
        LabeledContent("Range", value: accessibleRange.label)
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

      if !telemetryAvailable {
        Section {
          Text("Performance data is unavailable. Saved usage and spend remain available.")
        }
        .listRowBackground(theme.surfaceColor)
      }

      if telemetryAvailable && performance.providerRequestCount > 0 {
        Section("Performance") {
          LabeledContent("Median TTFT", value: usageDuration(performance.medianTTFTMilliseconds))
          LabeledContent("P95 TTFT", value: usageDuration(performance.p95TTFTMilliseconds))
          LabeledContent("Median duration", value: usageDuration(performance.medianDurationMilliseconds))
          LabeledContent("P95 duration", value: usageDuration(performance.p95DurationMilliseconds))
          LabeledContent("Median speed", value: usageRate(performance.medianOutputTokensPerSecond))
        }
        .listRowBackground(theme.surfaceColor)

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

      if telemetryAvailable && (performance.toolCallCount > 0 || performance.mcpRequestCount > 0) {
        Section("Tools & MCP") {
          if performance.toolCallCount > 0 {
            LabeledContent("Tool calls", value: performance.toolCallCount.formatted())
            LabeledContent("Tool success", value: usagePercent(performance.toolSuccessRate))
            if performance.toolFailureCount > 0 {
              LabeledContent("Tool failures", value: performance.toolFailureCount.formatted())
            }
          }
          if performance.mcpRequestCount > 0 {
            LabeledContent("MCP requests", value: performance.mcpRequestCount.formatted())
            LabeledContent("MCP failures", value: performance.mcpFailureCount.formatted())
          }
        }
        .listRowBackground(theme.surfaceColor)
      }
    }
    .scrollContentBackground(.hidden)
    .foregroundStyle(theme.primaryForegroundColor)
    .background(AppThemeBackground(theme: theme))
    .navigationTitle(conversation.title)
    .navigationBarTitleDisplayMode(.inline)
  }
}
