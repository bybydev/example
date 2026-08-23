import AppFoundation
import BYOKchatProviderCore
import SwiftUI

struct ChatListView: View {
  @Bindable var chats: ChatManagementModel
  @Bindable var providers: ProviderManagementModel
  @Bindable var projects: ProjectManagementModel
  @Bindable var mcp: MCPManagementModel
  let openProviders: () -> Void

  @State private var path: [ConversationID] = []
  @State private var renameTarget: ChatConversation?
  @State private var renameText = ""
  @State private var searchText = ""
  @State private var searchTarget: ConversationSearchResult?
  @Environment(\.appFoundationTheme) private var theme

  var body: some View {
    NavigationStack(path: $path) {
      Group {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          searchResults
        } else if chats.conversations.isEmpty {
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
          conversationList
        }
      }
      .scrollContentBackground(.hidden)
      .foregroundStyle(theme.primaryForegroundColor)
      .background(AppThemeBackground(theme: theme))
      .navigationTitle("BYOKchat")
      .searchable(text: $searchText, prompt: "Search chats and messages")
      .onChange(of: searchText) { _, value in chats.search(value) }
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("New Chat", systemImage: "square.and.pencil") { createChat() }
            .disabled(providers.accounts.isEmpty)
        }
      }
      .navigationDestination(for: ConversationID.self) { id in
        ChatView(
          conversationID: id,
          initialScrollMessageID: searchTarget?.conversationID == id
            ? searchTarget?.messageID : nil,
          chats: chats,
          providers: providers,
          projects: projects,
          mcp: mcp
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

  private var conversationList: some View {
    List {
      ForEach(chats.conversations) { conversation in
        NavigationLink(value: conversation.id) {
          ConversationRow(
            conversation: conversation,
            account: providers.accounts.first { $0.id == conversation.accountID }
          )
        }
        .simultaneousGesture(TapGesture().onEnded { searchTarget = nil })
        .contextMenu {
          Button("Rename", systemImage: "pencil") {
            renameTarget = conversation
            renameText = conversation.title
          }
          Button("Delete", systemImage: "trash", role: .destructive) {
            Task {
              await chats.deleteConversation(conversation.id)
              await projects.reloadFromStorage()
              await mcp.reloadFromStorage()
            }
          }
        }
      }
      .onDelete { offsets in
        let ids = offsets.map { chats.conversations[$0].id }
        for id in ids {
          Task {
            await chats.deleteConversation(id)
            await projects.reloadFromStorage()
            await mcp.reloadFromStorage()
          }
        }
      }
      .listRowBackground(theme.surfaceColor)
    }
    .listStyle(.plain)
  }

  @ViewBuilder
  private var searchResults: some View {
    if chats.searchResults.isEmpty {
      ContentUnavailableView.search(text: searchText)
    } else {
      List(chats.searchResults) { result in
        Button {
          searchTarget = result
          path.append(result.conversationID)
        } label: {
          SearchResultRow(result: result)
        }
        .buttonStyle(.plain)
        .listRowBackground(theme.surfaceColor)
      }
      .listStyle(.plain)
    }
  }

  private func createChat() {
    searchTarget = nil
    Task {
      if let id = await chats.createConversation() {
        path.append(id)
      }
    }
  }
}

private struct SearchResultRow: View {
  let result: ConversationSearchResult

  @Environment(\.appFoundationTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(result.title)
          .font(.headline)
          .lineLimit(1)
        Spacer()
        Label(roleLabel, systemImage: roleIcon)
          .labelStyle(.iconOnly)
          .foregroundStyle(theme.secondaryForegroundColor)
      }
      Text(result.snippet)
        .font(.subheadline)
        .foregroundStyle(theme.secondaryForegroundColor)
        .lineLimit(3)
    }
    .contentShape(Rectangle())
    .padding(.vertical, 3)
  }

  private var roleLabel: String {
    switch result.role {
    case .title: "Title"
    case .user: "User message"
    case .assistant: "Assistant message"
    }
  }

  private var roleIcon: String {
    switch result.role {
    case .title: "textformat"
    case .user: "person"
    case .assistant: "sparkles"
    }
  }
}

private struct ConversationRow: View {
  let conversation: ChatConversation
  let account: ProviderAccount?

  @Environment(\.appFoundationTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text(conversation.title)
          .font(.headline)
          .lineLimit(1)
        Spacer()
        Text(conversation.updatedAt, style: .relative)
          .font(.caption)
          .foregroundStyle(theme.secondaryForegroundColor)
      }

      if let preview = conversation.lastMessagePreview {
        Text(preview)
          .font(.subheadline)
          .foregroundStyle(theme.secondaryForegroundColor)
          .lineLimit(2)
      }

      HStack(spacing: 5) {
        Text(account?.label ?? conversation.providerID.rawValue)
        Text("·")
        Text(conversation.modelID.rawValue)
        if let draft = conversation.draftText, !draft.isEmpty {
          Text("· Draft")
            .foregroundStyle(.tint)
        }
      }
      .font(.caption)
      .foregroundStyle(theme.secondaryForegroundColor.opacity(0.72))
      .lineLimit(1)
    }
    .padding(.vertical, 4)
  }
}
