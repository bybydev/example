import BYOKchatProviderCore
import SwiftUI

struct ChatView: View {
  let conversationID: ConversationID
  @Bindable var chats: ChatManagementModel
  @Bindable var providers: ProviderManagementModel

  @Environment(\.dismiss) private var dismiss
  @State private var draft = ""
  @State private var showTargetSettings = false
  @State private var renameText = ""
  @State private var showRename = false

  private var conversation: ChatConversation? {
    chats.conversation(conversationID)
  }

  var body: some View {
    Group {
      if let conversation {
        chatContent(conversation)
      } else {
        ContentUnavailableView("Conversation Missing", systemImage: "exclamationmark.bubble")
      }
    }
    .navigationTitle(conversation?.title ?? "Chat")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItemGroup(placement: .topBarTrailing) {
        Button("Chat Settings", systemImage: "slider.horizontal.3") {
          showTargetSettings = true
        }
        Menu {
          Button("Rename", systemImage: "pencil") {
            renameText = conversation?.title ?? ""
            showRename = true
          }
          Button("Delete", systemImage: "trash", role: .destructive) {
            Task {
              await chats.deleteConversation(conversationID)
              dismiss()
            }
          }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
      }
    }
    .sheet(isPresented: $showTargetSettings) {
      if let conversation {
        ConversationTargetView(
          conversation: conversation,
          chats: chats,
          providers: providers
        )
      }
    }
    .alert("Rename Chat", isPresented: $showRename) {
      TextField("Title", text: $renameText)
      Button("Cancel", role: .cancel) {}
      Button("Save") {
        Task { await chats.renameConversation(conversationID, title: renameText) }
      }
    }
  }

  @ViewBuilder
  private func chatContent(_ conversation: ChatConversation) -> some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 14) {
          if conversation.lastContextOmittedMessageCount > 0 {
            Label(
              "\(conversation.lastContextOmittedMessageCount) earlier messages were omitted from the latest request.",
              systemImage: "text.badge.minus"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
          }

          if conversation.messages.isEmpty {
            ContentUnavailableView {
              Label("Ready", systemImage: "sparkles")
            } description: {
              Text("Using \(targetLabel(conversation))")
            }
            .padding(.top, 80)
          } else {
            ForEach(conversation.messages) { stored in
              ChatMessageView(message: chats.displayMessage(stored))
                .id(stored.id)
            }
          }

          Color.clear
            .frame(height: 1)
            .id("chat-bottom")
        }
        .padding(.horizontal)
        .padding(.top, 12)
      }
      .defaultScrollAnchor(.bottom)
      .onChange(of: conversation.messages.count) { _, _ in
        scrollToBottom(proxy)
      }
      .onChange(of: chats.streamRevision) { _, _ in
        scrollToBottom(proxy)
      }
      .safeAreaInset(edge: .bottom) {
        ChatComposer(
          draft: $draft,
          isGenerating: chats.isGenerating(conversationID),
          targetLabel: targetLabel(conversation),
          send: send,
          stop: { chats.stop(conversationID) }
        )
      }
    }
  }

  private func send() {
    let text = draft
    draft = ""
    chats.send(conversationID: conversationID, text: text)
  }

  private func targetLabel(_ conversation: ChatConversation) -> String {
    let account = providers.accounts.first { $0.id == conversation.accountID }
    return "\(account?.label ?? conversation.providerID.rawValue) · \(conversation.modelID.rawValue)"
  }

  private func scrollToBottom(_ proxy: ScrollViewProxy) {
    withAnimation(.easeOut(duration: 0.18)) {
      proxy.scrollTo("chat-bottom", anchor: .bottom)
    }
  }
}

private struct ChatComposer: View {
  @Binding var draft: String
  let isGenerating: Bool
  let targetLabel: String
  let send: () -> Void
  let stop: () -> Void

  var body: some View {
    VStack(spacing: 8) {
      HStack {
        Text(targetLabel)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer()
      }

      HStack(alignment: .bottom, spacing: 10) {
        TextField("Message", text: $draft, axis: .vertical)
          .lineLimit(1...8)
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          .background(.quaternary, in: RoundedRectangle(cornerRadius: 20))
          .disabled(isGenerating)

        Button {
          isGenerating ? stop() : send()
        } label: {
          Image(systemName: isGenerating ? "stop.fill" : "arrow.up")
            .font(.headline)
            .frame(width: 42, height: 42)
            .background(.tint, in: Circle())
            .foregroundStyle(.white)
        }
        .disabled(!isGenerating && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityLabel(isGenerating ? "Stop generation" : "Send message")
      }
    }
    .padding(.horizontal)
    .padding(.top, 8)
    .padding(.bottom, 6)
    .background(.bar)
  }
}

private struct ChatMessageView: View {
  let message: ChatMessage

  var body: some View {
    HStack {
      if message.role == .user { Spacer(minLength: 44) }

      VStack(alignment: .leading, spacing: 8) {
        if !message.reasoning.isEmpty {
          DisclosureGroup("Reasoning") {
            Text(message.reasoning)
              .font(.callout)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .font(.caption.weight(.semibold))
        }

        if !message.content.isEmpty {
          Text(.init(message.content))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if message.status == .pending || message.status == .streaming {
          HStack(spacing: 8) {
            ProgressView()
            Text("Thinking…")
              .foregroundStyle(.secondary)
          }
        }

        footer
      }
      .padding(12)
      .background(
        message.role == .user ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(.quaternary),
        in: RoundedRectangle(cornerRadius: 18)
      )

      if message.role == .assistant { Spacer(minLength: 20) }
    }
  }

  @ViewBuilder
  private var footer: some View {
    switch message.status {
    case .failed:
      Label(message.errorDescription ?? "Generation failed", systemImage: "exclamationmark.triangle")
        .font(.caption)
        .foregroundStyle(.red)
    case .cancelled:
      Label("Stopped", systemImage: "stop.circle")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .interrupted:
      Label("Interrupted", systemImage: "bolt.slash")
        .font(.caption)
        .foregroundStyle(.orange)
    case .complete:
      if let usage = message.usage {
        Text("\(usage.inputTokens ?? 0) in · \(usage.outputTokens ?? 0) out")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    case .pending, .streaming:
      EmptyView()
    }
  }
}
