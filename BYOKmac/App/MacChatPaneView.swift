import AppKit
import BYOKchatProviderCore
import MacAppFoundation
import SwiftUI
import UniformTypeIdentifiers
import os

struct MacChatPane: View {
  @Bindable var providers: MacProviderModel
  @Bindable var chats: MacChatSessionModel
  @Bindable var mcp: MacMCPModel
  let conversationID: ConversationID?
  let summary: ChatConversation?
  let retainedConversations: [MacPreparedConversation]
  let navigationTarget: MacTranscriptNavigationTarget?
  let isPreparingConversation: Bool
  let composerFocusRequestID: Int
  let attachments: [ChatAttachment]
  let sidebarVisible: Bool
  let toggleSidebar: () -> Void
  let chooseTarget: () -> Void
  let manageProviders: () -> Void
  let configureTools: () -> Void
  let appendAttachments: ([ChatAttachment]) -> Void
  let removeAttachment: (String) -> Void
  let send: (String, [ChatAttachment]) -> Void

  @State private var composerHeight: CGFloat = 0

  private var transcriptBottomSpace: CGFloat {
    max(
      MacDesignTokens.Layout.composerReservedScrollSpace,
      composerHeight + MacDesignTokens.Layout.composerBottomMargin + 12
    )
  }

  private var title: String {
    let value = chats.conversation(conversationID)?.title ?? summary?.title ?? ""
    return value.isEmpty ? "New Chat" : value
  }

  private var messageCount: Int? {
    chats.conversation(conversationID)?.messages.count ?? summary?.messageCount
  }

  var body: some View {
    VStack(spacing: 0) {
      MacChatHeader(
        title: title,
        messageCount: messageCount,
        sidebarVisible: sidebarVisible,
        toggleSidebar: toggleSidebar
      )

      ZStack(alignment: .bottom) {
        ZStack {
          ForEach(retainedConversations) { retained in
            MacTranscriptView(
              chats: chats,
              mcp: mcp,
              conversationID: retained.id,
              initialConversation: retained.conversation,
              bottomSpace: transcriptBottomSpace,
              isActive: retained.id == conversationID,
              navigationTarget: navigationTarget
            )
            .environment(\.macPreparedAnswers, retained.answers)
            .environment(\.macTranscriptIsActive, retained.id == conversationID)
            .opacity(retained.id == conversationID ? 1 : 0)
            .allowsHitTesting(retained.id == conversationID)
            .accessibilityHidden(retained.id != conversationID)
            .disabled(retained.id != conversationID)
          }
        }
        .overlay(alignment: .topTrailing) {
          if isPreparingConversation {
            ProgressView("Opening chat…")
              .controlSize(.small)
              .padding(10)
              .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
              .padding(12)
              .allowsHitTesting(false)
          }
        }

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
        .onGeometryChange(for: CGFloat.self) { geometry in
          geometry.size.height
        } action: { height in
          composerHeight = height
        }
        .padding(.horizontal, MacDesignTokens.Spacing.large)
        .padding(.bottom, MacDesignTokens.Layout.composerBottomMargin)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(MacDesignTokens.Colors.canvas)
  }
}

private struct MacChatHeader: View {
  let title: String
  let messageCount: Int?
  let sidebarVisible: Bool
  let toggleSidebar: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      if !sidebarVisible {
        Color.clear
          .frame(width: MacDesignTokens.Layout.titlebarTrafficLightReserve)
          .allowsHitTesting(false)
      }

      Button(action: toggleSidebar) {
        Image(systemName: "sidebar.left")
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(.secondary)
      }
      .buttonStyle(MacIconButtonStyle())
      .help(sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
      .accessibilityLabel(sidebarVisible ? "Hide sidebar" : "Show sidebar")

      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(MacDesignTokens.Colors.textPrimary)
          .lineLimit(1)
          .truncationMode(.tail)

        if let messageCount, messageCount > 0 {
          Text("\(messageCount) messages")
            .font(.system(size: 10.5, weight: .regular))
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
            .lineLimit(1)
        }
      }
      .frame(maxWidth: 360, alignment: .leading)

      Color.clear
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
        .allowsWindowActivationEvents(true)

      MacProHeaderButton()
        .fixedSize()
    }
    .padding(.horizontal, MacDesignTokens.Spacing.compact)
    .frame(height: MacDesignTokens.Layout.titlebarHeight)
    .background(MacDesignTokens.Colors.canvas)
  }
}

/// Header trailing action: opens the paywall for free users, or the Settings
/// Plan tab for Pro users, labeled with their active plan duration.
private struct MacProHeaderButton: View {
  @Environment(PurchaseManager.self) private var purchaseManager
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings
  @Environment(MacSettingsRouter.self) private var settingsRouter

  private var hasPro: Bool { purchaseManager.hasPro }

  private var planLabel: String? {
    guard let product = purchaseManager.activeProduct else { return nil }
    if product.type == .nonConsumable { return "Pro Lifetime" }
    switch product.subscriptionPeriod?.unit {
    case .month: return "Pro Monthly"
    case .year: return "Pro Yearly"
    default: return "Pro"
    }
  }

  @ViewBuilder
  var body: some View {
    if hasPro {
      planButton
        .buttonStyle(MacSecondaryButtonStyle())
    } else {
      planButton
        .buttonStyle(MacPrimaryButtonStyle())
    }
  }

  private var planButton: some View {
    Button {
      if hasPro {
        settingsRouter.request(.plan)
        openSettings()
      } else {
        openWindow(id: MacWindowID.proPaywall)
      }
    } label: {
      HStack(spacing: 5) {
        Image(systemName: hasPro ? "checkmark.seal.fill" : "crown.fill")
          .font(.system(size: 11, weight: .semibold))
        Text(hasPro ? (planLabel ?? "Pro") : "Unlock Pro")
          .font(.system(size: 12, weight: .semibold))
      }
      .lineLimit(1)
    }
    .help(hasPro ? "Manage your plan in Settings" : "Unlock BYOK Pro")
    .accessibilityLabel(hasPro ? "Manage plan" : "Unlock BYOK Pro")
    .accessibilityValue(hasPro ? (planLabel ?? "Pro") : "")
  }
}

private struct MacTranscriptView: View {
  @Bindable var chats: MacChatSessionModel
  @Bindable var mcp: MacMCPModel
  let conversationID: ConversationID?
  let bottomSpace: CGFloat
  let isActive: Bool
  let navigationTarget: MacTranscriptNavigationTarget?
  @State private var retainedConversation: ChatConversation?
  @State private var retainedBottomSpace: CGFloat
  @State private var lastNavigationToken: UUID?
  @State private var scrollConnection = MacTranscriptScrollConnection()

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isNearBottom = true
  @State private var followsLatest = true
  @State private var isUserDraggingTimeline = false
  @State private var showJumpToLatest = false
  @State private var hasCompletedInitialScroll = false
  @State private var pendingSourceMessageID: ChatMessageID?

  private struct GenerationState: Equatable {
    let isActive: Bool
    let isGenerating: Bool
  }

  private enum ScrollTarget {
    static let bottom = "mac-transcript-bottom"
  }

  init(
    chats: MacChatSessionModel,
    mcp: MacMCPModel,
    conversationID: ConversationID?,
    initialConversation: ChatConversation?,
    bottomSpace: CGFloat,
    isActive: Bool,
    navigationTarget: MacTranscriptNavigationTarget?
  ) {
    _chats = Bindable(wrappedValue: chats)
    _mcp = Bindable(wrappedValue: mcp)
    self.conversationID = conversationID
    self.bottomSpace = bottomSpace
    self.isActive = isActive
    self.navigationTarget = navigationTarget
    _retainedConversation = State(initialValue: initialConversation)
    _retainedBottomSpace = State(initialValue: bottomSpace)
  }

  private var effectiveBottomSpace: CGFloat {
    isActive ? bottomSpace : retainedBottomSpace
  }

  private var conversation: ChatConversation? {
    isActive ? chats.conversation(conversationID) : retainedConversation
  }

  private var messages: [ChatMessage] {
    conversation?.messages ?? []
  }

  var body: some View {
    ScrollViewReader { proxy in
      ZStack(alignment: .bottom) {
        List {
          transcriptRow {
            Color.clear
              .frame(height: MacDesignTokens.Spacing.transcriptTop)
          }
          .accessibilityHidden(true)

          if conversationID == nil {
            transcriptRow {
              newConversationEmptyState
            }
          } else if conversation != nil {
            if messages.isEmpty {
              transcriptRow {
                Text("This conversation has no messages yet.")
                  .font(.system(size: 15))
                  .foregroundStyle(.secondary)
              }
            } else {
              ForEach(messages) { message in
                transcriptRow(bottomSpacing: 48) {
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
                }
                .id(message.id.rawValue)
              }
            }

            if let conversationID {
              transcriptRow(bottomSpacing: 48) {
                MacMCPInteractionStack(
                  mcp: mcp,
                  chats: chats,
                  conversationID: conversationID
                )
              }
            }
          } else {
            transcriptRow {
              loadingState
            }
          }

          transcriptRow {
            Color.clear
              .frame(height: effectiveBottomSpace)
          }
          .accessibilityHidden(true)
          .id(ScrollTarget.bottom)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.automatic)
        .background {
          MacTranscriptScrollObserver(isEnabled: isActive, connection: scrollConnection) { previous, current in
            guard isActive else { return }
            if previous == nil {
              let log = OSLog(subsystem: "pro.byok.BYOKchat", category: "ChatSwitch")
              os_signpost(.event, log: log, name: "Transcript Geometry Ready")
            }
            isNearBottom = current.isNearBottom
            isUserDraggingTimeline = current.isUserScrolling
            showJumpToLatest = MacTranscriptScrollPolicy.shouldShowJumpToLatest(
              isNearBottom: current.isNearBottom,
              hasCompletedInitialScroll: hasCompletedInitialScroll
            )

            if current.isNearBottom {
              followsLatest = true
            } else if current.userDidScroll {
              followsLatest = false
            }

            if let previous,
              previous.contentHeight != current.contentHeight,
              !current.userDidScroll,
              MacTranscriptScrollPolicy.shouldFollowContentGrowth(
                hasCompletedInitialScroll: hasCompletedInitialScroll,
                followsLatest: followsLatest,
                isUserDraggingTimeline: current.isUserScrolling,
                isGenerating: chats.isGenerating(conversationID)
              )
            {
              scrollToBottom(proxy, animated: false)
            }
          }
          .allowsHitTesting(false)
        }
        .onChange(of: effectiveBottomSpace, initial: true) { _, value in
          guard isActive else { return }
          retainedBottomSpace = value
        }
        .onChange(of: conversation, initial: true) { _, value in
          guard isActive else { return }
          retainedConversation = value
        }
        .onChange(of: messages.count) { _, _ in
          guard isActive else { return }
          if scrollToPendingSourceMessageIfAvailable(proxy) { return }
          guard followsLatest, !isUserDraggingTimeline else {
            showJumpToLatest = !isNearBottom
            return
          }
          scrollToBottom(proxy, animated: true)
        }
        .onChange(of: isActive ? mcp.pendingApprovals.count : 0) { _, _ in
          guard isActive, followsLatest, !isUserDraggingTimeline else { return }
          scrollToBottom(proxy, animated: true)
        }
        .onChange(of: isActive ? mcp.pendingElicitations.count : 0) { _, _ in
          guard isActive, followsLatest, !isUserDraggingTimeline else { return }
          scrollToBottom(proxy, animated: true)
        }
        .onChange(of: GenerationState(
          isActive: isActive,
          isGenerating: isActive && chats.isGenerating(conversationID)
        )) { previous, current in
          // Reactivating a streaming chat must preserve its previous reading
          // position, rather than treating activation as a new generation.
          guard previous.isActive, current.isActive else { return }
          if current.isGenerating {
            followsLatest = true
            isUserDraggingTimeline = false
            showJumpToLatest = false
          } else if followsLatest {
            // The live row can change height when its completed representation
            // replaces it. Re-anchor explicitly rather than restoring a
            // persistent scroll position into List's recycled rows.
            scrollToBottom(proxy, animated: false)
          } else if !isNearBottom {
            showJumpToLatest = true
          }
        }
        .onChange(of: navigationTarget, initial: true) { _, target in
          guard let target, target.request.conversationID == conversationID,
            target.token != lastNavigationToken
          else { return }
          lastNavigationToken = target.token
          pendingSourceMessageID = target.request.messageID
          if isActive, hasCompletedInitialScroll {
            _ = scrollToPendingSourceMessageIfAvailable(proxy)
          }
        }
        .task(id: isActive) {
          guard isActive else { return }
          isUserDraggingTimeline = false
          await Task.yield()
          guard !Task.isCancelled else { return }
          if !scrollToPendingSourceMessageIfAvailable(proxy), followsLatest {
            scrollToBottom(proxy, animated: false)
          }
          await Task.yield()
          guard !Task.isCancelled else { return }
          hasCompletedInitialScroll = true
          showJumpToLatest = !isNearBottom
        }

        if isActive, conversationID != nil, !messages.isEmpty, showJumpToLatest {
          Button {
            followsLatest = true
            isUserDraggingTimeline = false
            showJumpToLatest = false
            pendingSourceMessageID = nil
            scrollToBottom(proxy, animated: true)
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
          .padding(.bottom, bottomSpace)
          .help("Scroll to bottom of chat")
          .accessibilityLabel("Scroll to bottom of chat")
        }
      }
    }
  }

  private func transcriptRow<Content: View>(
    bottomSpacing: CGFloat = 0,
    @ViewBuilder content: () -> Content
  ) -> some View {
    content()
      .frame(maxWidth: MacDesignTokens.Layout.transcriptMaximumWidth, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.horizontal, MacDesignTokens.Spacing.large)
      .padding(.bottom, bottomSpacing)
      .background(MacTranscriptScrollAnchor(connection: scrollConnection).allowsHitTesting(false))
      .listRowInsets(EdgeInsets())
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
  }

  private var loadingState: some View {
    VStack(spacing: 12) {
      ProgressView()
        .accessibilityLabel("Loading conversation")
      if let preview = retainedConversation?.lastMessagePreview, !preview.isEmpty {
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

  @discardableResult
  private func scrollToPendingSourceMessageIfAvailable(_ proxy: ScrollViewProxy) -> Bool {
    guard isActive, let messageID = pendingSourceMessageID,
      messages.contains(where: { $0.id == messageID })
    else { return false }

    pendingSourceMessageID = nil
    followsLatest = false
    isUserDraggingTimeline = false
    showJumpToLatest = true

    let scroll = {
      proxy.scrollTo(messageID.rawValue, anchor: .center)
    }
    if reduceMotion {
      scroll()
    } else {
      withAnimation(.easeOut(duration: 0.18), scroll)
    }
    return true
  }

  private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
    guard isActive else { return }
    let scroll = {
      proxy.scrollTo(ScrollTarget.bottom, anchor: .bottom)
    }
    if animated && !reduceMotion {
      withAnimation(.easeOut(duration: 0.18), scroll)
    } else {
      scroll()
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

  private var project: ChatProject? {
    if let conversationID {
      return workspace.project(for: conversationID)
    }
    return workspace.project(chats.newChatProjectID)
  }

  private var projectFiles: [ProjectFile] {
    project?.projectFiles ?? []
  }

  private var promptPresets: [ProjectPromptPreset] {
    project?.projectPromptPresets ?? []
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
        MacAppAnalytics.reportError("attachment_picker_failed", component: "attachments")
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
    HStack(spacing: 8) {
      attachmentMenu
      targetButton

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

      Divider()
      Button("From Library…", systemImage: "books.vertical") {
        showingLibraryPicker = true
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

      if !promptPresets.isEmpty {
        Divider()
        Menu("Prompts", systemImage: "text.bubble") {
          ForEach(promptPresets) { preset in
            Button(preset.name) { applyPromptPreset(preset) }
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
    // Menu is width-greedy on macOS; without this it absorbs the flexible
    // space in bottomControls and pushes the model pill toward the send button.
    .fixedSize()
    .disabled(isStreaming || target == nil)
    .accessibilityLabel("Add or configure")
    .help("Add attachments, project prompts, or configure chat tools")
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
      Text(target == nil ? "Set Up Provider" : targetLabel)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.primary)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .padding(.horizontal, 9)
        .frame(height: 26)
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
    .accessibilityLabel("Change provider, model, and reasoning")
    .accessibilityValue(targetDetails)
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

  private var targetLabel: String {
    guard let target else { return "No model" }
    let providerID = selectedAccount?.providerID ?? selectedAccount?.kind.defaultProviderID
      ?? ProviderID(rawValue: target.modelID.rawValue)
    return MacTargetLabelFormatter.make(
      providerID: providerID,
      providerName: accountLabel,
      modelName: selectedModel?.displayName ?? target.modelID.rawValue,
      modelID: target.modelID.rawValue,
      supportedParameters: selectedModel?.supportedParameters ?? [],
      reasoning: target.reasoning,
      capabilities: ModelCapabilityResolver.resolve(kind: selectedAccount?.kind ?? .openAICompatible,
        modelID: target.modelID, model: selectedModel)
    )
  }

  private func submit() {
    let text = draftBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (!text.isEmpty || !attachments.isEmpty), target != nil, !isStreaming else { return }
    send(text, attachments)
  }

  private func applyPromptPreset(_ preset: ProjectPromptPreset) {
    let value = preset.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    let current = draftBinding.wrappedValue
    if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      draftBinding.wrappedValue = value
    } else {
      draftBinding.wrappedValue = current + "\n\n" + value
    }
    editorFocused = true
  }

  private func importURLs(_ urls: [URL]) {
    guard !isStreaming else { return }
    Task { @MainActor in
      do {
        appendAttachments(try await MacAttachmentImporter.importURLs(urls))
      } catch {
        MacAppAnalytics.reportError("attachment_import_failed", component: "attachments")
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
        MacAppAnalytics.reportError("attachment_import_failed", component: "attachments")
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
        MacAppAnalytics.reportError("attachment_import_failed", component: "attachments")
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
}

private struct MacAssistantMessageActions: View {
  @Environment(\.macTranscriptIsActive) private var isTranscriptActive
  @Bindable var chats: MacChatSessionModel
  let conversationID: ConversationID?
  let message: ChatMessage

  @State private var copied = false
  @State private var showingRegenerateConfirmation = false

  private var canRetry: Bool {
    guard isTranscriptActive, let conversationID else { return false }
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
      .fixedSize()
      .help("More actions")
      .accessibilityLabel("More actions")
    }
    // Pulls the leading glyph back over its centered frame's inset so the
    // first icon's visual edge lines up with the message text above.
    .padding(.leading, -7)
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
      .contentShape(Rectangle())
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

private struct MacTranscriptActivityKey: EnvironmentKey {
  static let defaultValue = true
}

private struct MacPreparedAnswersKey: EnvironmentKey {
  static let defaultValue: [String: MacPreparedAnswer] = [:]
}

extension EnvironmentValues {
  var macTranscriptIsActive: Bool {
    get { self[MacTranscriptActivityKey.self] }
    set { self[MacTranscriptActivityKey.self] = newValue }
  }

  var macPreparedAnswers: [String: MacPreparedAnswer] {
    get { self[MacPreparedAnswersKey.self] }
    set { self[MacPreparedAnswersKey.self] = newValue }
  }
}

