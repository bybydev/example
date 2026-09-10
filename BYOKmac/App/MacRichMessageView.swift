import AppKit
import BYOKchatProviderCore
import SwiftUI
import UniformTypeIdentifiers

struct MacRichMessageView: View {
  @Bindable var chats: MacChatSessionModel
  @Bindable var mcp: MacMCPModel
  let conversationID: ConversationID?
  let storedMessage: ChatMessage

  @Environment(\.macTranscriptIsActive) private var isTranscriptActive
  @Environment(MacWorkspaceModel.self) private var workspace
  @State private var retainedLiveRendering: LiveRendering?
  @State private var showingDetails = false
  @State private var showingEdit = false
  @State private var showingRegenerateConfirmation = false
  @State private var copied = false

  init(
    chats: MacChatSessionModel,
    mcp: MacMCPModel,
    conversationID: ConversationID?,
    message: ChatMessage
  ) {
    _chats = Bindable(wrappedValue: chats)
    _mcp = Bindable(wrappedValue: mcp)
    self.conversationID = conversationID
    storedMessage = message
  }

  private struct LiveRendering: Equatable {
    let message: ChatMessage
    let answerSnapshot: MacStreamingAnswerSnapshot
    let reasoningSnapshot: MacStreamingAnswerSnapshot
  }

  private var livePresentation: LiveRendering? {
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
    .onChange(of: isTranscriptActive ? livePresentation : nil, initial: true) { _, rendering in
      guard isTranscriptActive else { return }
      // Preserve the last rendered height while hidden. Falling back to the
      // persisted partial text would shrink the row and clamp its scroll position.
      retainedLiveRendering = rendering
    }
    .contentShape(Rectangle())
    .contextMenu { contextActions }
    .sheet(isPresented: $showingDetails) {
      MacMessageDetailsView(message: message)
    }
    .sheet(isPresented: $showingEdit) {
      if let conversationID {
        MacEditAndResendView(
          original: message.content,
          save: { value in
            await chats.editAndResend(
              conversationID: conversationID,
              messageID: message.id,
              text: value
            )
          }
        )
      }
    }
    .confirmationDialog(
      "Regenerate this response?",
      isPresented: $showingRegenerateConfirmation,
      titleVisibility: .visible
    ) {
      Button("Regenerate") {
        regenerate(confirmingUncertainCompletion: true)
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The provider may have completed the previous request even though BYOKchat could not confirm it. Regenerating can create another billable response.")
    }
  }

  private var userMessage: some View {
    HStack(alignment: .top) {
      Spacer(minLength: 80)
      VStack(alignment: .leading, spacing: attachments.isEmpty || message.content.isEmpty ? 0 : 8) {
        if !attachments.isEmpty {
          MacAttachmentStrip(
            attachments: attachments,
            presentation: .message,
            loadThumbnail: loadThumbnail
          )
        }

        if !message.content.isEmpty {
          Text(message.content)
            .font(.system(size: 15))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
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
          streamingSnapshot: livePresentation?.reasoningSnapshot
        )
      }

      if !attachments.isEmpty {
        MacAttachmentStrip(
          attachments: attachments,
          presentation: .message,
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
              createdAt: message.createdAt
            )
            if !ok, let error = workspace.errorMessage { chats.errorMessage = error }
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
                if !ok, let error = workspace.errorMessage { chats.errorMessage = error }
              }
            }
          }
        }
      }
    }

    if message.role == .user, canMutateConversation, !message.content.isEmpty {
      Divider()
      Button("Edit & Resend", systemImage: "pencil") {
        showingEdit = true
      }
    }

    if message.role == .assistant,
      canMutateConversation,
      let conversationID,
      chats.isLatestAssistant(message.id, conversationID: conversationID)
    {
      Divider()
      Button(regenerateLabel, systemImage: "arrow.clockwise") {
        requestRegeneration()
      }
    }

    Divider()
    Button("Message Details", systemImage: "info.circle") {
      showingDetails = true
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
      Label(message.errorDescription ?? "Response failed", systemImage: "exclamationmark.triangle")
        .font(.caption)
        .foregroundStyle(.red)
    case .cancelled:
      Text("Stopped")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .interrupted:
      Label("Interrupted · partial response preserved", systemImage: "bolt.slash")
        .font(.caption)
        .foregroundStyle(.orange)
    default:
      EmptyView()
    }
  }

  private func requestRegeneration() {
    guard let conversationID else { return }
    if chats.latestAssistantRequiresRegenerationConfirmation(conversationID) {
      showingRegenerateConfirmation = true
    } else {
      regenerate(confirmingUncertainCompletion: false)
    }
  }

  private func regenerate(confirmingUncertainCompletion: Bool) {
    guard let conversationID else { return }
    Task {
      _ = await chats.regenerate(
        conversationID: conversationID,
        confirmingUncertainCompletion: confirmingUncertainCompletion
      )
    }
  }

  private func copyToPasteboard(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }

  private func exportMessage() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.markdown, .plainText]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = message.role == .assistant ? "assistant-response.md" : "message.md"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try message.content.write(to: url, atomically: true, encoding: .utf8)
    } catch {
      chats.errorMessage = error.localizedDescription
    }
  }
}

private struct MacReasoningDisclosure: View {
  let text: String
  let isStreaming: Bool
  let streamingSnapshot: MacStreamingAnswerSnapshot?

  /// Reasoning body renders one step smaller than the answer text.
  private static let contentFontSize: CGFloat = 13

  @State private var expanded = false
  @State private var reasoningStartedAt: Date?
  @State private var reasoningFinishedAt: Date?

  init(
    text: String,
    isStreaming: Bool,
    streamingSnapshot: MacStreamingAnswerSnapshot? = nil
  ) {
    self.text = text
    self.isStreaming = isStreaming
    self.streamingSnapshot = streamingSnapshot
    _reasoningStartedAt = State(initialValue: isStreaming ? .now : nil)
    _reasoningFinishedAt = State(initialValue: nil)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        expanded.toggle()
      } label: {
        reasoningLabel
      }
      .buttonStyle(.plain)
      .accessibilityLabel(isStreaming ? "Thinking" : "Reasoning")
      .accessibilityValue(expanded ? "Expanded" : "Collapsed")

      if expanded {
        reasoningContent
          .padding(.top, 7)
      }
    }
    .animation(.easeOut(duration: 0.15), value: expanded)
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
  }

  private var reasoningContent: some View {
    Group {
      if let streamingSnapshot {
        if streamingSnapshot.revision > 0 {
          MacStreamingRenderedContentView(
            snapshot: streamingSnapshot,
            textSize: Self.contentFontSize
          )
        } else {
          Text(text)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
      } else {
        MacMarkdownMessageContent(text: text, textSize: Self.contentFontSize)
      }
    }
    .font(.system(size: Self.contentFontSize))
    .foregroundStyle(.secondary)
    .padding(.leading, 14)
  }

  @ViewBuilder
  private var reasoningLabel: some View {
    HStack(spacing: 7) {
      if isStreaming {
        ProgressView()
          .controlSize(.mini)

        if let reasoningStartedAt {
          TimelineView(.periodic(from: .now, by: 1)) { context in
            Text("Thinking… \(elapsedSeconds(from: reasoningStartedAt, to: context.date))s")
          }
        } else {
          Text("Thinking…")
        }
      } else {
        Image(systemName: "brain")

        if let reasoningStartedAt, let reasoningFinishedAt {
          Text("Thought for \(elapsedSeconds(from: reasoningStartedAt, to: reasoningFinishedAt))s")
        } else {
          Text("Thought")
        }
      }

      Image(systemName: "chevron.right")
        .font(.system(size: 10, weight: .semibold))
        .rotationEffect(.degrees(expanded ? 90 : 0))
    }
    .font(.caption.weight(.semibold))
    .foregroundStyle(.secondary)
    .contentShape(Rectangle())
  }

  private func elapsedSeconds(from start: Date, to end: Date) -> Int {
    max(1, Int(end.timeIntervalSince(start).rounded(.down)))
  }
}

private struct MacEditAndResendView: View {
  let original: String
  let save: (String) async -> Bool

  @Environment(\.dismiss) private var dismiss
  @State private var text: String
  @State private var isSaving = false
  @FocusState private var focused: Bool

  init(original: String, save: @escaping (String) async -> Bool) {
    self.original = original
    self.save = save
    _text = State(initialValue: original)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Edit & Resend")
        .font(.headline)
      Text("Messages after this turn will be replaced by the new response.")
        .font(.caption)
        .foregroundStyle(.secondary)

      TextEditor(text: $text)
        .font(.system(size: 14))
        .focused($focused)
        .frame(minHeight: 180)
        .padding(6)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
          RoundedRectangle(cornerRadius: 8)
            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }

      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Resend") { commit() }
          .keyboardShortcut(.defaultAction)
          .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
      }
    }
    .padding(20)
    .frame(width: 560, height: 320)
    .onAppear { focused = true }
  }

  private func commit() {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, !isSaving else { return }
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

private struct MacMessageDetailsView: View {
  let message: ChatMessage

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Message Details")
          .font(.headline)
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
      .padding(16)
      Divider()

      Form {
        Section("Message") {
          LabeledContent("Role", value: message.role == .user ? "User" : "Assistant")
          LabeledContent("Status", value: statusLabel)
          LabeledContent("Created", value: message.createdAt.formatted(date: .abbreviated, time: .standard))
          LabeledContent("Updated", value: message.updatedAt.formatted(date: .abbreviated, time: .standard))
          LabeledContent("ID", value: message.id.rawValue)
            .textSelection(.enabled)
          if let finishReason = message.finishReason, !finishReason.isEmpty {
            LabeledContent("Finish reason", value: finishReason)
          }
        }

        if let attachments = message.attachments, !attachments.isEmpty {
          Section("Attachments") {
            ForEach(attachments) { attachment in
              VStack(alignment: .leading, spacing: 3) {
                Text(attachment.filename)
                  .font(.callout.weight(.medium))
                Text("\(attachment.mimeType) · \(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                Text(attachment.id)
                  .font(.caption2.monospaced())
                  .foregroundStyle(.tertiary)
                  .textSelection(.enabled)
              }
              .padding(.vertical, 2)
            }
          }
        }

        if let rounds = message.toolRounds, !rounds.isEmpty {
          Section("Tools") {
            LabeledContent("Rounds", value: rounds.count.formatted())
            LabeledContent("Calls", value: rounds.reduce(0, { $0 + $1.calls.count }).formatted())
            LabeledContent("Errors", value: rounds.reduce(0, { $0 + $1.results.filter(\.isError).count }).formatted())
          }
        }

        if message.providerID != nil || message.accountID != nil || message.modelID != nil {
          Section("Target") {
            if let providerID = message.providerID {
              LabeledContent("Provider", value: providerID.rawValue)
            }
            if let accountID = message.accountID {
              LabeledContent("Account", value: accountID.rawValue)
            }
            if let modelID = message.modelID {
              LabeledContent("Model", value: modelID.rawValue)
            }
          }
        }

        if let usage = message.usage {
          Section("Usage") {
            if let input = usage.inputTokens { LabeledContent("Input tokens", value: input.formatted()) }
            if let output = usage.outputTokens { LabeledContent("Output tokens", value: output.formatted()) }
            if let cached = usage.cachedInputTokens { LabeledContent("Cached input", value: cached.formatted()) }
            if let reasoning = usage.reasoningTokens { LabeledContent("Reasoning tokens", value: reasoning.formatted()) }
          }
        }

        if let errorCode = message.errorCode, !errorCode.isEmpty {
          Section("Error") {
            LabeledContent("Code", value: errorCode)
            if let description = message.errorDescription {
              Text(description)
                .textSelection(.enabled)
            }
          }
        }
      }
      .formStyle(.grouped)
    }
    .frame(width: 520, height: 560)
  }

  private var statusLabel: String {
    switch message.status {
    case .pending: "Pending"
    case .streaming: "Streaming"
    case .complete: "Complete"
    case .failed: "Failed"
    case .cancelled: "Cancelled"
    case .interrupted: "Interrupted"
    }
  }
}
