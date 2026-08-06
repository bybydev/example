import BYOKchatProviderCore
import SwiftUI

struct ChatListView: View {
  @Bindable var chats: ChatManagementModel
  @Bindable var providers: ProviderManagementModel
  let openProviders: () -> Void

  @State private var path: [ConversationID] = []
  @State private var renameTarget: ChatConversation?
  @State private var renameText = ""

  var body: some View {
    NavigationStack(path: $path) {
      Group {
        if chats.conversations.isEmpty {
          ContentUnavailableView {
            Label("No Chats", systemImage: "bubble.left.and.bubble.right")
          } description: {
            Text(
              providers.accounts.isEmpty
                ? "Add a provider account, then start your first conversation."
                : "Start a conversation with your own provider account."
            )
          } actions: {
            if providers.accounts.isEmpty {
              Button("Configure Provider", action: openProviders)
            } else {
              Button("New Chat") { createChat() }
                .buttonStyle(.borderedProminent)
            }
          }
        } else {
          List {
            ForEach(chats.conversations) { conversation in
              NavigationLink(value: conversation.id) {
                ConversationRow(
                  conversation: conversation,
                  account: providers.accounts.first { $0.id == conversation.accountID }
                )
              }
              .contextMenu {
                Button("Rename", systemImage: "pencil") {
                  renameTarget = conversation
                  renameText = conversation.title
                }
                Button("Delete", systemImage: "trash", role: .destructive) {
                  Task { await chats.deleteConversation(conversation.id) }
                }
              }
            }
            .onDelete { offsets in
              let ids = offsets.map { chats.conversations[$0].id }
              for id in ids {
                Task { await chats.deleteConversation(id) }
              }
            }
          }
          .listStyle(.plain)
        }
      }
      .navigationTitle("BYOKchat")
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("New Chat", systemImage: "square.and.pencil") { createChat() }
            .disabled(providers.accounts.isEmpty)
        }
      }
      .navigationDestination(for: ConversationID.self) { id in
        ChatView(
          conversationID: id,
          chats: chats,
          providers: providers
        )
      }
    }
    .alert(
      "Rename Chat",
      isPresented: Binding(
        get: { renameTarget != nil },
        set: { if !$0 { renameTarget = nil } }
      )
    ) {
      TextField("Title", text: $renameText)
      Button("Cancel", role: .cancel) { renameTarget = nil }
      Button("Save") {
        guard let id = renameTarget?.id else { return }
        Task { await chats.renameConversation(id, title: renameText) }
        renameTarget = nil
      }
    }
  }

  private func createChat() {
    Task {
      if let id = await chats.createConversation() {
        path.append(id)
      }
    }
  }
}

private struct ConversationRow: View {
  let conversation: ChatConversation
  let account: ProviderAccount?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text(conversation.title)
          .font(.headline)
          .lineLimit(1)
        Spacer()
        Text(conversation.updatedAt, style: .relative)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let preview = conversation.lastMessagePreview {
        Text(preview)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      HStack(spacing: 6) {
        Text(account?.label ?? conversation.providerID.rawValue)
        Text("·")
        Text(conversation.modelID.rawValue)
      }
      .font(.caption2)
      .foregroundStyle(.tertiary)
      .lineLimit(1)
    }
    .padding(.vertical, 4)
  }
}
