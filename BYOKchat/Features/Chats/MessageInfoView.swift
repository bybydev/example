import BYOKchatProviderCore
import SwiftUI

struct MessageInfoView: View {
  let message: ChatMessage
  let accountLabel: String?

  @Environment(\.dismiss) private var dismiss

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

        if let usage = message.usage {
          Section {
            if let value = usage.inputTokens {
              LabeledContent("Input", value: usageTokenCount(value))
            }
            if let value = usage.cachedInputTokens, value > 0 {
              LabeledContent("Cached input", value: usageTokenCount(value))
            }
            if let value = usage.outputTokens {
              LabeledContent("Output", value: usageTokenCount(value))
            }
            if let value = usage.reasoningTokens, value > 0 {
              LabeledContent("Reasoning", value: usageTokenCount(value))
            }

            LabeledContent(costLabel, value: costValue)
          } header: {
            Text("Usage")
          } footer: {
            Text(costFootnote)
          }
        }

        if billing.inputPricePerToken != nil || billing.outputPricePerToken != nil {
          Section {
            if let price = billing.inputPricePerToken {
              LabeledContent("Input / 1M", value: usagePricePerMillion(price))
            }
            if let price = billing.outputPricePerToken {
              LabeledContent("Output / 1M", value: usagePricePerMillion(price))
            }
          } header: {
            Text("Pricing snapshot")
          } footer: {
            Text("The price snapshot is stored with this message so later model price changes do not rewrite historical spend.")
          }
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
      }
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
    let prefix = billing.accuracy == .calculated ? "~" : ""
    return prefix + usageFormatUSD(cost)
  }

  private var costFootnote: String {
    switch billing.accuracy {
    case .providerReported:
      "Cost was reported by the provider for this request."
    case .calculated:
      "Estimated from the token usage and model pricing snapshot recorded when this response completed."
    case .unavailable:
      "Token usage is available, but this model did not expose pricing to BYOKchat."
    }
  }
}
