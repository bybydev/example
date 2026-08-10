import AppFoundation
import BYOKchatProviderCore
import Foundation
import SwiftUI

struct SidebarLibraryView: View {
  let conversations: [ChatConversation]

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Group {
        if items.isEmpty {
          ContentUnavailableView(
            "Library is Empty",
            systemImage: "books.vertical",
            description: Text("Files and images attached to chats will appear here.")
          )
        } else {
          List(items) { item in
            HStack(spacing: 12) {
              Image(systemName: item.kind == .image ? "photo" : "doc")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)

              VStack(alignment: .leading, spacing: 3) {
                Text(item.filename)
                  .font(.body.weight(.medium))
                  .lineLimit(1)
                Text("\(item.conversationTitle) · \(item.byteCountText)")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }

              Spacer(minLength: 8)

              Text(item.date, style: .date)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 3)
          }
          .listStyle(.plain)
        }
      }
      .navigationTitle("Library")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }

  private var items: [SidebarLibraryItem] {
    var result: [SidebarLibraryItem] = []
    for conversation in conversations {
      for message in conversation.messages {
        for attachment in message.attachments ?? [] {
          result.append(
            SidebarLibraryItem(
              id: "\(message.id.rawValue)::\(attachment.id)",
              filename: attachment.filename,
              kind: attachment.kind,
              byteCount: attachment.byteCount,
              conversationTitle: conversation.title,
              date: message.createdAt
            )
          )
        }
      }
    }
    return result.sorted { $0.date > $1.date }
  }
}

private struct SidebarLibraryItem: Identifiable {
  let id: String
  let filename: String
  let kind: ChatAttachmentKind
  let byteCount: Int
  let conversationTitle: String
  let date: Date

  var byteCountText: String {
    ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
  }
}

struct SidebarProjectsView: View {
  @Bindable var chats: ChatManagementModel
  @Bindable var projects: ProjectManagementModel
  @Bindable var providers: ProviderManagementModel
  @Bindable var mcp: MCPManagementModel
  let newChat: (ProjectID?) -> Void

  @Environment(\.dismiss) private var dismiss
  @Environment(PurchaseManager.self) private var purchaseManager
  @State private var editorTarget: ChatProject?
  @State private var showEditor = false
  @State private var showProUpsell = false
  @State private var pendingDelete: ChatProject?

  var body: some View {
    NavigationStack {
      Group {
        if projects.projects.isEmpty {
          ContentUnavailableView(
            "No Projects",
            systemImage: "folder",
            description: Text("Projects keep reusable instructions, files, models, and tools together.")
          )
        } else {
          List(projects.projects) { project in
            Button {
              editorTarget = project
              showEditor = true
            } label: {
              HStack(spacing: 12) {
                ProjectIconView(project: project, size: 34)

                VStack(alignment: .leading, spacing: 3) {
                  Text(project.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                  Text(projectDetail(project))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(.tertiary)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
          }
          .listStyle(.plain)
        }
      }
      .navigationTitle("Projects")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
          Button("New Project", systemImage: "plus") {
            if BYOKProAccess.canCreateProject(
              currentCount: projects.projects.count,
              hasPro: purchaseManager.hasPro
            ) {
              editorTarget = nil
              showEditor = true
            } else {
              showProUpsell = true
            }
          }
        }
      }
    }
    .sheet(isPresented: $showEditor) {
      ProjectEditorView(
        project: editorTarget,
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
          await mcp.reloadFromStorage()
        }
      }
      Button("Cancel", role: .cancel) { pendingDelete = nil }
    } message: {
      Text("Chats in this project will be kept and moved back to standalone chats.")
    }
  }

  private func projectDetail(_ project: ChatProject) -> String {
    let chatCount = chats.conversations.filter { projects.projectID(for: $0.id) == project.id }.count
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
