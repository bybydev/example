import AppFoundation
import BYOKchatProviderCore
import Foundation
import SwiftUI
import UIKit

struct ChatSidebarView: View {
  private enum SidebarDestination: String, Identifiable {
    case library
    case projects
    case plugins
    case usage

    var id: String { rawValue }
  }

  @Bindable var chats: ChatManagementModel
  @Bindable var providers: ProviderManagementModel
  @Bindable var projects: ProjectManagementModel
  @Bindable var mcp: MCPManagementModel
  let purchases: BYOKPurchaseStore

  let selectedConversationID: ConversationID?
  let newChat: (ProjectID?) -> Void
  let selectConversation: (ConversationID) -> Void
  let selectSearchResult: (ConversationSearchResult) -> Void
  let openSettings: () -> Void
  let close: () -> Void

  @Environment(\.appFoundationTheme) private var theme
  @AppStorage("byokchat.sidebar.pinnedConversationIDs") private var pinnedConversationIDs = ""
  @State private var searchText = ""
  @State private var isSearching = false
  @State private var renameTarget: ChatConversation?
  @State private var renameText = ""
  @State private var showProjectEditor = false
  @State private var projectEditorTarget: ChatProject?
  @State private var destination: SidebarDestination?
  @State private var showPaywall = false
  @State private var showCelebration = false
  @State private var showProjectUpsell = false
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
    .contentShape(Rectangle())
    .gesture(
      DragGesture(minimumDistance: 20)
        .onEnded { value in
          if value.translation.width < -70 { close() }
        }
    )
    .animation(.snappy(duration: 0.2), value: isSearching)
    .sheet(isPresented: $showProjectEditor) {
      ProjectEditorView(
        project: projectEditorTarget,
        projects: projects,
        providers: providers,
        mcp: mcp
      )
      .presentationDragIndicator(.visible)
    }
    .sheet(isPresented: $showProjectUpsell) {
      BYOKProUpsellFlow(feature: .projects)
    }
    .sheet(item: $destination) { value in
      switch value {
      case .library:
        SidebarLibraryView(conversations: chats.conversations)
          .presentationDragIndicator(.visible)
      case .projects:
        SidebarProjectsView(
          chats: chats,
          projects: projects,
          providers: providers,
          mcp: mcp,
          newChat: newChat,
          openChat: selectConversation
        )
        .presentationDragIndicator(.visible)
      case .plugins:
        NavigationStack {
          MCPServerListView(model: mcp)
        }
        .presentationDragIndicator(.visible)
      case .usage:
        UsageDashboardView(
          conversations: chats.conversations,
          currentConversationID: selectedConversationID
        )
        .presentationDragIndicator(.visible)
      }
    }
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
      brandTitle

      Spacer()

      Button("New Project", systemImage: "folder.badge.plus") {
        if BYOKProAccess.canCreateProject(
          currentCount: projects.projects.count,
          hasPro: purchases.hasPro
        ) {
          projectEditorTarget = nil
          showProjectEditor = true
        } else {
          showProjectUpsell = true
        }
      }
      .labelStyle(.iconOnly)
      .font(.system(size: 17, weight: .semibold))
      .symbolRenderingMode(.hierarchical)
      .frame(width: 40, height: 40)
      .background(.thinMaterial, in: Circle())
      .overlay(Circle().stroke(theme.borderColor, lineWidth: 0.5))
      .contentShape(Circle())
      .buttonStyle(.plain)
      .shadow(color: theme.appearance.shadow.color, radius: 9, y: 3)

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
    .onChange(of: searchText) { _, value in chats.search(value) }
  }

  private var primaryNavigation: some View {
    VStack(spacing: 0) {
      SidebarRichMenuRow(
        systemImage: "books.vertical",
        title: "Library",
        action: { destination = .library }
      )

      SidebarRichMenuRow(
        systemImage: "folder",
        title: "Projects",
        action: { destination = .projects }
      )

      SidebarRichMenuRow(
        systemImage: "puzzlepiece.extension",
        title: "Plugins",
        action: { destination = .plugins }
      )
    }
    .padding(.horizontal, 8)
    .padding(.bottom, 10)
  }

  private var scrollableSidebarContent: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 1) {
        primaryNavigation

        if chats.conversations.isEmpty {
          ContentUnavailableView(
            "No Chats",
            systemImage: "bubble.left",
            description: Text("Start a new conversation.")
          )
          .frame(maxWidth: .infinity)
          .padding(.top, 20)
        } else {
          if !pinnedConversations.isEmpty {
            sidebarSectionTitle("Pinned", topPadding: 2)
            ForEach(pinnedConversations) { conversation in
              conversationButton(conversation)
            }
          }

          if !recentConversations.isEmpty {
            sidebarSectionTitle(
              "Recent",
              topPadding: pinnedConversations.isEmpty ? 2 : 12
            )
            ForEach(recentConversations) { conversation in
              conversationButton(conversation)
            }
          }
        }
      }
      .padding(.bottom, 10)
    }
    .scrollIndicators(.hidden)
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
        if chats.searchResults.isEmpty {
          ContentUnavailableView.search(text: searchText)
            .padding(.top, 40)
        } else {
          ForEach(chats.searchResults) { result in
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
                    .lineLimit(1)
                }
                Text(result.snippet)
                  .font(.system(size: 13))
                  .foregroundStyle(theme.secondaryForegroundColor)
                  .lineLimit(2)
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

      Button("Upgrade to Pro", systemImage: "crown.fill") {
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

  private func conversationButton(_ conversation: ChatConversation) -> some View {
    let selected = selectedConversationID == conversation.id
    let pinned = pinnedIDSet.contains(conversation.id.rawValue)

    return Button {
      selectConversation(conversation.id)
    } label: {
      HStack(spacing: 0) {
        Text(conversation.title)
          .font(.system(size: 15.5, weight: selected ? .medium : .regular))
          .lineLimit(1)

        Spacer(minLength: 12)
      }
      .foregroundStyle(.primary)
      .padding(.horizontal, 12)
      .frame(height: 38)
      .background(
        selected ? theme.elevatedSurfaceColor.opacity(0.62) : Color.clear,
        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 8)
    .contextMenu {
      Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") {
        togglePinned(conversation.id)
      }
      Button("Rename", systemImage: "pencil") {
        renameTarget = conversation
        renameText = conversation.title
      }
      ConversationProjectMenu(conversationID: conversation.id, projects: projects)
      Button("Delete", systemImage: "trash", role: .destructive) {
        removePinned(conversation.id)
        Task { @MainActor in
          await chats.deleteConversation(conversation.id)
          await projects.reloadFromStorage()
          await mcp.reloadFromStorage()
          if selectedConversationID == conversation.id {
            newChat(nil)
          }
        }
      }
    }
  }

  private var pinnedIDSet: Set<String> {
    Set(
      pinnedConversationIDs
        .split(separator: "\n")
        .map(String.init)
    )
  }

  private var pinnedConversations: [ChatConversation] {
    chats.conversations
      .filter { pinnedIDSet.contains($0.id.rawValue) }
      .sorted { $0.updatedAt > $1.updatedAt }
  }

  private var recentConversations: [ChatConversation] {
    chats.conversations
      .filter { !pinnedIDSet.contains($0.id.rawValue) }
      .sorted { $0.updatedAt > $1.updatedAt }
  }

  private func togglePinned(_ id: ConversationID) {
    var values = pinnedIDSet
    if values.contains(id.rawValue) {
      values.remove(id.rawValue)
    } else {
      values.insert(id.rawValue)
    }
    pinnedConversationIDs = values.sorted().joined(separator: "\n")
  }

  private func removePinned(_ id: ConversationID) {
    var values = pinnedIDSet
    values.remove(id.rawValue)
    pinnedConversationIDs = values.sorted().joined(separator: "\n")
  }

  private var usageResetText: String {
    let calendar = Calendar.current
    let currentMonth = calendar.date(
      from: calendar.dateComponents([.year, .month], from: .now)
    ) ?? .now
    let nextMonth = calendar.date(byAdding: .month, value: 1, to: currentMonth) ?? .now
    let date = nextMonth.formatted(.dateTime.month(.abbreviated).day(.twoDigits))
    return "Usage resets on \(date)"
  }
}

private struct SidebarRichMenuRow: View {
  let systemImage: String
  let title: String
  var detail: String? = nil
  var iconColor: Color? = nil
  let action: () -> Void
  var actionTitle: String? = nil
  var actionColor: Color? = nil
  var actionHandler: (() -> Void)? = nil

  @Environment(\.appFoundationTheme) private var theme

  var body: some View {
    HStack(alignment: detail == nil ? .center : .top, spacing: 8) {
      Button(action: action) {
        HStack(alignment: detail == nil ? .center : .top, spacing: 11) {
          Image(systemName: systemImage)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(iconColor ?? theme.secondaryForegroundColor)
            .frame(width: 22, height: 22)

          VStack(alignment: .leading, spacing: 3) {
            Text(title)
              .font(.system(size: 16, weight: .medium))
              .foregroundStyle(theme.primaryForegroundColor)
              .lineLimit(1)

            if let detail {
              Text(detail)
                .font(.system(size: 11.5, weight: .regular))
                .foregroundStyle(theme.secondaryForegroundColor)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
            }
          }

          Spacer(minLength: 4)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if let actionTitle, let actionHandler {
        Button(actionTitle, action: actionHandler)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(actionColor ?? theme.accentColor)
          .padding(.horizontal, 9)
          .frame(height: 26)
          .background((actionColor ?? theme.accentColor).opacity(0.13), in: Capsule())
          .buttonStyle(.plain)
          .padding(.top, detail == nil ? 0 : -2)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, detail == nil ? 7 : 8)
    .frame(minHeight: detail == nil ? 42 : 52)
  }
}
