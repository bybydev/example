import AppFoundation
import BYOKchatProviderCore
import Foundation
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
    .padding(14)
    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
    .accessibilityElement(children: .combine)
  }
}

struct ChatComposer: View {
  @Binding var draft: String
  let attachments: [ChatAttachment]
  let isGenerating: Bool
  let canSend: Bool
  let targetLabel: String
  let openTarget: () -> Void
  let pickPhoto: () -> Void
  let pickFile: () -> Void
  let removeAttachment: (String) -> Void
  let send: () -> Void
  let stop: () -> Void

  @Environment(\.appFoundationTheme) private var theme
  @FocusState private var isEditorFocused: Bool

  private var normalizedDraft: String {
    draft.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var modelLabel: String {
    targetLabel.components(separatedBy: " · ").last ?? targetLabel
  }

  private var canSubmit: Bool {
    canSend && (!normalizedDraft.isEmpty || !attachments.isEmpty)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      if !attachments.isEmpty {
        ChatAttachmentStrip(
          attachments: attachments,
          removeAttachment: removeAttachment
        )
        .padding(.horizontal, 8)
        .padding(.top, 8)
      }

      if isEditorFocused {
        HStack(spacing: 6) {
          modelButton
          Spacer(minLength: 8)
        }
        .padding(.horizontal, 8)
        .padding(.top, attachments.isEmpty ? 8 : 4)
      }

      HStack(alignment: .bottom, spacing: 6) {
        optionsButton
        messageField
        sendButton
      }
      .padding(.horizontal, 8)
      .padding(.top, isEditorFocused ? 2 : 6)
      .padding(.bottom, 6)
    }
    .foregroundStyle(theme.primaryForegroundColor)
    .background(theme.elevatedSurfaceColor, in: composerShape)
    .overlay(composerShape.stroke(theme.borderColor, lineWidth: 0.75))
    .shadow(color: theme.appearance.shadow.color, radius: 14, y: 6)
    .padding(.horizontal, 14)
    .padding(.top, 6)
    .padding(.bottom, 8)
    .onChange(of: isGenerating) { _, generating in
      if generating { isEditorFocused = false }
    }
    .onDisappear { isEditorFocused = false }
  }

  private var composerShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: 24, style: .continuous)
  }

  private var messageField: some View {
    TextField("Message BYOKchat", text: $draft, axis: .vertical)
      .font(.system(size: 17))
      .foregroundStyle(theme.primaryForegroundColor)
      .tint(theme.accentColor)
      .lineLimit(1...7)
      .padding(.vertical, 4)
      .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
      .contentShape(Rectangle())
      .focused($isEditorFocused)
      .accessibilityLabel("Message")
  }

  private var optionsButton: some View {
    Menu {
      Button("Photo", systemImage: "photo", action: pickPhoto)
      Button("File", systemImage: "doc", action: pickFile)
      Divider()
      Button("Chat Settings", systemImage: "slider.horizontal.3", action: openTarget)
    } label: {
      Image(systemName: "plus")
        .font(.system(size: 22, weight: .regular))
        .foregroundStyle(theme.primaryForegroundColor)
        .frame(width: 44, height: 48)
        .contentShape(Rectangle())
    }
    .accessibilityLabel("Add attachment or open chat settings")
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
      .foregroundStyle(theme.primaryForegroundColor)
      .padding(.horizontal, 11)
      .frame(height: 38)
      .background(theme.surfaceColor, in: Capsule())
      .overlay(Capsule().stroke(theme.borderColor, lineWidth: 0.5))
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
        .frame(width: 44, height: 48)
        .background(sendButtonBackground, in: Circle())
        .foregroundStyle(sendButtonForeground)
    }
    .disabled(!isGenerating && !canSubmit)
    .accessibilityLabel(isGenerating ? "Stop generation" : "Send message")
  }

  private var sendButtonBackground: Color {
    if isGenerating || canSubmit { return theme.accentColor }
    return theme.surfaceColor
  }

  private var sendButtonForeground: Color {
    if isGenerating || canSubmit { return theme.backgroundColor }
    return theme.secondaryForegroundColor
  }
}

struct ChatAttachmentStrip: View {
  let attachments: [ChatAttachment]
  var removeAttachment: ((String) -> Void)?

  @Environment(\.appFoundationTheme) private var theme

  var body: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 8) {
        ForEach(attachments) { attachment in
          attachmentView(attachment)
        }
      }
    }
    .scrollIndicators(.hidden)
  }

  @ViewBuilder
  private func attachmentView(_ attachment: ChatAttachment) -> some View {
    ZStack(alignment: .topTrailing) {
      if attachment.isImage, let image = UIImage(data: attachment.data) {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
          .frame(width: 92, height: 72)
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .stroke(theme.borderColor, lineWidth: 0.75)
          )
          .accessibilityLabel("Image attachment \(attachment.filename)")
      } else {
        VStack(alignment: .leading, spacing: 5) {
          Image(systemName: "doc.fill")
            .font(.system(size: 20))
            .foregroundStyle(theme.accentColor)
          Text(attachment.filename)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(theme.primaryForegroundColor)
            .lineLimit(2)
          Text(
            ByteCountFormatter.string(
              fromByteCount: Int64(attachment.byteCount),
              countStyle: .file
            )
          )
          .font(.system(size: 10))
          .foregroundStyle(theme.secondaryForegroundColor)
        }
        .frame(width: 112, height: 72, alignment: .leading)
        .padding(.horizontal, 10)
        .background(theme.surfaceColor, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(theme.borderColor, lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
      }

      if let removeAttachment {
        Button("Remove \(attachment.filename)", systemImage: "xmark.circle.fill") {
          removeAttachment(attachment.id)
        }
        .labelStyle(.iconOnly)
        .font(.system(size: 17, weight: .semibold))
        .symbolRenderingMode(.palette)
        .foregroundStyle(.white, .black.opacity(0.65))
        .offset(x: 6, y: -6)
      }
    }
    .padding(.top, 6)
    .padding(.trailing, 6)
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

  @Environment(\.appFoundationTheme) private var theme
  @State private var reasoningExpanded = false
  @State private var showMessageInfo = false

  var body: some View {
    Group {
      if message.role == .user {
        userMessage
      } else {
        assistantMessage
      }
    }
    .foregroundStyle(theme.primaryForegroundColor)
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
        theme.elevatedSurfaceColor,
        in: RoundedRectangle(cornerRadius: 22, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 22, style: .continuous)
          .stroke(theme.borderColor, lineWidth: 0.5)
      )
      .contextMenu {
        if !message.content.isEmpty {
          Button("Copy", systemImage: "doc.on.doc", action: copy)
          ShareLink(item: message.content) {
            Label("Share", systemImage: "square.and.arrow.up")
          }
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

      if message.status != .pending && message.status != .streaming {
        assistantActions
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .sheet(isPresented: $showMessageInfo) {
      MessageInfoView(message: message, accountLabel: accountLabel)
    }
  }

  private var assistantActions: some View {
    HStack(spacing: 4) {
      actionButton("Copy", systemImage: "doc.on.doc", action: copy)
        .disabled(message.content.isEmpty)

      actionButton("Retry", systemImage: "arrow.clockwise", action: regenerate)
        .disabled(!canRegenerate)

      ShareLink(item: message.content) {
        Image(systemName: "square.and.arrow.up")
          .frame(width: 38, height: 38)
          .contentShape(Rectangle())
      }
      .disabled(message.content.isEmpty)
      .accessibilityLabel("Share")

      Menu {
        Button("Message Info", systemImage: "info.circle") {
          showMessageInfo = true
        }
        if !message.reasoning.isEmpty {
          Button("Copy Reasoning", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = message.reasoning
          }
        }
      } label: {
        Image(systemName: "ellipsis")
          .frame(width: 38, height: 38)
          .contentShape(Rectangle())
      }
      .accessibilityLabel("More")
    }
    .font(.system(size: 17))
    .foregroundStyle(theme.secondaryForegroundColor)
    .buttonStyle(.plain)
  }

  @ViewBuilder
  private var messageBody: some View {
    if shouldShowReasoningDisclosure {
      reasoningDisclosure
    }

    if let attachments = message.attachments, !attachments.isEmpty {
      ChatAttachmentStrip(attachments: attachments, removeAttachment: nil)
    }

    if !message.content.isEmpty {
      MarkdownMessageContent(
        text: message.content,
        showsSources: message.role == .assistant
      )
    }
  }

  private var shouldShowReasoningDisclosure: Bool {
    !message.reasoning.isEmpty || isReasoningActive
  }

  private var isReasoningActive: Bool {
    (message.status == .pending || message.status == .streaming) && message.content.isEmpty
  }

  private var reasoningDisclosure: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        guard !message.reasoning.isEmpty else { return }
        withAnimation(.snappy(duration: 0.2)) {
          reasoningExpanded.toggle()
        }
      } label: {
        HStack(spacing: 8) {
          if isReasoningActive {
            Text("Thinking…")
              .phaseAnimator([false, true]) { content, phase in
                content.opacity(phase ? 0.45 : 1)
              } animation: { _ in
                .easeInOut(duration: 0.8)
              }
          } else {
            Text("Reasoning")
          }

          Spacer(minLength: 8)

          Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .rotationEffect(.degrees(reasoningExpanded ? 90 : 0))
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(theme.secondaryForegroundColor)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(isReasoningActive ? "Thinking" : "Reasoning")
      .accessibilityValue(reasoningExpanded ? "Expanded" : "Collapsed")

      if reasoningExpanded, !message.reasoning.isEmpty {
        Text(message.reasoning)
          .font(.system(size: 15))
          .lineSpacing(4)
          .foregroundStyle(theme.secondaryForegroundColor)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
  }

  private func actionButton(
    _ title: String,
    systemImage: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(title, systemImage: systemImage, action: action)
      .labelStyle(.iconOnly)
      .frame(width: 38, height: 38)
      .contentShape(Rectangle())
      .accessibilityLabel(title)
  }

  @ViewBuilder
  private var footer: some View {
    switch message.status {
    case .failed:
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: "exclamationmark.circle.fill")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(.orange)
          .padding(.top, 1)

        VStack(alignment: .leading, spacing: 2) {
          Text("Couldn’t generate a response")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(theme.primaryForegroundColor)
          Text(message.errorDescription ?? "Try again or choose a different model.")
            .font(.system(size: 12))
            .foregroundStyle(theme.secondaryForegroundColor)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(.horizontal, 11)
      .padding(.vertical, 9)
      .background(
        Color.orange.opacity(0.09),
        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
      )
    case .cancelled:
      Label("Stopped", systemImage: "stop.circle")
        .font(.system(size: 11))
        .foregroundStyle(theme.secondaryForegroundColor)
    case .interrupted:
      Label("Interrupted", systemImage: "bolt.slash")
        .font(.system(size: 11))
        .foregroundStyle(.orange)
    case .complete, .pending, .streaming:
      EmptyView()
    }
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
