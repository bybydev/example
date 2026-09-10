import BYOKchatProviderCore
import Foundation
import MacAppFoundation
import SwiftUI

struct MacAnalyticsGateView: View {
  let services: BYOKCoreServices

  @Environment(PurchaseManager.self) private var purchaseManager

  @ViewBuilder
  var body: some View {
    switch purchaseManager.entitlementState {
    case .checking:
      VStack(spacing: 12) {
        ProgressView()
        Text("Checking BYOK Pro status…")
          .font(.callout)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(MacDesignTokens.Colors.canvas)

    case .active:
      MacAnalyticsView(services: services)

    case .inactive:
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
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Text("Overview")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(MacDesignTokens.Colors.textPrimary)
          .padding(.horizontal, 12)
          .frame(height: 30)
          .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 7))
          .overlay {
            RoundedRectangle(cornerRadius: 7)
              .stroke(MacDesignTokens.Colors.separator.opacity(0.75), lineWidth: 0.5)
          }

        Spacer()

        Text("This Month")
          .font(.caption.weight(.medium))
          .foregroundStyle(MacDesignTokens.Colors.textMuted)

        Button {
          Task { await load() }
        } label: {
          Label(isLoading ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(isLoading)
      }
      .padding(.horizontal, 16)
      .frame(height: 54)
      .background(MacDesignTokens.Colors.surface.opacity(0.45))

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          VStack(alignment: .leading, spacing: 3) {
            Text("Usage")
              .font(.title3.weight(.semibold))
              .foregroundStyle(MacDesignTokens.Colors.textPrimary)
            Text("Monthly usage reconstructed from conversations stored on this Mac.")
              .font(.caption)
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
            MacAnalyticsMetricGrid(
              metrics: [
                .init(title: "Spend", value: macUsageAggregateCost(snapshot.aggregate), symbol: "dollarsign.circle"),
                .init(title: "Model Requests", value: snapshot.aggregate.modelRequestCount.formatted(), symbol: "arrow.up.arrow.down"),
                .init(title: "Input", value: macUsageCompactTokens(snapshot.aggregate.inputTokens), symbol: "arrow.down.left"),
                .init(title: "Output", value: macUsageCompactTokens(snapshot.aggregate.outputTokens), symbol: "arrow.up.right")
              ]
            )

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

          MacAnalyticsSection(title: "Advanced Analytics", symbol: "crown.fill") {
            VStack(alignment: .leading, spacing: 12) {
              HStack {
                Text("BYOK Pro")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(MacDesignTokens.Colors.accent)
                  .padding(.horizontal, 8)
                  .padding(.vertical, 3)
                  .background(MacDesignTokens.Colors.accent.opacity(0.10), in: Capsule())
                Spacer()
              }

              Text("Unlock selectable time ranges, cached and reasoning tokens, tool usage, performance, reliability, errors, provider/model breakdowns, per-conversation analytics, and monthly budgets.")
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)

              HStack {
                Spacer()
                Button("Unlock BYOK Pro") {
                  openWindow(id: MacWindowID.proPaywall)
                }
                .buttonStyle(.borderedProminent)
              }
            }
          }

          Text("Usage and spend are reconstructed from chat history stored on this Mac.")
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }
        .frame(maxWidth: 860, alignment: .leading)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .top)
      }
    }
    .background(MacDesignTokens.Colors.canvas)
    .task { await load() }
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