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

  private enum ScrollTarget {
    static let bottom = "mac-transcript-bottom"
  }

  private var conversation: ChatConversation? {
    chats.conversation(conversationID)
  }

  private var messages: [ChatMessage] {
    chats.messages(for: conversationID)
  }

  private var streamRevision: Int {
    chats.streamRevision(for: conversationID)
  }

  var body: some View {
    ScrollViewReader { proxy in
      ZStack(alignment: .bottomTrailing) {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: MacDesignTokens.Spacing.large) {
            if conversationID == nil {
              newConversationEmptyState
            } else if conversation != nil {
              if messages.isEmpty {
                Text("This conversation has no messages yet.")
                  .font(.system(size: 15))
                  .foregroundStyle(.secondary)
              } else {
                ForEach(messages) { message in
                  MacRichMessageView(
                    chats: chats,
                    mcp: mcp,
                    conversationID: conversationID,
                    message: message
                  )
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
          }
          .frame(maxWidth: MacDesignTokens.Layout.transcriptMaximumWidth)
          .frame(maxWidth: .infinity, alignment: .top)
          .padding(.horizontal, MacDesignTokens.Spacing.large)
          .padding(.top, MacDesignTokens.Spacing.transcriptTop)
          .padding(.bottom, MacDesignTokens.Layout.composerReservedScrollSpace)
        }
        .scrollIndicators(.automatic)
        .defaultScrollAnchor(.bottom)
        .onScrollGeometryChange(for: Bool.self) { geometry in
          let distance = geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height
          return distance < 180
        } action: { _, nearBottom in
          isNearBottom = nearBottom
        }
        .onChange(of: conversationID?.rawValue) { _, _ in
          isNearBottom = true
          scrollToBottom(proxy, animated: false)
        }
        .onChange(of: messages.count) { _, _ in
          guard isNearBottom else { return }
          scrollToBottom(proxy, animated: true)
        }
        .onChange(of: streamRevision) { _, _ in
          guard isNearBottom else { return }
          scrollToBottom(proxy, animated: false)
        }
        .onChange(of: mcp.pendingApprovals.count) { _, _ in
          guard isNearBottom else { return }
          scrollToBottom(proxy, animated: true)
        }
        .onChange(of: mcp.pendingElicitations.count) { _, _ in
          guard isNearBottom else { return }
          scrollToBottom(proxy, animated: true)
        }

        if conversationID != nil, !messages.isEmpty, !isNearBottom {
          Button {
            isNearBottom = true
            scrollToBottom(proxy, animated: true)
          } label: {
            Label("Latest", systemImage: "arrow.down")
              .font(.caption.weight(.medium))
              .padding(.horizontal, 10)
              .frame(height: 30)
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .padding(.trailing, MacDesignTokens.Spacing.large)
          .padding(.bottom, MacDesignTokens.Layout.composerReservedScrollSpace - 20)
          .help("Jump to latest message")
          .accessibilityHint("Scrolls to the newest response")
        }
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

      Text("Choose a provider and model, then ask anything.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 84)
  }

  private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
    Task { @MainActor in
      await Task.yield()
      if animated && !reduceMotion {
        withAnimation(.easeOut(duration: 0.16)) {
          proxy.scrollTo(ScrollTarget.bottom, anchor: .bottom)
        }
      } else {
        proxy.scrollTo(ScrollTarget.bottom, anchor: .bottom)
      }
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
    VStack(spacing: MacDesignTokens.Spacing.small) {
      if !attachments.isEmpty {
        MacAttachmentStrip(
          attachments: attachments,
          presentation: .composer,
          remove: removeAttachment
        )
        .padding(.horizontal, 2)
      }

      ZStack(alignment: .topLeading) {
        if draftBinding.wrappedValue.isEmpty {
          Text(target == nil ? "Set up a provider to chat…" : "Ask anything or send attachments…")
            .font(.system(size: 15))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 5)
            .padding(.vertical, 8)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }

        TextEditor(text: draftBinding)
          .font(.system(size: 15))
          .scrollContentBackground(.hidden)
          .focused($editorFocused)
          .frame(minHeight: attachments.isEmpty ? 48 : 38, maxHeight: attachments.isEmpty ? 112 : 88)
          .disabled(target == nil || isStreaming)
          .accessibilityLabel("Message")
          .accessibilityHint(target == nil ? "Set up a provider before composing a message" : "Return sends. Shift Return inserts a new line")
          .onKeyPress(keys: [.return], phases: .down) { press in
            if press.modifiers.contains(.shift) { return .ignored }
            guard canSend else { return .ignored }
            submit()
            return .handled
          }
      }

      HStack(spacing: MacDesignTokens.Spacing.small) {
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
        } label: {
          Image(systemName: "plus")
            .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .disabled(isStreaming || target == nil)
        .accessibilityLabel("Add attachment")
        .help("Attach files, project references, Library items, or paste from the clipboard")

        Button {
          if target == nil {
            manageProviders()
          } else {
            chooseTarget()
          }
        } label: {
          HStack(spacing: 5) {
            Image(systemName: "sparkles")
            Text(targetLabel)
              .lineLimit(1)
          }
          .font(.caption)
          .padding(.horizontal, 8)
          .frame(height: 28)
          .background(
            Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.small)
          )
        }
        .buttonStyle(.plain)
        .disabled(isStreaming)
        .help(target == nil ? "Set up a provider" : "Change provider and model")
        .accessibilityLabel("Provider and model")
        .accessibilityValue(targetLabel)

        if let conversationID {
          Button(action: configureTools) {
            HStack(spacing: 5) {
              Image(systemName: "wrench.and.screwdriver")
              Text(enabledToolCount == 0 ? "Tools" : "Tools · \(enabledToolCount)")
                .lineLimit(1)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(
              enabledToolCount > 0 ? MacDesignTokens.Colors.accentSoft : Color.primary.opacity(0.045),
              in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.small)
            )
          }
          .buttonStyle(.plain)
          .disabled(isStreaming)
          .help(mcp.inheritsProjectTools(conversationID) ? "Configure tools · currently inheriting project defaults" : "Configure tools for this chat")
          .accessibilityLabel("Chat tools")
          .accessibilityValue(enabledToolCount == 0 ? "No enabled tools" : "\(enabledToolCount) enabled tools")
        }

        if supportsReasoning {
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
            Text(reasoningLabel)
              .font(.caption)
              .padding(.horizontal, 8)
              .frame(height: 28)
              .background(
                Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.small)
              )
          }
          .menuStyle(.borderlessButton)
          .disabled(isStreaming)
          .accessibilityLabel("Reasoning")
          .accessibilityValue(reasoningLabel)
        }

        Spacer(minLength: MacDesignTokens.Spacing.small)

        Text("↩ Send  ⇧↩ New line")
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .accessibilityHidden(true)

        Button {
          if isStreaming {
            Task { await chats.stop(conversationID) }
          } else {
            submit()
          }
        } label: {
          Image(systemName: isStreaming ? "stop.fill" : "arrow.up")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(
              MacDesignTokens.Colors.accent.opacity(isStreaming || canSend ? 0.9 : 0.38),
              in: Circle()
            )
        }
        .buttonStyle(.plain)
        .disabled(!isStreaming && !canSend)
        .accessibilityLabel(isStreaming ? "Stop response" : "Send message")
        .accessibilityHint(isStreaming ? "Stops the current model response" : "Sends the current message and attachments")
      }
    }
    .padding(.horizontal, MacDesignTokens.Spacing.compact)
    .padding(.top, MacDesignTokens.Spacing.small)
    .padding(.bottom, MacDesignTokens.Spacing.small)
    .background(
      fileDropTargeted ? MacDesignTokens.Colors.accentSoft : MacDesignTokens.Colors.surface,
      in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.large)
    )
    .overlay {
      RoundedRectangle(cornerRadius: MacDesignTokens.Radius.large)
        .stroke(
          fileDropTargeted ? MacDesignTokens.Colors.accent : MacDesignTokens.Colors.separator.opacity(0.8),
          lineWidth: 1
        )
    }
    .shadow(radius: 10, y: 3)
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

  private var targetLabel: String {
    guard let target, let selectedAccount else { return "Set Up Provider" }
    let modelName = selectedModel?.displayName ?? target.modelID.rawValue
    return "\(selectedAccount.label) · \(modelName)"
  }

  private var reasoningLabel: String {
    guard target?.reasoning?.enabled == true else { return "Reasoning Off" }
    return "Reasoning · \(reasoningTitle(target?.reasoning?.effort ?? .high))"
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
