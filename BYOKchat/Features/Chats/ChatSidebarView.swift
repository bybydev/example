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
  @State private var isSearching = false
  @State private var renameTarget: ChatConversation?
  @State private var renameText = ""
  @FocusState private var searchFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      header

      if isSearching {
        searchField
          .transition(.move(edge: .top).combined(with: .opacity))
      }

      if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        conversationHistory
      } else {
        searchResults
      }

      footer
    }
    .safeAreaPadding(.top, 8)
    .safeAreaPadding(.bottom, 8)
    .background(Color(uiColor: .systemBackground).ignoresSafeArea())
    .contentShape(Rectangle())
    .gesture(
      DragGesture(minimumDistance: 20)
        .onEnded { value in
          if value.translation.width < -70 { close() }
        }
    )
    .animation(.snappy(duration: 0.2), value: isSearching)
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
    HStack(alignment: .center) {
      Text("BYOKchat")
        .font(.system(size: 28, weight: .bold))

      Spacer()

      Button("Search Chats", systemImage: isSearching ? "xmark" : "magnifyingglass") {
        isSearching.toggle()
        if isSearching {
          searchFocused = true
        } else {
          searchText = ""
          chats.search("")
        }
      }
      .labelStyle(.iconOnly)
      .font(.system(size: 17, weight: .semibold))
      .symbolRenderingMode(.hierarchical)
      .frame(width: 40, height: 40)
      .background(.thinMaterial, in: Circle())
      .overlay(Circle().stroke(.primary.opacity(0.08), lineWidth: 0.5))
      .contentShape(Circle())
      .buttonStyle(.plain)
      .shadow(color: .black.opacity(0.05), radius: 9, y: 3)
    }
    .padding(.horizontal, 20)
    .padding(.bottom, 12)
  }

  private var searchField: some View {
    HStack(spacing: 9) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
      TextField("Search chats", text: $searchText)
        .font(.system(size: 17))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .focused($searchFocused)
      if !searchText.isEmpty {
        Button("Clear Search", systemImage: "xmark.circle.fill") {
          searchText = ""
        }
        .labelStyle(.iconOnly)
        .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 14)
    .frame(height: 48)
    .background(
      Color(uiColor: .secondarySystemBackground),
      in: RoundedRectangle(cornerRadius: 16, style: .continuous)
    )
    .padding(.horizontal, 20)
    .padding(.bottom, 12)
    .onChange(of: searchText) { _, value in chats.search(value) }
  }

  private var conversationHistory: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 8) {
        if chats.conversations.isEmpty {
          ContentUnavailableView(
            "No Chats",
            systemImage: "bubble.left",
            description: Text("Start a new conversation to see it here.")
          )
          .frame(maxWidth: .infinity)
          .padding(.top, 64)
        } else {
          ForEach(groupedConversations) { group in
            Text(group.title)
              .font(.system(size: 16, weight: .semibold))
              .padding(.horizontal, 20)
              .padding(.top, group.title == groupedConversations.first?.title ? 4 : 18)
              .padding(.bottom, 4)

            ForEach(group.conversations) { conversation in
              conversationButton(conversation)
            }
          }
        }
      }
      .padding(.bottom, 12)
    }
    .scrollIndicators(.hidden)
  }

  private var searchResults: some View {
    ScrollView {
      LazyVStack(spacing: 4) {
        if chats.searchResults.isEmpty {
          ContentUnavailableView.search(text: searchText)
            .padding(.top, 64)
        } else {
          ForEach(chats.searchResults) { result in
            Button {
              selectSearchResult(result)
            } label: {
              VStack(alignment: .leading, spacing: 5) {
                Text(result.title)
                  .font(.system(size: 17, weight: .medium))
                  .lineLimit(1)
                Text(result.snippet)
                  .font(.system(size: 14))
                  .foregroundStyle(.secondary)
                  .lineLimit(2)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 14)
              .padding(.vertical, 11)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
          }
        }
      }
    }
    .scrollIndicators(.hidden)
  }

  private var footer: some View {
    VStack(spacing: 8) {
      HStack {
        Button(action: newChat) {
          Label("New Chat", systemImage: "square.and.pencil")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(height: 48)
            .background(Color.accentColor, in: Capsule())
        }
        .buttonStyle(.plain)

        Spacer()

        Button("Settings", systemImage: "gearshape", action: openSettings)
          .labelStyle(.iconOnly)
          .font(.system(size: 17, weight: .semibold))
          .symbolRenderingMode(.hierarchical)
          .frame(width: 44, height: 44)
          .background(.thinMaterial, in: Circle())
          .overlay(Circle().stroke(.primary.opacity(0.08), lineWidth: 0.5))
          .overlay(alignment: .bottomTrailing) {
            Circle()
              .fill(providers.accounts.isEmpty ? Color.orange : Color.green)
              .frame(width: 8, height: 8)
              .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 1.5))
          }
          .contentShape(Circle())
          .buttonStyle(.plain)
          .shadow(color: .black.opacity(0.05), radius: 9, y: 3)
      }

      Text(
        providers.accounts.isEmpty
          ? "No provider configured"
          : "\(providers.accounts.count) provider account\(providers.accounts.count == 1 ? "" : "s") ready"
      )
      .font(.system(size: 11))
      .foregroundStyle(.tertiary)
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .padding(.horizontal, 20)
    .padding(.top, 10)
  }

  private func conversationButton(_ conversation: ChatConversation) -> some View {
    Button {
      selectConversation(conversation.id)
    } label: {
      HStack(spacing: 12) {
        Image(systemName: "bubble.left")
          .font(.system(size: 20, weight: .regular))
          .frame(width: 28)

        VStack(alignment: .leading, spacing: 3) {
          Text(conversation.title)
            .font(.system(size: 17, weight: selectedConversationID == conversation.id ? .medium : .regular))
            .lineLimit(1)

          if let preview = conversation.lastMessagePreview,
            selectedConversationID == conversation.id
          {
            Text(preview)
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }

        Spacer(minLength: 0)
      }
      .foregroundStyle(.primary)
      .padding(.horizontal, 14)
      .frame(minHeight: selectedConversationID == conversation.id ? 62 : 52)
      .background(
        selectedConversationID == conversation.id
          ? Color(uiColor: .secondarySystemBackground) : Color.clear,
        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 8)
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
