import AppFoundation
import BYOKchatProviderCore
import Foundation
import SwiftUI

struct SidebarProjectsView: View {
  @Bindable var chats: ChatManagementModel
  @Bindable var projects: ProjectManagementModel
  @Bindable var providers: ProviderManagementModel
  @Bindable var mcp: MCPManagementModel
  let newChat: (ProjectID?) -> Void
  let openChat: (ConversationID) -> Void
  /// Opens the sidebar drawer; this view renders as the app's main screen
  /// inside the root navigation stack rather than as a sheet.
  var openSidebar: () -> Void = {}

  @Environment(\.appFoundationTheme) private var theme
  @Environment(PurchaseManager.self) private var purchaseManager
  @State private var showNewProjectEditor = false
  @State private var showProUpsell = false
  @State private var pendingDelete: ChatProject?

  var body: some View {
    Group {
      if projects.projects.isEmpty {
        ContentUnavailableView(
          "No Projects",
          systemImage: "folder",
          description: Text("Projects keep reusable instructions, files, models, and tools together.")
        )
      } else {
        List(projects.projects) { project in
          NavigationLink(value: AppRoute.project(project.id)) {
            HStack(spacing: 12) {
              ProjectIconView(project: project, size: 34)

              VStack(alignment: .leading, spacing: 3) {
                Text(project.name)
                  .font(.body.weight(.medium))
                  .lineLimit(1)
                Text(projectDetail(project))
                  .font(.caption)
                  .foregroundStyle(theme.secondaryForegroundColor)
                  .lineLimit(1)
              }

              Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
          }
          .swipeActions(edge: .leading) {
            Button("New Chat", systemImage: "square.and.pencil") {
              newChat(project.id)
            }
            .tint(.accentColor)
          }
          .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) {
              pendingDelete = project
            }
          }
          .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .listRowSeparatorTint(theme.borderColor)
      }
    }
    .scrollContentBackground(.hidden)
    .foregroundStyle(theme.primaryForegroundColor)
    .background(AppThemeBackground(theme: theme))
    .navigationTitle("Projects")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Open Sidebar", systemImage: "text.alignleft", action: openSidebar)
          .labelStyle(.iconOnly)
          .accessibilityLabel("Open sidebar")
      }
      ToolbarItem(placement: .primaryAction) {
        Button("New Project", systemImage: "plus") {
          if BYOKProAccess.canCreateProject(
            currentCount: projects.projects.count,
            hasPro: purchaseManager.hasPro
          ) {
            showNewProjectEditor = true
          } else {
            showProUpsell = true
          }
        }
      }
    }
    .sheet(isPresented: $showNewProjectEditor) {
      ProjectEditorView(
        project: nil,
        projects: projects,
        providers: providers,
        mcp: mcp
      )
      .presentationDragIndicator(.visible)
    }
    .sheet(isPresented: $showProUpsell) {
      BYOKProUpsellFlow(feature: .projects)
    }
    .confirmationDialog(
      "Delete project?",
      isPresented: Binding(
        get: { pendingDelete != nil },
        set: { if !$0 { pendingDelete = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete Project", role: .destructive) {
        guard let project = pendingDelete else { return }
        pendingDelete = nil
        Task { @MainActor in
          await projects.deleteProject(project.id)
        }
      }
      Button("Cancel", role: .cancel) { pendingDelete = nil }
    } message: {
      Text("Chats in this project will be kept and moved back to standalone chats.")
    }
    .projectErrorPresenter(projects)
  }

  private func projectDetail(_ project: ChatProject) -> String {
    let chatCount = chats.historyConversations.filter { projects.projectID(for: $0.id) == project.id }.count
    let fileCount = project.projectFiles.count

    switch (chatCount, fileCount) {
    case (0, 0):
      return "No chats yet"
    case (_, 0):
      return "\(chatCount) chat\(chatCount == 1 ? "" : "s")"
    case (0, _):
      return "\(fileCount) file\(fileCount == 1 ? "" : "s")"
    default:
      return "\(chatCount) chat\(chatCount == 1 ? "" : "s") · \(fileCount) file\(fileCount == 1 ? "" : "s")"
    }
  }
}
