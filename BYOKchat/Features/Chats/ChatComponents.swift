import BYOKchatProviderCore
import SwiftUI
import UIKit

struct RepairBanner: View {
  let message: String
  let repair: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(message, systemImage: "wrench.and.screwdriver")
        .font(.callout)
      Button("Repair Chat Configuration", action: repair)
        .buttonStyle(.bordered)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
    .accessibilityElement(children: .combine)
  }
}

struct ChatComposer: View {
  @Binding var draft: String
  let isGenerating: Bool
  let canSend: Bool
  let targetLabel: String
  let openTarget: () -> Void
  let send: () -> Void
  let stop: () -> Void

  var body: some View {
    VStack(spacing: 8) {
      Button(action: openTarget) {
        HStack {
          Image(systemName: "slider.horizontal.3")
          Text(targetLabel)
            .lineLimit(1)
          Spacer()
          Image(systemName: "chevron.up.chevron.down")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Change provider account and model")

      HStack(alignment: .bottom, spacing: 10) {
        TextField("Message", text: $draft, axis: .vertical)
          .lineLimit(1...8)
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          .background(.quaternary, in: RoundedRectangle(cornerRadius: 20))
          .disabled(isGenerating)
          .accessibilityLabel("Message")

        Button {
          isGenerating ? stop() : send()
        } label: {
          Image(systemName: isGenerating ? "stop.fill" : "arrow.up")
            .font(.headline)
            .frame(width: 44, height: 44)
            .background(.tint, in: Circle())
            .foregroundStyle(.white)
        }
        .disabled(
          !isGenerating
            && (!canSend || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        )
        .accessibilityLabel(isGenerating ? "Stop generation" : "Send message")
      }
    }
    .padding(.horizontal)
    .padding(.top, 8)
    .padding(.bottom, 6)
    .background(.bar)
  }
}

struct ChatMessageView: View {
  let message: ChatMessage
  let accountLabel: String?
  let canEdit: Bool
  let canRegenerate: Bool
  let edit: () -> Void
  let regenerate: () -> Void
  let copy: () -> Void

  var body: some View {
    HStack {
      if message.role == .user { Spacer(minLength: 44) }

      VStack(alignment: .leading, spacing: 8) {
        if !message.reasoning.isEmpty {
          DisclosureGroup("Reasoning") {
            Text(message.reasoning)
              .font(.callout)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .font(.caption.weight(.semibold))
        }

        if !message.content.isEmpty {
          MarkdownMessageContent(text: message.content)
        } else if message.status == .pending || message.status == .streaming {
          HStack(spacing: 8) {
            ProgressView()
            Text("Thinking…")
              .foregroundStyle(.secondary)
          }
        }

        footer

        if !message.content.isEmpty {
          HStack(spacing: 12) {
            Button("Copy", systemImage: "doc.on.doc", action: copy)
              .labelStyle(.iconOnly)
            ShareLink(item: message.content) {
              Label("Share", systemImage: "square.and.arrow.up")
                .labelStyle(.iconOnly)
            }
            if canEdit {
              Button("Edit and Resend", systemImage: "pencil", action: edit)
                .labelStyle(.iconOnly)
            }
            if canRegenerate {
              Button("Regenerate", systemImage: "arrow.clockwise", action: regenerate)
                .labelStyle(.iconOnly)
            }
          }
          .font(.caption)
          .foregroundStyle(.secondary)
          .buttonStyle(.plain)
          .frame(minHeight: 44)
        }
      }
      .padding(12)
      .background(
        message.role == .user ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(.quaternary),
        in: RoundedRectangle(cornerRadius: 18)
      )

      if message.role == .assistant { Spacer(minLength: 20) }
    }
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder
  private var footer: some View {
    VStack(alignment: .leading, spacing: 4) {
      switch message.status {
      case .failed:
        Label(
          message.errorDescription ?? "Generation failed", systemImage: "exclamationmark.triangle"
        )
        .foregroundStyle(.red)
      case .cancelled:
        Label("Stopped", systemImage: "stop.circle")
          .foregroundStyle(.secondary)
      case .interrupted:
        Label("Interrupted", systemImage: "bolt.slash")
          .foregroundStyle(.orange)
      case .complete, .pending, .streaming:
        EmptyView()
      }

      if message.role == .assistant {
        HStack(spacing: 5) {
          if let accountLabel { Text(accountLabel) }
          if let modelID = message.modelID { Text(modelID.rawValue) }
          if let usage = message.usage {
            Text("\(usage.inputTokens ?? 0) in · \(usage.outputTokens ?? 0) out")
          }
        }
        .foregroundStyle(.tertiary)
      }
    }
    .font(.caption2)
  }
}

struct MessageEditorSheet: View {
  let original: String
  @Binding var text: String
  let save: () -> Void
  let cancel: () -> Void

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextEditor(text: $text)
            .frame(minHeight: 220)
        } footer: {
          Text("Saving removes every later message and generates a new response in linear history.")
        }
      }
      .navigationTitle("Edit Message")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: cancel)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save & Resend", action: save)
            .disabled(
              text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text == original
            )
        }
      }
    }
  }
}
