import BYOKchatProviderCore
import SwiftUI
import UIKit

struct ChatSidebarView: View {
  private struct ConversationGroup: Identifiable {
    let title: String
    let conversations: [ChatConversation]
    var id: String { title }
  }

  @Bindable var chats: ChatManagementModel
  @Bindable var providers: ProviderManagementModel

  let selectedConversationID: ConversationID?
  let newChat: () -> Void
  let selectConversation: (ConversationID) -> Void
  let selectSearchResult: (ConversationSearchResult) -> Void
  let openSettings: () -> Void
  let close: () -> Void

  @State private var searchText = ""
  @State private var renameTarget: ChatConversation?
  @State private var renameText = ""

  var body: some View {
    VStack(spacing: 0) {
      header
      newChatButton
      searchField

      if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        conversationHistory
      } else {
        searchResults
      }

      footer
    }
    .safeAreaPadding(.top, 8)
    .safeAreaPadding(.bottom, 8)
    .background(Color(uiColor: .secondarySystemBackground).ignoresSafeArea())
    .shadow(color: .black.opacity(0.18), radius: 18, x: 6)
    .contentShape(Rectangle())
    .gesture(
      DragGesture(minimumDistance: 20)
        .onEnded { value in
          if value.translation.width < -70 { close() }
        }
    )
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
        Task { @MainActor in
          await chats.renameConversation(id, title: renameText)
        }
        renameTarget = nil
      }
    }
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "bubble.left.and.bubble.right.fill")
        .font(.title3)
        .frame(width: 34, height: 34)
        .background(.tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))

      Text("BYOKchat")
        .font(.headline)

      Spacer()

      Button("Close Sidebar", systemImage: "sidebar.left") { close() }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
    }
    .padding(.horizontal, 14)
  }

  private var newChatButton: some View {
    Button(action: newChat) {
      Label("New Chat", systemImage: "square.and.pencil")
        .font(.headline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 12)
    .padding(.top, 6)
  }

  private var searchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
      TextField("Search chats", text: $searchText)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
      if !searchText.isEmpty {
        Button("Clear Search", systemImage: "xmark.circle.fill") {
          searchText = ""
        }
        .labelStyle(.iconOnly)
        .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 12)
    .frame(height: 42)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .onChange(of: searchText) { _, value in chats.search(value) }
  }

  private var conversationHistory: some View {
    List {
      if chats.conversations.isEmpty {
        ContentUnavailableView(
          "No Chats",
          systemImage: "bubble.left",
          description: Text("Start a new conversation to see it here.")
        )
        .listRowBackground(Color.clear)
      } else {
        ForEach(groupedConversations) { group in
          Section(group.title) {
            ForEach(group.conversations) { conversation in
              conversationButton(conversation)
            }
          }
        }
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
  }

  private var searchResults: some View {
    List {
      if chats.searchResults.isEmpty {
        ContentUnavailableView.search(text: searchText)
          .listRowBackground(Color.clear)
      } else {
        ForEach(chats.searchResults) { result in
          Button {
            selectSearchResult(result)
          } label: {
            VStack(alignment: .leading, spacing: 5) {
              Text(result.title)
                .font(.headline)
                .lineLimit(1)
              Text(result.snippet)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
  }

  private var footer: some View {
    VStack(spacing: 0) {
      Divider()

      HStack(spacing: 10) {
        Image(systemName: providers.accounts.isEmpty ? "key.slash" : "checkmark.circle.fill")
          .foregroundStyle(providers.accounts.isEmpty ? Color.secondary : Color.green)
        VStack(alignment: .leading, spacing: 2) {
          Text(providers.accounts.isEmpty ? "No provider configured" : "Providers ready")
            .font(.subheadline.weight(.medium))
          Text("\(providers.accounts.count) account\(providers.accounts.count == 1 ? "" : "s")")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)

      Button(action: openSettings) {
        Label("Settings", systemImage: "gearshape")
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 14)
          .frame(height: 46)
      }
      .buttonStyle(.plain)
    }
  }

  private func conversationButton(_ conversation: ChatConversation) -> some View {
    Button {
      selectConversation(conversation.id)
    } label: {
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text(conversation.title)
            .font(.subheadline.weight(
              selectedConversationID == conversation.id ? .semibold : .regular
            ))
            .lineLimit(1)
          Spacer()
          if selectedConversationID == conversation.id {
            Circle()
              .fill(.tint)
              .frame(width: 6, height: 6)
          }
        }

        if let preview = conversation.lastMessagePreview {
          Text(preview)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .contextMenu {
      Button("Rename", systemImage: "pencil") {
        renameTarget = conversation
        renameText = conversation.title
      }
      Button("Delete", systemImage: "trash", role: .destructive) {
        Task { @MainActor in
          await chats.deleteConversation(conversation.id)
          if selectedConversationID == conversation.id {
            newChat()
          }
        }
      }
    }
  }

  private var groupedConversations: [ConversationGroup] {
    let calendar = Calendar.current
    let startOfToday = calendar.startOfDay(for: Date())
    var today: [ChatConversation] = []
    var previousSevenDays: [ChatConversation] = []
    var previousThirtyDays: [ChatConversation] = []
    var older: [ChatConversation] = []

    for conversation in chats.conversations {
      let day = calendar.startOfDay(for: conversation.updatedAt)
      let distance = calendar.dateComponents([.day], from: day, to: startOfToday).day ?? 0
      switch distance {
      case ...0: today.append(conversation)
      case 1...7: previousSevenDays.append(conversation)
      case 8...30: previousThirtyDays.append(conversation)
      default: older.append(conversation)
      }
    }

    return [
      ConversationGroup(title: "Today", conversations: today),
      ConversationGroup(title: "Previous 7 Days", conversations: previousSevenDays),
      ConversationGroup(title: "Previous 30 Days", conversations: previousThirtyDays),
      ConversationGroup(title: "Older", conversations: older),
    ].filter { !$0.conversations.isEmpty }
  }
}
