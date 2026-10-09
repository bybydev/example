import AppFoundation
import BYOKchatProviderCore
import SwiftUI

struct MessageInfoView: View {
  let message: ChatMessage
  let accountLabel: String?

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appFoundationTheme) private var theme

  private var billing: ChatBillingSnapshot { ChatBilling.snapshot(for: message) }

  var body: some View {
    NavigationStack {
      List {
        Section("Model") {
          if let providerID = message.providerID {
            LabeledContent("Provider", value: usageDisplayName(providerID.rawValue))
          }
          if let accountLabel, !accountLabel.isEmpty {
            LabeledContent("Account", value: accountLabel)
          }
          if let modelID = message.modelID {
            LabeledContent("Model", value: modelID.rawValue)
          }
        }
        .listRowBackground(theme.surfaceColor)

        if message.role == .assistant {
          let usage = message.usage
          Section {
            if let value = usage?.inputTokens {
              LabeledContent("Input", value: usageTokenCount(value))
            }
            if let value = usage?.cachedInputTokens, value > 0 {
              LabeledContent("Cached input", value: usageTokenCount(value))
            }
            if let value = usage?.outputTokens {
              LabeledContent("Output", value: usageTokenCount(value))
            }
            if let value = usage?.reasoningTokens, value > 0 {
              LabeledContent("Reasoning", value: usageTokenCount(value))
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

        if billing.requests.contains(where: { $0.pricing != nil }) || billing.inputPricePerToken != nil || billing.outputPricePerToken != nil {
          Section {
            if !billing.requests.isEmpty {
              LabeledContent("Saved request snapshots", value: billing.requests.count.formatted())
            }
            if let snapshot = billing.requests.first?.pricing {
              LabeledContent("Source", value: snapshot.source == "bundledCatalog" ? "Bundled catalog" : "Model API")
              if let version = snapshot.version { LabeledContent("Version", value: version) }
              if let verified = snapshot.verifiedAt { LabeledContent("Verified", value: verified) }
              if let sourceURL = snapshot.sourceURL, let url = URL(string: sourceURL), url.scheme == "https" {
                Link("Official pricing", destination: url)
              }
            }
            if let price = billing.inputPricePerToken {
              LabeledContent("First request input / 1M", value: usagePricePerMillion(price))
            }
            if let price = billing.outputPricePerToken {
              LabeledContent("First request output / 1M", value: usagePricePerMillion(price))
            }
          } header: {
            Text("Pricing snapshot")
              .foregroundStyle(theme.secondaryForegroundColor)
          } footer: {
            Text("Prices and billing rules are stored per request. The rates shown are for the first request; tool rounds may differ. Later price changes do not rewrite saved spend.")
              .foregroundStyle(theme.secondaryForegroundColor)
          }
          .listRowBackground(theme.surfaceColor)
        }

        Section("Request") {
          if billing.modelRequestCount > 0 {
            LabeledContent("Model requests", value: String(billing.modelRequestCount))
          }
          if billing.toolCallCount > 0 {
            LabeledContent("Tool calls", value: String(billing.toolCallCount))
          }
          if let finishReason = message.finishReason, !finishReason.isEmpty {
            LabeledContent("Finish reason", value: finishReason)
          }
          LabeledContent("Generated") {
            Text(message.updatedAt, format: .dateTime.year().month().day().hour().minute().second())
              .multilineTextAlignment(.trailing)
          }
        }
        .listRowBackground(theme.surfaceColor)
      }
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
    }
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
