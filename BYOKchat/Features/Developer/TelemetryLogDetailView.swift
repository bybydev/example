import BYOKchatProviderCore
import SwiftUI
import UIKit

struct TelemetryLogDetailView: View {
  let event: TelemetryEvent

  var body: some View {
    List {
      Section("Event") {
        LabeledContent("Name", value: event.name.rawValue)
        LabeledContent("Category", value: event.category.rawValue.capitalized)
        LabeledContent("Class", value: event.dataClass.rawValue.capitalized)
        LabeledContent("Severity", value: event.severity.rawValue.capitalized)
        if let outcome = event.outcome {
          LabeledContent("Outcome", value: outcome.rawValue.capitalized)
        }
        LabeledContent("Time") {
          Text(event.timestamp, format: .dateTime.year().month().day().hour().minute().second())
            .multilineTextAlignment(.trailing)
        }
      }

      if hasTargetDetails {
        Section("Target") {
          if let providerID = event.providerID {
            LabeledContent("Provider", value: providerID.rawValue)
          }
          if let accountID = event.accountID {
            LabeledContent("Account", value: accountID.rawValue)
          }
          if let modelID = event.modelID {
            LabeledContent("Model", value: modelID.rawValue)
          }
          if let conversationID = event.conversationID {
            LabeledContent("Conversation", value: conversationID.rawValue)
          }
          if let messageID = event.messageID {
            LabeledContent("Message", value: messageID.rawValue)
          }
        }
      }

      if hasMetrics {
        Section("Metrics") {
          if let value = event.durationMilliseconds {
            LabeledContent("Duration", value: telemetryMilliseconds(value))
          }
          if let value = event.timeToFirstTokenMilliseconds {
            LabeledContent("TTFT", value: telemetryMilliseconds(value))
          }
          if let value = event.inputTokens {
            LabeledContent("Input tokens", value: value.formatted())
          }
          if let value = event.outputTokens {
            LabeledContent("Output tokens", value: value.formatted())
          }
          if let value = event.cachedInputTokens {
            LabeledContent("Cached tokens", value: value.formatted())
          }
          if let value = event.reasoningTokens {
            LabeledContent("Reasoning tokens", value: value.formatted())
          }
          if let value = event.modelRequestCount {
            LabeledContent("Model requests", value: value.formatted())
          }
          if let value = event.toolCallCount {
            LabeledContent("Tool calls", value: value.formatted())
          }
          if let value = event.httpStatus {
            LabeledContent("HTTP status", value: value.formatted())
          }
        }
      }

      if let errorCode = event.errorCode {
        Section("Failure") {
          LabeledContent("Error code", value: errorCode)
          if let classification = event.metadata["classification"] {
            LabeledContent("Classification", value: classification)
          }
        }
      }

      if !event.metadata.isEmpty {
        Section("Metadata") {
          ForEach(event.metadata.keys.sorted(), id: \.self) { key in
            if let value = event.metadata[key] {
              LabeledContent(key, value: value)
            }
          }
        }
      }

      Section {
        Button("Copy Sanitized Event", systemImage: "doc.on.doc") {
          UIPasteboard.general.string = TelemetryDiagnostics.text(for: event)
        }

        ShareLink(
          item: TelemetryDiagnostics.text(for: event),
          subject: Text("BYOK Diagnostic Event"),
          message: Text("Sanitized local telemetry event")
        ) {
          Label("Share Sanitized Event", systemImage: "square.and.arrow.up")
        }
      } footer: {
        Text("This view contains structured telemetry only. Prompt text, assistant responses, credentials, request bodies, tool arguments, tool results, and attachment contents are not stored by default.")
      }
    }
    .navigationTitle("Event Details")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var hasTargetDetails: Bool {
    event.providerID != nil
      || event.accountID != nil
      || event.modelID != nil
      || event.conversationID != nil
      || event.messageID != nil
  }

  private var hasMetrics: Bool {
    event.durationMilliseconds != nil
      || event.timeToFirstTokenMilliseconds != nil
      || event.inputTokens != nil
      || event.outputTokens != nil
      || event.cachedInputTokens != nil
      || event.reasoningTokens != nil
      || event.modelRequestCount != nil
      || event.toolCallCount != nil
      || event.httpStatus != nil
  }

  private func telemetryMilliseconds(_ value: Double) -> String {
    if value >= 1_000 {
      return String(format: "%.2f s", value / 1_000)
    }
    return String(format: "%.1f ms", value)
  }
}
