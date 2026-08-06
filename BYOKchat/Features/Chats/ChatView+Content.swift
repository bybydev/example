import BYOKchatProviderCore
import SwiftUI
import UIKit

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
      .scrollDismissesKeyboard(.interactively)
      .defaultScrollAnchor(.bottom)
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
      .onChange(of: conversation.messages.count) { _, _ in
        if followsLatest {
          scrollToBottom(proxy)
        } else {
          showJumpToLatest = true
        }
      }
      .onChange(of: chats.streamRevision) { _, _ in
        if followsLatest {
          scrollToBottom(proxy, animated: false)
        } else {
          showJumpToLatest = true
        }
      }
      .onChange(of: chats.isGenerating(conversationID)) { _, generating in
        if generating {
          followsLatest = true
          showJumpToLatest = false
          scrollToBottom(proxy)
        } else if followsLatest {
          scrollToBottom(proxy, animated: false)
        }
      }
      .task {
        try? await Task.sleep(for: .milliseconds(80))
        if let initialScrollMessageID {
          followsLatest = false
          showJumpToLatest = true
          proxy.scrollTo(initialScrollMessageID, anchor: .center)
        } else {
          followsLatest = true
          proxy.scrollTo("chat-bottom", anchor: .bottom)
        }
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
          isGenerating: chats.isGenerating(conversationID),
          canSend: configurationIssue(conversation) == nil,
          targetLabel: targetLabel(conversation),
          openTarget: { showTargetSettings = true },
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

  private func send() {
    let text = draft
    draft = ""
    followsLatest = true
    showJumpToLatest = false
    chats.send(conversationID: conversationID, text: text)
  }

  private func regenerate() {
    followsLatest = true
    showJumpToLatest = false
    if chats.latestAssistantRequiresRegenerationConfirmation(conversationID) {
      showRegenerateConfirmation = true
    } else {
      chats.regenerate(conversationID: conversationID)
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
