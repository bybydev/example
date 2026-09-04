import BYOKchatProviderCore
import Foundation
import MacAppFoundation
import SwiftUI

struct MacAnalyticsGateView: View {
  let services: BYOKCoreServices

  @Environment(PurchaseManager.self) private var purchaseManager

  var body: some View {
    if purchaseManager.hasPro {
      MacAnalyticsView(services: services)
    } else {
      MacBasicAnalyticsView(services: services)
    }
  }
}

private struct MacBasicAnalyticsView: View {
  let services: BYOKCoreServices

  @Environment(\.openWindow) private var openWindow
  @State private var snapshot: UsageAnalyticsSnapshot?
  @State private var isLoading = false
  @State private var errorMessage: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Basic Usage · This Month")
            .font(.title2.weight(.semibold))
          Text("Free analytics includes monthly spend, requests, input tokens, and output tokens.")
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }

        if isLoading, snapshot == nil {
          HStack(spacing: 10) {
            ProgressView()
            Text("Loading local usage…")
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }
          .frame(maxWidth: .infinity, minHeight: 160)
        } else if let snapshot {
          metricGrid(snapshot.aggregate)

          if snapshot.aggregate.hasPartialCost {
            Label(
              "Spend is partial because some models did not expose known pricing.",
              systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }
        } else if let errorMessage {
          ContentUnavailableView(
            "Analytics Unavailable",
            systemImage: "chart.bar.xaxis",
            description: Text(errorMessage)
          )
        }

        VStack(alignment: .leading, spacing: 12) {
          Label("Advanced Analytics", systemImage: "crown.fill")
            .font(.headline)

          Text("BYOK Pro adds selectable time ranges, cached and reasoning tokens, tool usage, performance, reliability, errors, provider/model breakdowns, per-conversation analytics, and monthly budgets.")
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
            .fixedSize(horizontal: false, vertical: true)

          Button("Unlock BYOK Pro") {
            openWindow(id: MacWindowID.proPaywall)
          }
          .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          MacDesignTokens.Colors.surface,
          in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.large)
        )
        .overlay {
          RoundedRectangle(cornerRadius: MacDesignTokens.Radius.large)
            .stroke(MacDesignTokens.Colors.separator, lineWidth: 1)
        }

        HStack {
          Text("Usage and spend are reconstructed from chat history stored on this Mac.")
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
          Spacer()
          Button("Refresh", systemImage: "arrow.clockwise") {
            Task { await load() }
          }
          .disabled(isLoading)
        }
      }
      .frame(maxWidth: 760, alignment: .leading)
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .background(MacDesignTokens.Colors.canvas)
    .task { await load() }
  }

  private func metricGrid(_ aggregate: ChatUsageAggregate) -> some View {
    let metrics = [
      BasicMetric(title: "Spend", value: basicUsageCost(aggregate), symbol: "dollarsign.circle"),
      BasicMetric(title: "Model Requests", value: aggregate.modelRequestCount.formatted(), symbol: "arrow.up.arrow.down"),
      BasicMetric(title: "Input", value: basicCompactTokens(aggregate.inputTokens), symbol: "arrow.down.left"),
      BasicMetric(title: "Output", value: basicCompactTokens(aggregate.outputTokens), symbol: "arrow.up.right"),
    ]

    return LazyVGrid(
      columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12, alignment: .top)],
      alignment: .leading,
      spacing: 12
    ) {
      ForEach(metrics) { metric in
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 6) {
            Image(systemName: metric.symbol)
            Text(metric.title)
          }
          .font(.caption.weight(.medium))
          .foregroundStyle(MacDesignTokens.Colors.textMuted)

          Text(metric.value)
            .font(.system(size: 20, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
          MacDesignTokens.Colors.surface,
          in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.large)
        )
        .overlay {
          RoundedRectangle(cornerRadius: MacDesignTokens.Radius.large)
            .stroke(MacDesignTokens.Colors.separator, lineWidth: 1)
        }
      }
    }
  }

  @MainActor
  private func load() async {
    guard !isLoading else { return }
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }

    let conversations = await services.conversationStore.allConversations()
    snapshot = UsageAnalytics.snapshot(
      conversations: conversations,
      telemetryEvents: [],
      range: .month,
      reference: .now
    )
  }
}

private struct BasicMetric: Identifiable {
  let title: String
  let value: String
  let symbol: String

  var id: String { title }
}

private func basicCompactTokens(_ value: Int) -> String {
  let number = Double(value)
  if value >= 1_000_000 { return String(format: "%.2fM", number / 1_000_000) }
  if value >= 1_000 { return String(format: "%.1fK", number / 1_000) }
  return value.formatted()
}

private func basicUsageCost(_ aggregate: ChatUsageAggregate) -> String {
  guard aggregate.hasKnownCost else { return "Unavailable" }
  return (aggregate.hasPartialCost ? "≥" : "~") + basicUSD(aggregate.costUSD)
}

private func basicUSD(_ cost: Decimal) -> String {
  let value = NSDecimalNumber(decimal: cost).doubleValue
  if abs(value) < 0.001 { return String(format: "$%.6f", value) }
  if abs(value) < 1 { return String(format: "$%.4f", value) }
  return String(format: "$%.2f", value)
}
