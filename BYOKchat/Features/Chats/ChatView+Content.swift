import BYOKchatProviderCore
import SwiftUI
import UIKit

private struct ChatAutoScrollTrigger: Equatable {
  var conversationID: ConversationID
  var messageCount: Int
  var streamRevision: Int
  var isGenerating: Bool
}

extension ChatView {
  @ViewBuilder
  func chatContent(_ conversation: ChatConversation) -> some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 24) {
          if let issue = configurationIssue(conversation) {
            RepairBanner(message: issue) { showTargetSettings = true }
          }

          if conversation.lastContextOmittedMessageCount > 0 {
            Label(
              "\(conversation.lastContextOmittedMessageCount) earlier messages were omitted from the latest request.",
              systemImage: "text.badge.minus"
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
          }

          if conversation.messages.isEmpty {
            VStack(spacing: 12) {
              Text("How can I help?")
                .font(.system(size: 30, weight: .semibold))
              Text("Using \(targetLabel(conversation))")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 112)
          } else {
            ForEach(conversation.messages) { stored in
              let displayed = chats.displayMessage(stored)
              ChatMessageView(
                message: displayed,
                accountLabel: accountLabel(for: stored),
                canEdit: stored.role == .user && !chats.isGenerating(conversationID),
                canRegenerate: stored.id == latestAssistantID
                  && !chats.isGenerating(conversationID),
                edit: {
                  editText = stored.content
                  editTarget = stored
                },
                regenerate: regenerate,
                copy: { UIPasteboard.general.string = displayed.content }
              )
              .id(stored.id)
            }
          }

          Color.clear
            .frame(height: 1)
            .id("chat-bottom")
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 18)
      }
      .contentShape(Rectangle())
      .simultaneousGesture(
        TapGesture().onEnded {
          dismissKeyboard()
        }
      )
      .scrollDismissesKeyboard(.interactively)
      .simultaneousGesture(
        DragGesture(minimumDistance: 4)
          .onChanged { _ in
            isUserDraggingTimeline = true
          }
          .onEnded { _ in
            isUserDraggingTimeline = false
            if isNearBottom {
              followsLatest = true
              showJumpToLatest = false
            } else {
              followsLatest = false
              showJumpToLatest = true
            }
          }
      )
      .onScrollGeometryChange(for: Bool.self) { geometry in
        geometry.contentSize.height <= geometry.containerSize.height
          || geometry.contentOffset.y + geometry.containerSize.height
            >= geometry.contentSize.height - 120
      } action: { _, nearBottom in
        isNearBottom = nearBottom
        if nearBottom {
          followsLatest = true
          showJumpToLatest = false
        } else if isUserDraggingTimeline {
          followsLatest = false
          showJumpToLatest = true
        }
      }
      .onChange(of: chats.isGenerating(conversationID)) { _, generating in
        if generating {
          followsLatest = true
          showJumpToLatest = false
        } else if !isNearBottom {
          showJumpToLatest = true
        }
      }
      .task(
        id: ChatAutoScrollTrigger(
          conversationID: conversationID,
          messageCount: conversation.messages.count,
          streamRevision: chats.streamRevision(for: conversationID),
          isGenerating: chats.isGenerating(conversationID)
        )
      ) {
        guard hasCompletedInitialScroll else { return }
        guard followsLatest, !isUserDraggingTimeline else {
          if !isNearBottom { showJumpToLatest = true }
          return
        }

        // Streaming text changes the rendered Markdown height asynchronously. Coalesce rapid
        // revisions and wait for the next layout pass before moving the viewport. This prevents
        // competing ScrollViewReader commands from targeting stale LazyVStack geometry.
        do {
          try await Task.sleep(for: .milliseconds(12))
        } catch {
          return
        }
        await Task.yield()
        guard !Task.isCancelled, followsLatest, !isUserDraggingTimeline else { return }
        scrollToBottom(proxy, animated: false)
      }
      .task(id: conversationID) {
        hasCompletedInitialScroll = false
        followsLatest = initialScrollMessageID == nil
        showJumpToLatest = initialScrollMessageID != nil

        // Let the lazy timeline materialize a visible child before resolving an
        // offscreen target. Repeat after the safe-area composer gets its final size.
        await Task.yield()
        scrollToInitialTarget(proxy)

        do {
          try await Task.sleep(for: .milliseconds(32))
        } catch {
          return
        }
        guard !Task.isCancelled else { return }
        scrollToInitialTarget(proxy)
        hasCompletedInitialScroll = true
      }
      .overlay(alignment: .bottomTrailing) {
        if showJumpToLatest {
          Button("Jump to Latest", systemImage: "arrow.down") {
            followsLatest = true
            scrollToBottom(proxy)
            showJumpToLatest = false
          }
          .labelStyle(.iconOnly)
          .font(.system(size: 16, weight: .semibold))
          .frame(width: 44, height: 44)
          .background(.ultraThinMaterial, in: Circle())
          .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1))
          .shadow(color: .black.opacity(0.1), radius: 12, y: 5)
          .padding(.trailing, 18)
          .padding(.bottom, 104)
          .accessibilityLabel("Jump to latest message")
        }
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        ChatComposer(
          draft: $draft,
          attachments: pendingAttachments,
          isGenerating: chats.isGenerating(conversationID),
          canSend: configurationIssue(conversation) == nil,
          targetLabel: targetLabel(conversation),
          openTarget: { showTargetSettings = true },
          pickPhoto: { showPhotoPicker = true },
          pickFile: { showFileImporter = true },
          removeAttachment: removePendingAttachment,
          send: send,
          stop: {
            Task { @MainActor in
              await chats.stop(conversationID)
            }
          }
        )
      }
    }
  }

  private func scrollToInitialTarget(_ proxy: ScrollViewProxy) {
    if let initialScrollMessageID {
      proxy.scrollTo(initialScrollMessageID, anchor: .center)
    } else {
      proxy.scrollTo("chat-bottom", anchor: .bottom)
    }
  }

  private func send() {
    let text = draft
    let attachments = pendingAttachments

    if let issue = attachmentCompatibilityIssue(includingPending: true) {
      chats.errorMessage = issue
      return
    }

    draft = ""
    pendingAttachments = []
    followsLatest = true
    showJumpToLatest = false
    chats.send(
      conversationID: conversationID,
      text: text,
      attachments: attachments
    )
  }

  private func regenerate() {
    if let issue = attachmentCompatibilityIssue(includingPending: false) {
      chats.errorMessage = issue
      return
    }

    followsLatest = true
    showJumpToLatest = false
    if chats.latestAssistantRequiresRegenerationConfirmation(conversationID) {
      showRegenerateConfirmation = true
    } else {
      chats.regenerate(conversationID: conversationID)
    }
  }

  private func attachmentCompatibilityIssue(includingPending: Bool) -> String? {
    guard let conversation else { return nil }
    var attachments = conversation.messages.flatMap { $0.attachments ?? [] }
    if includingPending {
      attachments.append(contentsOf: pendingAttachments)
    }
    return providers.attachmentCompatibilityIssue(
      accountID: conversation.accountID,
      modelID: conversation.modelID,
      attachments: attachments
    )
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

  private func configurationIssue(_ conversation: ChatConversation) -> String? {
    guard providers.definitions.contains(where: { $0.id == conversation.providerID }) else {
      return "This conversation references a provider that is no longer configured."
    }
    guard let account = providers.accounts.first(where: { $0.id == conversation.accountID }) else {
      return
        "The provider account used by this conversation was deleted. Select another account to continue."
    }
    guard account.isEnabled else {
      return "The selected provider account is disabled."
    }
    guard
      providers.credentialAccountIDs.contains(account.id)
        || providers.provider(for: account.providerID)?.authentication
          == ProviderAuthentication.none
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

  private func dismissKeyboard() {
    UIApplication.shared.sendAction(
      #selector(UIResponder.resignFirstResponder),
      to: nil,
      from: nil,
      for: nil
    )
  }

  private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
    if animated {
      withAnimation(.easeOut(duration: 0.18)) {
        proxy.scrollTo("chat-bottom", anchor: .bottom)
      }
    } else {
      proxy.scrollTo("chat-bottom", anchor: .bottom)
    }
  }
}
