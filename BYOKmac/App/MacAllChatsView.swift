import BYOKchatProviderCore
import Foundation
import MacAppFoundation
import SwiftUI

struct MacAllChatsView: View {
  enum Scope: String, CaseIterable, Identifiable {
    case all = "All"
    case pinned = "Pinned"

    var id: String { rawValue }
  }

  enum ProjectFilter: Hashable {
    case all
    case unassigned
    case project(ProjectID)
  }

  @Bindable var providers: MacProviderModel
  @Bindable var chats: MacChatSessionModel
  @Bindable var workspace: MacWorkspaceModel
  @Bindable var mcp: MacMCPModel
  let openChat: (ConversationID, ChatMessageID?) -> Void
  let startNewChat: () -> Void

  @Environment(PurchaseManager.self) private var purchaseManager
  @Environment(\.macToastCenter) private var toastCenter
  @AppStorage(MacSidebarPinStore.storageKey) private var pinnedConversationIDs = ""
  @State private var searchText = ""
  @State private var scope: Scope = .all
  @State private var projectFilter: ProjectFilter = .all
  @State private var renameTarget: ChatConversation?
  @State private var deleteTarget: ChatConversation?
  @FocusState private var searchFocused: Bool

  private var trimmedSearchText: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var isSearching: Bool {
    !trimmedSearchText.isEmpty
  }

  private var canUseFullTextSearch: Bool {
    MacProAccess.canUseChatSearch(hasPro: purchaseManager.hasPro)
  }

  private var isCheckingEntitlement: Bool {
    purchaseManager.entitlementState == .checking
  }

  private var pinnedIDSet: Set<String> {
    MacSidebarPinStore.parse(pinnedConversationIDs)
  }

  private var accountsByID: [ProviderAccountID: ProviderAccount] {
    Dictionary(
      providers.accounts.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
  }

  private var hasActiveFilters: Bool {
    scope != .all || projectFilter != .all
  }

  private var filteredConversations: [ChatConversation] {
    chats.conversationSummaries.filter { conversation in
      matchesFilters(conversationID: conversation.id)
    }
  }

  private var groupedSections: [MacChatListSection] {
    MacChatListGrouping.sections(
      from: filteredConversations,
      pinnedIDs: pinnedIDSet
    )
  }

  private var displayedSearchItems: [MacChatSessionModel.SearchItem] {
    let rawItems: [MacChatSessionModel.SearchItem]
    if canUseFullTextSearch {
      rawItems = chats.searchItems
    } else {
      rawItems = MacSidebarSearchSupport.titleMatches(
        for: searchText,
        in: chats.conversationSummaries
      )
    }
    guard hasActiveFilters else { return rawItems }
    return rawItems.filter { matchesFilters(conversationID: $0.conversationID) }
  }

  private var pinnedCount: Int {
    let pinned = pinnedIDSet
    return chats.conversationSummaries.reduce(into: 0) { count, conversation in
      if pinned.contains(conversation.id.rawValue) {
        count += 1
      }
    }
  }

  private var projectFilterLabel: String {
    switch projectFilter {
    case .all:
      return "All Projects"
    case .unassigned:
      return "No Project"
    case .project(let id):
      return workspace.project(id)?.name ?? "Project"
    }
  }

  private var indexingProgressLabel: String {
    if let progress = chats.searchIndexingProgress, progress.total > 0 {
      return "Indexing messages (\(progress.processed)/\(progress.total))…"
    }
    return "Indexing messages…"
  }

  private var deleteDialogTitle: String {
    guard let target = deleteTarget else { return "Delete conversation?" }
    let title = target.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return "Delete \"\(title.isEmpty ? "New Chat" : title)\"?"
  }

  var body: some View {
    VStack(spacing: 0) {
      toolbar

      Divider()

      Group {
        if isSearching {
          searchResultsContent
        } else if chats.conversationSummaries.isEmpty {
          emptyHistoryState
        } else if filteredConversations.isEmpty {
          emptyFilteredState
        } else {
          conversationListContent
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(MacDesignTokens.Colors.canvas)
    .onAppear {
      pruneInvalidFilterAndPins()
      if isSearching && canUseFullTextSearch {
        chats.updateSearch(searchText)
      }
    }
    .onChange(of: searchText) { _, value in
      if canUseFullTextSearch {
        chats.updateSearch(value)
      } else if !chats.searchItems.isEmpty || chats.isSearching {
        chats.updateSearch("")
      }
    }
    .onChange(of: purchaseManager.hasPro) { _, hasPro in
      if MacProAccess.canUseChatSearch(hasPro: hasPro) {
        if isSearching {
          chats.updateSearch(searchText)
        }
      } else {
        chats.updateSearch("")
      }
    }
    .onChange(of: workspace.projects.map(\.id)) { _, _ in
      if case .project(let id) = projectFilter, workspace.project(id) == nil {
        projectFilter = .all
      }
    }
    .onChange(of: chats.conversationSummaries.map(\.id)) { _, _ in
      pruneInvalidFilterAndPins()
    }
    .onDisappear {
      chats.updateSearch("")
    }
    .sheet(item: $renameTarget) { conversation in
      MacRenameConversationSheet(conversation: conversation) { title in
        await chats.renameConversation(conversation.id, title: title)
      }
    }
    .confirmationDialog(
      deleteDialogTitle,
      isPresented: Binding(
        get: { deleteTarget != nil },
        set: { if !$0 { deleteTarget = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete Conversation", role: .destructive) {
        confirmDelete()
      }
      Button("Cancel", role: .cancel) {
        deleteTarget = nil
      }
    } message: {
      Text("This removes the conversation and its chat-specific project/tool references. This cannot be undone.")
    }
  }

  private var toolbar: some View {
    HStack(spacing: 10) {
      searchField
        .frame(maxWidth: 340)

      MacSegmentedControl(
        options: Scope.allCases,
        selection: $scope,
        title: \.rawValue
      )
      .frame(width: 152)

      if !workspace.projects.isEmpty {
        Menu {
          Button {
            projectFilter = .all
          } label: {
            Label("All Projects", systemImage: projectFilter == .all ? "checkmark" : "folder")
          }

          Button {
            projectFilter = .unassigned
          } label: {
            Label(
              "No Project",
              systemImage: projectFilter == .unassigned ? "checkmark" : "tray"
            )
          }

          Divider()

          ForEach(workspace.projects) { project in
            let selected = projectFilter == .project(project.id)
            Button {
              projectFilter = .project(project.id)
            } label: {
              Label(
                project.name,
                systemImage: selected ? "checkmark" : project.symbolName
              )
            }
          }
        } label: {
          MacMenuButtonLabel(
            title: projectFilterLabel,
            systemImage: projectFilter == .all ? "folder" : "line.3.horizontal.decrease.circle.fill",
            isAccentIcon: projectFilter != .all
          )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
      }

      Spacer(minLength: 8)

      Button("New Chat", systemImage: "square.and.pencil", action: startNewChat)
        .buttonStyle(MacActionButtonStyle(.primary))
    }
    .padding(.horizontal, 16)
    .frame(height: 54)
    .background(MacDesignTokens.Colors.surface.opacity(0.45))
  }

  private var searchField: some View {
    HStack(spacing: 7) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(MacDesignTokens.Colors.textMuted)

      TextField(
        canUseFullTextSearch ? "Search chats and messages" : "Search chat titles",
        text: $searchText
      )
      .textFieldStyle(.plain)
      .focused($searchFocused)

      if canUseFullTextSearch && chats.isSearching {
        ProgressView()
          .controlSize(.mini)
      } else if !searchText.isEmpty {
        Button {
          searchText = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear search")
      }
    }
    .padding(.horizontal, 10)
    .frame(height: 32)
    .background(
      MacDesignTokens.Colors.surface,
      in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(
          searchFocused
            ? MacDesignTokens.Colors.accent.opacity(0.55)
            : MacDesignTokens.Colors.separator.opacity(0.75),
          lineWidth: searchFocused ? 1 : 0.75
        )
    }
  }

  private var emptyHistoryState: some View {
    ContentUnavailableView {
      Label("No Chats", systemImage: "bubble.left.and.bubble.right")
    } description: {
      Text("Your conversations will appear here once you start chatting.")
    } actions: {
      Button("New Chat", systemImage: "square.and.pencil", action: startNewChat)
        .buttonStyle(MacActionButtonStyle(.primary))
    }
  }

  private var emptyFilteredState: some View {
    ContentUnavailableView {
      Label(
        scope == .pinned ? "No Pinned Chats" : "No Matching Chats",
        systemImage: scope == .pinned ? "pin.slash" : "line.3.horizontal.decrease.circle"
      )
    } description: {
      Text(
        scope == .pinned
          ? "Pin important chats to keep them at the top of your sidebar and All Chats."
          : "No conversations match the current filter."
      )
    } actions: {
      Button("Clear Filters") {
        scope = .all
        projectFilter = .all
      }
      .buttonStyle(MacActionButtonStyle(.secondary))
    }
  }

  private var conversationListContent: some View {
    let sections = groupedSections
    let accounts = accountsByID
    let totalCount = chats.conversationSummaries.count
    let shownCount = filteredConversations.count

    return ScrollView {
      LazyVStack(alignment: .leading, spacing: 18) {
        HStack(spacing: 8) {
          Text(summaryCaption(shown: shownCount, total: totalCount))
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)

          Spacer()

          if hasActiveFilters {
            Button("Clear Filters") {
              scope = .all
              projectFilter = .all
            }
            .buttonStyle(.link)
            .font(.caption)
          }
        }

        ForEach(sections) { section in
          VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
              if section.isPinned {
                Image(systemName: "pin.fill")
                  .font(.system(size: 10, weight: .semibold))
                  .foregroundStyle(MacDesignTokens.Colors.accent)
              }
              Text(section.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
                .textCase(.uppercase)

              Text("\(section.conversations.count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(MacDesignTokens.Colors.textMuted.opacity(0.75))
            }
            .padding(.horizontal, 2)

            VStack(spacing: 6) {
              ForEach(section.conversations) { conversation in
                let pinned = section.isPinned || pinnedIDSet.contains(conversation.id.rawValue)
                let currentProject = workspace.project(for: conversation.id)
                let hasDraft = !chats.draft(for: conversation.id)
                  .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

                MacAllChatsRow(
                  conversation: conversation,
                  account: accounts[conversation.accountID],
                  currentProject: currentProject,
                  projects: workspace.projects,
                  pinned: pinned,
                  isGenerating: chats.isGenerating(conversation.id),
                  hasDraft: hasDraft,
                  open: { openChat(conversation.id, nil) },
                  assignProject: { projectID in assignProject(projectID, to: conversation) },
                  togglePinned: { togglePinned(conversation.id) },
                  rename: { renameTarget = conversation },
                  delete: { deleteTarget = conversation }
                )
              }
            }
          }
        }
      }
      .padding(16)
    }
  }

  private var searchResultsContent: some View {
    let items = displayedSearchItems
    let pinned = pinnedIDSet

    return VStack(spacing: 0) {
      if canUseFullTextSearch && chats.isIndexingSearch {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.mini)
          Text(indexingProgressLabel)
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
          Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(MacDesignTokens.Colors.surface.opacity(0.6))
        Divider()
      } else if !canUseFullTextSearch {
        proSearchUpsellBanner
        Divider()
      }

      if canUseFullTextSearch && chats.isSearching && items.isEmpty {
        VStack(spacing: 10) {
          ProgressView()
            .controlSize(.regular)
          Text("Searching conversations…")
            .font(.callout)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if items.isEmpty {
        ContentUnavailableView {
          Label(
            canUseFullTextSearch ? "No Matching Conversations" : "No Matching Chat Titles",
            systemImage: "magnifyingglass"
          )
        } description: {
          Text(
            hasActiveFilters
              ? "No conversations match \"\(trimmedSearchText)\" with the active filters."
              : "No conversations match \"\(trimmedSearchText)\"."
          )
        } actions: {
          if hasActiveFilters {
            Button("Clear Filters") {
              scope = .all
              projectFilter = .all
            }
            .buttonStyle(MacActionButtonStyle(.secondary))
          }
        }
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 8) {
            HStack {
              Text("\(items.count) result\(items.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
              Spacer()
              if hasActiveFilters {
                Button("Clear Filters") {
                  scope = .all
                  projectFilter = .all
                }
                .buttonStyle(.link)
                .font(.caption)
              }
            }
            .padding(.bottom, 2)

            ForEach(items) { item in
              let summary = chats.summary(item.conversationID)
              let currentProject = workspace.project(for: item.conversationID)
              let isPinned = pinned.contains(item.conversationID.rawValue)

              MacAllChatsSearchRow(
                item: item,
                subtitle: MacSidebarSearchSupport.subtitle(for: item, summary: summary),
                project: currentProject,
                projects: workspace.projects,
                summary: summary,
                pinned: isPinned,
                open: { openChat(item.conversationID, item.messageID) },
                assignProject: { projectID in
                  guard let summary else { return }
                  assignProject(projectID, to: summary)
                },
                togglePinned: { togglePinned(item.conversationID) },
                rename: {
                  guard let summary else { return }
                  renameTarget = summary
                },
                delete: {
                  guard let summary else { return }
                  deleteTarget = summary
                }
              )
            }
          }
          .padding(16)
        }
      }
    }
  }

  private var proSearchUpsellBanner: some View {
    HStack(spacing: 12) {
      Image(systemName: "crown.fill")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(MacDesignTokens.Colors.accent)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text("Searching chat titles")
          .font(.system(size: 12.5, weight: .semibold))
          .foregroundStyle(MacDesignTokens.Colors.textPrimary)
        Text("Upgrade to BYOK Pro for full-text search across every message and attachment.")
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
      }

      Spacer(minLength: 8)

      Button("Upgrade to Pro") {
        MacProAccess.requestUpgrade(.chatSearch)
      }
      .buttonStyle(MacActionButtonStyle(.primary, size: .small))
      .disabled(isCheckingEntitlement)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(MacDesignTokens.Colors.surface.opacity(0.65))
  }

  private func summaryCaption(shown: Int, total: Int) -> String {
    if hasActiveFilters {
      return "Showing \(shown) of \(total) conversation\(total == 1 ? "" : "s")"
    }
    if pinnedCount > 0 {
      return "\(total) conversation\(total == 1 ? "" : "s") · \(pinnedCount) pinned"
    }
    return "\(total) conversation\(total == 1 ? "" : "s")"
  }

  private func matchesFilters(conversationID: ConversationID) -> Bool {
    if scope == .pinned && !pinnedIDSet.contains(conversationID.rawValue) {
      return false
    }
    switch projectFilter {
    case .all:
      return true
    case .unassigned:
      return workspace.project(for: conversationID) == nil
    case .project(let targetID):
      return workspace.project(for: conversationID)?.id == targetID
    }
  }

  private func togglePinned(_ id: ConversationID) {
    pinnedConversationIDs = MacSidebarPinStore.toggled(id, in: pinnedConversationIDs)
  }

  private func assignProject(_ projectID: ProjectID?, to conversation: ChatConversation) {
    Task { @MainActor in
      let wasRestricted = projectID.map { workspace.isProjectRestricted($0) } ?? false
      if await workspace.assignConversation(conversation.id, to: projectID) {
        await mcp.reloadFromStorage()
      } else if let error = workspace.consumeErrorMessage(), !wasRestricted {
        toastCenter?.error(error)
      }
    }
  }

  private func confirmDelete() {
    guard let target = deleteTarget else { return }
    deleteTarget = nil
    Task { @MainActor in
      if await chats.deleteConversation(target.id) {
        await workspace.reload()
        await mcp.reloadFromStorage()
        pinnedConversationIDs = MacSidebarPinStore.removing(target.id, from: pinnedConversationIDs)
        toastCenter?.showStatus("Conversation deleted.")
      }
    }
  }

  private func pruneInvalidFilterAndPins() {
    let validIDs = Set(chats.conversationSummaries.map { $0.id.rawValue })
    let pruned = MacSidebarPinStore.parse(pinnedConversationIDs).intersection(validIDs)
    let serialized = MacSidebarPinStore.serialize(pruned)
    if serialized != pinnedConversationIDs {
      pinnedConversationIDs = serialized
    }
    if case .project(let id) = projectFilter, workspace.project(id) == nil {
      projectFilter = .all
    }
  }
}

private struct MacAllChatsRow: View {
  let conversation: ChatConversation
  let account: ProviderAccount?
  let currentProject: ChatProject?
  let projects: [ChatProject]
  let pinned: Bool
  let isGenerating: Bool
  let hasDraft: Bool
  let open: () -> Void
  let assignProject: (ProjectID?) -> Void
  let togglePinned: () -> Void
  let rename: () -> Void
  let delete: () -> Void

  @State private var isHovered = false
  @State private var isEllipsisHovered = false

  private var displayTitle: String {
    conversation.title.isEmpty ? "New Chat" : conversation.title
  }

  private var previewText: String {
    if let preview = conversation.lastMessagePreview?.trimmingCharacters(in: .whitespacesAndNewlines),
      !preview.isEmpty
    {
      return preview
    }
    return conversation.messageCount == 1
      ? "1 message"
      : "\(conversation.messageCount) messages"
  }

  private var timestampText: String {
    if Calendar.current.isDateInToday(conversation.updatedAt) {
      return conversation.updatedAt.formatted(date: .omitted, time: .shortened)
    }
    return conversation.updatedAt.formatted(date: .abbreviated, time: .shortened)
  }

  var body: some View {
    HStack(spacing: 8) {
      Button(action: open) {
        HStack(alignment: .center, spacing: 12) {
          if let currentProject {
            MacSidebarProjectIconView(project: currentProject, size: 28)
          } else {
            Image(systemName: pinned ? "pin.fill" : "bubble.left")
              .font(.system(size: 12.5, weight: .semibold))
              .foregroundStyle(
                pinned ? MacDesignTokens.Colors.accent : MacDesignTokens.Colors.textMuted
              )
              .frame(width: 28, height: 28)
              .background(
                (pinned ? MacDesignTokens.Colors.accent : Color.primary).opacity(pinned ? 0.12 : 0.05),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
              )
              .accessibilityHidden(true)
          }

          VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 6) {
              Text(displayTitle)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(MacDesignTokens.Colors.textPrimary)
                .lineLimit(1)

              if isGenerating {
                ProgressView()
                  .controlSize(.mini)
                  .accessibilityLabel("Generating")
              }

              if hasDraft {
                Text("Draft")
                  .font(.caption2.weight(.semibold))
                  .foregroundStyle(MacDesignTokens.Colors.accent)
                  .padding(.horizontal, 6)
                  .padding(.vertical, 1.5)
                  .background(MacDesignTokens.Colors.accentSoft, in: Capsule())
              }

              Spacer(minLength: 8)

              Text(timestampText)
                .font(.caption)
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
                .monospacedDigit()
            }

            Text(previewText)
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
              .lineLimit(1)

            HStack(spacing: 6) {
              Text(account?.label ?? conversation.providerID.rawValue)
              Text("·")
              Text(conversation.modelID.rawValue)
              Text("·")
              Text(conversation.messageCount == 1 ? "1 message" : "\(conversation.messageCount) messages")

              if let currentProject {
                Text("·")
                Text(currentProject.name)
                  .foregroundStyle(MacDesignTokens.Colors.textPrimary.opacity(0.75))
              }
            }
            .font(.caption2)
            .foregroundStyle(MacDesignTokens.Colors.textMuted.opacity(0.85))
            .lineLimit(1)
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      Menu {
        menuItems
      } label: {
        Image(systemName: "ellipsis")
          .font(.system(size: 12.5, weight: .semibold))
          .foregroundStyle(
            isEllipsisHovered ? MacDesignTokens.Colors.textPrimary : MacDesignTokens.Colors.textMuted
          )
          .frame(width: 28, height: 28)
          .background(
            Color.primary.opacity(isEllipsisHovered ? MacDesignTokens.Control.sheetCloseHoverOpacity : 0),
            in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.small, style: .continuous)
          )
          .contentShape(Rectangle())
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .onHover { isEllipsisHovered = $0 }
      .opacity(isHovered ? 1 : 0.35)
      .help("Chat options")
      .accessibilityLabel("Options for \(displayTitle)")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(
      isHovered
        ? MacDesignTokens.Colors.selection.opacity(0.42)
        : MacDesignTokens.Colors.surface,
      in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.medium, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: MacDesignTokens.Radius.medium, style: .continuous)
        .stroke(
          MacDesignTokens.Colors.separator.opacity(isHovered ? 0.95 : 0.7),
          lineWidth: 0.75
        )
    }
    .onHover { isHovered = $0 }
    .animation(
      .easeOut(duration: MacDesignTokens.Control.interactionDuration),
      value: isHovered
    )
    .contextMenu {
      menuItems
    }
  }

  private var menuItems: some View {
    MacConversationMenuItems(
      pinned: pinned,
      currentProject: currentProject,
      projects: projects,
      assignProject: assignProject,
      togglePinned: togglePinned,
      rename: rename,
      delete: delete
    )
  }
}

private struct MacAllChatsSearchRow: View {
  let item: MacChatSessionModel.SearchItem
  let subtitle: String?
  let project: ChatProject?
  let projects: [ChatProject]
  let summary: ChatConversation?
  let pinned: Bool
  let open: () -> Void
  let assignProject: (ProjectID?) -> Void
  let togglePinned: () -> Void
  let rename: () -> Void
  let delete: () -> Void

  @State private var isHovered = false
  @State private var isEllipsisHovered = false

  private var displayTitle: String {
    item.title.isEmpty ? "New Chat" : item.title
  }

  private var roleLabel: String {
    switch item.role {
    case .title: "Title"
    case .user: "You"
    case .assistant: "Assistant"
    }
  }

  private var roleIcon: String {
    switch item.role {
    case .title: "textformat"
    case .user: "person"
    case .assistant: "sparkles"
    }
  }

  var body: some View {
    HStack(spacing: 8) {
      Button(action: open) {
        HStack(alignment: .center, spacing: 12) {
          if let project {
            MacSidebarProjectIconView(project: project, size: 28)
          } else {
            Image(systemName: roleIcon)
              .font(.system(size: 12.5, weight: .semibold))
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
              .frame(width: 28, height: 28)
              .background(
                Color.primary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
              )
              .accessibilityHidden(true)
          }

          VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
              Text(displayTitle)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(MacDesignTokens.Colors.textPrimary)
                .lineLimit(1)

              Spacer(minLength: 8)

              Text(roleLabel)
                .font(.caption2.weight(.medium))
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(Color.primary.opacity(0.055), in: Capsule())

              Text(item.updatedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
                .monospacedDigit()
            }

            if let subtitle {
              Text(subtitle)
                .font(.caption)
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
                .lineLimit(2)
            }
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if summary != nil {
        Menu {
          menuItems
        } label: {
          Image(systemName: "ellipsis")
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(
              isEllipsisHovered ? MacDesignTokens.Colors.textPrimary : MacDesignTokens.Colors.textMuted
            )
            .frame(width: 28, height: 28)
            .background(
              Color.primary.opacity(isEllipsisHovered ? MacDesignTokens.Control.sheetCloseHoverOpacity : 0),
              in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.small, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isEllipsisHovered = $0 }
        .opacity(isHovered ? 1 : 0.35)
        .help("Chat options")
        .accessibilityLabel("Options for \(displayTitle)")
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(
      isHovered
        ? MacDesignTokens.Colors.selection.opacity(0.42)
        : MacDesignTokens.Colors.surface,
      in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.medium, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: MacDesignTokens.Radius.medium, style: .continuous)
        .stroke(
          MacDesignTokens.Colors.separator.opacity(isHovered ? 0.95 : 0.7),
          lineWidth: 0.75
        )
    }
    .onHover { isHovered = $0 }
    .animation(
      .easeOut(duration: MacDesignTokens.Control.interactionDuration),
      value: isHovered
    )
    .contextMenu {
      if summary != nil {
        menuItems
      }
    }
  }

  private var menuItems: some View {
    MacConversationMenuItems(
      pinned: pinned,
      currentProject: project,
      projects: projects,
      assignProject: assignProject,
      togglePinned: togglePinned,
      rename: rename,
      delete: delete
    )
  }
}
