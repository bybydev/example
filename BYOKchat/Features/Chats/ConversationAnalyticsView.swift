import AppFoundation
import BYOKchatProviderCore
import SwiftUI

struct ConversationAnalyticsView: View {
  let conversation: ChatConversation
  let range: UsageRange
  let telemetryEvents: [TelemetryEvent]

  private var messages: [ChatMessage] {
    let startDate = range.startDate(reference: .now)
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
    TelemetryAnalytics.aggregate(
      events: telemetryEvents.filter { $0.conversationID == conversation.id }
    )
  }

  @Environment(\.appFoundationTheme) private var theme

  var body: some View {
    List {
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
        if aggregate.hasPartialCost {
          Text("Spend is partial because some responses do not have known pricing.")
            .foregroundStyle(theme.secondaryForegroundColor)
        }
      }
      .listRowBackground(theme.surfaceColor)

      if performance.providerRequestCount > 0 {
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

      if performance.toolCallCount > 0 || performance.mcpRequestCount > 0 {
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
