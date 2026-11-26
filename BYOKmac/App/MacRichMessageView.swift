import AppKit
import BYOKchatProviderCore
import MacAppFoundation
import SwiftUI
import UniformTypeIdentifiers

struct MacRichMessageView: View {
  @Bindable var providers: MacProviderModel
  @Bindable var chats: MacChatSessionModel
  @Bindable var mcp: MacMCPModel
  let conversationID: ConversationID?
  let storedMessage: ChatMessage
  let failureContext: String?
  let isLatestAssistant: Bool
  let onShowDetails: (ChatMessage) -> Void
  let onEditMessage: (ChatMessage) -> Void
  let onPreviewAttachment: (ChatAttachment, ChatMessage) -> Void
  let onRequestRegenerate: () -> Void

  @Environment(\.macAppTheme) private var theme
  @Environment(\.macTranscriptIsActive) private var isTranscriptActive
  @Environment(\.macToastCenter) private var toastCenter
  @Environment(MacWorkspaceModel.self) private var workspace
  @State private var retainedLiveRendering: LiveRendering?
  @State private var copied = false

  init(
    providers: MacProviderModel,
    chats: MacChatSessionModel,
    mcp: MacMCPModel,
    conversationID: ConversationID?,
    message: ChatMessage,
    failureContext: String? = nil,
    isLatestAssistant: Bool = false,
    onShowDetails: @escaping (ChatMessage) -> Void,
    onEditMessage: @escaping (ChatMessage) -> Void,
    onPreviewAttachment: @escaping (ChatAttachment, ChatMessage) -> Void,
    onRequestRegenerate: @escaping () -> Void
  ) {
    _providers = Bindable(wrappedValue: providers)
    _chats = Bindable(wrappedValue: chats)
    _mcp = Bindable(wrappedValue: mcp)
    self.conversationID = conversationID
    storedMessage = message
    self.failureContext = failureContext
    self.isLatestAssistant = isLatestAssistant
    self.onShowDetails = onShowDetails
    self.onEditMessage = onEditMessage
    self.onPreviewAttachment = onPreviewAttachment
    self.onRequestRegenerate = onRequestRegenerate
  }

  private struct LiveRendering: Equatable {
    let message: ChatMessage
    let answerSnapshot: MacStreamingAnswerSnapshot
    let reasoningSnapshot: MacStreamingAnswerSnapshot
  }

  private var mayStream: Bool {
    storedMessage.role == .assistant
      && (storedMessage.status == .pending || storedMessage.status == .streaming)
  }

  private var livePresentation: LiveRendering? {
    guard mayStream else { return nil }
    guard isTranscriptActive else { return retainedLiveRendering }
    guard let presentation = chats.livePresentations[storedMessage.id] else { return nil }
    return LiveRendering(
      message: presentation.resolve(storedMessage),
      answerSnapshot: presentation.answerSnapshot,
      reasoningSnapshot: presentation.reasoningSnapshot
    )
  }

  private var message: ChatMessage {
    livePresentation?.message ?? storedMessage
  }

  private var isStreaming: Bool {
    message.status == .pending || message.status == .streaming
  }

  private var expectsReasoning: Bool {
    isTranscriptActive && chats.target(for: conversationID)?.reasoning?.enabled == true
  }

  private var canMutateConversation: Bool {
    guard isTranscriptActive, let conversationID else { return false }
    return !chats.isGenerating(conversationID)
  }

  private var attachments: [ChatAttachment] {
    message.attachments ?? []
  }

  private var toolRounds: [ChatToolRound] {
    message.toolRounds ?? []
  }

  var body: some View {
    Group {
      switch message.role {
      case .user:
        userMessage
      case .assistant:
        assistantMessage
      }
    }
    .onChange(of: (isTranscriptActive && mayStream) ? livePresentation : nil, initial: true) { _, rendering in
      guard isTranscriptActive, mayStream else { return }
      // Preserve the last rendered height while hidden. Falling back to the
      // persisted partial text would shrink the row and clamp its scroll position.
      retainedLiveRendering = rendering
    }
    .contentShape(Rectangle())
    .contextMenu { contextActions }
  }

  private var userMessage: some View {
    HStack(alignment: .top) {
      Spacer(minLength: 80)
      VStack(alignment: .leading, spacing: attachments.isEmpty || message.content.isEmpty ? 0 : 8) {
        if !attachments.isEmpty {
          MacAttachmentStrip(
            attachments: attachments,
            presentation: .message,
            onOpenAttachment: { onPreviewAttachment($0, message) },
            saveToLibrary: attachmentSaveClosure,
            loadThumbnail: loadThumbnail
          )
        }

        if !message.content.isEmpty {
          MacUserMessageTextView(text: message.content)
            .padding(.top, attachments.isEmpty ? 0 : 2)
        }

        statusView
          .padding(.top, statusNeedsSpacing ? 6 : 0)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, attachments.isEmpty ? 10 : 9)
      .background(
        Color.primary.opacity(0.065),
        in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.message, style: .continuous)
      )
      .frame(maxWidth: 620, alignment: .trailing)
    }
  }

  private var assistantMessage: some View {
    VStack(alignment: .leading, spacing: 14) {
      if !message.reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        MacReasoningDisclosure(
          text: message.reasoning,
          isStreaming: isStreaming && message.content.isEmpty,
          streamingSnapshot: livePresentation?.reasoningSnapshot,
          onExpandedChange: { expanded in
            livePresentation?.setReasoningRenderEnabled(expanded)
          }
        )
      }

      if !attachments.isEmpty {
        MacAttachmentStrip(
          attachments: attachments,
          presentation: .message,
          onOpenAttachment: { onPreviewAttachment($0, message) },
          saveToLibrary: attachmentSaveClosure,
          loadThumbnail: loadThumbnail
        )
      }

      if !toolRounds.isEmpty {
        MacToolRoundsView(
          rounds: toolRounds,
          displayName: mcp.toolDisplayName
        )
      }

      if !message.content.isEmpty {
        if let livePresentation {
          if livePresentation.answerSnapshot.revision > 0 {
            MacStreamingRenderedContentView(snapshot: livePresentation.answerSnapshot)
          } else {
            Text(message.content)
              .font(.system(size: 15))
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
        } else {
          MacMarkdownMessageContent(text: message.content)
        }
      } else if isStreaming && message.reasoning.isEmpty && attachments.isEmpty && toolRounds.isEmpty {
        HStack(spacing: 7) {
          ProgressView()
            .controlSize(.mini)
          Text(expectsReasoning ? "Thinking…" : "Generating…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      statusView
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var statusNeedsSpacing: Bool {
    switch message.status {
    case .failed, .cancelled, .interrupted: true
    default: false
    }
  }

  private var loadThumbnail: (String, CGFloat) async -> Data? {
    { id, maxPixelSize in
      await chats.attachmentThumbnail(id, maxPixelSize: maxPixelSize)
    }
  }

  private var attachmentSaveClosure: ((ChatAttachment) -> Void)? {
    guard let conversationID, !isStreaming else { return nil }
    return { attachment in
      saveAttachmentToLibrary(attachment, conversationID: conversationID)
    }
  }

  private func saveAttachmentToLibrary(
    _ attachment: ChatAttachment,
    conversationID: ConversationID
  ) {
    Task { @MainActor in
      let ok = await workspace.saveStoredAttachmentToLibrary(
        attachment,
        conversationID: conversationID,
        messageID: message.id
      )
      if !ok, let error = workspace.consumeErrorMessage() {
        chats.errorMessage = error
      }
    }
  }

  @ViewBuilder
  private var contextActions: some View {
    if !message.content.isEmpty {
      Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
        copyToPasteboard(message.content)
        copied = true
        Task { @MainActor in
          try? await Task.sleep(for: .seconds(1.2))
          copied = false
        }
      }
    }

    if !message.reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      Button("Copy Reasoning", systemImage: "brain") {
        copyToPasteboard(message.reasoning)
      }
    }

    if !message.content.isEmpty {
      ShareLink(item: message.content) {
        Label("Share", systemImage: "square.and.arrow.up")
      }

      Button("Export as Markdown…", systemImage: "square.and.arrow.down") {
        exportMessage()
      }
    }

    if let conversationID, !isStreaming {
      if message.role == .assistant, !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Button("Save Response to Library", systemImage: "books.vertical") {
          Task { @MainActor in
            let ok = await workspace.saveResponseToLibrary(
              message.content,
              conversationID: conversationID,
              messageID: message.id,
              createdAt: message.createdAt,
              conversationTitle: chats.summary(conversationID)?.title
            )
            if ok {
              toastCenter?.success(workspace.statusMessage ?? "Saved response to Library")
            } else if let error = workspace.consumeErrorMessage() {
              chats.errorMessage = error
            }
          }
        }
      }

      if !attachments.isEmpty {
        Menu("Save Attachments to Library", systemImage: "books.vertical") {
          ForEach(attachments) { attachment in
            Button(attachment.filename) {
              Task { @MainActor in
                let ok = await workspace.saveStoredAttachmentToLibrary(
                  attachment,
                  conversationID: conversationID,
                  messageID: message.id
                )
                if ok {
                  toastCenter?.success(workspace.statusMessage ?? "Saved \"\(attachment.filename)\" to Library")
                } else if let error = workspace.consumeErrorMessage() {
                  chats.errorMessage = error
                }
              }
            }
          }
        }
      }
    }

    if message.role == .user, canMutateConversation, !message.content.isEmpty {
      Divider()
      Button("Edit & Resend", systemImage: "pencil") {
        onEditMessage(message)
      }
    }

    if isLatestAssistant, canMutateConversation {
      Divider()
      Button(regenerateLabel, systemImage: "arrow.clockwise") {
        onRequestRegenerate()
      }
    }

    Divider()
    Button("Message Details", systemImage: "info.circle") {
      onShowDetails(message)
    }
  }

  private var regenerateLabel: String {
    switch message.status {
    case .failed, .cancelled, .interrupted:
      "Retry Response"
    default:
      "Regenerate Response"
    }
  }

  @ViewBuilder
  private var statusView: some View {
    switch message.status {
    case .failed:
      failureNotice
    case .cancelled:
      HStack(spacing: 5) {
        Image(systemName: "stop.circle.fill")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
        Text("Stopped")
          .font(.system(size: 11.5, weight: .medium))
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
      }
      .padding(.horizontal, 9)
      .padding(.vertical, 4)
      .background(MacDesignTokens.Colors.surface, in: Capsule())
      .overlay(Capsule().stroke(MacDesignTokens.Colors.separator, lineWidth: 0.6))
    case .interrupted:
      HStack(spacing: 5) {
        Image(systemName: "bolt.slash.fill")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Color.orange)
        Text("Interrupted · partial response preserved")
          .font(.system(size: 11.5, weight: .medium))
          .foregroundStyle(MacDesignTokens.Colors.textPrimary)
      }
      .padding(.horizontal, 9)
      .padding(.vertical, 4)
      .background(MacDesignTokens.Colors.surface, in: Capsule())
      .overlay(Capsule().stroke(Color.orange.opacity(0.38), lineWidth: 0.7))
    default:
      EmptyView()
    }
  }

  private var failureNotice: some View {
    let description = message.errorDescription ?? "Something went wrong. Try again."

    return VStack(alignment: .leading, spacing: 3) {
      Text(description)
        .font(.system(size: 13.5))
        .foregroundStyle(MacDesignTokens.Colors.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)

      if let failureContext, !failureContext.isEmpty {
        Text(failureContext)
          .font(.system(size: 11.5, weight: .medium))
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
    .padding(.leading, 11)
    .padding(.vertical, 1)
    .overlay(alignment: .leading) {
      RoundedRectangle(cornerRadius: 1.5, style: .continuous)
        .fill(theme.destructive.opacity(0.65))
        .frame(width: 2.5)
        .padding(.vertical, 2)
        .accessibilityHidden(true)
    }
    .frame(maxWidth: 620, alignment: .leading)
  }

  private func copyToPasteboard(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }

  private func exportMessage() {
    let content = message.content
    let suggestedName = MacMessageExportSupport.filename(
      for: message,
      conversationTitle: chats.summary(conversationID)?.title
    )
    Task { @MainActor in
      let panel = NSSavePanel()
      panel.allowedContentTypes = [.markdown, .plainText]
      panel.canCreateDirectories = true
      panel.isExtensionHidden = false
      panel.nameFieldStringValue = suggestedName

      let response: NSApplication.ModalResponse
      if let window = NSApp.keyWindow {
        response = await panel.beginSheetModal(for: window)
      } else {
        response = panel.runModal()
      }
      guard response == .OK, let url = panel.url else { return }

      do {
        try content.write(to: url, atomically: true, encoding: .utf8)
        toastCenter?.success("Exported \"\(url.lastPathComponent)\"")
      } catch {
        MacAppAnalytics.reportError("message_export_failed", component: "chat")
        chats.errorMessage = error.localizedDescription
      }
    }
  }
}

nonisolated enum MacReasoningDurationFormatter {
  static func format(seconds: Int) -> String {
    let clamped = max(1, seconds)
    if clamped < 60 {
      return "\(clamped)s"
    }
    let minutes = clamped / 60
    let remainder = clamped % 60
    return remainder == 0 ? "\(minutes)m" : "\(minutes)m \(remainder)s"
  }

  static func elapsedSeconds(from start: Date, to end: Date) -> Int {
    max(1, Int(end.timeIntervalSince(start).rounded(.down)))
  }
}

private struct MacReasoningDisclosure: View {
  let text: String
  let isStreaming: Bool
  let streamingSnapshot: MacStreamingAnswerSnapshot?
  var onExpandedChange: ((Bool) -> Void)? = nil

  /// Reasoning body renders one step smaller than the answer text.
  private static let contentFontSize: CGFloat = 13
  private static let longTraceCollapseThreshold = 600

  @State private var expanded = false
  @State private var isHeaderHovered = false
  @State private var isCopyHovered = false
  @State private var isCollapseHovered = false
  @State private var copied = false
  @State private var copyResetTask: Task<Void, Never>?
  @State private var reasoningStartedAt: Date?
  @State private var reasoningFinishedAt: Date?

  init(
    text: String,
    isStreaming: Bool,
    streamingSnapshot: MacStreamingAnswerSnapshot? = nil,
    onExpandedChange: ((Bool) -> Void)? = nil
  ) {
    self.text = text
    self.isStreaming = isStreaming
    self.streamingSnapshot = streamingSnapshot
    self.onExpandedChange = onExpandedChange
    _reasoningStartedAt = State(initialValue: isStreaming ? .now : nil)
    _reasoningFinishedAt = State(initialValue: nil)
  }

  private var showsBottomCollapse: Bool {
    text.count > Self.longTraceCollapseThreshold
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 4) {
        Button {
          expanded.toggle()
        } label: {
          reasoningLabel
        }
        .buttonStyle(.plain)
        .onHover { isHeaderHovered = $0 }
        .accessibilityLabel(isStreaming ? "Thinking" : "Reasoning")
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")

        if expanded {
          Button {
            copyReasoning()
          } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(
                copied
                  ? MacDesignTokens.Colors.accent
                  : (isCopyHovered ? MacDesignTokens.Colors.textPrimary : MacDesignTokens.Colors.textMuted)
              )
              .frame(width: 22, height: 22)
              .background(
                Color.primary.opacity(isCopyHovered ? MacDesignTokens.Control.hoverOpacity : 0),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
              )
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .onHover { isCopyHovered = $0 }
          .animation(.easeOut(duration: MacDesignTokens.Control.interactionDuration), value: isCopyHovered)
          .help(copied ? "Copied reasoning" : "Copy reasoning")
          .accessibilityLabel(copied ? "Reasoning copied" : "Copy reasoning")
        }
      }

      if expanded {
        reasoningContent
          .padding(.top, 7)
      }
    }
    .animation(.easeOut(duration: 0.15), value: expanded)
    .onChange(of: expanded) { _, isExpanded in
      onExpandedChange?(isExpanded)
    }
    .onChange(of: isStreaming) { _, value in
      if value {
        if reasoningStartedAt == nil {
          reasoningStartedAt = .now
        }
        reasoningFinishedAt = nil
      } else if reasoningFinishedAt == nil, reasoningStartedAt != nil {
        reasoningFinishedAt = .now
      }
    }
    .onDisappear {
      copyResetTask?.cancel()
      copyResetTask = nil
      onExpandedChange?(false)
    }
  }

  private var reasoningContent: some View {
    VStack(alignment: .leading, spacing: 8) {
      Group {
        if let streamingSnapshot {
          if streamingSnapshot.revision > 0 {
            MacStreamingRenderedContentView(
              snapshot: streamingSnapshot,
              textSize: Self.contentFontSize,
              muted: true
            )
          } else {
            Text(text)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
        } else {
          MacMarkdownMessageContent(
            text: text,
            textSize: Self.contentFontSize,
            muted: true
          )
        }
      }
      .font(.system(size: Self.contentFontSize))

      if showsBottomCollapse {
        Button {
          expanded = false
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "chevron.up")
              .font(.system(size: 9.5, weight: .semibold))
            Text("Collapse")
              .font(.caption.weight(.medium))
          }
          .foregroundStyle(
            isCollapseHovered ? MacDesignTokens.Colors.textPrimary : MacDesignTokens.Colors.textMuted
          )
          .padding(.horizontal, 6)
          .padding(.vertical, 3)
          .background(
            Color.primary.opacity(isCollapseHovered ? MacDesignTokens.Control.hoverOpacity : 0),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
          )
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, -6)
        .onHover { isCollapseHovered = $0 }
        .animation(.easeOut(duration: MacDesignTokens.Control.interactionDuration), value: isCollapseHovered)
        .accessibilityLabel("Collapse reasoning")
      }
    }
    .padding(.leading, 12)
    .padding(.vertical, 2)
    .overlay(alignment: .leading) {
      RoundedRectangle(cornerRadius: 1.5, style: .continuous)
        .fill(MacDesignTokens.Colors.separator)
        .frame(width: 2)
        .padding(.vertical, 2)
        .accessibilityHidden(true)
    }
  }

  @ViewBuilder
  private var reasoningLabel: some View {
    HStack(spacing: 6) {
      if isStreaming {
        ProgressView()
          .controlSize(.mini)

        if let reasoningStartedAt {
          TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = MacReasoningDurationFormatter.elapsedSeconds(
              from: reasoningStartedAt,
              to: context.date
            )
            Text("Thinking… \(MacReasoningDurationFormatter.format(seconds: elapsed))")
              .monospacedDigit()
          }
        } else {
          Text("Thinking…")
        }
      } else {
        Image(systemName: "brain")

        if let reasoningStartedAt, let reasoningFinishedAt {
          let elapsed = MacReasoningDurationFormatter.elapsedSeconds(
            from: reasoningStartedAt,
            to: reasoningFinishedAt
          )
          Text("Thought for \(MacReasoningDurationFormatter.format(seconds: elapsed))")
            .monospacedDigit()
        } else {
          Text("Thought")
        }
      }

      Image(systemName: "chevron.right")
        .font(.system(size: 10, weight: .semibold))
        .rotationEffect(.degrees(expanded ? 90 : 0))
    }
    .font(.caption.weight(.semibold))
    .foregroundStyle(
      isHeaderHovered || expanded
        ? MacDesignTokens.Colors.textPrimary
        : MacDesignTokens.Colors.textMuted
    )
    .padding(.horizontal, 6)
    .padding(.vertical, 4)
    .background(
      Color.primary.opacity(isHeaderHovered ? MacDesignTokens.Control.hoverOpacity : 0),
      in: RoundedRectangle(cornerRadius: 6, style: .continuous)
    )
    .contentShape(Rectangle())
    .padding(.leading, -6)
    .animation(.easeOut(duration: MacDesignTokens.Control.interactionDuration), value: isHeaderHovered)
  }

  private func copyReasoning() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    copied = true
    copyResetTask?.cancel()
    copyResetTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(1.2))
      guard !Task.isCancelled else { return }
      copied = false
    }
  }
}

nonisolated enum MacEditAndResendGuard {
  enum BlockReason: Equatable, Sendable {
    case configurationIssue(String)
    case generating
    case empty
    case unchanged
  }

  static func blockReason(
    draft: String,
    original: String,
    configurationIssue: MacChatConfigurationIssue? = nil,
    isGenerating: Bool = false
  ) -> BlockReason? {
    if let configurationIssue {
      return .configurationIssue(configurationIssue.message)
    }
    if isGenerating {
      return .generating
    }
    let trimmedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedDraft.isEmpty else {
      return .empty
    }
    let trimmedOriginal = original.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedDraft != trimmedOriginal else {
      return .unchanged
    }
    return nil
  }

  static func canResend(
    draft: String,
    original: String,
    configurationIssue: MacChatConfigurationIssue? = nil,
    isGenerating: Bool = false
  ) -> Bool {
    blockReason(
      draft: draft,
      original: original,
      configurationIssue: configurationIssue,
      isGenerating: isGenerating
    ) == nil
  }
}

struct MacEditAndResendView: View {
  @Bindable var chats: MacChatSessionModel
  let conversationID: ConversationID
  let original: String
  let chooseTarget: (() -> Void)?
  let manageProviders: (() -> Void)?
  let save: (String) async -> Bool

  @Environment(\.dismiss) private var dismiss
  @State private var text: String
  @State private var isSaving = false
  @FocusState private var focused: Bool

  init(
    chats: MacChatSessionModel,
    conversationID: ConversationID,
    original: String,
    chooseTarget: (() -> Void)? = nil,
    manageProviders: (() -> Void)? = nil,
    save: @escaping (String) async -> Bool
  ) {
    _chats = Bindable(wrappedValue: chats)
    self.conversationID = conversationID
    self.original = original
    self.chooseTarget = chooseTarget
    self.manageProviders = manageProviders
    self.save = save
    _text = State(initialValue: original)
  }

  private var configurationIssue: MacChatConfigurationIssue? {
    chats.configurationIssue(for: conversationID)
  }

  private var isGenerating: Bool {
    chats.isGenerating(conversationID)
  }

  private var blockReason: MacEditAndResendGuard.BlockReason? {
    MacEditAndResendGuard.blockReason(
      draft: text,
      original: original,
      configurationIssue: configurationIssue,
      isGenerating: isGenerating
    )
  }

  private var canResend: Bool {
    blockReason == nil && !isSaving
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Edit & Resend")
        .font(.headline)
      Text("Messages after this turn will be replaced by the new response.")
        .font(.caption)
        .foregroundStyle(.secondary)

      if let issue = configurationIssue {
        warningBanner(
          title: "Chat configuration needs attention",
          message: issue.message,
          issue: issue
        )
      } else if isGenerating {
        warningBanner(
          title: "Generation in progress",
          message: "Wait for the current response to finish before editing and resending.",
          issue: nil
        )
      }

      TextEditor(text: $text)
        .font(.system(size: 14))
        .scrollContentBackground(.hidden)
        .focused($focused)
        .frame(minHeight: 180)
        .padding(6)
        .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
          RoundedRectangle(cornerRadius: 8)
            .stroke(MacDesignTokens.Colors.separator.opacity(0.85), lineWidth: 1)
        }

      HStack(spacing: 10) {
        if blockReason == .unchanged {
          Text("Edit the message before resending.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Cancel") { dismiss() }
          .buttonStyle(MacActionButtonStyle(.secondary))
          .keyboardShortcut(.cancelAction)
        Button("Resend") { commit() }
          .buttonStyle(MacActionButtonStyle(.primary))
          .keyboardShortcut(.defaultAction)
          .disabled(!canResend)
      }
    }
    .padding(20)
    .frame(
      minWidth: MacDesignTokens.Sheet.standardWidth,
      idealWidth: MacDesignTokens.Sheet.standardWidth,
      maxWidth: MacDesignTokens.Sheet.standardWidth,
      minHeight: 320
    )
    .onAppear { focused = true }
  }

  private func warningBanner(
    title: String,
    message: String,
    issue: MacChatConfigurationIssue?
  ) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.orange)
        .padding(.top, 1)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.caption.weight(.semibold))
          .foregroundStyle(MacDesignTokens.Colors.textPrimary)
        Text(message)
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 8)

      if let issue {
        if issue.prefersProviderRepair, let manageProviders {
          Button("Fix Connection") {
            dismiss()
            manageProviders()
          }
          .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
        } else if let chooseTarget {
          Button("Switch Model") {
            dismiss()
            chooseTarget()
          }
          .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
        }
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color.orange.opacity(0.35), lineWidth: 0.75)
    }
  }

  private func commit() {
    guard canResend else { return }
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    isSaving = true
    Task { @MainActor in
      if await save(value) {
        dismiss()
      } else {
        isSaving = false
      }
    }
  }
}

enum MacUserMessageTextSupport {
  static let collapsedLineLimit = 12
  static let collapsedCharacterLimit = 900

  struct Preview: Equatable, Sendable {
    let displayedText: String
    let isLong: Bool
    let toggleLabel: String
  }

  struct LinkMatch: Equatable, Sendable {
    let startOffset: Int
    let endOffset: Int
    let url: URL
  }

  static func isValidBrowsableURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
      return false
    }
    guard let host = url.host, !host.isEmpty else { return false }
    return true
  }

  static func preview(for text: String, isExpanded: Bool) -> Preview {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    let exceedsLines = lines.count > collapsedLineLimit
    let exceedsCharacters = text.count > collapsedCharacterLimit
    let isLong = exceedsLines || exceedsCharacters

    let displayedText: String
    if isLong, !isExpanded {
      let lineCapped = exceedsLines
        ? lines.prefix(collapsedLineLimit).joined(separator: "\n")
        : text
      let charCapped = lineCapped.count > collapsedCharacterLimit
        ? String(lineCapped.prefix(collapsedCharacterLimit))
        : lineCapped
      let trimmedTail = charCapped.replacingOccurrences(
        of: #"[ \t\r\n]+$"#,
        with: "",
        options: .regularExpression
      )
      displayedText = trimmedTail + "…"
    } else {
      displayedText = text
    }

    return Preview(
      displayedText: displayedText,
      isLong: isLong,
      toggleLabel: isExpanded ? "Show less" : "Show more"
    )
  }

  private final class LinkDetectorCache: @unchecked Sendable {
    static let shared = LinkDetectorCache()

    private let lock = NSLock()
    private lazy var detector: NSDataDetector? = try? NSDataDetector(
      types: NSTextCheckingResult.CheckingType.link.rawValue
    )
    private var cache: [String: [LinkMatch]] = [:]
    private var order: [String] = []
    private let limit = 128

    func matches(in text: String) -> [LinkMatch] {
      lock.lock()
      defer { lock.unlock() }
      if let cached = cache[text] {
        return cached
      }
      guard let detector else { return [] }
      let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
      var matches: [LinkMatch] = []
      for match in detector.matches(in: text, range: fullRange) {
        guard let url = match.url,
          MacUserMessageTextSupport.isValidBrowsableURL(url),
          let range = Range(match.range, in: text)
        else { continue }
        let startOffset = text.distance(from: text.startIndex, to: range.lowerBound)
        let endOffset = text.distance(from: text.startIndex, to: range.upperBound)
        guard endOffset > startOffset else { continue }
        matches.append(LinkMatch(startOffset: startOffset, endOffset: endOffset, url: url))
      }
      cache[text] = matches
      order.append(text)
      if order.count > limit {
        cache.removeValue(forKey: order.removeFirst())
      }
      return matches
    }
  }

  static func linkMatches(in text: String) -> [LinkMatch] {
    guard text.contains("http://")
      || text.contains("https://")
      || text.localizedCaseInsensitiveContains("www.")
    else { return [] }
    return LinkDetectorCache.shared.matches(in: text)
  }

  static func attributedText(
    _ value: String,
    matches: [LinkMatch],
    accentColor: Color
  ) -> AttributedString {
    var attributed = AttributedString(value)
    for match in matches {
      let lower = attributed.characters.index(attributed.startIndex, offsetBy: match.startOffset)
      let upper = attributed.characters.index(attributed.startIndex, offsetBy: match.endOffset)
      let range = lower..<upper
      attributed[range].link = match.url
      attributed[range].swiftUI.foregroundColor = accentColor
      attributed[range].swiftUI.underlineStyle = .single
    }
    return attributed
  }
}

private struct MacUserMessageTextView: View {
  let text: String

  @State private var isExpanded = false

  var body: some View {
    let preview = MacUserMessageTextSupport.preview(for: text, isExpanded: isExpanded)
    let matches = MacUserMessageTextSupport.linkMatches(in: preview.displayedText)

    VStack(alignment: .leading, spacing: 6) {
      if matches.isEmpty {
        Text(preview.displayedText)
          .font(.system(size: 15))
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        Text(
          MacUserMessageTextSupport.attributedText(
            preview.displayedText,
            matches: matches,
            accentColor: MacDesignTokens.Colors.accent
          )
        )
        .font(.system(size: 15))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .tint(MacDesignTokens.Colors.accent)
      }

      if preview.isLong {
        Button {
          withAnimation(.snappy(duration: 0.2)) {
            isExpanded.toggle()
          }
        } label: {
          Label(
            preview.toggleLabel,
            systemImage: isExpanded ? "chevron.up" : "chevron.down"
          )
          .font(.system(size: 12.5, weight: .semibold))
          .foregroundStyle(MacDesignTokens.Colors.accent)
          .padding(.top, 2)
        }
        .buttonStyle(.plain)
      }
    }
    .environment(
      \.openURL,
      OpenURLAction { url in
        guard MacUserMessageTextSupport.isValidBrowsableURL(url) else {
          return .discarded
        }
        NSWorkspace.shared.open(url)
        return .handled
      }
    )
  }
}

nonisolated enum MacMessageDetailsFormatter {
  struct TargetResolution: Sendable, Equatable {
    let providerName: String?
    let accountName: String?
    let isAccountDeleted: Bool
    let modelDisplayName: String?
    let modelRawID: String?

    var distinctModelRawID: String? {
      guard let modelRawID, !modelRawID.isEmpty else { return nil }
      guard let modelDisplayName, modelDisplayName != modelRawID else { return nil }
      return modelRawID
    }

    var hasAnyMetadata: Bool {
      providerName != nil || accountName != nil || modelRawID != nil
    }
  }

  enum CostBadgeKind: Sendable, Equatable {
    case exact
    case estimated
    case partial
    case unavailable
  }

  struct CostPresentation: Sendable, Equatable {
    let label: String
    let value: String
    let badgeTitle: String
    let badgeKind: CostBadgeKind
    let footnote: String
  }

  struct PerformanceRow: Sendable, Equatable, Identifiable {
    let id: String
    let label: String
    let value: String
  }

  struct PricingSnapshotPresentation: Sendable, Equatable {
    let isMultiRequest: Bool
    let inputLabel: String
    let inputPerMillion: String?
    let outputLabel: String
    let outputPerMillion: String?
    let cachedInputPerMillion: String?
    let cacheWritePerMillion: String?
    let longCacheWritePerMillion: String?
    let reasoningPerMillionNote: String?
    let officialPricingURL: URL?
    let sourceLabel: String?
    let version: String?
    let verifiedAt: String?
    let catalogUpdatedAt: Date?
    let longContextThresholdLabel: String?
    let timeRule: String?
    let contextNote: String?
    let footnote: String

    var hasAnyRates: Bool {
      inputPerMillion != nil
        || outputPerMillion != nil
        || cachedInputPerMillion != nil
        || cacheWritePerMillion != nil
        || longCacheWritePerMillion != nil
    }

    var hasCatalogDetails: Bool {
      sourceLabel != nil
        || version != nil
        || verifiedAt != nil
        || catalogUpdatedAt != nil
        || longContextThresholdLabel != nil
        || timeRule != nil
        || contextNote != nil
    }

    var shouldDisplaySection: Bool {
      hasAnyRates || officialPricingURL != nil || hasCatalogDetails
    }
  }

  struct ToolInvocationCount: Sendable, Equatable, Identifiable {
    let id: String
    let displayName: String
    let count: Int
  }

  struct ToolSummary: Sendable, Equatable {
    let roundCount: Int
    let callCount: Int
    let errorCount: Int
    let invocations: [ToolInvocationCount]
  }

  private static let posixLocale = Locale(identifier: "en_US_POSIX")

  static func providerDisplayName(
    _ raw: String,
    accounts: [ProviderAccount] = [],
    definitions: [ProviderDefinition] = [],
    fallbackLabel: String? = nil
  ) -> String {
    let trimmedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedRaw.isEmpty else { return "Unknown Provider" }

    let kind = ProviderKind(providerID: ProviderID(rawValue: trimmedRaw.lowercased()))
    if !kind.displayName.isEmpty {
      return kind.displayName
    }
    if let definition = definitions.first(where: {
      $0.id.rawValue.caseInsensitiveCompare(trimmedRaw) == .orderedSame
    }) {
      let trimmed = definition.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { return trimmed }
    }
    if let matched = accounts.first(where: {
      $0.providerID.rawValue.caseInsensitiveCompare(trimmedRaw) == .orderedSame
    }) {
      let trimmed = matched.label.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { return trimmed }
    }
    if let fallbackLabel {
      let trimmed = fallbackLabel.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { return trimmed }
    }
    if UUID(uuidString: trimmedRaw) != nil {
      return "Custom Provider"
    }
    return trimmedRaw
  }

  static func resolveTarget(
    providerID: ProviderID?,
    accountID: ProviderAccountID?,
    modelID: ModelID?,
    accounts: [ProviderAccount],
    definitions: [ProviderDefinition],
    modelsByAccount: [ProviderAccountID: [AccountModelRecord]]
  ) -> TargetResolution {
    let matchedAccount = accountID.flatMap { id in
      accounts.first { $0.id == id }
    }

    let accountName: String?
    let isAccountDeleted: Bool
    if let matchedAccount {
      let trimmed = matchedAccount.label.trimmingCharacters(in: .whitespacesAndNewlines)
      accountName = trimmed.isEmpty ? nil : trimmed
      isAccountDeleted = false
    } else if accountID != nil {
      accountName = "Deleted connection"
      isAccountDeleted = true
    } else {
      accountName = nil
      isAccountDeleted = false
    }

    let effectiveProviderID = providerID ?? matchedAccount?.providerID
    let providerName: String? = {
      if let matchedAccount, !matchedAccount.kind.displayName.isEmpty {
        return matchedAccount.kind.displayName
      }
      if let effectiveProviderID {
        return providerDisplayName(
          effectiveProviderID.rawValue,
          accounts: accounts,
          definitions: definitions,
          fallbackLabel: matchedAccount?.label
        )
      }
      return nil
    }()

    let trimmedModelID = modelID?.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let rawModelID = (trimmedModelID?.isEmpty == false) ? trimmedModelID : nil
    let modelDisplayName: String? = {
      guard let modelID, let rawModelID else { return nil }
      if let accountID,
        let record = modelsByAccount[accountID]?.first(where: { $0.model.id == modelID })
      {
        let trimmed = record.model.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
      }
      if let record = modelsByAccount.values.lazy.joined().first(where: { record in
        record.model.id == modelID
          && (effectiveProviderID == nil || record.model.providerID == effectiveProviderID)
      }) {
        let trimmed = record.model.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
      }
      if let effectiveProviderID,
        let seed = definitions.first(where: { $0.id == effectiveProviderID })?
          .seedModels.first(where: { $0.id == modelID })
      {
        let trimmed = seed.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
      }
      if let effectiveProviderID {
        let kind = matchedAccount?.kind
          ?? ProviderKind(providerID: ProviderID(rawValue: effectiveProviderID.rawValue.lowercased()))
        if let catalogModel = ModelCatalogRegistry.current?.seedModels(for: kind)
          .first(where: { $0.id == modelID })
        {
          let trimmed = catalogModel.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
          if !trimmed.isEmpty { return trimmed }
        }
      }
      return rawModelID
    }()

    return TargetResolution(
      providerName: providerName,
      accountName: accountName,
      isAccountDeleted: isAccountDeleted,
      modelDisplayName: modelDisplayName,
      modelRawID: rawModelID
    )
  }

  static func statusLabel(for status: ChatMessageStatus) -> String {
    switch status {
    case .pending: "Pending"
    case .streaming: "Streaming"
    case .complete: "Complete"
    case .failed: "Failed"
    case .cancelled: "Stopped"
    case .interrupted: "Interrupted"
    }
  }

  static func finishReasonTitle(_ raw: String) -> String {
    let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch normalized {
    case "stop", "end_turn", "completed", "complete":
      return "Completed"
    case "length", "max_tokens", "max_output_tokens", "model_length":
      return "Max tokens reached"
    case "tool_calls", "tool_use", "function_call":
      return "Tool calls"
    case "content_filter", "safety", "recitation", "refusal":
      return "Filtered by safety"
    case "pause_turn":
      return "Paused"
    case "stop_sequence":
      return "Stop sequence"
    case "cancelled", "canceled":
      return "Stopped"
    default:
      return errorTitle(normalized)
    }
  }

  static func errorTitle(_ raw: String) -> String {
    let acronyms: [String: String] = [
      "http": "HTTP",
      "mcp": "MCP",
      "url": "URL",
      "api": "API",
      "id": "ID",
      "json": "JSON",
      "sse": "SSE",
    ]
    return raw
      .replacingOccurrences(of: "_", with: " ")
      .split(separator: " ")
      .map { part in
        let lower = part.lowercased()
        return acronyms[lower] ?? part.capitalized
      }
      .joined(separator: " ")
  }

  static func tokenCount(_ value: Int, locale: Locale = .current) -> String {
    IntegerFormatStyle<Int>(locale: locale).grouping(.automatic).format(value)
  }

  static func cacheHitRate(cached: Int, input: Int) -> Double? {
    guard input > 0, cached > 0 else { return nil }
    return min(max(Double(cached) / Double(input), 0), 1)
  }

  static func percent(_ value: Double?, locale: Locale = .current) -> String {
    guard let value, value.isFinite else { return "—" }
    return FloatingPointFormatStyle<Double>.Percent(locale: locale)
      .precision(.fractionLength(0...1))
      .format(value)
  }

  static func cachedTokensWithRate(
    cached: Int,
    input: Int,
    locale: Locale = .current
  ) -> String {
    let formatted = tokenCount(cached, locale: locale)
    guard let rate = cacheHitRate(cached: cached, input: input) else { return formatted }
    return "\(formatted) (\(percent(rate, locale: locale)))"
  }

  static func duration(_ milliseconds: Double?) -> String {
    guard let milliseconds, milliseconds.isFinite, milliseconds >= 0 else { return "—" }
    if milliseconds < 999.5 {
      return "\(Int(milliseconds.rounded())) ms"
    }
    if milliseconds < 9_995 {
      return String(format: "%.2f s", locale: posixLocale, milliseconds / 1_000)
    }
    return String(format: "%.1f s", locale: posixLocale, milliseconds / 1_000)
  }

  static func throughput(_ tokensPerSecond: Double?) -> String {
    guard let tokensPerSecond, tokensPerSecond.isFinite, tokensPerSecond >= 0 else { return "—" }
    return String(format: "%.1f tok/s", locale: posixLocale, tokensPerSecond)
  }

  static func performanceRows(for performance: TelemetryPerformanceAggregate) -> [PerformanceRow] {
    guard performance.hasLatencyOrSpeedMetrics else { return [] }
    let isMultiRequest = performance.providerRequestCount > 1
    var rows: [PerformanceRow] = []
    if isMultiRequest, let totalDuration = performance.totalDurationMilliseconds {
      rows.append(PerformanceRow(
        id: "total-duration",
        label: "Total duration",
        value: duration(totalDuration)
      ))
    }
    if let ttft = performance.medianTTFTMilliseconds {
      rows.append(PerformanceRow(
        id: "ttft",
        label: isMultiRequest ? "Median TTFT" : "TTFT",
        value: duration(ttft)
      ))
    }
    if let requestDuration = performance.medianDurationMilliseconds
      ?? (!isMultiRequest ? performance.totalDurationMilliseconds : nil)
    {
      rows.append(PerformanceRow(
        id: "duration",
        label: isMultiRequest ? "Median request" : "Duration",
        value: duration(requestDuration)
      ))
    }
    if let speed = performance.medianOutputTokensPerSecond {
      rows.append(PerformanceRow(
        id: "speed",
        label: isMultiRequest ? "Median speed" : "Output speed",
        value: throughput(speed)
      ))
    }
    return rows
  }

  static func resolvedOmittedContextCount(
    telemetryCount: Int,
    message: ChatMessage,
    conversation: ChatConversation?
  ) -> Int {
    if telemetryCount > 0 { return telemetryCount }
    guard message.role == .assistant,
      let conversation,
      conversation.lastContextOmittedMessageCount > 0,
      conversation.messages.last(where: { $0.role == .assistant })?.id == message.id
    else { return 0 }
    return conversation.lastContextOmittedMessageCount
  }

  static func contextTrimmedLabel(omittedCount: Int, locale: Locale = .current) -> String? {
    guard omittedCount > 0 else { return nil }
    let countText = tokenCount(omittedCount, locale: locale)
    return "\(countText) earlier \(omittedCount == 1 ? "message" : "messages")"
  }

  static func formatUSD(_ cost: Decimal) -> String {
    let value = NSDecimalNumber(decimal: cost).doubleValue
    let magnitude = abs(value)
    if magnitude == 0 {
      return "$0.00"
    }
    if magnitude < 0.0009995 {
      return String(format: "$%.6f", locale: posixLocale, value)
    }
    if magnitude < 0.99995 {
      return String(format: "$%.4f", locale: posixLocale, value)
    }
    return String(format: "$%.2f", locale: posixLocale, value)
  }

  static func pricePerMillion(fromPerToken perToken: Decimal) -> String {
    formatUSD(perToken * Decimal(1_000_000))
  }

  static func pricePerMillion(fromPerMillionString raw: String?) -> String? {
    guard let rate = ChatBilling.decimal(raw) else { return nil }
    return formatUSD(rate)
  }

  static func costPresentation(
    billing: ChatBillingSnapshot,
    messageMetadata: [String: String] = [:]
  ) -> CostPresentation {
    let isScopedProviderCost =
      billing.requests.contains(where: { $0.missingDimensions.contains("provider billing scope") })
      || messageMetadata[ChatBilling.scopedProviderCostKey] == "true"

    let label: String = switch billing.accuracy {
    case .providerReported: "Cost"
    case .calculated: "Estimated cost"
    case .unavailable: "Cost"
    }

    let value: String
    let badgeTitle: String
    let badgeKind: CostBadgeKind
    if let cost = billing.costUSD {
      let prefix = billing.isLowerBound ? "≥" : (billing.accuracy == .calculated ? "~" : "")
      value = prefix + formatUSD(cost) + (billing.isComplete ? "" : " (partial)")
      if !billing.isComplete {
        badgeKind = .partial
        badgeTitle = isScopedProviderCost ? "BYOK Partial" : "Partial"
      } else {
        switch billing.accuracy {
        case .providerReported:
          badgeKind = .exact
          badgeTitle = "Reported"
        case .calculated:
          badgeKind = .estimated
          badgeTitle = "Estimated"
        case .unavailable:
          badgeKind = .unavailable
          badgeTitle = "Unavailable"
        }
      }
    } else {
      value = "Unavailable"
      badgeKind = .unavailable
      badgeTitle = "Unavailable"
    }

    let footnote: String
    if isScopedProviderCost {
      footnote = "Includes the reported OpenRouter account charge. Upstream provider cost is excluded, so total inference spend is incomplete."
    } else if !billing.isComplete {
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
        footnote = reasons.joined(separator: " ") + " Saved costs are estimates and may differ from provider charges."
      } else {
        footnote = "Cost is incomplete or unavailable because some requests lack usage, pricing, or supported billing details. A partial estimate is not a guaranteed minimum."
      }
    } else {
      switch billing.accuracy {
      case .providerReported:
        footnote = "Cost was reported by the provider for the saved requests."
      case .calculated:
        footnote = "Estimated from usage and the prices and billing rules saved for each request."
      case .unavailable:
        footnote = "Cost is unavailable for the saved requests."
      }
    }

    return CostPresentation(
      label: label,
      value: value,
      badgeTitle: badgeTitle,
      badgeKind: badgeKind,
      footnote: footnote
    )
  }

  static func pricingSourceLabel(_ raw: String) -> String {
    switch raw {
    case "remoteCatalog": "Remote catalog"
    case "bundledCatalog": "Bundled catalog"
    default: "Model API"
    }
  }

  static func validatedOfficialPricingURL(_ raw: String?) -> URL? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed),
      url.scheme?.lowercased() == "https",
      let host = url.host, !host.isEmpty
    else { return nil }
    return url
  }

  static func pricingSnapshotPresentation(
    billing: ChatBillingSnapshot,
    usage: ProviderUsage?,
    catalogStatus: ModelCatalogStatus? = nil,
    locale: Locale = .current
  ) -> PricingSnapshotPresentation {
    let isMultiRequest = billing.modelRequestCount > 1
    let firstSnapshotRequest = billing.requests.first { $0.pricing != nil }
    let snapshot = firstSnapshotRequest?.pricing
    let effectiveRates: ModelPricingRates? = snapshot.map { pricing in
      if let requestUsage = firstSnapshotRequest?.usage {
        return pricing.rates(for: requestUsage)
      }
      if let usage {
        return pricing.rates(for: usage)
      }
      return pricing.rates
    }

    let inputPerMillion = billing.inputPricePerToken.map(pricePerMillion(fromPerToken:))
      ?? pricePerMillion(fromPerMillionString: effectiveRates?.input)
    let outputPerMillion = billing.outputPricePerToken.map(pricePerMillion(fromPerToken:))
      ?? pricePerMillion(fromPerMillionString: effectiveRates?.output)
    let cachedInputPerMillion = pricePerMillion(fromPerMillionString: effectiveRates?.cachedInput)
    let cacheWritePerMillion = pricePerMillion(fromPerMillionString: effectiveRates?.cacheWrite)
    let longCacheWritePerMillion = pricePerMillion(fromPerMillionString: effectiveRates?.longCacheWrite)

    let reasoningPerMillionNote: String? = {
      guard (usage?.reasoningTokens ?? 0) > 0, let outputPerMillion else { return nil }
      return "\(outputPerMillion) (billed as output)"
    }()

    let officialPricingURL = validatedOfficialPricingURL(snapshot?.sourceURL)
    let sourceLabel = snapshot.map { pricingSourceLabel($0.source) }
    let catalogUpdatedAt: Date? = {
      guard let snapshot,
        let catalogStatus,
        snapshot.source == catalogStatus.source.pricingSnapshotSource
      else { return nil }
      return catalogStatus.lastUpdatedAt
    }()
    let longContextThresholdLabel = snapshot?.longContextThreshold.map {
      "\(tokenCount($0, locale: locale))+ input tokens"
    }
    let trimmedTimeRule = snapshot?.timeRule?.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedContextNote = snapshot?.contextNote?.trimmingCharacters(in: .whitespacesAndNewlines)

    let footnote = isMultiRequest
      ? "Prices and billing rules are stored per request. The rates shown are for the first request; tool rounds may differ. Later price changes do not rewrite saved spend."
      : "Prices and billing rules are stored per request. Later price changes do not rewrite saved spend."

    return PricingSnapshotPresentation(
      isMultiRequest: isMultiRequest,
      inputLabel: isMultiRequest ? "First request input / 1M" : "Input / 1M",
      inputPerMillion: inputPerMillion,
      outputLabel: isMultiRequest ? "First request output / 1M" : "Output / 1M",
      outputPerMillion: outputPerMillion,
      cachedInputPerMillion: cachedInputPerMillion,
      cacheWritePerMillion: cacheWritePerMillion,
      longCacheWritePerMillion: longCacheWritePerMillion,
      reasoningPerMillionNote: reasoningPerMillionNote,
      officialPricingURL: officialPricingURL,
      sourceLabel: sourceLabel,
      version: snapshot?.version,
      verifiedAt: snapshot?.verifiedAt,
      catalogUpdatedAt: catalogUpdatedAt,
      longContextThresholdLabel: longContextThresholdLabel,
      timeRule: trimmedTimeRule?.isEmpty == false ? trimmedTimeRule : nil,
      contextNote: trimmedContextNote?.isEmpty == false ? trimmedContextNote : nil,
      footnote: footnote
    )
  }

  static func toolSummary(
    rounds: [ChatToolRound],
    displayName: (String) -> String = { $0 }
  ) -> ToolSummary? {
    guard !rounds.isEmpty else { return nil }
    var callCount = 0
    var errorCount = 0
    var orderedKeys: [String] = []
    var countsByKey: [String: (displayName: String, count: Int)] = [:]

    for round in rounds {
      callCount += round.calls.count
      errorCount += round.results.filter(\.isError).count
      for call in round.calls {
        let resolved = displayName(call.name)
        if let existing = countsByKey[call.name] {
          countsByKey[call.name] = (existing.displayName, existing.count + 1)
        } else {
          orderedKeys.append(call.name)
          countsByKey[call.name] = (resolved, 1)
        }
      }
    }

    let invocations = orderedKeys.compactMap { key -> ToolInvocationCount? in
      guard let entry = countsByKey[key] else { return nil }
      return ToolInvocationCount(id: key, displayName: entry.displayName, count: entry.count)
    }

    return ToolSummary(
      roundCount: rounds.count,
      callCount: callCount,
      errorCount: errorCount,
      invocations: invocations
    )
  }

  static func plainTextSummary(
    message: ChatMessage,
    target: TargetResolution,
    billing: ChatBillingSnapshot,
    cost: CostPresentation,
    pricing: PricingSnapshotPresentation,
    performanceRows: [PerformanceRow],
    omittedContextCount: Int,
    toolSummary: ToolSummary?,
    locale: Locale = .current
  ) -> String {
    var lines: [String] = ["Message Details"]
    lines.append("Role: \(message.role == .user ? "User" : "Assistant")")
    lines.append("Status: \(statusLabel(for: message.status))")
    if let provider = target.providerName {
      lines.append("Provider: \(provider)")
    }
    if let account = target.accountName {
      lines.append("Account: \(account)")
    }
    if let model = target.modelDisplayName {
      if let rawID = target.distinctModelRawID {
        lines.append("Model: \(model) (\(rawID))")
      } else {
        lines.append("Model: \(model)")
      }
    }
    if let usage = message.usage {
      if let input = usage.inputTokens {
        lines.append("Input tokens: \(tokenCount(input, locale: locale))")
      }
      if let cached = usage.cachedInputTokens, cached > 0 {
        lines.append("Cached input: \(cachedTokensWithRate(cached: cached, input: usage.inputTokens ?? 0, locale: locale))")
      }
      if let cacheWrite = usage.cacheWriteTokens, cacheWrite > 0 {
        lines.append("Cache write: \(tokenCount(cacheWrite, locale: locale))")
      }
      if let output = usage.outputTokens {
        lines.append("Output tokens: \(tokenCount(output, locale: locale))")
      }
      if let reasoning = usage.reasoningTokens, reasoning > 0 {
        lines.append("Reasoning tokens: \(tokenCount(reasoning, locale: locale))")
      }
      if let input = usage.inputTokens, let output = usage.outputTokens {
        lines.append("Total tokens: \(tokenCount(input + output, locale: locale))")
      }
    }
    if message.role == .assistant {
      lines.append("\(cost.label): \(cost.value)")
    }
    for row in performanceRows {
      lines.append("\(row.label): \(row.value)")
    }
    if billing.modelRequestCount > 0 {
      lines.append("Model requests: \(tokenCount(billing.modelRequestCount, locale: locale))")
    }
    if billing.toolCallCount > 0 {
      lines.append("Tool calls: \(tokenCount(billing.toolCallCount, locale: locale))")
    }
    if let trimmed = contextTrimmedLabel(omittedCount: omittedContextCount, locale: locale) {
      lines.append("Context trimmed: \(trimmed)")
    }
    if let finishReason = message.finishReason, !finishReason.isEmpty {
      lines.append("Finish reason: \(finishReasonTitle(finishReason))")
    }
    if let errorCode = message.errorCode, !errorCode.isEmpty {
      lines.append("Error code: \(errorTitle(errorCode))")
    }
    if pricing.hasAnyRates {
      if let input = pricing.inputPerMillion {
        lines.append("\(pricing.inputLabel): \(input)")
      }
      if let output = pricing.outputPerMillion {
        lines.append("\(pricing.outputLabel): \(output)")
      }
      if let cached = pricing.cachedInputPerMillion {
        lines.append("Cached input / 1M: \(cached)")
      }
      if let write = pricing.cacheWritePerMillion {
        lines.append("Cache write / 1M: \(write)")
      }
    }
    if let toolSummary {
      lines.append("Tools: \(toolSummary.roundCount) rounds, \(toolSummary.callCount) calls, \(toolSummary.errorCount) errors")
    }
    if let attachments = message.attachments, !attachments.isEmpty {
      lines.append("Attachments: \(attachments.count)")
    }
    lines.append("Created: \(message.createdAt.ISO8601Format())")
    lines.append("Updated: \(message.updatedAt.ISO8601Format())")
    lines.append("ID: \(message.id.rawValue)")
    return lines.joined(separator: "\n")
  }
}

private enum MacMessageDetailsTelemetry {
  static let shared: TelemetryRecorder = MacStorageEnvironment.current.makeTelemetryRecorder()
}

struct MacMessageDetailsView: View {
  let message: ChatMessage
  @Bindable var providers: MacProviderModel
  let conversation: ChatConversation?
  let toolDisplayName: ((String) -> String)?
  let telemetryRecorder: TelemetryRecorder?

  @Environment(\.dismiss) private var dismiss
  @Environment(\.macToastCenter) private var toastCenter

  @State private var messagePerformance: TelemetryPerformanceAggregate?
  @State private var telemetryOmittedContextCount = 0
  @State private var catalogExpanded = false
  @State private var copiedDetails = false

  init(
    message: ChatMessage,
    providers: MacProviderModel,
    conversation: ChatConversation? = nil,
    toolDisplayName: ((String) -> String)? = nil,
    telemetryRecorder: TelemetryRecorder? = nil
  ) {
    self.message = message
    _providers = Bindable(wrappedValue: providers)
    self.conversation = conversation
    self.toolDisplayName = toolDisplayName
    self.telemetryRecorder = telemetryRecorder
  }

  private var billing: ChatBillingSnapshot {
    ChatBilling.snapshot(for: message)
  }

  private var target: MacMessageDetailsFormatter.TargetResolution {
    MacMessageDetailsFormatter.resolveTarget(
      providerID: message.providerID,
      accountID: message.accountID,
      modelID: message.modelID,
      accounts: providers.accounts,
      definitions: providers.definitions,
      modelsByAccount: providers.modelsByAccount
    )
  }

  private var cost: MacMessageDetailsFormatter.CostPresentation {
    MacMessageDetailsFormatter.costPresentation(
      billing: billing,
      messageMetadata: message.metadata
    )
  }

  private var pricing: MacMessageDetailsFormatter.PricingSnapshotPresentation {
    MacMessageDetailsFormatter.pricingSnapshotPresentation(
      billing: billing,
      usage: message.usage,
      catalogStatus: providers.modelCatalogStatus
    )
  }

  private var performanceRows: [MacMessageDetailsFormatter.PerformanceRow] {
    guard let messagePerformance else { return [] }
    return MacMessageDetailsFormatter.performanceRows(for: messagePerformance)
  }

  private var effectiveOmittedContextCount: Int {
    MacMessageDetailsFormatter.resolvedOmittedContextCount(
      telemetryCount: telemetryOmittedContextCount,
      message: message,
      conversation: conversation
    )
  }

  private var toolSummary: MacMessageDetailsFormatter.ToolSummary? {
    MacMessageDetailsFormatter.toolSummary(
      rounds: message.toolRounds ?? [],
      displayName: { name in toolDisplayName?(name) ?? name }
    )
  }

  private var attachments: [ChatAttachment] {
    message.attachments ?? []
  }

  private var showUsageSection: Bool {
    message.role == .assistant || message.usage != nil || billing.costUSD != nil
  }

  var body: some View {
    VStack(spacing: 0) {
      headerBar
      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          if target.hasAnyMetadata {
            modelSection
          }

          if showUsageSection {
            usageAndCostSection
          }

          if message.role == .assistant, !performanceRows.isEmpty {
            performanceSection
          }

          requestSection

          if pricing.shouldDisplaySection {
            pricingSection
          }

          if let toolSummary {
            toolsSection(toolSummary)
          }

          if !attachments.isEmpty {
            attachmentsSection
          }
        }
        .padding(18)
      }
    }
    .frame(
      width: MacDesignTokens.Sheet.standardWidth,
      height: MacDesignTokens.Sheet.standardHeight
    )
    .background(MacDesignTokens.Colors.canvas)
    .task(id: message.id) {
      await loadMessageTelemetry()
    }
  }

  private var headerBar: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Message Details")
          .font(.headline)
        Text(headerSubtitle)
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
          .lineLimit(1)
      }

      Spacer()

      Button {
        copyDetailsSummary()
      } label: {
        Label(
          copiedDetails ? "Copied" : "Copy Details",
          systemImage: copiedDetails ? "checkmark" : "doc.on.doc"
        )
      }
      .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
      .help("Copy a plain-text summary of message details")

      Button("Done") { dismiss() }
        .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
        .keyboardShortcut(.cancelAction)
    }
    .padding(16)
  }

  private var headerSubtitle: String {
    let role = message.role == .user ? "User" : "Assistant"
    let timestamp = message.updatedAt.formatted(date: .abbreviated, time: .shortened)
    if let model = target.modelDisplayName {
      return "\(role) · \(model) · \(timestamp)"
    }
    return "\(role) · \(timestamp)"
  }

  private var modelSection: some View {
    detailsCard("Model & Connection", systemImage: "cpu") {
      VStack(spacing: 8) {
        if let providerName = target.providerName {
          detailRow("Provider", value: providerName)
        }
        if let accountName = target.accountName {
          detailRow(
            "Account",
            value: accountName,
            valueColor: target.isAccountDeleted
              ? MacDesignTokens.Colors.textMuted
              : MacDesignTokens.Colors.textPrimary
          )
        }
        if let modelDisplayName = target.modelDisplayName {
          detailRow("Model", value: modelDisplayName, selectable: true)
        }
        if let rawID = target.distinctModelRawID {
          detailRow("Model ID", value: rawID, monospaced: true, selectable: true)
        }
      }
    }
  }

  private var usageAndCostSection: some View {
    let usage = message.usage
    let hasTokens =
      usage?.inputTokens != nil
      || (usage?.cachedInputTokens ?? 0) > 0
      || (usage?.cacheWriteTokens ?? 0) > 0
      || (usage?.longCacheWriteTokens ?? 0) > 0
      || usage?.outputTokens != nil
      || (usage?.reasoningTokens ?? 0) > 0

    return detailsCard(
      "Tokens & Cost",
      systemImage: "chart.bar.doc.horizontal",
      footer: message.role == .assistant ? cost.footnote : nil
    ) {
      VStack(spacing: 8) {
        if let input = usage?.inputTokens {
          detailRow(
            "Input",
            value: MacMessageDetailsFormatter.tokenCount(input),
            monospacedDigits: true
          )
        }
        if let cached = usage?.cachedInputTokens, cached > 0 {
          detailRow(
            "Cached input",
            value: MacMessageDetailsFormatter.cachedTokensWithRate(
              cached: cached,
              input: usage?.inputTokens ?? 0
            ),
            monospacedDigits: true
          )
        }
        if let cacheWrite = usage?.cacheWriteTokens, cacheWrite > 0 {
          detailRow(
            "Cache write",
            value: MacMessageDetailsFormatter.tokenCount(cacheWrite),
            monospacedDigits: true
          )
        }
        if let longCacheWrite = usage?.longCacheWriteTokens, longCacheWrite > 0 {
          detailRow(
            "Long cache write",
            value: MacMessageDetailsFormatter.tokenCount(longCacheWrite),
            monospacedDigits: true
          )
        }
        if let output = usage?.outputTokens {
          detailRow(
            "Output",
            value: MacMessageDetailsFormatter.tokenCount(output),
            monospacedDigits: true
          )
        }
        if let reasoning = usage?.reasoningTokens, reasoning > 0 {
          detailRow(
            "Reasoning",
            value: MacMessageDetailsFormatter.tokenCount(reasoning),
            monospacedDigits: true
          )
        }
        if let input = usage?.inputTokens, let output = usage?.outputTokens {
          detailRow(
            "Total tokens",
            value: MacMessageDetailsFormatter.tokenCount(input + output),
            monospacedDigits: true,
            emphasized: true
          )
        }

        if message.role == .assistant {
          if hasTokens {
            Divider()
              .padding(.vertical, 2)
          }

          HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(spacing: 6) {
              Text(cost.label)
                .font(.system(size: 12.5))
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
              costBadge(cost.badgeTitle, kind: cost.badgeKind)
            }
            Spacer(minLength: 12)
            Text(cost.value)
              .font(.system(size: 13, weight: .semibold))
              .monospacedDigit()
              .foregroundStyle(MacDesignTokens.Colors.textPrimary)
              .textSelection(.enabled)
          }
        }
      }
    }
  }

  private var performanceSection: some View {
    detailsCard("Performance", systemImage: "gauge.with.dots.needle.67percent") {
      VStack(spacing: 8) {
        ForEach(performanceRows) { row in
          detailRow(row.label, value: row.value, monospacedDigits: true)
        }
      }
    }
  }

  private var requestSection: some View {
    detailsCard("Request", systemImage: "doc.text.magnifyingglass") {
      VStack(alignment: .leading, spacing: 8) {
        detailRow("Role", value: message.role == .user ? "User" : "Assistant")
        detailRow(
          "Status",
          value: MacMessageDetailsFormatter.statusLabel(for: message.status),
          valueColor: statusColor
        )
        if message.status == .failed, let errorCode = message.errorCode, !errorCode.isEmpty {
          detailRow(
            "Error code",
            value: MacMessageDetailsFormatter.errorTitle(errorCode),
            valueColor: .red
          )
        }
        if billing.modelRequestCount > 0 {
          detailRow(
            "Model requests",
            value: MacMessageDetailsFormatter.tokenCount(billing.modelRequestCount),
            monospacedDigits: true
          )
        }
        if billing.toolCallCount > 0 {
          detailRow(
            "Tool calls",
            value: MacMessageDetailsFormatter.tokenCount(billing.toolCallCount),
            monospacedDigits: true
          )
        }
        if let trimmedLabel = MacMessageDetailsFormatter.contextTrimmedLabel(
          omittedCount: effectiveOmittedContextCount
        ) {
          detailRow(
            "Context trimmed",
            value: trimmedLabel,
            valueColor: .orange,
            monospacedDigits: true
          )
        }
        if let finishReason = message.finishReason, !finishReason.isEmpty {
          detailRow(
            "Finish reason",
            value: MacMessageDetailsFormatter.finishReasonTitle(finishReason)
          )
        }
        detailRow(
          "Created",
          value: message.createdAt.formatted(date: .abbreviated, time: .standard),
          monospacedDigits: true
        )
        detailRow(
          message.role == .assistant ? "Generated" : "Updated",
          value: message.updatedAt.formatted(date: .abbreviated, time: .standard),
          monospacedDigits: true
        )
        detailRow(
          "Message ID",
          value: message.id.rawValue,
          monospaced: true,
          selectable: true
        )

        if let description = message.errorDescription, !description.isEmpty {
          Divider()
            .padding(.vertical, 2)
          VStack(alignment: .leading, spacing: 4) {
            Text("Error details")
              .font(.system(size: 11.5, weight: .semibold))
              .foregroundStyle(Color.red)
            Text(description)
              .font(.system(size: 12.5))
              .foregroundStyle(MacDesignTokens.Colors.textPrimary)
              .fixedSize(horizontal: false, vertical: true)
              .textSelection(.enabled)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(10)
          .background(
            Color.red.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
          )
          .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .stroke(Color.red.opacity(0.22), lineWidth: 0.6)
          }
        }
      }
    }
  }

  private var pricingSection: some View {
    detailsCard(
      "Pricing Snapshot",
      systemImage: "dollarsign.circle",
      footer: pricing.footnote
    ) {
      VStack(alignment: .leading, spacing: 8) {
        if let input = pricing.inputPerMillion {
          detailRow(pricing.inputLabel, value: input, monospacedDigits: true)
        }
        if let output = pricing.outputPerMillion {
          detailRow(pricing.outputLabel, value: output, monospacedDigits: true)
        }
        if let cached = pricing.cachedInputPerMillion {
          detailRow("Cached input / 1M", value: cached, monospacedDigits: true)
        }
        if let write = pricing.cacheWritePerMillion {
          detailRow("Cache write / 1M", value: write, monospacedDigits: true)
        }
        if let longWrite = pricing.longCacheWritePerMillion {
          detailRow("Long cache write / 1M", value: longWrite, monospacedDigits: true)
        }
        if let reasoningNote = pricing.reasoningPerMillionNote {
          detailRow("Reasoning / 1M", value: reasoningNote, monospacedDigits: true)
        }

        if let url = pricing.officialPricingURL {
          if pricing.hasAnyRates {
            Divider()
              .padding(.vertical, 2)
          }
          Button {
            NSWorkspace.shared.open(url)
          } label: {
            HStack(spacing: 6) {
              Label("Official pricing", systemImage: "arrow.up.right.square")
                .font(.system(size: 12.5, weight: .medium))
              Spacer()
              if let host = url.host {
                Text(host)
                  .font(.caption)
                  .foregroundStyle(MacDesignTokens.Colors.textMuted)
              }
            }
            .foregroundStyle(MacDesignTokens.Colors.accent)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help("Open \(url.absoluteString)")
        }

        if pricing.hasCatalogDetails {
          Divider()
            .padding(.vertical, 2)
          DisclosureGroup("Catalog details", isExpanded: $catalogExpanded) {
            VStack(spacing: 7) {
              if let sourceLabel = pricing.sourceLabel {
                detailRow("Source", value: sourceLabel)
              }
              if let version = pricing.version {
                detailRow("Version", value: version, monospaced: true, selectable: true)
              }
              if let verified = pricing.verifiedAt {
                detailRow("Verified", value: verified, monospacedDigits: true)
              }
              if let updatedAt = pricing.catalogUpdatedAt {
                detailRow(
                  "Catalog updated",
                  value: updatedAt.formatted(date: .abbreviated, time: .shortened),
                  monospacedDigits: true
                )
              }
              if let threshold = pricing.longContextThresholdLabel {
                detailRow("Long-context tier", value: threshold, monospacedDigits: true)
              }
              if let timeRule = pricing.timeRule {
                detailRow("Schedule rule", value: timeRule)
              }
              if let note = pricing.contextNote {
                Text(note)
                  .font(.caption)
                  .foregroundStyle(MacDesignTokens.Colors.textMuted)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .fixedSize(horizontal: false, vertical: true)
                  .padding(.top, 2)
              }
            }
            .padding(.top, 8)
          }
          .font(.system(size: 12.5, weight: .medium))
          .foregroundStyle(MacDesignTokens.Colors.textPrimary)
        }
      }
    }
  }

  private func toolsSection(_ summary: MacMessageDetailsFormatter.ToolSummary) -> some View {
    detailsCard("Tool Calls", systemImage: "wrench.and.screwdriver") {
      VStack(alignment: .leading, spacing: 8) {
        detailRow(
          "Rounds",
          value: MacMessageDetailsFormatter.tokenCount(summary.roundCount),
          monospacedDigits: true
        )
        detailRow(
          "Calls",
          value: MacMessageDetailsFormatter.tokenCount(summary.callCount),
          monospacedDigits: true
        )
        detailRow(
          "Errors",
          value: MacMessageDetailsFormatter.tokenCount(summary.errorCount),
          valueColor: summary.errorCount > 0 ? .red : MacDesignTokens.Colors.textPrimary,
          monospacedDigits: true
        )

        if !summary.invocations.isEmpty {
          Divider()
            .padding(.vertical, 2)
          VStack(alignment: .leading, spacing: 6) {
            ForEach(summary.invocations) { invocation in
              HStack(spacing: 8) {
                Text(invocation.displayName)
                  .font(.system(size: 12.5))
                  .foregroundStyle(MacDesignTokens.Colors.textPrimary)
                  .lineLimit(1)
                Spacer(minLength: 10)
                Text("\(invocation.count)×")
                  .font(.system(size: 12, weight: .medium))
                  .monospacedDigit()
                  .foregroundStyle(MacDesignTokens.Colors.textMuted)
              }
            }
          }
        }
      }
    }
  }

  private var attachmentsSection: some View {
    detailsCard("Attachments (\(attachments.count))", systemImage: "paperclip") {
      VStack(alignment: .leading, spacing: 10) {
        ForEach(Array(attachments.enumerated()), id: \.element.id) { index, attachment in
          if index > 0 {
            Divider()
          }
          VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
              Image(systemName: attachment.isImage ? "photo" : "doc")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
              Text(attachment.filename)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(MacDesignTokens.Colors.textPrimary)
                .lineLimit(1)
              Spacer(minLength: 8)
              Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
            }
            Text(attachment.mimeType)
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
            Text(attachment.id)
              .font(.caption2.monospaced())
              .foregroundStyle(.tertiary)
              .textSelection(.enabled)
          }
        }
      }
    }
  }

  private var statusColor: Color {
    switch message.status {
    case .failed: .red
    case .interrupted: .orange
    case .cancelled: MacDesignTokens.Colors.textMuted
    case .complete, .pending, .streaming: MacDesignTokens.Colors.textPrimary
    }
  }

  private func costBadge(
    _ title: String,
    kind: MacMessageDetailsFormatter.CostBadgeKind
  ) -> some View {
    let tint: Color = switch kind {
    case .exact: .green
    case .estimated: MacDesignTokens.Colors.accent
    case .partial: .orange
    case .unavailable: MacDesignTokens.Colors.textMuted
    }
    return Text(title)
      .font(.system(size: 10.5, weight: .semibold))
      .foregroundStyle(tint)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(tint.opacity(0.12), in: Capsule())
  }

  private func detailsCard<Content: View>(
    _ title: String,
    systemImage: String,
    footer: String? = nil,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      VStack(alignment: .leading, spacing: 10) {
        Label(title, systemImage: systemImage)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(MacDesignTokens.Colors.textPrimary)
        content()
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        MacDesignTokens.Colors.surface,
        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
          .stroke(MacDesignTokens.Colors.separator.opacity(0.75), lineWidth: 0.6)
      }

      if let footer, !footer.isEmpty {
        Text(footer)
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 4)
      }
    }
  }

  private func detailRow(
    _ label: String,
    value: String,
    valueColor: Color = MacDesignTokens.Colors.textPrimary,
    monospaced: Bool = false,
    monospacedDigits: Bool = false,
    emphasized: Bool = false,
    selectable: Bool = false
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(label)
        .font(.system(size: 12.5))
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
      Spacer(minLength: 12)
      valueText(
        value,
        color: valueColor,
        monospaced: monospaced,
        monospacedDigits: monospacedDigits,
        emphasized: emphasized,
        selectable: selectable
      )
    }
  }

  @ViewBuilder
  private func valueText(
    _ value: String,
    color: Color,
    monospaced: Bool,
    monospacedDigits: Bool,
    emphasized: Bool,
    selectable: Bool
  ) -> some View {
    let base = Text(value)
      .font(
        monospaced
          ? .system(size: 12, design: .monospaced)
          : .system(size: 12.5, weight: emphasized ? .semibold : .regular)
      )
      .foregroundStyle(color)
      .multilineTextAlignment(.trailing)

    let formatted = Group {
      if monospacedDigits {
        base.monospacedDigit()
      } else {
        base
      }
    }

    if selectable {
      formatted.textSelection(.enabled)
    } else {
      formatted
    }
  }

  private func loadMessageTelemetry() async {
    guard message.role == .assistant else {
      messagePerformance = nil
      telemetryOmittedContextCount = 0
      return
    }
    let recorder = telemetryRecorder ?? MacMessageDetailsTelemetry.shared
    let events = await recorder.loadMessageAnalytics(messageID: message.id)
    guard !Task.isCancelled else { return }
    let performance = UsageAnalytics.messagePerformance(
      messageID: message.id,
      telemetryEvents: events,
      range: .all
    )
    messagePerformance = performance.hasLatencyOrSpeedMetrics ? performance : nil
    telemetryOmittedContextCount = UsageAnalytics.messageOmittedContextCount(
      messageID: message.id,
      telemetryEvents: events
    )
  }

  private func copyDetailsSummary() {
    let summary = MacMessageDetailsFormatter.plainTextSummary(
      message: message,
      target: target,
      billing: billing,
      cost: cost,
      pricing: pricing,
      performanceRows: performanceRows,
      omittedContextCount: effectiveOmittedContextCount,
      toolSummary: toolSummary
    )
    NSPasteboard.general.clearContents()
    guard NSPasteboard.general.setString(summary, forType: .string) else { return }
    copiedDetails = true
    toastCenter?.success("Copied message details")
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(1.5))
      copiedDetails = false
    }
  }
}
