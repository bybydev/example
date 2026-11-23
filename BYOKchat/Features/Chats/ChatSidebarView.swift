import AppFoundation
import BYOKchatProviderCore
import Foundation
import SwiftUI

struct ChatSidebarView: View {
  /// Menu destinations replace the app's main screen; usage shows the
  /// analytics dashboard.
  enum SidebarDestination: String, Identifiable {
    case providers
    case library
    case projects
    case plugins
    case usage
    case allChats

    var id: String { rawValue }
  }

  /// Maximum number of unpinned recent conversations displayed inline in the
  /// sidebar drawer before offering the "All Chats" destination.
  nonisolated static let recentDisplayLimit = 20

  nonisolated struct SidebarConversationBuckets: Equatable {
    let pinned: [ChatConversation]
    let recent: [ChatConversation]
    let totalHistoryCount: Int
    let hiddenRecentCount: Int

    var hasMoreRecent: Bool { hiddenRecentCount > 0 }
  }

  @Bindable var chats: ChatManagementModel
  @Bindable var projects: ProjectManagementModel
  @Bindable var mcp: MCPManagementModel
  let purchases: BYOKPurchaseStore

  let selectedConversationID: ConversationID?
  let activeDestination: SidebarDestination?
  let newChat: (ProjectID?) -> Void
  let selectConversation: (ConversationID) -> Void
  let selectSearchResult: (ConversationSearchResult) -> Void
  /// Swaps the app's main screen to the chosen menu destination.
  let openDestination: (SidebarDestination) -> Void
  let openSettings: () -> Void
  let close: () -> Void

  @Environment(\.appFoundationTheme) private var theme
  @AppStorage(SidebarPinStore.storageKey) private var pinnedConversationIDs = ""
  @State private var searchText = ""
  @State private var isSearching = false
  @State private var renameTarget: ChatConversation?
  @State private var renameText = ""
  @State private var pendingDelete: ChatConversation?
  @State private var showPaywall = false
  @State private var showCelebration = false
  @State private var showSearchUpsell = false
  @FocusState private var searchFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      header

      if isSearching {
        searchField
          .transition(.move(edge: .top).combined(with: .opacity))
      }

      if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        scrollableSidebarContent
      } else {
        searchResults
      }

      footer
    }
    .safeAreaPadding(.top, 8)
    .safeAreaPadding(.bottom, 8)
    .background(theme.backgroundColor.ignoresSafeArea())
    .projectErrorPresenter(projects)
    .contentShape(Rectangle())
    .accessibilityAction(.escape) { close() }
    .onDisappear {
      if isSearching || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        chats.search("")
      }
    }
    .animation(.snappy(duration: 0.2), value: isSearching)
    .sheet(isPresented: $showPaywall) {
      ProPaywallView(
        purchases: purchases.manager,
        configuration: BYOKPurchaseStore.paywallConfiguration,
        initialSelectedProductID: BYOKPurchaseStore.yearlyProductID
      )
      .environment(purchases.manager)
      .presentationDragIndicator(.visible)
    }
    .sheet(isPresented: $showCelebration) {
      ProCelebrationView(
        configuration: FoundationProCelebrationConfiguration(
          navigationTitle: "BYOK Pro",
          rows: BYOKProAccess.comparisonRows.map {
            FoundationProComparisonRow(
              feature: $0.feature,
              freeValue: $0.freeValue,
              proValue: $0.proValue
            )
          },
          comparisonAccessibilityLabel: "BYOK Free and Pro feature comparison"
        )
      )
      .environment(purchases.manager)
    }
    .sheet(isPresented: $showSearchUpsell) {
      BYOKProUpsellFlow(feature: .chatSearch)
        .environment(purchases.manager)
    }
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
            removePinned(target.id)
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

  private var header: some View {
    HStack(alignment: .center) {
      brandTitle

      Spacer()

      Button(
        isSearching ? "Close Search" : "Search Chats",
        systemImage: isSearching ? "xmark" : "magnifyingglass"
      ) {
        isSearching.toggle()
        if isSearching {
          searchFocused = true
        } else {
          searchFocused = false
          searchText = ""
          chats.search("")
        }
      }
      .labelStyle(.iconOnly)
      .font(.system(size: 17, weight: .semibold))
      .foregroundStyle(theme.primaryForegroundColor)
      .symbolRenderingMode(.hierarchical)
      .frame(width: 40, height: 40)
      .background(.thinMaterial, in: Circle())
      .overlay(Circle().stroke(theme.borderColor, lineWidth: 0.5))
      .contentShape(Circle())
      .buttonStyle(.plain)
      .shadow(color: theme.appearance.shadow.color, radius: 9, y: 3)
    }
    .padding(.horizontal, 20)
    .padding(.bottom, 8)
  }

  private var brandTitle: some View {
    HStack(spacing: 0) {
      Text("B").foregroundStyle(Color(red: 0.25, green: 0.49, blue: 1.00))
      Text("Y").foregroundStyle(Color(red: 0.66, green: 0.34, blue: 0.96))
      Text("O").foregroundStyle(Color(red: 0.13, green: 0.79, blue: 0.89))
      Text("K").foregroundStyle(Color(red: 1.00, green: 0.38, blue: 0.47))
    }
    .font(.system(size: 29, weight: .bold, design: .rounded))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("BYOK")
  }

  private var searchField: some View {
    HStack(spacing: 9) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(theme.secondaryForegroundColor)
      TextField(
        purchases.hasPro ? "Search chats and messages" : "Search chat titles",
        text: $searchText
      )
        .font(.system(size: 17))
        .foregroundStyle(theme.primaryForegroundColor)
        .submitLabel(.search)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .focused($searchFocused)
      if !searchText.isEmpty {
        Button("Clear Search", systemImage: "xmark.circle.fill") {
          searchText = ""
        }
        .labelStyle(.iconOnly)
        .foregroundStyle(theme.secondaryForegroundColor)
      }
    }
    .padding(.horizontal, 14)
    .frame(height: 46)
    .background(
      theme.surfaceColor,
      in: RoundedRectangle(cornerRadius: 15, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 15, style: .continuous)
        .stroke(theme.borderColor, lineWidth: 0.5)
    )
    .padding(.horizontal, 20)
    .padding(.bottom, 8)
    .onAppear { searchFocused = true }
    .onChange(of: searchText) { _, value in
      chats.search(value, hasPro: purchases.hasPro)
    }
    .onChange(of: purchases.hasPro) { _, hasPro in
      if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        chats.search(searchText, hasPro: hasPro)
      }
    }
  }

  private var primaryNavigation: some View {
    VStack(spacing: 1) {
      SidebarRichMenuRow(
        systemImage: "sparkles",
        title: "AI Providers",
        isSelected: activeDestination == .providers,
        action: { openDestination(.providers) }
      )

      SidebarRichMenuRow(
        systemImage: "books.vertical",
        title: "Library",
        isSelected: activeDestination == .library,
        action: { openDestination(.library) }
      )

      SidebarRichMenuRow(
        systemImage: "folder",
        title: "Projects",
        isSelected: activeDestination == .projects,
        action: { openDestination(.projects) }
      )

      SidebarRichMenuRow(
        systemImage: "puzzlepiece.extension",
        title: "MCP Servers",
        isSelected: activeDestination == .plugins,
        action: { openDestination(.plugins) }
      )

      SidebarRichMenuRow(
        systemImage: "chart.bar.xaxis",
        title: "Analytics",
        isSelected: activeDestination == .usage,
        action: { openDestination(.usage) }
      )
    }
    .padding(.horizontal, 8)
    .padding(.bottom, 10)
  }

  private var scrollableSidebarContent: some View {
    let buckets = Self.conversationBuckets(
      from: chats.historyConversations,
      pinnedRaw: pinnedConversationIDs
    )

    return ScrollView {
      LazyVStack(alignment: .leading, spacing: 1) {
        primaryNavigation

        if buckets.totalHistoryCount == 0 {
          ContentUnavailableView(
            "No Chats",
            systemImage: "bubble.left",
            description: Text("Start a new conversation.")
          )
          .frame(maxWidth: .infinity)
          .padding(.top, 20)
        } else {
          if !buckets.pinned.isEmpty {
            sidebarSectionTitle("Pinned", topPadding: 2)
            ForEach(buckets.pinned) { conversation in
              conversationButton(conversation, isPinned: true)
            }
          }

          if !buckets.recent.isEmpty {
            sidebarSectionTitle(
              "Recent",
              topPadding: buckets.pinned.isEmpty ? 2 : 12
            )
            ForEach(buckets.recent) { conversation in
              conversationButton(conversation, isPinned: false)
            }
          }

          if buckets.hasMoreRecent || activeDestination == .allChats {
            allChatsButton(totalCount: buckets.totalHistoryCount)
              .padding(.top, 6)
          }
        }
      }
      .padding(.bottom, 10)
    }
    .scrollIndicators(.hidden)
  }

  private func allChatsButton(totalCount: Int) -> some View {
    let selected = activeDestination == .allChats
    return Button {
      openDestination(.allChats)
    } label: {
      HStack(alignment: .center, spacing: 10) {
        Image(systemName: "bubble.left.and.bubble.right")
          .font(.system(size: 15, weight: .medium))
          .foregroundStyle(selected ? theme.accentColor : theme.secondaryForegroundColor)
          .frame(width: 20, height: 20)

        Text("All Chats")
          .font(.system(size: 15, weight: selected ? .semibold : .medium))
          .foregroundStyle(selected ? theme.primaryForegroundColor : theme.secondaryForegroundColor)
          .lineLimit(1)

        Spacer(minLength: 8)

        Text("\(totalCount)")
          .font(.system(size: 13, weight: .medium).monospacedDigit())
          .foregroundStyle(theme.secondaryForegroundColor)

        Image(systemName: "chevron.right")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(theme.secondaryForegroundColor.opacity(0.72))
      }
      .padding(.horizontal, 12)
      .frame(minHeight: 40)
      .background(
        selected ? theme.elevatedSurfaceColor.opacity(0.62) : Color.clear,
        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("All Chats, \(totalCount) conversation\(totalCount == 1 ? "" : "s")")
    .accessibilityAddTraits(selected ? .isSelected : [])
    .padding(.horizontal, 8)
  }

  private func sidebarSectionTitle(_ title: String, topPadding: CGFloat) -> some View {
    Text(title)
      .font(.system(size: 13, weight: .semibold))
      .foregroundStyle(theme.secondaryForegroundColor)
      .padding(.horizontal, 20)
      .padding(.top, topPadding)
      .padding(.bottom, 4)
  }

  private var searchResults: some View {
    ScrollView {
      LazyVStack(spacing: 2) {
        if purchases.hasPro && chats.isIndexingSearch {
          HStack(spacing: 8) {
            ProgressView()
              .controlSize(.mini)
            Text(indexingProgressLabel)
              .font(.system(size: 12))
              .foregroundStyle(theme.secondaryForegroundColor)
            Spacer()
          }
          .padding(.horizontal, 20)
          .padding(.vertical, 6)
        } else if !purchases.hasPro {
          Button {
            showSearchUpsell = true
          } label: {
            HStack(spacing: 8) {
              Image(systemName: "crown.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.accentColor)
              VStack(alignment: .leading, spacing: 1) {
                Text("Searching chat titles")
                  .font(.system(size: 12.5, weight: .semibold))
                  .foregroundStyle(theme.primaryForegroundColor)
                Text("Upgrade to Pro for full-text message search")
                  .font(.system(size: 11.5))
                  .foregroundStyle(theme.secondaryForegroundColor)
              }
              Spacer(minLength: 4)
              Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.secondaryForegroundColor.opacity(0.72))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
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
          .padding(.horizontal, 16)
          .padding(.bottom, 6)
        }

        if chats.isSearching && chats.searchResults.isEmpty {
          ProgressView("Searching…")
            .foregroundStyle(theme.secondaryForegroundColor)
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        } else if chats.searchResults.isEmpty {
          ContentUnavailableView.search(text: searchText)
            .padding(.top, 40)
        } else {
          ForEach(chats.searchResults) { result in
            let subtitle = Self.searchSubtitle(
              for: result,
              summary: chats.summary(result.conversationID)
            )
            Button {
              selectSearchResult(result)
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                  if let project = projects.project(for: result.conversationID) {
                    ProjectIconView(project: project, size: 20)
                  }
                  Text(result.title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(theme.primaryForegroundColor)
                    .lineLimit(1)
                }
                if let subtitle {
                  Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.secondaryForegroundColor)
                    .lineLimit(2)
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 12)
              .padding(.vertical, 8)
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

  private var indexingProgressLabel: String {
    if let progress = chats.searchIndexingProgress, progress.total > 0 {
      return "Indexing messages (\(progress.processed)/\(progress.total))…"
    }
    return "Indexing messages…"
  }

  private var footer: some View {
    HStack(alignment: .center, spacing: 8) {
      Button {
        newChat(nil)
      } label: {
        Label("Chat", systemImage: "square.and.pencil")
          .font(.system(size: 15, weight: .semibold))
          .padding(.horizontal, 16)
          .frame(height: 44)
      }
      .foregroundStyle(theme.backgroundColor)
      .background(theme.accentColor, in: Capsule())
      .contentShape(Capsule())
      .buttonStyle(.plain)
      .shadow(color: theme.accentColor.opacity(0.22), radius: 9, y: 3)
      .accessibilityLabel("Start new chat")

      Spacer(minLength: 8)

      Button(
        purchases.hasPro ? "BYOK Pro" : "Upgrade to Pro",
        systemImage: "crown.fill"
      ) {
        if purchases.hasPro {
          showCelebration = true
        } else {
          showPaywall = true
        }
      }
      .labelStyle(.iconOnly)
      .font(.system(size: 17, weight: .semibold))
      .foregroundStyle(theme.accentColor)
      .frame(width: 44, height: 44)
      .background(.thinMaterial, in: Circle())
      .overlay(Circle().stroke(theme.accentColor.opacity(0.45), lineWidth: 0.8))
      .contentShape(Circle())
      .buttonStyle(.plain)
      .shadow(color: theme.appearance.shadow.color, radius: 9, y: 3)

      Button("Settings", systemImage: "gearshape", action: openSettings)
        .labelStyle(.iconOnly)
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(theme.primaryForegroundColor)
        .symbolRenderingMode(.hierarchical)
        .frame(width: 44, height: 44)
        .background(.thinMaterial, in: Circle())
        .overlay(Circle().stroke(theme.borderColor, lineWidth: 0.5))
        .contentShape(Circle())
        .buttonStyle(.plain)
        .shadow(color: theme.appearance.shadow.color, radius: 9, y: 3)
    }
    .padding(.horizontal, 20)
    .padding(.top, 8)
  }

  private func conversationButton(_ conversation: ChatConversation, isPinned: Bool) -> some View {
    let selected = selectedConversationID == conversation.id
    let project = projects.project(for: conversation.id)
    let isGenerating = chats.isGenerating(conversation.id)

    return Button {
      selectConversation(conversation.id)
    } label: {
      HStack(spacing: 8) {
        if let project {
          ProjectIconView(project: project, size: 18)
        }

        Text(conversation.title)
          .font(.system(size: 15.5, weight: selected ? .medium : .regular))
          .lineLimit(1)

        Spacer(minLength: 8)

        if isGenerating {
          ProgressView()
            .controlSize(.mini)
            .accessibilityLabel("Generating")
        }
      }
      .foregroundStyle(theme.primaryForegroundColor)
      .padding(.horizontal, 12)
      .frame(height: 38)
      .background(
        selected ? theme.elevatedSurfaceColor.opacity(0.62) : Color.clear,
        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .padding(.horizontal, 8)
    .contextMenu {
      Button(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash" : "pin") {
        togglePinned(conversation.id)
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
  }

  private func togglePinned(_ id: ConversationID) {
    pinnedConversationIDs = SidebarPinStore.toggled(id, in: pinnedConversationIDs)
  }

  private func removePinned(_ id: ConversationID) {
    pinnedConversationIDs = SidebarPinStore.removing(id, from: pinnedConversationIDs)
  }

  nonisolated static func conversationBuckets(
    from history: [ChatConversation],
    pinnedRaw: String,
    recentLimit: Int = recentDisplayLimit
  ) -> SidebarConversationBuckets {
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
    let allRecent = history
      .filter { !pinnedIDs.contains($0.id.rawValue) }
      .sorted(by: sortedByRecency)
    let limit = max(0, recentLimit)
    let displayedRecent = Array(allRecent.prefix(limit))
    return SidebarConversationBuckets(
      pinned: pinned,
      recent: displayedRecent,
      totalHistoryCount: history.count,
      hiddenRecentCount: max(0, allRecent.count - displayedRecent.count)
    )
  }

  nonisolated static func searchSubtitle(
    for result: ConversationSearchResult,
    summary: ChatConversation?
  ) -> String? {
    let trimmedTitle = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedSnippet = result.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
    if result.role == .title || trimmedSnippet == trimmedTitle {
      let preview = summary?.lastMessagePreview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return preview.isEmpty ? nil : preview
    }
    return trimmedSnippet.isEmpty ? nil : trimmedSnippet
  }
}

private struct SidebarRichMenuRow: View {
  let systemImage: String
  let title: String
  let isSelected: Bool
  let action: () -> Void

  @Environment(\.appFoundationTheme) private var theme

  var body: some View {
    Button(action: action) {
      HStack(alignment: .center, spacing: 11) {
        Image(systemName: systemImage)
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(isSelected ? theme.accentColor : theme.secondaryForegroundColor)
          .frame(width: 22, height: 22)

        Text(title)
          .font(.system(size: 16, weight: isSelected ? .semibold : .medium))
          .foregroundStyle(theme.primaryForegroundColor)
          .lineLimit(1)

        Spacer(minLength: 4)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
      .frame(minHeight: 42)
      .background(
        isSelected ? theme.elevatedSurfaceColor.opacity(0.62) : Color.clear,
        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}
