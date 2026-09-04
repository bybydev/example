import AppKit
import BYOKchatProviderCore
import SwiftUI
import UniformTypeIdentifiers

struct MacChatPane: View {
  @Bindable var providers: MacProviderModel
  @Bindable var chats: MacChatSessionModel
  @Bindable var mcp: MacMCPModel
  let conversationID: ConversationID?
  let summary: ChatConversation?
  @Binding var columnVisibility: NavigationSplitViewVisibility
  let composerFocusRequestID: Int
  let attachments: [ChatAttachment]
  let chooseTarget: () -> Void
  let manageProviders: () -> Void
  let configureTools: () -> Void
  let renameConversation: () -> Void
  let deleteConversation: () -> Void
  let appendAttachments: ([ChatAttachment]) -> Void
  let removeAttachment: (String) -> Void
  let send: (String, [ChatAttachment]) -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var title: String {
    chats.conversation(conversationID)?.title ?? summary?.title ?? "New Chat"
  }

  private var messageCount: Int? {
    chats.conversation(conversationID)?.messages.count ?? summary?.messageCount
  }

  var body: some View {
    VStack(spacing: 0) {
      MacTopBar(
        title: title,
        messageCount: messageCount,
        hasConversation: conversationID != nil,
        toggleSidebar: toggleSidebar,
        renameConversation: renameConversation,
        deleteConversation: deleteConversation
      )

      Divider()

      ZStack(alignment: .bottom) {
        MacTranscriptView(
          chats: chats,
          mcp: mcp,
          conversationID: conversationID,
          summary: summary
        )

        MacComposerView(
          providers: providers,
          chats: chats,
          mcp: mcp,
          conversationID: conversationID,
          focusRequestID: composerFocusRequestID,
          attachments: attachments,
          chooseTarget: chooseTarget,
          manageProviders: manageProviders,
          configureTools: configureTools,
          appendAttachments: appendAttachments,
          removeAttachment: removeAttachment,
          send: send
        )
        .id(conversationID?.rawValue ?? "new-chat")
        .frame(maxWidth: MacDesignTokens.Layout.composerMaximumWidth)
        .padding(.horizontal, MacDesignTokens.Spacing.large)
        .padding(.bottom, MacDesignTokens.Layout.composerBottomMargin)
      }
    }
    .background(MacDesignTokens.Colors.canvas)
  }

  private func toggleSidebar() {
    let update = {
      columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
    }
    if reduceMotion {
      update()
    } else {
      withAnimation(.easeInOut(duration: 0.16), update)
    }
  }
}

private struct MacTopBar: View {
  let title: String
  let messageCount: Int?
  let hasConversation: Bool
  let toggleSidebar: () -> Void
  let renameConversation: () -> Void
  let deleteConversation: () -> Void

  var body: some View {
    HStack(spacing: MacDesignTokens.Spacing.compact) {
      Button(action: toggleSidebar) {
        Image(systemName: "sidebar.left")
          .frame(width: 28, height: 28)
      }
      .buttonStyle(.plain)
      .help("Toggle Sidebar")
      .accessibilityLabel("Toggle Sidebar")
      .accessibilityHint("Shows or hides the conversation list")

      Text(title.isEmpty ? "New Chat" : title)
        .font(.system(size: 14, weight: .semibold))
        .lineLimit(1)
        .accessibilityAddTraits(.isHeader)

      Spacer()

      if let messageCount, messageCount > 0 {
        Text("\(messageCount) messages")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .accessibilityLabel("\(messageCount) messages in this conversation")
      }

      if hasConversation {
        Menu {
          Button("Rename", systemImage: "pencil", action: renameConversation)
          Divider()
          Button("Delete", systemImage: "trash", role: .destructive, action: deleteConversation)
        } label: {
          Image(systemName: "ellipsis")
            .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .help("Conversation Actions")
        .accessibilityLabel("Conversation actions")
      }
    }
    .padding(.horizontal, MacDesignTokens.Spacing.standard)
    .frame(height: MacDesignTokens.Layout.topBarHeight)
    .background(MacDesignTokens.Colors.canvas)
  }
}

private struct MacTranscriptView: View {
  @Bindable var chats: MacChatSessionModel
  @Bindable var mcp: MacMCPModel
  let conversationID: ConversationID?
  let summary: ChatConversation?

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isNearBottom = true
  @State private var followsLatest = true
  @State private var isUserDraggingTimeline = false
  @State private var showJumpToLatest = false
  @State private var hasCompletedInitialScroll = false
  @State private var transcriptScrollPosition = ScrollPosition(idType: String.self)

  private enum ScrollTarget {
    static let bottom = "mac-transcript-bottom"
  }

  private var conversation: ChatConversation? {
    chats.conversation(conversationID)
  }

  private var messages: [ChatMessage] {
    chats.messages(for: conversationID)
  }

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 38) {
          if conversationID == nil {
            newConversationEmptyState
          } else if conversation != nil {
            if messages.isEmpty {
              Text("This conversation has no messages yet.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            } else {
              ForEach(messages) { message in
                VStack(alignment: .leading, spacing: 8) {
                  MacRichMessageView(
                    chats: chats,
                    mcp: mcp,
                    conversationID: conversationID,
                    message: message
                  )

                  if message.role == .assistant, message.status == .complete {
                    MacAssistantMessageActions(
                      chats: chats,
                      conversationID: conversationID,
                      message: message
                    )
                  }
                }
                .id(message.id)
              }
            }

            if let conversationID {
              MacMCPInteractionStack(
                mcp: mcp,
                chats: chats,
                conversationID: conversationID
              )
            }
          } else {
            loadingState
          }

          Color.clear
            .frame(height: 1)
            .id(ScrollTarget.bottom)
            .onScrollVisibilityChange(threshold: 0.01) { isVisible in
              isNearBottom = isVisible
              if isVisible {
                followsLatest = true
                showJumpToLatest = false
              } else if hasCompletedInitialScroll && isUserDraggingTimeline {
                followsLatest = false
                showJumpToLatest = true
              }
            }
        }
        .frame(maxWidth: MacDesignTokens.Layout.transcriptMaximumWidth)
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(.horizontal, MacDesignTokens.Spacing.large)
        .padding(.top, MacDesignTokens.Spacing.transcriptTop)
        .padding(.bottom, MacDesignTokens.Layout.composerReservedScrollSpace)
      }
      .scrollIndicators(.automatic)
      .defaultScrollAnchor(.bottom)
      .scrollPosition($transcriptScrollPosition)
      .onScrollPhaseChange { _, newPhase in
        switch newPhase {
        case .tracking, .interacting, .decelerating:
          isUserDraggingTimeline = true
          if !isNearBottom {
            followsLatest = false
            showJumpToLatest = true
          }
        case .idle:
          let wasUserDriven = isUserDraggingTimeline
          isUserDraggingTimeline = false
          if isNearBottom {
            followsLatest = true
            showJumpToLatest = false
          } else if wasUserDriven {
            followsLatest = false
            showJumpToLatest = true
          }
        case .animating:
          isUserDraggingTimeline = false
        @unknown default:
          break
        }
      }
      .onScrollGeometryChange(for: CGFloat.self) { geometry in
        geometry.contentSize.height
      } action: { oldHeight, newHeight in
        guard oldHeight != newHeight,
          hasCompletedInitialScroll,
          followsLatest,
          !isUserDraggingTimeline,
          chats.isGenerating(conversationID)
        else { return }

        scrollToBottom(animated: false)
      }
      .onChange(of: messages.count) { _, _ in
        guard followsLatest, !isUserDraggingTimeline else {
          showJumpToLatest = !isNearBottom
          return
        }
        scrollToBottom(animated: true)
      }
      .onChange(of: mcp.pendingApprovals.count) { _, _ in
        guard followsLatest, !isUserDraggingTimeline else { return }
        scrollToBottom(animated: true)
      }
      .onChange(of: mcp.pendingElicitations.count) { _, _ in
        guard followsLatest, !isUserDraggingTimeline else { return }
        scrollToBottom(animated: true)
      }
      .onChange(of: chats.isGenerating(conversationID)) { _, generating in
        if generating {
          followsLatest = true
          isUserDraggingTimeline = false
          showJumpToLatest = false
        } else if !isNearBottom {
          showJumpToLatest = true
        }
      }
      .task(id: conversationID?.rawValue ?? "new-chat") {
        hasCompletedInitialScroll = false
        isNearBottom = true
        followsLatest = true
        isUserDraggingTimeline = false
        showJumpToLatest = false

        await Task.yield()
        guard !Task.isCancelled else { return }
        scrollToBottom(animated: false)
        hasCompletedInitialScroll = true
      }

      if conversationID != nil, !messages.isEmpty, showJumpToLatest {
        Button {
          followsLatest = true
          isUserDraggingTimeline = false
          showJumpToLatest = false
          scrollToBottom(animated: true)
        } label: {
          Image(systemName: "arrow.down")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 32, height: 32)
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, MacDesignTokens.Spacing.large)
        .padding(.bottom, MacDesignTokens.Layout.composerReservedScrollSpace - 20)
        .help("Scroll to bottom of chat")
        .accessibilityLabel("Scroll to bottom of chat")
      }
    }
  }

  private var loadingState: some View {
    VStack(spacing: 12) {
      ProgressView()
        .accessibilityLabel("Loading conversation")
      if let preview = summary?.lastMessagePreview, !preview.isEmpty {
        Text(preview)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(3)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 60)
  }

  private var newConversationEmptyState: some View {
    VStack(spacing: MacDesignTokens.Spacing.compact) {
      Image(systemName: "sparkles")
        .font(.system(size: 26, weight: .medium))
        .foregroundStyle(MacDesignTokens.Colors.accent)
        .accessibilityHidden(true)

      Text("Start a conversation")
        .font(.title2.weight(.semibold))
        .accessibilityAddTraits(.isHeader)

      Text("Choose a model, then ask anything.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 84)
  }

  private func scrollToBottom(animated: Bool) {
    if animated && !reduceMotion {
      withAnimation(.easeOut(duration: 0.18)) {
        transcriptScrollPosition.scrollTo(edge: .bottom)
      }
    } else {
      transcriptScrollPosition.scrollTo(edge: .bottom)
    }
  }
}

private struct MacComposerView: View {
  @Bindable var providers: MacProviderModel
  @Bindable var chats: MacChatSessionModel
  @Bindable var mcp: MacMCPModel
  let conversationID: ConversationID?
  let focusRequestID: Int
  let attachments: [ChatAttachment]
  let chooseTarget: () -> Void
  let manageProviders: () -> Void
  let configureTools: () -> Void
  let appendAttachments: ([ChatAttachment]) -> Void
  let removeAttachment: (String) -> Void
  let send: (String, [ChatAttachment]) -> Void

  @Environment(MacWorkspaceModel.self) private var workspace
  @FocusState private var editorFocused: Bool
  @State private var fileDropTargeted = false
  @State private var showingFileImporter = false
  @State private var showingLibraryPicker = false

  private var target: MacChatTarget? {
    chats.target(for: conversationID)
  }

  private var selectedAccount: ProviderAccount? {
    providers.account(target?.accountID)
  }

  private var selectedModel: ProviderModel? {
    guard let target else { return nil }
    return providers.models(for: target.accountID, includeHidden: true)
      .first { $0.model.id == target.modelID }?.model
  }

  private var isStreaming: Bool {
    chats.isGenerating(conversationID)
  }

  private var draftBinding: Binding<String> {
    Binding(
      get: { chats.draft(for: conversationID) },
      set: { chats.setDraft($0, conversationID: conversationID) }
    )
  }

  private var canSend: Bool {
    (!draftBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !attachments.isEmpty)
      && target != nil
      && !isStreaming
  }

  private var supportsReasoning: Bool {
    guard let target else { return false }
    return providers.supportsReasoning(accountID: target.accountID, modelID: target.modelID)
  }

  private var projectFiles: [ProjectFile] {
    if let conversationID {
      return workspace.projectFiles(conversationID: conversationID)
    }
    return workspace.projectFiles(projectID: chats.newChatProjectID)
  }

  private var enabledToolCount: Int {
    guard let conversationID else { return 0 }
    let configuration = mcp.chatConfiguration(for: conversationID)
    let enabledIDs = Set(configuration.enabledServerIDs)
    return enabledIDs.reduce(0) { total, serverID in
      total + mcp.tools(for: serverID).filter {
        configuration.policy(for: $0.exposedName) != .disabled
      }.count
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if !attachments.isEmpty {
        MacAttachmentStrip(
          attachments: attachments,
          presentation: .composer,
          remove: removeAttachment
        )
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 3)
      }

      messageField
        .padding(.horizontal, 14)
        .padding(.top, attachments.isEmpty ? 8 : 2)
        .padding(.bottom, 3)

      bottomControls
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }
    .background(
      fileDropTargeted ? MacDesignTokens.Colors.accentSoft : MacDesignTokens.Colors.surface,
      in: composerShape
    )
    .clipShape(composerShape)
    .overlay {
      composerShape
        .stroke(
          fileDropTargeted ? MacDesignTokens.Colors.accent : MacDesignTokens.Colors.separator.opacity(0.8),
          lineWidth: 0.75
        )
    }
    .shadow(color: .black.opacity(0.10), radius: 14, y: 5)
    .fileImporter(
      isPresented: $showingFileImporter,
      allowedContentTypes: [.item],
      allowsMultipleSelection: true
    ) { result in
      switch result {
      case .success(let urls):
        importURLs(urls)
      case .failure(let error):
        chats.errorMessage = error.localizedDescription
      }
    }
    .sheet(isPresented: $showingLibraryPicker) {
      MacLibraryAttachmentPickerView(
        workspace: workspace,
        excludedIDs: Set(attachments.map(\.id)),
        attach: appendAttachments
      )
    }
    .dropDestination(for: URL.self) { urls, _ in
      guard !urls.isEmpty, !isStreaming else { return false }
      importURLs(urls)
      return true
    } isTargeted: { targeted in
      fileDropTargeted = targeted
    }
    .dropDestination(for: MacDroppedImage.self) { images, _ in
      guard !images.isEmpty, !isStreaming else { return false }
      importImages(images)
      return true
    } isTargeted: { targeted in
      fileDropTargeted = targeted
    }
    .onChange(of: focusRequestID) { _, _ in
      editorFocused = true
    }
  }

  private var composerShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: 18, style: .continuous)
  }

  private var messageField: some View {
    TextField(
      target == nil ? "Set up a provider to chat…" : "Message…",
      text: draftBinding,
      axis: .vertical
    )
    .textFieldStyle(.plain)
    .font(.system(size: 15))
    .lineLimit(1...5)
    .focused($editorFocused)
    .padding(.horizontal, 3)
    .padding(.vertical, 6)
    .disabled(target == nil || isStreaming)
    .accessibilityLabel("Message")
    .accessibilityHint(
      target == nil
        ? "Set up a provider before composing a message"
        : "Return sends. Shift Return inserts a new line"
    )
    .onKeyPress(keys: [.return], phases: .down) { press in
      if press.modifiers.contains(.shift) { return .ignored }
      guard canSend else { return .ignored }
      submit()
      return .handled
    }
  }

  private var bottomControls: some View {
    HStack(spacing: 6) {
      attachmentMenu
      targetButton

      if supportsReasoning {
        reasoningMenu
      }

      Spacer(minLength: 10)
      sendButton
    }
    .frame(minHeight: 34)
  }

  private var attachmentMenu: some View {
    Menu {
      Button("Choose Files…", systemImage: "doc.badge.plus") {
        showingFileImporter = true
      }
      Button("Paste Image or File", systemImage: "doc.on.clipboard") {
        importPasteboard()
      }

      if !workspace.libraryEntries.isEmpty {
        Divider()
        Button("From Library…", systemImage: "books.vertical") {
          showingLibraryPicker = true
        }
      }

      if !projectFiles.isEmpty {
        Divider()
        Menu("Project Files", systemImage: "folder.badge.plus") {
          ForEach(projectFiles) { file in
            Button(file.filename) {
              attachProjectFile(file)
            }
            .disabled(attachments.contains(where: { $0.id == file.id }))
          }
        }
      }

      if conversationID != nil {
        Divider()
        Button(
          enabledToolCount == 0 ? "Tools…" : "Tools · \(enabledToolCount)…",
          systemImage: "wrench.and.screwdriver",
          action: configureTools
        )
      }
    } label: {
      Image(systemName: "plus")
        .font(.system(size: 16, weight: .regular))
        .frame(width: 34, height: 34)
        .contentShape(Circle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .disabled(isStreaming || target == nil)
    .accessibilityLabel("Add or configure")
    .help("Add attachments or configure chat tools")
  }

  private var targetButton: some View {
    Button {
      editorFocused = false
      if target == nil {
        manageProviders()
      } else {
        chooseTarget()
      }
    } label: {
      HStack(spacing: 5) {
        Text(target == nil ? "Set Up Provider" : modelLabel)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)
          .frame(maxWidth: 220)

        Image(systemName: "chevron.down")
          .font(.system(size: 7.5, weight: .semibold))
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 10)
      .frame(height: 34)
      .background(Color.primary.opacity(0.025), in: Capsule())
      .overlay {
        Capsule()
          .stroke(MacDesignTokens.Colors.separator.opacity(0.95), lineWidth: 0.75)
      }
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .disabled(isStreaming)
    .help(target == nil ? "Set up a provider" : "Change model")
    .accessibilityLabel("Model")
    .accessibilityValue(targetDetails)
  }

  private var reasoningMenu: some View {
    Menu {
      Button {
        setReasoning(nil)
      } label: {
        if target?.reasoning?.enabled != true {
          Label("Off", systemImage: "checkmark")
        } else {
          Text("Off")
        }
      }

      Divider()

      ForEach(ReasoningEffort.allCases, id: \.rawValue) { effort in
        Button {
          setReasoning(ReasoningOptions(enabled: true, effort: effort))
        } label: {
          if target?.reasoning?.enabled == true && target?.reasoning?.effort == effort {
            Label(reasoningTitle(effort), systemImage: "checkmark")
          } else {
            Text(reasoningTitle(effort))
          }
        }
      }
    } label: {
      HStack(spacing: 5) {
        Text(reasoningLabel)
          .font(.system(size: 12, weight: .semibold))
        Image(systemName: "chevron.down")
          .font(.system(size: 7.5, weight: .semibold))
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 10)
      .frame(height: 34)
      .background(Color.primary.opacity(0.025), in: Capsule())
      .overlay {
        Capsule()
          .stroke(MacDesignTokens.Colors.separator.opacity(0.95), lineWidth: 0.75)
      }
      .contentShape(Capsule())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .disabled(isStreaming)
    .accessibilityLabel("Reasoning")
    .accessibilityValue(reasoningLabel)
  }

  private var sendButton: some View {
    Button {
      if isStreaming {
        Task { await chats.stop(conversationID) }
      } else {
        submit()
        editorFocused = false
      }
    } label: {
      Image(systemName: isStreaming ? "stop.fill" : "arrow.up")
        .font(.system(size: 13, weight: .bold))
        .foregroundStyle(.white)
        .frame(width: 34, height: 34)
        .background(
          MacDesignTokens.Colors.accent.opacity(isStreaming || canSend ? 0.95 : 0.34),
          in: Circle()
        )
    }
    .buttonStyle(.plain)
    .disabled(!isStreaming && !canSend)
    .accessibilityLabel(isStreaming ? "Stop response" : "Send message")
    .accessibilityHint(
      isStreaming ? "Stops the current model response" : "Sends the current message and attachments"
    )
  }

  private var modelLabel: String {
    guard let target else { return "No model" }
    return selectedModel?.displayName ?? target.modelID.rawValue
  }

  private var accountLabel: String {
    selectedAccount?.label ?? "Provider"
  }

  private var targetDetails: String {
    guard target != nil else { return "No provider configured" }
    return "\(accountLabel) · \(modelLabel)"
  }

  private var reasoningLabel: String {
    guard target?.reasoning?.enabled == true else { return "Off" }
    return reasoningTitle(target?.reasoning?.effort ?? .high)
  }

  private func submit() {
    let text = draftBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (!text.isEmpty || !attachments.isEmpty), target != nil, !isStreaming else { return }
    send(text, attachments)
  }

  private func importURLs(_ urls: [URL]) {
    guard !isStreaming else { return }
    Task { @MainActor in
      do {
        appendAttachments(try await MacAttachmentImporter.importURLs(urls))
      } catch {
        chats.errorMessage = error.localizedDescription
      }
    }
  }

  private func importImages(_ images: [MacDroppedImage]) {
    guard !isStreaming else { return }
    Task { @MainActor in
      do {
        appendAttachments(try await MacAttachmentImporter.importDroppedImages(images))
      } catch {
        chats.errorMessage = error.localizedDescription
      }
    }
  }

  private func importPasteboard() {
    guard !isStreaming else { return }
    Task { @MainActor in
      do {
        appendAttachments(try await MacAttachmentImporter.importPasteboard())
      } catch {
        chats.errorMessage = error.localizedDescription
      }
    }
  }

  private func attachProjectFile(_ file: ProjectFile) {
    guard !isStreaming, !attachments.contains(where: { $0.id == file.id }) else { return }
    Task { @MainActor in
      if let attachment = await workspace.attachment(for: file) {
        appendAttachments([attachment])
      } else if let error = workspace.errorMessage {
        chats.errorMessage = error
      }
    }
  }

  private func setReasoning(_ reasoning: ReasoningOptions?) {
    guard var target else { return }
    target.reasoning = reasoning
    Task { _ = await chats.applyTarget(target, conversationID: conversationID) }
  }

  private func reasoningTitle(_ effort: ReasoningEffort) -> String {
    switch effort {
    case .minimal: "Minimal"
    case .low: "Low"
    case .medium: "Medium"
    case .high: "High"
    case .max: "Max"
    }
  }
}

private struct MacAssistantMessageActions: View {
  @Bindable var chats: MacChatSessionModel
  let conversationID: ConversationID?
  let message: ChatMessage

  @State private var copied = false
  @State private var showingRegenerateConfirmation = false

  private var canRetry: Bool {
    guard let conversationID else { return false }
    return chats.isLatestAssistant(message.id, conversationID: conversationID)
      && !chats.isGenerating(conversationID)
  }

  var body: some View {
    HStack(spacing: 2) {
      Button {
        copyToPasteboard(message.content)
        copied = true
        Task { @MainActor in
          try? await Task.sleep(for: .seconds(1.2))
          copied = false
        }
      } label: {
        actionIcon(copied ? "checkmark" : "doc.on.doc")
      }
      .buttonStyle(.plain)
      .disabled(message.content.isEmpty)
      .help(copied ? "Copied" : "Copy response")
      .accessibilityLabel(copied ? "Response copied" : "Copy response")

      Button(action: requestRegeneration) {
        actionIcon("arrow.clockwise")
      }
      .buttonStyle(.plain)
      .disabled(!canRetry)
      .help(canRetry ? "Retry response" : "Retry is available on the latest response")
      .accessibilityLabel("Retry response")

      Menu {
        if !message.reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Button("Copy Reasoning", systemImage: "brain") {
            copyToPasteboard(message.reasoning)
          }
        }

        if !message.content.isEmpty {
          ShareLink(item: message.content) {
            Label("Share", systemImage: "square.and.arrow.up")
          }
        }
      } label: {
        actionIcon("ellipsis")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .help("More actions")
      .accessibilityLabel("More actions")
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

  private func actionIcon(_ symbol: String) -> some View {
    Image(systemName: symbol)
      .font(.system(size: 13, weight: .medium))
      .foregroundStyle(.secondary)
      .frame(width: 30, height: 30)
      .contentShape(RoundedRectangle(cornerRadius: 7))
  }

  private func requestRegeneration() {
    guard let conversationID, canRetry else { return }
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
}
