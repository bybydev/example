import BYOKchatProviderCore
import SwiftUI
import UIKit

struct ChatTopBar<MenuContent: View>: View {
  let openSidebar: () -> Void
  let newChat: () -> Void
  private let menuContent: MenuContent

  init(
    openSidebar: @escaping () -> Void,
    newChat: @escaping () -> Void,
    @ViewBuilder menuContent: () -> MenuContent
  ) {
    self.openSidebar = openSidebar
    self.newChat = newChat
    self.menuContent = menuContent()
  }

  var body: some View {
    HStack(spacing: 12) {
      Button("Open Sidebar", systemImage: "line.3.horizontal", action: openSidebar)
        .labelStyle(.iconOnly)
        .font(.system(size: 17, weight: .semibold))
        .symbolRenderingMode(.hierarchical)
        .frame(width: 40, height: 40)
        .background(.thinMaterial, in: Circle())
        .overlay(Circle().stroke(.primary.opacity(0.08), lineWidth: 0.5))
        .contentShape(Circle())
        .accessibilityLabel("Open sidebar")

      Spacer()

      HStack(spacing: 2) {
        Button("New Chat", systemImage: "square.and.pencil", action: newChat)
          .labelStyle(.iconOnly)
          .font(.system(size: 17, weight: .semibold))
          .symbolRenderingMode(.hierarchical)
          .frame(width: 40, height: 40)
          .contentShape(Rectangle())

        Rectangle()
          .fill(.primary.opacity(0.10))
          .frame(width: 0.5, height: 18)
          .accessibilityHidden(true)

        Menu {
          menuContent
        } label: {
          Image(systemName: "ellipsis")
            .font(.system(size: 17, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("More options")
      }
      .foregroundStyle(.primary)
      .padding(2)
      .background(.thinMaterial, in: Capsule())
      .overlay(Capsule().stroke(.primary.opacity(0.08), lineWidth: 0.5))
    }
    .buttonStyle(.plain)
    .foregroundStyle(.primary)
    .shadow(color: .black.opacity(0.055), radius: 10, y: 4)
    .padding(.horizontal, 14)
    .padding(.top, 4)
    .padding(.bottom, 8)
  }
}

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
    .padding(14)
    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
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

  @FocusState private var isEditorFocused: Bool

  private var normalizedDraft: String {
    draft.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var modelLabel: String {
    targetLabel.components(separatedBy: " · ").last ?? targetLabel
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .bottom, spacing: 6) {
        optionsButton
          .frame(width: isEditorFocused ? 0 : 40)
          .opacity(isEditorFocused ? 0 : 1)
          .clipped()
          .allowsHitTesting(!isEditorFocused)

        messageField

        sendButton
          .frame(width: isEditorFocused ? 0 : 40)
          .opacity(isEditorFocused ? 0 : 1)
          .clipped()
          .allowsHitTesting(!isEditorFocused)
      }
      .padding(.horizontal, 8)
      .padding(.top, isEditorFocused ? 10 : 6)
      .padding(.bottom, isEditorFocused ? 2 : 6)

      if isEditorFocused {
        HStack(spacing: 6) {
          optionsButton
          modelButton
          Spacer(minLength: 8)
          sendButton
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .background(.thinMaterial, in: composerShape)
    .overlay(composerShape.stroke(.primary.opacity(0.08), lineWidth: 0.5))
    .shadow(color: .black.opacity(0.06), radius: 14, y: 6)
    .animation(.snappy(duration: 0.22), value: isEditorFocused)
    .padding(.horizontal, 14)
    .padding(.top, 6)
    .padding(.bottom, 8)
    .onChange(of: isGenerating) { _, generating in
      if generating { isEditorFocused = false }
    }
    .onDisappear { isEditorFocused = false }
  }

  private var composerShape: RoundedRectangle {
    RoundedRectangle(
      cornerRadius: isEditorFocused ? 24 : 28,
      style: .continuous
    )
  }

  private var messageField: some View {
    TextField("Message BYOKchat", text: $draft, axis: .vertical)
      .font(.system(size: 17))
      .lineLimit(isEditorFocused ? 1...7 : 1...1)
      .frame(minHeight: 40)
      .focused($isEditorFocused)
      .accessibilityLabel("Message")
  }

  private var optionsButton: some View {
    Button("Chat options", systemImage: "plus", action: openTarget)
      .labelStyle(.iconOnly)
      .font(.system(size: 22, weight: .regular))
      .frame(width: 40, height: 40)
      .contentShape(Circle())
      .accessibilityLabel("Chat options")
  }

  private var modelButton: some View {
    Button(action: openTarget) {
      HStack(spacing: 5) {
        Text(modelLabel)
          .lineLimit(1)
        Image(systemName: "chevron.down")
          .font(.system(size: 9, weight: .semibold))
      }
      .font(.system(size: 14, weight: .medium))
      .foregroundStyle(.primary)
      .padding(.horizontal, 11)
      .frame(height: 38)
      .background(Color(uiColor: .secondarySystemFill), in: Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Change provider account and model, currently \(targetLabel)")
  }

  private var sendButton: some View {
    Button {
      if isGenerating {
        stop()
      } else {
        send()
      }
      isEditorFocused = false
    } label: {
      Image(systemName: isGenerating ? "stop.fill" : "arrow.up")
        .font(.system(size: 16, weight: .bold))
        .frame(width: 40, height: 40)
        .background(sendButtonBackground, in: Circle())
        .foregroundStyle(sendButtonForeground)
    }
    .disabled(!isGenerating && (!canSend || normalizedDraft.isEmpty))
    .accessibilityLabel(isGenerating ? "Stop generation" : "Send message")
  }

  private var sendButtonBackground: Color {
    if isGenerating || (canSend && !normalizedDraft.isEmpty) { return .primary }
    return Color(uiColor: .tertiarySystemFill)
  }

  private var sendButtonForeground: Color {
    if isGenerating || (canSend && !normalizedDraft.isEmpty) {
      return Color(uiColor: .systemBackground)
    }
    return .secondary
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
    Group {
      if message.role == .user {
        userMessage
      } else {
        assistantMessage
      }
    }
    .accessibilityElement(children: .contain)
  }

  private var userMessage: some View {
    HStack(alignment: .top) {
      Spacer(minLength: 54)
      VStack(alignment: .leading, spacing: 8) {
        messageBody
      }
      .padding(.horizontal, 15)
      .padding(.vertical, 11)
      .background(
        Color(uiColor: .secondarySystemBackground),
        in: RoundedRectangle(cornerRadius: 22, style: .continuous)
      )
      .contextMenu {
        Button("Copy", systemImage: "doc.on.doc", action: copy)
        ShareLink(item: message.content) {
          Label("Share", systemImage: "square.and.arrow.up")
        }
        if canEdit {
          Button("Edit and Resend", systemImage: "pencil", action: edit)
        }
      }
    }
  }

  private var assistantMessage: some View {
    VStack(alignment: .leading, spacing: 10) {
      messageBody
      footer

      if !message.content.isEmpty {
        HStack(spacing: 4) {
          actionButton("Copy", systemImage: "doc.on.doc", action: copy)
          ShareLink(item: message.content) {
            Image(systemName: "square.and.arrow.up")
              .frame(width: 38, height: 38)
              .contentShape(Rectangle())
          }
          .accessibilityLabel("Share")

          if canRegenerate {
            actionButton("Regenerate", systemImage: "arrow.clockwise", action: regenerate)
          }
        }
        .font(.system(size: 17))
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private var messageBody: some View {
    if !message.reasoning.isEmpty {
      DisclosureGroup("Reasoning") {
        Text(message.reasoning)
          .font(.system(size: 15))
          .lineSpacing(4)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 4)
      }
      .font(.system(size: 13, weight: .semibold))
      .tint(.secondary)
    }

    if !message.content.isEmpty {
      MarkdownMessageContent(text: message.content)
    } else if message.status == .pending || message.status == .streaming {
      HStack(spacing: 8) {
        ProgressView()
        Text("Thinking…")
          .font(.system(size: 17))
          .foregroundStyle(.secondary)
      }
    }
  }

  private func actionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
    Button(title, systemImage: systemImage, action: action)
      .labelStyle(.iconOnly)
      .frame(width: 38, height: 38)
      .contentShape(Rectangle())
      .accessibilityLabel(title)
  }

  @ViewBuilder
  private var footer: some View {
    VStack(alignment: .leading, spacing: 5) {
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

      if message.role == .assistant,
        let detail = metadataSummary
      {
        Text(detail)
          .foregroundStyle(.tertiary)
      }
    }
    .font(.system(size: 11))
  }

  private var metadataSummary: String? {
    var parts: [String] = []
    if let accountLabel { parts.append(accountLabel) }
    if let modelID = message.modelID { parts.append(modelID.rawValue) }
    if let usage = message.usage {
      parts.append("\(usage.inputTokens ?? 0) in · \(usage.outputTokens ?? 0) out")
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
            .font(.system(size: 17))
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
