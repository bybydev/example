import AppFoundation
import BYOKchatProviderCore
import SwiftUI
import UIKit

nonisolated struct ChatTimelineGeometry: Equatable, Sendable {
  let contentHeight: CGFloat
  let containerHeight: CGFloat
  let needsBottomPin: Bool
  let isNearBottom: Bool

  static func shouldContinueBottomSettle(
    geometry: ChatTimelineGeometry?,
    previousContentHeight: CGFloat,
    isNearBottom: Bool
  ) -> Bool {
    guard let geometry else { return true }
    if geometry.needsBottomPin || !geometry.isNearBottom || !isNearBottom { return true }
    return geometry.contentHeight > previousContentHeight + 1
  }
}

private extension View {
  func chatTimelineRow() -> some View {
    listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
  }
}

extension ChatView {
  private static let bottomAnchorID = "chat.timeline.bottom"
  @ViewBuilder
  func chatContent(_ conversation: ChatConversation) -> some View {
    let isUntouched = conversation.messages.isEmpty && !chats.isGenerating(conversation.id)
    Group {
      if isUntouched {
        // An untouched chat has no scroll view: the empty state *is* the content
        // area, centered between the nav bar and the composer.
        VStack(spacing: 0) {
          Spacer(minLength: 0)
          existingEmptyState(conversation)
            .padding(.horizontal, 24)
          Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
          dismissKeyboard()
        }
      } else {
        scrollViewContent(conversation)
          .overlay(alignment: .bottom) {
            if showJumpToLatest {
              jumpToLatestButton
                .padding(.bottom, 6)
            }
          }
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      chatComposer(for: conversation, isGenerating: !isUntouched && chats.isGenerating(conversationID))
    }
  }

  private var jumpToLatestButton: some View {
    Button {
      followsLatest = true
      isUserDraggingTimeline = false
      showJumpToLatest = false
      scrollToBottom()
    } label: {
      Image(systemName: "arrow.down")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(theme.secondaryForegroundColor)
        .frame(width: 32, height: 32)
        .glassEffect(.clear, in: Circle())
        .overlay(Circle().stroke(.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .zIndex(10)
    .accessibilityLabel("Scroll to bottom of chat")
  }

  private func chatComposer(for conversation: ChatConversation, isGenerating: Bool) -> some View {
    ChatInputComposer(
      draft: $draft,
      attachments: pendingAttachments,
      isGenerating: isGenerating,
      isImportingAttachments: isImportingAttachments,
      canSend: configurationIssue(conversation) == nil && chats.canSend(conversation.id),
      conversation: conversation,
      providers: providers,
      openChatSettings: { showTargetSettings = true },
      pickPhoto: openPhotoPicker,
      pickFile: openFileImporter,
      pickFromLibrary: openLibraryPicker,
      projectFiles: projects.project(for: conversationID)?.projectFiles ?? [],
      attachProjectFile: { file in
        Task { @MainActor in
          await self.attachProjectFile(file)
        }
      },
      removeAttachment: removePendingAttachment,
      send: send,
      stop: {
        Task { @MainActor in
          await chats.stop(conversationID)
        }
      }
    )
  }

  private func scrollViewContent(_ conversation: ChatConversation) -> some View {
    let canMutateConversation = configurationIssue(conversation) == nil && chats.canSend(conversation.id)
    let approvals = mcp.pendingApprovals(for: conversationID)
    let approvalCallIDs = Set(approvals.map(\.callID))
    let elicitations = mcp.pendingElicitations(for: conversationID)
    let activeTools = chats.activeToolCalls(for: conversationID)

    // Use a plain List (UICollectionView-backed) rather than ScrollView + LazyVStack:
    // UICollectionView recycles self-sizing variable-height Markdown cells reliably,
    // never lands in an unrealized blank viewport on open, and resolves scrollTo(id)
    // across arbitrarily tall chats.
    return ScrollViewReader { proxy in
      List {
        if let issue = configurationIssue(conversation) {
          RepairBanner(message: issue) { showTargetSettings = true }
            .chatTimelineRow()
        }

        if conversation.lastContextOmittedMessageCount > 0 {
          Label(
            "\(conversation.lastContextOmittedMessageCount) earlier messages were omitted from the latest request.",
            systemImage: "text.badge.minus"
          )
          .font(.system(size: 12))
          .foregroundStyle(theme.secondaryForegroundColor)
          .frame(maxWidth: .infinity, alignment: .leading)
          .chatTimelineRow()
        }

        ForEach(conversation.messages) { stored in
          let displayed = chats.displayMessage(stored)
          let isLatest = stored.id == latestAssistantID
          VStack(alignment: .leading, spacing: 10) {
            ChatMessageView(
              message: displayed,
              accountLabel: accountLabel(for: stored),
              failureContext: failureContextLabel(for: stored),
              canEdit: stored.role == .user
                && !chats.isGenerating(conversationID)
                && canMutateConversation,
              isLatestAssistant: isLatest,
              canRegenerate: isLatest
                && !chats.isGenerating(conversationID)
                && canMutateConversation,
              conversationID: conversationID,
              library: library,
              onLibraryError: handleLibraryError,
              loadThumbnail: chats.attachmentThumbnail,
              onOpenAttachment: openAttachment,
              edit: {
                editText = stored.content
                editTarget = stored
              },
              regenerate: regenerate,
              copy: { UIPasteboard.general.string = displayed.content }
            )

            if stored.role == .assistant,
              let rounds = displayed.toolRounds,
              !rounds.isEmpty
            {
              ForEach(rounds) { round in
                ChatToolRoundView(
                  round: round,
                  displayName: { mcp.toolDisplayName($0) }
                )
              }
            }
          }
          .contentShape(Rectangle())
          .onTapGesture {
            dismissKeyboard()
          }
          .id(stored.id)
          .chatTimelineRow()
        }

        ForEach(approvals) { request in
          MCPToolApprovalCard(request: request) { decision in
            Task { @MainActor in
              await mcp.resolveApproval(request.id, decision: decision)
            }
          }
          .chatTimelineRow()
        }

        ForEach(elicitations) { request in
          MCPElicitationCard(request: request) { decision in
            Task { @MainActor in
              await mcp.resolveElicitation(request.id, decision: decision)
            }
          }
          .chatTimelineRow()
        }

        ForEach(activeTools) { call in
          MCPToolRunningCard(
            call: call,
            displayName: mcp.toolDisplayName(call.name),
            isWaitingForApproval: approvalCallIDs.contains(call.id)
          )
          .chatTimelineRow()
        }

        Color.clear
          .frame(height: 1)
          .id(Self.bottomAnchorID)
          .listRowInsets(EdgeInsets())
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .environment(\.defaultMinListRowHeight, 1)
      .contentMargins(.top, 2, for: .scrollContent)
      .contentMargins(.bottom, 6, for: .scrollContent)
      .opacity(hasCompletedInitialScroll ? 1 : 0)
      .defaultScrollAnchor(
        initialScrollMessageID == nil ? UnitPoint.bottom : nil,
        for: .initialOffset
      )
      .scrollDismissesKeyboard(.interactively)
      .onScrollPhaseChange { _, newPhase in
        switch newPhase {
        case .tracking, .interacting, .decelerating:
          if !hasCompletedInitialScroll {
            hasCompletedInitialScroll = true
          }
          isProgrammaticScroll = false
          isAnimatedProgrammaticScroll = false
          isUserDraggingTimeline = true
          if !isNearBottom {
            followsLatest = false
            showJumpToLatest = true
          }
        case .idle:
          let wasUserDriven = isUserDraggingTimeline
          isUserDraggingTimeline = false
          isProgrammaticScroll = false
          isAnimatedProgrammaticScroll = false
          if isNearBottom {
            followsLatest = true
            showJumpToLatest = false
          } else if wasUserDriven || !chats.isGenerating(conversationID) {
            followsLatest = false
            showJumpToLatest = true
          }
        case .animating:
          // Non-programmatic animating transitions include status-bar tap to top
          // and VoiceOver scroll; treat them as user-driven so auto-follow pauses.
          if !isProgrammaticScroll {
            isUserDraggingTimeline = true
            if !isNearBottom {
              followsLatest = false
              showJumpToLatest = true
            }
          } else {
            isUserDraggingTimeline = false
          }
        @unknown default:
          break
        }
      }
      .onScrollGeometryChange(for: ChatTimelineGeometry.self) { geometry in
        let distanceFromBottom = max(0, geometry.contentSize.height - geometry.visibleRect.maxY)
        return ChatTimelineGeometry(
          contentHeight: geometry.contentSize.height,
          containerHeight: geometry.containerSize.height,
          needsBottomPin: distanceFromBottom > 2,
          isNearBottom: distanceFromBottom <= 28
        )
      } action: { oldGeometry, newGeometry in
        latestTimelineGeometry = newGeometry
        isNearBottom = newGeometry.isNearBottom
        if newGeometry.isNearBottom {
          followsLatest = true
          showJumpToLatest = false
        } else if hasCompletedInitialScroll && isUserDraggingTimeline {
          followsLatest = false
          showJumpToLatest = true
        }
        guard hasCompletedInitialScroll,
          followsLatest,
          !isUserDraggingTimeline,
          !isAnimatedProgrammaticScroll,
          newGeometry.needsBottomPin
        else { return }

        if newGeometry.contentHeight > oldGeometry.contentHeight + 0.5,
          chats.isGenerating(conversationID)
        {
          performScrollToBottom(using: proxy, animated: false)
        } else if newGeometry.containerHeight < oldGeometry.containerHeight - 0.5 {
          performScrollToBottom(using: proxy, animated: false)
        }
      }
      .task(id: scrollToBottomRequest) {
        guard scrollToBottomRequest.id > 0 else { return }
        await Task.yield()
        guard !Task.isCancelled else { return }
        performScrollToBottom(using: proxy, animated: scrollToBottomRequest.animated)
      }
      .onChange(of: chats.isGenerating(conversationID)) { _, generating in
        if generating {
          followsLatest = true
          showJumpToLatest = false
        } else if !isNearBottom {
          showJumpToLatest = true
        }
      }
      .task(id: conversationID) {
        hasCompletedInitialScroll = false
        isProgrammaticScroll = false
        isAnimatedProgrammaticScroll = false
        followsLatest = initialScrollMessageID == nil
        showJumpToLatest = false

        isProgrammaticScroll = true
        await Task.yield()
        guard !Task.isCancelled else {
          isProgrammaticScroll = false
          return
        }

        if initialScrollMessageID == nil {
          if !isUserDraggingTimeline {
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
          }
          var previousContentHeight = latestTimelineGeometry?.contentHeight ?? 0
          // Give List + MarkdownUI up to a few brief layout frames to
          // measure tall self-sizing bottom rows, stopping early once pinned.
          for _ in 0..<3 {
            do {
              try await Task.sleep(for: .milliseconds(32))
            } catch {
              isProgrammaticScroll = false
              return
            }
            guard !Task.isCancelled else {
              isProgrammaticScroll = false
              return
            }
            if isUserDraggingTimeline { break }
            let geometry = latestTimelineGeometry
            let shouldContinue = ChatTimelineGeometry.shouldContinueBottomSettle(
              geometry: geometry,
              previousContentHeight: previousContentHeight,
              isNearBottom: isNearBottom
            )
            previousContentHeight = geometry?.contentHeight ?? previousContentHeight
            if shouldContinue {
              proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            } else {
              break
            }
          }
          await Task.yield()
          isProgrammaticScroll = false
          withAnimation(.easeOut(duration: 0.14)) {
            hasCompletedInitialScroll = true
          }
          return
        }

        if !isUserDraggingTimeline {
          scrollToInitialTarget(proxy)
        }

        do {
          try await Task.sleep(for: .milliseconds(32))
        } catch {
          isProgrammaticScroll = false
          return
        }
        guard !Task.isCancelled else {
          isProgrammaticScroll = false
          return
        }
        if !isUserDraggingTimeline {
          scrollToInitialTarget(proxy)
        }
        await Task.yield()
        isProgrammaticScroll = false
        withAnimation(.easeOut(duration: 0.14)) {
          hasCompletedInitialScroll = true
        }
        showJumpToLatest = !isNearBottom
      }
    }
  }

  private func scrollToInitialTarget(_ proxy: ScrollViewProxy) {
    guard let initialScrollMessageID else { return }
    proxy.scrollTo(initialScrollMessageID, anchor: .center)
  }

  private func send() {
    let text = draft
    let attachments = pendingAttachments
    followsLatest = true
    showJumpToLatest = false
    chats.send(
      conversationID: conversationID,
      text: text,
      attachments: attachments,
      onMessagePersisted: { committed in
        guard committed else { return } // Retry keeps text and attachment bytes.
        if draft == text { draft = "" }
        let sentIDs = Set(attachments.map(\.id))
        pendingAttachments.removeAll { sentIDs.contains($0.id) }
      }
    )
    scrollToBottom(animated: !isNearBottom)
  }

  private func regenerate() {
    guard let currentConversation = conversation,
      configurationIssue(currentConversation) == nil,
      chats.canSend(conversationID)
    else { return }
    followsLatest = true
    showJumpToLatest = false
    if chats.latestAssistantRequiresRegenerationConfirmation(conversationID) {
      showRegenerateConfirmation = true
    } else {
      chats.regenerate(conversationID: conversationID)
      scrollToBottom(animated: !isNearBottom)
    }
  }

  private func targetLabel(_ conversation: ChatConversation) -> String {
    let accountName = providers.accounts.first(where: { $0.id == conversation.accountID })?.label
      ?? conversation.providerID.rawValue
    let modelName = providers.models(for: conversation.accountID, includeHidden: true)
      .first(where: { $0.model.id == conversation.modelID })?.model.displayName
      ?? conversation.modelID.rawValue
    return "\(accountName) · \(modelName)"
  }

  private func accountLabel(for message: ChatMessage) -> String? {
    guard let accountID = message.accountID else { return nil }
    return providers.accounts.first { $0.id == accountID }?.label
  }

  /// Remote failures name the connection that rejected the request: provider
  /// and model, with the account label only when one provider has several
  /// accounts and the label is the only way to tell them apart. Local failures
  /// never reached an account, so they get no context line at all.
  private func failureContextLabel(for message: ChatMessage) -> String? {
    guard message.status == .failed, message.failureOrigin == .remote else { return nil }
    guard let accountID = message.accountID,
      let account = providers.accounts.first(where: { $0.id == accountID })
    else { return nil }

    var parts: [String] = []
    if providers.accounts.filter({ $0.providerID == account.providerID }).count > 1 {
      parts.append(account.label)
    }
    parts.append(
      providers.provider(for: account.providerID)?.displayName ?? account.providerID.rawValue
    )

    if let modelID = message.modelID {
      let modelName = providers.models(for: account.id, includeHidden: true)
        .first(where: { $0.model.id == modelID })?.model.displayName
      parts.append(modelName ?? modelID.rawValue)
    }
    return parts.joined(separator: " · ")
  }

  func configurationIssue(_ conversation: ChatConversation) -> String? {
    if let issue = chats.pendingConfigurationIssue(conversation.id) { return issue }
    guard providers.definitions.contains(where: { $0.id == conversation.providerID }) else {
      return "This conversation references a provider that is no longer configured."
    }
    guard let account = providers.accounts.first(where: { $0.id == conversation.accountID }) else {
      return "The provider account used by this conversation was deleted. Select another account to continue."
    }
    guard account.isEnabled else {
      return "The selected provider account is disabled."
    }
    guard
      providers.credentialAccountIDs.contains(account.id)
        || !(providers.provider(for: account.providerID)?.requiresCredential ?? account.definition.requiresCredential)
    else {
      return "The selected account is missing its credential."
    }
    guard
      let model = providers.models(for: account.id, includeHidden: true).first(where: {
        $0.model.id == conversation.modelID
      })
    else {
      return "The selected model is missing. Choose another model to continue."
    }
    guard model.isAvailable else {
      return "The selected model is no longer reported by the provider."
    }
    return nil
  }

  func dismissKeyboard() {
    UIApplication.shared.sendAction(
      #selector(UIResponder.resignFirstResponder),
      to: nil,
      from: nil,
      for: nil
    )
  }

  func scrollToBottom(animated: Bool = true) {
    scrollToBottomRequest = ChatScrollToBottomRequest(
      id: scrollToBottomRequest.id &+ 1,
      animated: animated
    )
  }

  private func performScrollToBottom(using proxy: ScrollViewProxy, animated: Bool) {
    programmaticScrollGeneration &+= 1
    let generation = programmaticScrollGeneration
    isProgrammaticScroll = true
    isAnimatedProgrammaticScroll = animated
    if animated {
      withAnimation(.easeOut(duration: 0.22)) {
        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
      }
    } else {
      proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
    }
    Task { @MainActor in
      try? await Task.sleep(for: animated ? .milliseconds(250) : .milliseconds(60))
      guard programmaticScrollGeneration == generation else { return }
      // If tall variable-height cells expanded during a long animated jump,
      // finish with one silent un-animated snap to the true bottom.
      if animated, !isUserDraggingTimeline, followsLatest,
        latestTimelineGeometry?.needsBottomPin ?? false
      {
        isAnimatedProgrammaticScroll = false
        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        try? await Task.sleep(for: .milliseconds(50))
        guard programmaticScrollGeneration == generation else { return }
      }
      isProgrammaticScroll = false
      isAnimatedProgrammaticScroll = false
    }
  }
}

private struct MCPToolApprovalCard: View {
  let request: MCPToolApprovalRequest
  let resolve: (MCPToolApprovalDecision) -> Void

  @State private var isResolving = false
  @Environment(\.appFoundationTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: request.destructiveHint == true ? "exclamationmark.shield" : "hand.raised")
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(request.destructiveHint == true ? Color.orange : Color.primary)
          .frame(width: 28, height: 28)

        VStack(alignment: .leading, spacing: 3) {
          Text("Allow tool call?")
            .font(.system(size: 15, weight: .semibold))
          Text("\(request.serverName) · \(request.displayName)")
            .font(.system(size: 13, weight: .medium))
          Text(request.toolDescription)
            .font(.system(size: 12))
            .foregroundStyle(theme.secondaryForegroundColor)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      if request.readOnlyHint == true || request.destructiveHint == true {
        HStack(spacing: 7) {
          if request.readOnlyHint == true {
            Label("Read-only", systemImage: "eye")
          }
          if request.destructiveHint == true {
            Label("Destructive", systemImage: "exclamationmark.triangle")
              .foregroundStyle(.orange)
          }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(theme.secondaryForegroundColor)
      }

      DisclosureGroup("Arguments") {
        Text(request.arguments.prettyJSONString())
          .font(.system(size: 11, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 6)
      }
      .font(.system(size: 12, weight: .semibold))

      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) {
          denyButton
          Spacer(minLength: 4)
          allowOnceButton
          alwaysAllowButton
        }
        VStack(spacing: 8) {
          HStack(spacing: 8) {
            denyButton
            allowOnceButton
          }
          .frame(maxWidth: .infinity, alignment: .trailing)
          alwaysAllowButton.frame(maxWidth: .infinity, alignment: .trailing)
        }
      }
      .font(.system(size: 13, weight: .semibold))
      .disabled(isResolving)
    }
    .padding(14)
    .background(theme.surfaceColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(
          request.destructiveHint == true ? Color.orange.opacity(0.35) : theme.borderColor,
          lineWidth: 0.8
        )
    )
  }

  private func submit(_ decision: MCPToolApprovalDecision) {
    guard !isResolving else { return }
    isResolving = true
    resolve(decision)
  }

  private var denyButton: some View {
    Button("Deny", role: .destructive) { submit(.deny) }.buttonStyle(.bordered)
  }

  private var allowOnceButton: some View {
    Button("Allow Once") { submit(.allowOnce) }.buttonStyle(.bordered)
  }

  private var alwaysAllowButton: some View {
    Button("Always Allow") { submit(.alwaysAllow) }.buttonStyle(.borderedProminent)
  }
}

private struct MCPToolRunningCard: View {
  let call: ChatToolCall
  let displayName: String
  let isWaitingForApproval: Bool

  @Environment(\.appFoundationTheme) private var theme

  var body: some View {
    HStack(spacing: 10) {
      ProgressView().controlSize(.small)
      VStack(alignment: .leading, spacing: 2) {
        Text(isWaitingForApproval ? "Waiting for approval" : "Tool requested")
          .font(.system(size: 12, weight: .semibold))
        Text(displayName)
          .font(.system(size: 12))
          .foregroundStyle(theme.secondaryForegroundColor)
      }
      Spacer()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(
      theme.surfaceColor,
      in: RoundedRectangle(cornerRadius: 14, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(theme.borderColor, lineWidth: 0.75)
    )
  }
}

private struct ChatToolRoundView: View {
  let round: ChatToolRound
  let displayName: (String) -> String

  @Environment(\.appFoundationTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(round.calls) { call in
        let result = round.results.first { $0.callID == call.id }
        toolCard(call, result: result)
      }
    }
  }

  private func toolCard(_ call: ChatToolCall, result: ChatToolResult?) -> some View {
    let failed = result?.isError == true || result == nil
    return DisclosureGroup {
      VStack(alignment: .leading, spacing: 10) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Arguments").font(.caption.weight(.semibold))
          ScrollView([.vertical, .horizontal]) {
            Text(call.arguments.prettyJSONString())
              .font(.system(size: 11, design: .monospaced))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: 220)
        }
        if let result {
          VStack(alignment: .leading, spacing: 4) {
            Text(result.isError ? "Error" : "Result").font(.caption.weight(.semibold))
            ScrollView([.vertical, .horizontal]) {
              Text(result.content.prettyJSONString())
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
          }
        } else {
          Text("No result returned.")
            .font(.caption)
            .foregroundStyle(theme.secondaryForegroundColor)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 6)
    } label: {
      HStack(spacing: 8) {
        Image(systemName: failed ? "xmark.circle.fill" : "checkmark.circle.fill")
          .foregroundStyle(failed ? Color.orange : theme.secondaryForegroundColor)
        Text(displayName(call.name))
          .font(.system(size: 12, weight: .semibold))
          .lineLimit(2)
        Spacer()
        Text(failed ? "Failed" : "Done")
          .font(.system(size: 11))
          .foregroundStyle(theme.secondaryForegroundColor)
      }
    }
    .tint(theme.secondaryForegroundColor)
    .padding(.horizontal, 11)
    .padding(.vertical, 9)
    .background(
      theme.surfaceColor,
      in: RoundedRectangle(cornerRadius: 14, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(theme.borderColor, lineWidth: 0.75)
    )
  }
}

nonisolated enum MCPElicitationFormSupport {
  static func initialValues(
    for fields: [MCPElicitationField]
  ) -> (text: [String: String], bools: [String: Bool]) {
    var text: [String: String] = [:]
    var bools: [String: Bool] = [:]
    for field in fields {
      if field.kind == .string, !field.allowedValues.isEmpty {
        if case .string(let value)? = field.defaultValue, field.allowedValues.contains(value) {
          text[field.name] = value
        } else if field.isRequired {
          text[field.name] = field.allowedValues.first
        } else {
          text[field.name] = ""
        }
        continue
      }
      switch (field.kind, field.defaultValue) {
      case (.boolean, .bool(let value)):
        bools[field.name] = value
      case (.string, .string(let value)):
        text[field.name] = value
      case (.integer, .number(let value)):
        if let exact = Int(exactly: value) {
          text[field.name] = String(exact)
        } else if value.isFinite {
          text[field.name] = String(value)
        }
      case (.number, .number(let value)):
        if let exact = Int(exactly: value) {
          text[field.name] = String(exact)
        } else if value.isFinite {
          text[field.name] = String(value)
        }
      case (.stringArray, .array(let values)):
        text[field.name] = values.compactMap {
          if case .string(let value) = $0 { return value }
          return nil
        }.joined(separator: ", ")
      default:
        if field.kind == .boolean { bools[field.name] = false }
      }
    }
    return (text, bools)
  }

  static func canSubmit(
    mode: MCPElicitationMode,
    url: URL?,
    fields: [MCPElicitationField],
    textValues: [String: String]
  ) -> Bool {
    guard mode == .form else { return url != nil }
    for field in fields {
      let storedValue = textValues[field.name] ?? ""
      if field.kind == .string, !field.allowedValues.isEmpty {
        if storedValue.isEmpty {
          if field.isRequired { return false }
          continue
        }
        guard field.allowedValues.contains(storedValue) else { return false }
        continue
      }
      let raw = storedValue.trimmingCharacters(in: .whitespacesAndNewlines)
      switch field.kind {
      case .boolean:
        continue
      case .string:
        if field.isRequired, raw.isEmpty { return false }
      case .integer:
        if raw.isEmpty {
          if field.isRequired { return false }
          continue
        }
        guard Int(raw) != nil else { return false }
      case .number:
        if raw.isEmpty {
          if field.isRequired { return false }
          continue
        }
        guard let value = Double(raw), value.isFinite else { return false }
      case .stringArray:
        let items = parseStringArray(raw)
        if items.isEmpty {
          if field.isRequired { return false }
          continue
        }
        if !field.allowedValues.isEmpty,
          !items.allSatisfy(field.allowedValues.contains)
        {
          return false
        }
      }
    }
    return true
  }

  static func responseContent(
    fields: [MCPElicitationField],
    textValues: [String: String],
    boolValues: [String: Bool]
  ) -> [String: JSONValue] {
    var values: [String: JSONValue] = [:]
    for field in fields {
      switch field.kind {
      case .boolean:
        values[field.name] = .bool(boolValues[field.name] ?? false)
      case .integer:
        let raw = (textValues[field.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = Int(raw) { values[field.name] = .number(Double(value)) }
      case .number:
        let raw = (textValues[field.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = Double(raw), value.isFinite { values[field.name] = .number(value) }
      case .string:
        let value = textValues[field.name] ?? ""
        if !field.allowedValues.isEmpty {
          if !value.isEmpty { values[field.name] = .string(value) }
        } else if !value.isEmpty || field.isRequired {
          values[field.name] = .string(value)
        }
      case .stringArray:
        let items = parseStringArray(textValues[field.name] ?? "")
        if !items.isEmpty || field.isRequired {
          values[field.name] = .array(items.map(JSONValue.string))
        }
      }
    }
    return values
  }

  static func parseStringArray(_ raw: String) -> [String] {
    raw
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }
}

private struct MCPElicitationCard: View {
  let request: MCPElicitationRequest
  let resolve: (MCPElicitationDecision) -> Void

  @State private var textValues: [String: String]
  @State private var boolValues: [String: Bool]
  @State private var isResolving = false

  @Environment(\.appFoundationTheme) private var theme

  init(request: MCPElicitationRequest, resolve: @escaping (MCPElicitationDecision) -> Void) {
    self.request = request
    self.resolve = resolve
    let initial = MCPElicitationFormSupport.initialValues(for: request.fields)
    _textValues = State(initialValue: initial.text)
    _boolValues = State(initialValue: initial.bools)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("\(request.serverName) needs input", systemImage: "text.bubble")
        .font(.system(size: 14, weight: .semibold))
      Text(request.message)
        .font(.system(size: 13))
        .fixedSize(horizontal: false, vertical: true)

      switch request.mode {
      case .form:
        formFields
      case .url:
        if let url = request.url {
          VStack(alignment: .leading, spacing: 8) {
            Text("Complete the requested step in your browser, then return here.")
              .font(.caption)
              .foregroundStyle(theme.secondaryForegroundColor)
            Text(url.host ?? url.absoluteString)
              .font(.subheadline.weight(.semibold))
            Text(url.absoluteString)
              .font(.caption)
              .foregroundStyle(theme.secondaryForegroundColor)
              .lineLimit(3)
              .truncationMode(.middle)
              .textSelection(.enabled)
            Link(destination: url) {
              Label("Open \(url.host ?? url.absoluteString)", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.borderedProminent)
          }
        }
      }

      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) {
          cancelButton
          declineButton
          Spacer()
          submitButton
        }
        VStack(alignment: .trailing, spacing: 8) {
          HStack(spacing: 8) {
            cancelButton
            declineButton
          }
          submitButton
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
      }
      .font(.system(size: 13, weight: .semibold))
      .disabled(isResolving)
    }
    .padding(14)
    .background(theme.surfaceColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(theme.borderColor, lineWidth: 0.8)
    )
  }

  private func submitDecision(_ decision: MCPElicitationDecision) {
    guard !isResolving else { return }
    isResolving = true
    resolve(decision)
  }

  private var cancelButton: some View {
    Button("Cancel") { submitDecision(.cancel) }.buttonStyle(.bordered)
  }

  private var declineButton: some View {
    Button("Decline", role: .destructive) { submitDecision(.decline) }.buttonStyle(.bordered)
  }

  private var submitButton: some View {
    Button(request.mode == .url ? "Continue" : "Submit") {
      submitDecision(.accept(responseContent()))
    }
    .buttonStyle(.borderedProminent)
    .disabled(!canSubmit || isResolving)
  }

  @ViewBuilder
  private var formFields: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(request.fields) { field in
        switch field.kind {
        case .boolean:
          Toggle(
            field.displayName,
            isOn: Binding(
              get: { boolValues[field.name] ?? false },
              set: { boolValues[field.name] = $0 }
            )
          )
        case .string where !field.allowedValues.isEmpty:
          Picker(
            field.displayName,
            selection: Binding(
              get: { textValues[field.name] ?? "" },
              set: { textValues[field.name] = $0 }
            )
          ) {
            if !field.isRequired {
              Text("None").tag("")
            }
            ForEach(field.allowedValues, id: \.self) { value in Text(value).tag(value) }
          }
        default:
          TextField(
            field.isRequired ? field.displayName : "\(field.displayName) (optional)",
            text: Binding(
              get: { textValues[field.name] ?? "" },
              set: { textValues[field.name] = $0 }
            )
          )
          .textFieldStyle(.roundedBorder)
          .keyboardType(
            field.kind == .integer || field.kind == .number
              ? .numbersAndPunctuation
              : .default
          )
          if field.kind == .stringArray, !field.allowedValues.isEmpty {
            Text("Allowed: \(field.allowedValues.joined(separator: ", "))")
              .font(.caption2)
              .foregroundStyle(theme.secondaryForegroundColor)
          }
        }
        if let description = field.description, !description.isEmpty {
          Text(description).font(.caption2).foregroundStyle(theme.secondaryForegroundColor)
        }
      }
    }
    .disabled(isResolving)
  }

  private var canSubmit: Bool {
    MCPElicitationFormSupport.canSubmit(
      mode: request.mode,
      url: request.url,
      fields: request.fields,
      textValues: textValues
    )
  }

  private func responseContent() -> [String: JSONValue] {
    MCPElicitationFormSupport.responseContent(
      fields: request.fields,
      textValues: textValues,
      boolValues: boolValues
    )
  }
}

private extension JSONValue {
  func prettyJSONString() -> String {
    if case .string(let value) = self { return value }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let encoded = try? encoder.encode(self),
      let object = try? JSONSerialization.jsonObject(with: encoded),
      JSONSerialization.isValidJSONObject(object),
      let pretty = try? JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      ),
      let value = String(data: pretty, encoding: .utf8)
    else {
      return String(describing: self)
    }
    return value
  }
}

// MARK: - Empty-state surface (ported from the retired NewChatView)

extension ChatView {
  /// Provider/model resolution for connection setup: project pinning, then
  /// the provider model's resolved default (the single rule —
  /// stored-if-usable → ready → enabled → first, never rewritten).
  var defaultAccount: ProviderAccount? {
    let enabled = providers.accounts.filter(\.isEnabled)

    if let accountID = project?.accountID {
      return enabled.first { $0.id == accountID }
    }
    if let resolved = providers.resolvedDefaultAccount, resolved.isEnabled {
      return resolved
    }
    return enabled.first
  }

  var defaultProvider: ProviderDefinition? {
    guard let account = defaultAccount else { return nil }
    return providers.provider(for: account.providerID)
  }

  var defaultModelID: ModelID? {
    guard let account = defaultAccount else { return nil }
    let models = providers.models(for: account.id).filter(\.isAvailable)

    if let projectModelID = project?.modelID {
      return models.contains(where: { $0.model.id == projectModelID }) ? projectModelID : nil
    }
    if let accountModelID = account.defaultModelID,
      models.contains(where: { $0.model.id == accountModelID })
    {
      return accountModelID
    }
    return models.first?.model.id
  }

  var readiness: ChatReadiness {
    guard defaultAccount != nil else { return .noConnection }
    if let account = defaultAccount,
      providerRequiresCredential(account.providerID),
      !providers.credentialAccountIDs.contains(account.id)
    {
      return .missingCredential
    }
    guard defaultModelID != nil else { return .noModel }
    return .ready
  }

  @ViewBuilder
  var emptyStateContent: some View {
    switch readiness {
    case .ready:
      ProgressView()
        .accessibilityLabel("Opening chat")
    case .noConnection, .missingCredential, .noModel:
      setupContent
    }
  }

  /// One hero for every untouched chat — project or not. Project identity
  /// lives in the nav pill only.
  @ViewBuilder
  func existingEmptyState(_ conversation: ChatConversation) -> some View {
    if let issue = configurationIssue(conversation) {
      existingIssueCard(issue)
    } else {
      readyChatContent(subline: "Using \(targetLabel(conversation))")
    }
  }

  private func readyChatContent(subline: String?) -> some View {
    VStack(spacing: 18) {
      Image(systemName: "bubble.left.and.bubble.right")
        .font(.system(size: 30, weight: .medium))
        .foregroundStyle(theme.accentColor)
        .accessibilityHidden(true)
      Text("How can I help?")
        .font(.system(size: 30, weight: .semibold))
        .multilineTextAlignment(.center)
      if let subline {
        Text(subline)
          .font(.system(size: 14))
          .foregroundStyle(theme.secondaryForegroundColor)
          .multilineTextAlignment(.center)
      }
    }
    .frame(maxWidth: .infinity)
  }

  /// Configuration-problem variant of the hero for existing conversations —
  /// the old RepairBanner's content in the setup-card visual language.
  private func existingIssueCard(_ issue: String) -> some View {
    VStack(spacing: 16) {
      Image(systemName: "wrench.and.screwdriver")
        .font(.system(size: 32, weight: .medium))
        .foregroundStyle(theme.accentColor)
        .accessibilityHidden(true)
      Text("Finish setting up this chat")
        .font(.system(size: 28, weight: .semibold))
        .multilineTextAlignment(.center)
      Text(issue)
        .font(.system(size: 15))
        .multilineTextAlignment(.center)
        .foregroundStyle(theme.secondaryForegroundColor)
        .frame(maxWidth: 440)

      Button {
        showTargetSettings = true
      } label: {
        Label("Repair Chat Configuration", systemImage: "wrench.and.screwdriver")
          .font(.system(size: 16, weight: .semibold))
          .frame(maxWidth: 320)
          .padding(.vertical, 12)
      }
      .buttonStyle(.borderedProminent)
      .tint(theme.accentColor)
    }
    .frame(maxWidth: .infinity)
  }

  private var setupContent: some View {
    VStack(spacing: 16) {
      Image(systemName: setupIcon)
        .font(.system(size: 32, weight: .medium))
        .foregroundStyle(theme.accentColor)
        .accessibilityHidden(true)
      Text(setupTitle)
        .font(.system(size: 28, weight: .semibold))
        .multilineTextAlignment(.center)
      Text(setupDescription)
        .font(.system(size: 15))
        .multilineTextAlignment(.center)
        .foregroundStyle(theme.secondaryForegroundColor)
        .frame(maxWidth: 440)

      Button { primarySetupAction() } label: {
        Label(primarySetupTitle, systemImage: primarySetupIcon)
          .font(.system(size: 16, weight: .semibold))
          .frame(maxWidth: 320)
          .padding(.vertical, 12)
      }
      .buttonStyle(.borderedProminent)
      .tint(theme.accentColor)

      Text(
        needsProjectDefaultRepair
          ? "Edit this project's defaults to pick another provider account or model, or switch back to App Default."
          : "Connections keep your provider, API key, and default model together in one place."
      )
        .font(.caption)
        .multilineTextAlignment(.center)
        .foregroundStyle(theme.secondaryForegroundColor.opacity(0.72))
        .frame(maxWidth: 420)
    }
    .frame(maxWidth: .infinity)
  }

  private var needsProjectDefaultRepair: Bool {
    (project?.accountID != nil && defaultAccount == nil)
      || (project?.modelID != nil && defaultModelID == nil)
  }

  private var setupIcon: String {
    if needsProjectDefaultRepair {
      return "folder.badge.questionmark"
    }
    switch readiness {
    case .noConnection: return "link"
    case .missingCredential: return "key.slash"
    case .noModel: return "rectangle.stack.badge.plus"
    case .ready: return "bubble.left.and.bubble.right"
    }
  }

  private var setupTitle: String {
    switch readiness {
    case .noConnection:
      if project?.accountID != nil && defaultAccount == nil {
        return "Project connection unavailable"
      }
      return project == nil ? "Connect your AI" : "Set up a connection"
    case .missingCredential:
      return "Finish setting up \(defaultProvider?.displayName ?? defaultAccount?.label ?? "connection")"
    case .noModel:
      if project?.modelID != nil && defaultModelID == nil {
        return "Project model unavailable"
      }
      return "Choose a model"
    case .ready:
      return "How can I help?"
    }
  }

  private var setupDescription: String {
    switch readiness {
    case .noConnection:
      if let project {
        if project.accountID != nil && defaultAccount == nil {
          return "The provider account selected for \(project.name) is unavailable or disabled. Choose another account in project defaults."
        }
        return "Add a connection before starting a chat in \(project.name)."
      }
      return "Connect an AI provider with your own API key to start chatting."
    case .missingCredential:
      return "\(defaultAccount?.label ?? "This connection") needs an API key before it can be used."
    case .noModel:
      if let project, project.modelID != nil {
        return "The model selected for \(project.name) is no longer available. Choose another project model."
      }
      return "Choose a default model for \(defaultAccount?.label ?? "this connection") before starting a chat."
    case .ready:
      return ""
    }
  }

  private var primarySetupTitle: String {
    if needsProjectDefaultRepair {
      return "Edit Project Defaults"
    }
    switch readiness {
    case .noConnection: return "Set Up Connection"
    case .missingCredential, .noModel: return "Open Connections"
    case .ready: return "Start Chatting"
    }
  }

  private var primarySetupIcon: String {
    if needsProjectDefaultRepair {
      return "folder.badge.gearshape"
    }
    switch readiness {
    case .noConnection: return "plus.circle.fill"
    case .missingCredential: return "key.fill"
    case .noModel: return "rectangle.stack.fill"
    case .ready: return "arrow.up.circle.fill"
    }
  }

  private func primarySetupAction() {
    switch readiness {
    case .noConnection, .missingCredential, .noModel:
      if needsProjectDefaultRepair {
        showProjectEditorSheet = true
      } else {
        showConnections = true
      }
    case .ready:
      break
    }
  }

  func providerRequiresCredential(_ providerID: ProviderID) -> Bool {
    guard let provider = providers.provider(for: providerID) else { return true }
    return provider.requiresCredential
  }
}

