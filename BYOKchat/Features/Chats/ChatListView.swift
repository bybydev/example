import AppFoundation
import BYOKchatProviderCore
import Foundation
import SwiftUI

nonisolated struct ChatListSection: Identifiable, Equatable {
  let id: String
  let title: String
  let isPinned: Bool
  let conversations: [ChatConversation]
}

nonisolated enum ChatListGrouping {
  static func sections(
    from history: [ChatConversation],
    pinnedRaw: String,
    now: Date = .now,
    calendar: Calendar = .current,
    locale: Locale = .current
  ) -> [ChatListSection] {
    let pinnedIDs = SidebarPinStore.parse(pinnedRaw)
    let sortedByRecency: (ChatConversation, ChatConversation) -> Bool = { lhs, rhs in
      if lhs.updatedAt != rhs.updatedAt {
        return lhs.updatedAt > rhs.updatedAt
      }
      return lhs.id.rawValue < rhs.id.rawValue
    }

    let pinned = history
      .filter { pinnedIDs.contains($0.id.rawValue) }
      .sorted(by: sortedByRecency)
    let unpinned = history
      .filter { !pinnedIDs.contains($0.id.rawValue) }
      .sorted(by: sortedByRecency)

    var sections: [ChatListSection] = []
    if !pinned.isEmpty {
      sections.append(
        ChatListSection(
          id: "pinned",
          title: "Pinned",
          isPinned: true,
          conversations: pinned
        )
      )
    }

    let startOfToday = calendar.startOfDay(for: now)
    let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
    let startOfLast7Days = calendar.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfToday
    let startOfLast30Days = calendar.date(byAdding: .day, value: -30, to: startOfToday) ?? startOfToday

    var today: [ChatConversation] = []
    var yesterday: [ChatConversation] = []
    var last7Days: [ChatConversation] = []
    var last30Days: [ChatConversation] = []
    var monthOrder: [String] = []
    var monthTitles: [String: String] = [:]
    var monthBuckets: [String: [ChatConversation]] = [:]
    let monthFormat = Date.FormatStyle(
      locale: locale,
      calendar: calendar,
      timeZone: calendar.timeZone
    ).month(.wide).year()

    for conversation in unpinned {
      if conversation.updatedAt >= startOfToday {
        today.append(conversation)
      } else if conversation.updatedAt >= startOfYesterday {
        yesterday.append(conversation)
      } else if conversation.updatedAt >= startOfLast7Days {
        last7Days.append(conversation)
      } else if conversation.updatedAt >= startOfLast30Days {
        last30Days.append(conversation)
      } else {
        let components = calendar.dateComponents([.year, .month], from: conversation.updatedAt)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let key = "month-\(year)-\(month)"
        if monthBuckets[key] == nil {
          monthOrder.append(key)
          let monthAnchor = calendar.date(from: DateComponents(year: year, month: month, day: 1))
            ?? conversation.updatedAt
          monthTitles[key] = monthAnchor.formatted(monthFormat)
        }
        monthBuckets[key, default: []].append(conversation)
      }
    }

    if !today.isEmpty {
      sections.append(ChatListSection(id: "today", title: "Today", isPinned: false, conversations: today))
    }
    if !yesterday.isEmpty {
      sections.append(
        ChatListSection(id: "yesterday", title: "Yesterday", isPinned: false, conversations: yesterday)
      )
    }
    if !last7Days.isEmpty {
      sections.append(
        ChatListSection(
          id: "last7days",
          title: "Previous 7 Days",
          isPinned: false,
          conversations: last7Days
        )
      )
    }
    if !last30Days.isEmpty {
      sections.append(
        ChatListSection(
          id: "last30days",
          title: "Previous 30 Days",
          isPinned: false,
          conversations: last30Days
        )
      )
    }
    for key in monthOrder {
      guard let items = monthBuckets[key], !items.isEmpty else { continue }
      sections.append(
        ChatListSection(
          id: key,
          title: monthTitles[key] ?? "Older",
          isPinned: false,
          conversations: items
        )
      )
    }

    return sections
  }
}

struct ChatListView: View {
  @Bindable var chats: ChatManagementModel
  @Bindable var providers: ProviderManagementModel
  @Bindable var projects: ProjectManagementModel
  @Bindable var mcp: MCPManagementModel
  let openSidebar: () -> Void
  let startNewChat: () -> Void

  @Environment(\.appFoundationTheme) private var theme
  @Environment(PurchaseManager.self) private var purchaseManager
  @AppStorage(SidebarPinStore.storageKey) private var pinnedConversationIDs = ""
  @State private var searchText = ""
  @State private var showSearchUpsell = false
  @State private var renameTarget: ChatConversation?
  @State private var renameText = ""
  @State private var pendingDelete: ChatConversation?

  private var trimmedSearchText: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    Group {
      if !trimmedSearchText.isEmpty {
        searchResults
      } else if chats.historyConversations.isEmpty {
        ContentUnavailableView {
          Label("No Chats", systemImage: "bubble.left.and.bubble.right")
        } description: {
          Text("Your conversations will appear here.")
        } actions: {
          Button("New Chat", action: startNewChat)
            .buttonStyle(.borderedProminent)
        }
      } else {
        conversationList
      }
    }
    .scrollContentBackground(.hidden)
    .foregroundStyle(theme.primaryForegroundColor)
    .background(AppThemeBackground(theme: theme))
    .navigationTitle("All Chats")
    .navigationBarTitleDisplayMode(.inline)
    .searchable(
      text: $searchText,
      prompt: purchaseManager.hasPro ? "Search chats and messages" : "Search chat titles"
    )
    .onChange(of: searchText) { _, value in
      chats.search(value, hasPro: purchaseManager.hasPro)
    }
    .onChange(of: purchaseManager.hasPro) { _, hasPro in
      if !trimmedSearchText.isEmpty {
        chats.search(searchText, hasPro: hasPro)
      }
    }
    .onAppear {
      if !trimmedSearchText.isEmpty {
        chats.search(searchText, hasPro: purchaseManager.hasPro)
      }
    }
    .onDisappear { chats.search("") }
    .sheet(isPresented: $showSearchUpsell) {
      BYOKProUpsellFlow(feature: .chatSearch)
    }
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Open Sidebar", systemImage: "text.alignleft", action: openSidebar)
          .labelStyle(.iconOnly)
          .accessibilityLabel("Open sidebar")
      }
      ToolbarItem(placement: .primaryAction) {
        Button("New Chat", systemImage: "square.and.pencil", action: startNewChat)
      }
    }
    .projectErrorPresenter(projects)
    .alert(
      "Rename Chat",
      isPresented: Binding(
        get: { renameTarget != nil },
        set: { if !$0 { renameTarget = nil } }
      )
    ) {
      let trimmedTitle = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
      TextField("Title", text: $renameText)
      Button("Cancel", role: .cancel) { renameTarget = nil }
      Button("Save") {
        guard let id = renameTarget?.id, !trimmedTitle.isEmpty else { return }
        renameTarget = nil
        Task { @MainActor in
          await chats.renameConversation(id, title: trimmedTitle)
        }
      }
      .disabled(trimmedTitle.isEmpty)
    }
    .confirmationDialog(
      "Delete chat?",
      isPresented: Binding(
        get: { pendingDelete != nil },
        set: { if !$0 { pendingDelete = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete Chat", role: .destructive) {
        guard let target = pendingDelete else { return }
        pendingDelete = nil
        Task { @MainActor in
          await chats.deleteConversation(target.id)
          await projects.reloadFromStorage()
          await mcp.reloadFromStorage()
          if !chats.hasConversation(target.id) {
            pinnedConversationIDs = SidebarPinStore.removing(target.id, from: pinnedConversationIDs)
          }
        }
      }
      Button("Cancel", role: .cancel) { pendingDelete = nil }
    } message: {
      Text(deleteConfirmationMessage)
    }
  }

  private var deleteConfirmationMessage: String {
    guard let title = pendingDelete?.title.trimmingCharacters(in: .whitespacesAndNewlines),
      !title.isEmpty
    else {
      return "This chat and its messages will be permanently deleted."
    }
    return "\"\(title)\" and its messages will be permanently deleted."
  }

  private var conversationList: some View {
    let sections = ChatListGrouping.sections(
      from: chats.historyConversations,
      pinnedRaw: pinnedConversationIDs
    )
    let accountsByID = Dictionary(
      providers.accounts.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )

    return List {
      ForEach(sections) { section in
        Section {
          ForEach(section.conversations) { conversation in
            let isPinned = section.isPinned
            NavigationLink(value: AppRoute.chat(conversation.id)) {
              ConversationRow(
                conversation: conversation,
                account: accountsByID[conversation.accountID],
                project: projects.project(for: conversation.id),
                isGenerating: chats.isGenerating(conversation.id)
              )
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
              Button(
                isPinned ? "Unpin" : "Pin",
                systemImage: isPinned ? "pin.slash" : "pin"
              ) {
                pinnedConversationIDs = SidebarPinStore.toggled(
                  conversation.id,
                  in: pinnedConversationIDs
                )
              }
              .tint(.orange)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
              Button("Delete", systemImage: "trash", role: .destructive) {
                pendingDelete = conversation
              }
            }
            .contextMenu {
              Button(
                isPinned ? "Unpin" : "Pin",
                systemImage: isPinned ? "pin.slash" : "pin"
              ) {
                pinnedConversationIDs = SidebarPinStore.toggled(
                  conversation.id,
                  in: pinnedConversationIDs
                )
              }
              Button("Rename", systemImage: "pencil") {
                renameTarget = conversation
                renameText = conversation.title
              }
              ConversationProjectMenu(conversationID: conversation.id, projects: projects)
              Button("Delete", systemImage: "trash", role: .destructive) {
                pendingDelete = conversation
              }
            }
            .listRowBackground(Color.clear)
          }
        } header: {
          Text(section.title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(theme.secondaryForegroundColor)
        }
      }
    }
    .listStyle(.plain)
    .listRowSeparatorTint(theme.borderColor)
  }

  @ViewBuilder
  private var searchResults: some View {
    if chats.isSearching && chats.searchResults.isEmpty {
      ProgressView("Searching…")
        .foregroundStyle(theme.secondaryForegroundColor)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if chats.searchResults.isEmpty {
      VStack(spacing: 0) {
        if !purchaseManager.hasPro {
          proSearchUpsellBanner
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
        ContentUnavailableView.search(text: searchText)
      }
    } else {
      List {
        if purchaseManager.hasPro && chats.isIndexingSearch {
          HStack(spacing: 8) {
            ProgressView()
              .controlSize(.mini)
            Text(indexingProgressLabel)
              .font(.footnote)
              .foregroundStyle(theme.secondaryForegroundColor)
          }
          .listRowBackground(Color.clear)
        } else if !purchaseManager.hasPro {
          proSearchUpsellBanner
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }

        ForEach(chats.searchResults) { result in
          NavigationLink(value: AppRoute.chat(result.conversationID, messageID: result.messageID)) {
            SearchResultRow(
              result: result,
              subtitle: ChatSidebarView.searchSubtitle(
                for: result,
                summary: chats.summary(result.conversationID)
              ),
              project: projects.project(for: result.conversationID)
            )
          }
          .listRowBackground(Color.clear)
        }
      }
      .listStyle(.plain)
      .listRowSeparatorTint(theme.borderColor)
    }
  }

  private var indexingProgressLabel: String {
    if let progress = chats.searchIndexingProgress, progress.total > 0 {
      return "Indexing messages (\(progress.processed)/\(progress.total))…"
    }
    return "Indexing messages…"
  }

  private var proSearchUpsellBanner: some View {
    Button {
      showSearchUpsell = true
    } label: {
      HStack(spacing: 10) {
        Image(systemName: "crown.fill")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(theme.accentColor)
        VStack(alignment: .leading, spacing: 2) {
          Text("Searching chat titles")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(theme.primaryForegroundColor)
          Text("Upgrade to Pro for full-text search across messages and attachments.")
            .font(.caption)
            .foregroundStyle(theme.secondaryForegroundColor)
        }
        Spacer(minLength: 4)
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(theme.secondaryForegroundColor.opacity(0.72))
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .background(
        theme.surfaceColor,
        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(theme.borderColor, lineWidth: 0.5)
      )
    }
    .buttonStyle(.plain)
  }
}

private struct SearchResultRow: View {
  let result: ConversationSearchResult
  let subtitle: String?
  let project: ChatProject?

  @Environment(\.appFoundationTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 6) {
        if let project {
          ProjectIconView(project: project, size: 20)
        }
        Text(result.title)
          .font(.headline)
          .lineLimit(1)
        Spacer()
        Label(roleLabel, systemImage: roleIcon)
          .labelStyle(.iconOnly)
          .foregroundStyle(theme.secondaryForegroundColor)
      }
      if let subtitle {
        Text(subtitle)
          .font(.subheadline)
          .foregroundStyle(theme.secondaryForegroundColor)
          .lineLimit(3)
      }
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

struct ConversationRow: View {
  let conversation: ChatConversation
  let account: ProviderAccount?
  var project: ChatProject? = nil
  var isGenerating: Bool = false

  @Environment(\.appFoundationTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .center, spacing: 6) {
        if let project {
          ProjectIconView(project: project, size: 18)
        }
        Text(conversation.title)
          .font(.headline)
          .lineLimit(1)
        Spacer()
        if isGenerating {
          ProgressView()
            .controlSize(.mini)
            .accessibilityLabel("Generating")
        }
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
