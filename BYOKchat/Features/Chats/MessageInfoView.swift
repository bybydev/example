import AppFoundation
import BYOKchatProviderCore
import SwiftUI

struct MessageInfoView: View {
  let message: ChatMessage
  let accountLabel: String?

  @Environment(\.dismiss) private var dismiss
  @Environment(AppModel.self) private var model
  @Environment(\.appFoundationTheme) private var theme

  @State private var messagePerformance: TelemetryPerformanceAggregate?
  @State private var omittedContextCount = 0

  private var billing: ChatBillingSnapshot { ChatBilling.snapshot(for: message) }

  private var hasModelMetadata: Bool {
    message.providerID != nil
      || !(accountLabel?.isEmpty ?? true)
      || message.modelID != nil
  }

  private var firstPricingSnapshot: ModelPricingSnapshot? {
    billing.requests.compactMap(\.pricing).first
  }

  var body: some View {
    NavigationStack {
      List {
        if hasModelMetadata {
          Section {
            if let providerID = message.providerID {
              LabeledContent("Provider", value: usageDisplayName(providerID.rawValue))
            }
            if let accountLabel, !accountLabel.isEmpty {
              LabeledContent("Account", value: accountLabel)
            }
            if let modelID = message.modelID {
              LabeledContent("Model", value: modelID.rawValue)
            }
          } header: {
            Text("Model")
              .foregroundStyle(theme.secondaryForegroundColor)
          }
          .listRowBackground(theme.surfaceColor)
        }

        if message.role == .assistant {
          let usage = message.usage
          Section {
            if let input = usage?.inputTokens {
              LabeledContent("Input", value: usageTokenCount(input))
            }
            if let value = usage?.cachedInputTokens, value > 0 {
              LabeledContent(
                "Cached input",
                value: usageCachedTokensWithRate(
                  cached: value,
                  input: usage?.inputTokens ?? 0,
                  compact: false
                )
              )
            }
            if let value = usage?.cacheWriteTokens, value > 0 {
              LabeledContent("Cache write", value: usageTokenCount(value))
            }
            if let output = usage?.outputTokens {
              LabeledContent("Output", value: usageTokenCount(output))
            }
            if let value = usage?.reasoningTokens, value > 0 {
              LabeledContent("Reasoning", value: usageTokenCount(value))
            }
            if let input = usage?.inputTokens, let output = usage?.outputTokens {
              LabeledContent("Total tokens", value: usageTokenCount(input + output))
            }

            LabeledContent(costLabel, value: costValue)
          } header: {
            Text("Usage")
              .foregroundStyle(theme.secondaryForegroundColor)
          } footer: {
            Text(costFootnote)
              .foregroundStyle(theme.secondaryForegroundColor)
          }
          .listRowBackground(theme.surfaceColor)
        }

        if message.role == .assistant, let performance = messagePerformance, performance.hasLatencyOrSpeedMetrics {
          performanceSection(performance)
        }

        Section {
          if message.status == .failed {
            LabeledContent("Status", value: "Failed")
            if let errorCode = message.errorCode, !errorCode.isEmpty {
              LabeledContent("Error code", value: usageErrorTitle(errorCode))
            }
          } else if message.status == .cancelled {
            LabeledContent("Status", value: "Stopped")
          } else if message.status == .interrupted {
            LabeledContent("Status", value: "Interrupted")
          }
          if billing.modelRequestCount > 0 {
            LabeledContent("Model requests", value: String(billing.modelRequestCount))
          }
          if billing.toolCallCount > 0 {
            LabeledContent("Tool calls", value: String(billing.toolCallCount))
          }
          if omittedContextCount > 0 {
            LabeledContent(
              "Context trimmed",
              value: "\(omittedContextCount.formatted()) earlier \(omittedContextCount == 1 ? "message" : "messages")"
            )
          }
          if let finishReason = message.finishReason, !finishReason.isEmpty {
            LabeledContent("Finish reason", value: usageFinishReasonTitle(finishReason))
          }
          LabeledContent("Generated") {
            Text(message.updatedAt, format: .dateTime.year().month().day().hour().minute().second())
              .multilineTextAlignment(.trailing)
          }
        } header: {
          Text("Request")
            .foregroundStyle(theme.secondaryForegroundColor)
        }
        .listRowBackground(theme.surfaceColor)

        if firstPricingSnapshot != nil || billing.inputPricePerToken != nil || billing.outputPricePerToken != nil {
          let isMultiRequest = billing.modelRequestCount > 1
          Section {
            if let price = billing.inputPricePerToken {
              LabeledContent(
                isMultiRequest ? "First request input / 1M" : "Input / 1M",
                value: usagePricePerMillion(price)
              )
            }
            if let price = billing.outputPricePerToken {
              LabeledContent(
                isMultiRequest ? "First request output / 1M" : "Output / 1M",
                value: usagePricePerMillion(price)
              )
            }
            if let snapshot = firstPricingSnapshot {
              if let sourceURL = snapshot.sourceURL, let url = URL(string: sourceURL), url.scheme == "https" {
                Link("Official pricing", destination: url)
              }
              DisclosureGroup("Catalog details") {
                LabeledContent("Source", value: snapshot.source == "bundledCatalog" ? "Bundled catalog" : "Model API")
                if let version = snapshot.version { LabeledContent("Version", value: version) }
                if let verified = snapshot.verifiedAt { LabeledContent("Verified", value: verified) }
              }
            }
          } header: {
            Text("Pricing snapshot")
              .foregroundStyle(theme.secondaryForegroundColor)
          } footer: {
            Text(
              isMultiRequest
                ? "Prices and billing rules are stored per request. The rates shown are for the first request; tool rounds may differ. Later price changes do not rewrite saved spend."
                : "Prices and billing rules are stored per request. Later price changes do not rewrite saved spend."
            )
            .foregroundStyle(theme.secondaryForegroundColor)
          }
          .listRowBackground(theme.surfaceColor)
        }
      }
      .listStyle(.insetGrouped)
      .scrollContentBackground(.hidden)
      .foregroundStyle(theme.primaryForegroundColor)
      .background(AppThemeBackground(theme: theme))
      .navigationTitle("Message Info")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .task(id: message.id) {
        await loadMessagePerformance()
      }
    }
  }

  private func performanceSection(_ performance: TelemetryPerformanceAggregate) -> some View {
    let isMultiRequest = performance.providerRequestCount > 1
    return Section {
      if isMultiRequest, let totalDuration = performance.totalDurationMilliseconds {
        LabeledContent("Total duration", value: usageDuration(totalDuration))
      }
      if let ttft = performance.medianTTFTMilliseconds {
        LabeledContent(isMultiRequest ? "Median TTFT" : "TTFT", value: usageDuration(ttft))
      }
      if let duration = performance.medianDurationMilliseconds {
        LabeledContent(isMultiRequest ? "Median request" : "Duration", value: usageDuration(duration))
      }
      if let speed = performance.medianOutputTokensPerSecond {
        LabeledContent(isMultiRequest ? "Median speed" : "Speed", value: usageRate(speed))
      }
    } header: {
      Text("Performance")
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }

  private func loadMessagePerformance() async {
    guard message.role == .assistant else {
      messagePerformance = nil
      omittedContextCount = 0
      return
    }
    let events = await model.telemetryRecorder.loadMessageAnalytics(messageID: message.id)
    let performance = UsageAnalytics.messagePerformance(
      messageID: message.id,
      telemetryEvents: events,
      range: .all
    )
    messagePerformance = performance.hasLatencyOrSpeedMetrics ? performance : nil
    omittedContextCount = UsageAnalytics.messageOmittedContextCount(
      messageID: message.id,
      telemetryEvents: events
    )
  }

  private var costLabel: String {
    switch billing.accuracy {
    case .providerReported: "Cost"
    case .calculated: "Estimated cost"
    case .unavailable: "Cost"
    }
  }

  private var costValue: String {
    guard let cost = billing.costUSD else { return "Unavailable" }
    let prefix = billing.isLowerBound ? "≥" : (billing.accuracy == .calculated ? "~" : "")
    return prefix + usageFormatUSD(cost) + (billing.isComplete ? "" : " (partial)")
  }

  private var costFootnote: String {
    if billing.requests.contains(where: { $0.missingDimensions.contains("provider billing scope") }) {
      return "Includes the reported OpenRouter account charge. Upstream provider cost is excluded, so total inference spend is incomplete."
    }
    if !billing.isComplete {
      let missing = Set(billing.requests.flatMap(\.missingDimensions))
      var reasons: [String] = []
      if missing.contains("supported model pricing") {
        reasons.append("No supported price was available for the saved model and connection. Official catalog rates cover only listed model IDs and supported direct-provider endpoints.")
      }
      if missing.contains("matching model and account configuration") {
        reasons.append("The returned model differed from the requested model, or the connection changed during the request.")
      }
      if missing.contains("request usage") {
        reasons.append("The provider did not supply request usage.")
      }
      if missing.contains("supported billing context") {
        reasons.append("The provider used a billing mode that the saved pricing rule does not support.")
      }
      if !reasons.isEmpty {
        return reasons.joined(separator: " ") + " Saved costs are estimates and may differ from provider charges."
      }
      return "Cost is incomplete or unavailable because some requests lack usage, pricing, or supported billing details. A partial estimate is not a guaranteed minimum."
    }
    switch billing.accuracy {
    case .providerReported:
      return "Cost was reported by the provider for the saved requests."
    case .calculated:
      return "Estimated from usage and the prices and billing rules saved for each request."
    case .unavailable:
      return "Cost is unavailable for the saved requests."
    }
  }
}
