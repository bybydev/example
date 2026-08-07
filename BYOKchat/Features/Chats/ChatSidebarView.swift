import AppFoundation
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
  @Bindable var projects: ProjectManagementModel

  let selectedConversationID: ConversationID?
  let newChat: (ProjectID?) -> Void
  let selectConversation: (ConversationID) -> Void
  let selectSearchResult: (ConversationSearchResult) -> Void
  let openSettings: () -> Void
  let close: () -> Void

  @Environment(\.appFoundationTheme) private var theme
  @State private var searchText = ""
  @State private var isSearching = false
  @State private var renameTarget: ChatConversation?
  @State private var renameText = ""
  @State private var showProjectEditor = false
  @State private var projectEditorTarget: ChatProject?
  @State private var deleteProjectTarget: ChatProject?
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
        providers: providers
      )
      .presentationDragIndicator(.visible)
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
    .alert(
      "Delete Project?",
      isPresented: Binding(
        get: { deleteProjectTarget != nil },
        set: { if !$0 { deleteProjectTarget = nil } }
      )
    ) {
      Button("Cancel", role: .cancel) { deleteProjectTarget = nil }
      Button("Delete Project", role: .destructive) {
        guard let id = deleteProjectTarget?.id else { return }
        Task { @MainActor in
          await projects.deleteProject(id)
        }
        deleteProjectTarget = nil
      }
    } message: {
      Text("Chats in this project will be kept and moved back to standalone Chats.")
    }
  }

  private var header: some View {
    HStack(alignment: .center) {
      Text("BYOKchat")
        .font(.system(size: 28, weight: .bold))

      Spacer()

      Button("New Project", systemImage: "folder.badge.plus") {
        projectEditorTarget = nil
        showProjectEditor = true
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
    .padding(.bottom, 10)
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
    .padding(.bottom, 10)
    .onChange(of: searchText) { _, value in chats.search(value) }
  }

  private var conversationHistory: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 2) {
        if chats.conversations.isEmpty && projects.projects.isEmpty {
          ContentUnavailableView(
            "No Chats",
            systemImage: "bubble.left",
            description: Text("Start a new conversation or create a project.")
          )
          .frame(maxWidth: .infinity)
          .padding(.top, 64)
        } else {
          if !projects.projects.isEmpty {
            sidebarSectionTitle("Projects", topPadding: 4)
            ForEach(projects.projects) { project in
              projectSection(project)
            }
          }

          let standalone = standaloneConversations
          if !standalone.isEmpty {
            sidebarSectionTitle(
              "Chats",
              topPadding: projects.projects.isEmpty ? 4 : 18
            )
            ForEach(groupedConversations(standalone)) { group in
              Text(group.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 2)

              ForEach(group.conversations) { conversation in
                conversationButton(conversation)
              }
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
      .foregroundStyle(.secondary)
      .padding(.horizontal, 20)
      .padding(.top, topPadding)
      .padding(.bottom, 5)
  }

  private func projectSection(_ project: ChatProject) -> some View {
    let conversations = conversations(in: project.id)
    return VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 9) {
        ProjectIconView(project: project, size: 28)
        Text(project.name)
          .font(.system(size: 15, weight: .semibold))
          .lineLimit(1)
        Spacer(minLength: 8)
        if !conversations.isEmpty {
          Text(conversations.count.formatted())
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.tertiary)
        }
        Button("New Chat in \(project.name)", systemImage: "plus") {
          newChat(project.id)
        }
        .labelStyle(.iconOnly)
        .font(.system(size: 13, weight: .semibold))
        .frame(width: 30, height: 30)
        .contentShape(Rectangle())
      }
      .padding(.leading, 12)
      .padding(.trailing, 8)
      .frame(height: 40)
      .contentShape(Rectangle())
      .contextMenu {
        Button("Edit Project", systemImage: "slider.horizontal.3") {
          projectEditorTarget = project
          showProjectEditor = true
        }
        Button("Delete Project", systemImage: "trash", role: .destructive) {
          deleteProjectTarget = project
        }
      }

      if conversations.isEmpty {
        Button {
          newChat(project.id)
        } label: {
          Text("New chat")
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .frame(height: 36)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
      } else {
        ForEach(conversations) { conversation in
          conversationButton(conversation, nested: true)
        }
      }
    }
    .padding(.bottom, 6)
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
                  .foregroundStyle(.secondary)
                  .lineLimit(2)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 12)
              .padding(.vertical, 9)
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
        Button(action: { newChat(nil) }) {
          Label("New Chat", systemImage: "square.and.pencil")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(theme.backgroundColor)
            .padding(.horizontal, 18)
            .frame(height: 48)
            .background(theme.accentColor, in: Capsule())
        }
        .buttonStyle(.plain)

        Spacer()

        Button("Settings", systemImage: "gearshape", action: openSettings)
          .labelStyle(.iconOnly)
          .font(.system(size: 17, weight: .semibold))
          .symbolRenderingMode(.hierarchical)
          .frame(width: 44, height: 44)
          .background(.thinMaterial, in: Circle())
          .overlay(Circle().stroke(theme.borderColor, lineWidth: 0.5))
          .overlay(alignment: .bottomTrailing) {
            Circle()
              .fill(providers.accounts.isEmpty ? Color.orange : Color.green)
              .frame(width: 8, height: 8)
              .overlay(Circle().stroke(theme.backgroundColor, lineWidth: 1.5))
          }
          .contentShape(Circle())
          .buttonStyle(.plain)
          .shadow(color: theme.appearance.shadow.color, radius: 9, y: 3)
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
    .padding(.top, 8)
  }

  private func conversationButton(_ conversation: ChatConversation, nested: Bool = false) -> some View {
    Button {
      selectConversation(conversation.id)
    } label: {
      HStack(spacing: 0) {
        Text(conversation.title)
          .font(
            .system(
              size: nested ? 15 : 16,
              weight: selectedConversationID == conversation.id ? .medium : .regular
            )
          )
          .lineLimit(1)

        Spacer(minLength: 12)
      }
      .foregroundStyle(.primary)
      .padding(.leading, nested ? 22 : 12)
      .padding(.trailing, 12)
      .frame(height: 42)
      .background(
        selectedConversationID == conversation.id
          ? theme.elevatedSurfaceColor
          : Color.clear,
        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 11, style: .continuous)
          .stroke(
            selectedConversationID == conversation.id ? theme.borderColor : Color.clear,
            lineWidth: 0.5
          )
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
          await projects.reloadFromStorage()
          if selectedConversationID == conversation.id {
            newChat(nil)
          }
        }
      }
    }
  }

  private var standaloneConversations: [ChatConversation] {
    chats.conversations.filter { projects.projectID(for: $0.id) == nil }
  }

  private func conversations(in projectID: ProjectID) -> [ChatConversation] {
    chats.conversations
      .filter { projects.projectID(for: $0.id) == projectID }
      .sorted { $0.updatedAt > $1.updatedAt }
  }

  private func groupedConversations(_ values: [ChatConversation]) -> [ConversationGroup] {
    let calendar = Calendar.current
    let startOfToday = calendar.startOfDay(for: Date())
    var today: [ChatConversation] = []
    var previousSevenDays: [ChatConversation] = []
    var previousThirtyDays: [ChatConversation] = []
    var older: [ChatConversation] = []

    for conversation in values.sorted(by: { $0.updatedAt > $1.updatedAt }) {
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
