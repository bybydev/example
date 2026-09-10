import BYOKchatProviderCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum MacProjectWorkspaceSection: String, CaseIterable, Identifiable {
  case overview = "Overview"
  case chats = "Chats"
  case sources = "Sources"
  case tools = "Tools"

  var id: String { rawValue }
}

enum MacProjectChatDateGrouper {
  struct Section {
    let title: String
    let conversations: [ChatConversation]
  }

  static func sections(
    for conversations: [ChatConversation],
    now: Date = .now
  ) -> [Section] {
    let calendar = Calendar.current
    let formatter = DateFormatter()
    formatter.locale = .current
    formatter.dateFormat = "MMMM yyyy"
    let weekAgo = calendar.date(byAdding: .day, value: -7, to: now)
    let sorted = conversations.sorted { $0.updatedAt > $1.updatedAt }

    func title(for date: Date) -> String {
      if calendar.isDate(date, inSameDayAs: now) { return "Today" }
      if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
        calendar.isDate(date, inSameDayAs: yesterday)
      {
        return "Yesterday"
      }
      if let weekAgo, date > weekAgo { return "Previous 7 Days" }
      return formatter.string(from: date)
    }

    var buckets: [(String, [ChatConversation])] = []
    for conversation in sorted {
      let bucket = title(for: conversation.updatedAt)
      if let last = buckets.indices.last, buckets[last].0 == bucket {
        buckets[last].1.append(conversation)
      } else {
        buckets.append((bucket, [conversation]))
      }
    }
    return buckets.map { Section(title: $0.0, conversations: $0.1) }
  }
}

struct MacProjectsWorkspaceView: View {
  @Bindable var workspace: MacWorkspaceModel
  @Bindable var providers: MacProviderModel
  @Bindable var chats: MacChatSessionModel
  @Bindable var mcp: MacMCPModel
  let openChat: (ConversationID) -> Void
  let startNewChat: (ProjectID, String?) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var selectedProjectID: ProjectID?
  @State private var searchText = ""
  @State private var showingNewProject = false
  @State private var deleteProject: ChatProject?

  private var selectedProject: ChatProject? {
    workspace.project(selectedProjectID)
  }

  private var visibleProjects: [ChatProject] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return workspace.projects }
    return workspace.projects.filter { project in
      project.name.localizedCaseInsensitiveContains(query)
        || projectProviderSummary(project).localizedCaseInsensitiveContains(query)
    }
  }

  var body: some View {
    Group {
      if let project = selectedProject {
        MacProjectWorkspaceDetailView(
          project: project,
          workspace: workspace,
          providers: providers,
          chats: chats,
          mcp: mcp,
          back: { selectedProjectID = nil },
          openChat: { conversationID in
            openChat(conversationID)
            dismiss()
          },
          startNewChat: { prompt in
            startNewChat(project.id, prompt)
            dismiss()
          },
          requestDelete: { deleteProject = project }
        )
      } else {
        projectsHome
      }
    }
    .frame(minWidth: 920, minHeight: 620)
    .background(MacDesignTokens.Colors.canvas)
    .onChange(of: workspace.projects.map(\.id)) { _, ids in
      if let selectedProjectID, !ids.contains(selectedProjectID) {
        self.selectedProjectID = nil
      }
    }
    .sheet(isPresented: $showingNewProject) {
      MacProjectCreateSheet(
        workspace: workspace,
        providers: providers,
        created: { projectID in
          selectedProjectID = projectID
        }
      )
    }
    .confirmationDialog(
      deleteProject.map { "Delete \"\($0.name)\"?" } ?? "Delete project?",
      isPresented: Binding(
        get: { deleteProject != nil },
        set: { if !$0 { deleteProject = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete Project", role: .destructive) {
        guard let project = deleteProject else { return }
        deleteProject = nil
        Task { @MainActor in
          if await workspace.deleteProject(project.id) {
            await mcp.reloadFromStorage()
            if selectedProjectID == project.id { selectedProjectID = nil }
          }
        }
      }
      Button("Cancel", role: .cancel) { deleteProject = nil }
    } message: {
      Text("Chats in this project will be kept and moved back to standalone chats.")
    }
    .alert(
      "Project Error",
      isPresented: Binding(
        get: { workspace.errorMessage != nil },
        set: { if !$0 { workspace.errorMessage = nil } }
      )
    ) {
      Button("OK") { workspace.errorMessage = nil }
    } message: {
      Text(workspace.errorMessage ?? "Unknown error")
    }
  }

  @ViewBuilder
  private var projectsHome: some View {
    if workspace.projects.isEmpty {
      ContentUnavailableView {
        Label("No Projects", systemImage: "folder")
      } description: {
        Text("Projects keep chats, sources, instructions, defaults, prompts, and tools together.")
      } actions: {
        Button("New Project", systemImage: "plus") { beginNewProject() }
          .buttonStyle(.borderedProminent)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      VStack(spacing: 0) {
        homeToolbar
        Divider()

        ScrollView {
          LazyVStack(spacing: 10) {
            HStack {
              Text("\(visibleProjects.count) project\(visibleProjects.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
              Spacer()
            }
            .padding(.bottom, 2)

            if visibleProjects.isEmpty {
              ContentUnavailableView.search(text: searchText)
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
            } else {
              ForEach(visibleProjects) { project in
                projectCard(project)
              }
            }
          }
          .padding(16)
        }
      }
    }
  }

  private var homeToolbar: some View {
    HStack(spacing: 10) {
      MacProjectSearchField(
        placeholder: "Search projects",
        text: $searchText
      )
      .frame(maxWidth: 360)

      Spacer()

      Button("New Project", systemImage: "plus") { beginNewProject() }
    }
    .padding(.horizontal, 16)
    .frame(height: 54)
    .background(MacDesignTokens.Colors.surface.opacity(0.45))
  }

  private func projectCard(_ project: ChatProject) -> some View {
    HStack(spacing: 14) {
      Button {
        selectedProjectID = project.id
      } label: {
        HStack(spacing: 12) {
          MacProjectWorkspaceIcon(project: project, size: 42)

          VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
              Text(project.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(MacDesignTokens.Colors.textPrimary)
                .lineLimit(1)
              Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
            }

            Text(projectActivitySummary(project))
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
              .lineLimit(1)

            Text(projectProviderSummary(project))
              .font(.caption2)
              .foregroundStyle(MacDesignTokens.Colors.textMuted.opacity(0.85))
              .lineLimit(1)
          }

          Spacer(minLength: 12)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      Button("New Chat", systemImage: "square.and.pencil") {
        startNewChat(project.id, nil)
        dismiss()
      }
      .controlSize(.small)

      Menu {
        Button("Open Project", systemImage: "arrow.right.circle") {
          selectedProjectID = project.id
        }
        Button("New Chat", systemImage: "square.and.pencil") {
          startNewChat(project.id, nil)
          dismiss()
        }
        Divider()
        Button("Delete Project…", systemImage: "trash", role: .destructive) {
          deleteProject = project
        }
      } label: {
        Image(systemName: "ellipsis")
          .frame(width: 28, height: 28)
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help("Project actions")
    }
    .padding(14)
    .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 11))
    .overlay {
      RoundedRectangle(cornerRadius: 11)
        .stroke(MacDesignTokens.Colors.separator.opacity(0.75), lineWidth: 0.5)
    }
    .contextMenu {
      Button("Open Project") { selectedProjectID = project.id }
      Button("New Chat") {
        startNewChat(project.id, nil)
        dismiss()
      }
      Divider()
      Button("Delete Project", role: .destructive) { deleteProject = project }
    }
  }

  private func beginNewProject() {
    guard MacProAccess.requireProjectCapacity(currentCount: workspace.projects.count) else {
      return
    }
    showingNewProject = true
  }

  private func projectActivitySummary(_ project: ChatProject) -> String {
    let chatCount = chats.conversationSummaries.filter {
      workspace.projectID(for: $0.id) == project.id
    }.count
    let sourceCount = project.projectFiles.count
    let toolCount = project.mcpConfiguration?.enabledServerIDs.count ?? 0

    var parts: [String] = []
    parts.append("\(chatCount) chat\(chatCount == 1 ? "" : "s")")
    parts.append("\(sourceCount) source\(sourceCount == 1 ? "" : "s")")
    if toolCount > 0 {
      parts.append("\(toolCount) MCP server\(toolCount == 1 ? "" : "s")")
    }
    return parts.joined(separator: " · ")
  }

  private func projectProviderSummary(_ project: ChatProject) -> String {
    let account: String
    if let accountID = project.accountID {
      account = providers.account(accountID)?.label ?? "Unavailable Account"
    } else {
      account = "App default provider"
    }

    guard let modelID = project.modelID else {
      return project.accountID == nil ? "App defaults" : "\(account) · Account default model"
    }

    let model: String
    if let accountID = project.accountID,
      let record = providers.models(for: accountID, includeHidden: true)
        .first(where: { $0.model.id == modelID })
    {
      model = record.model.displayName
    } else {
      model = modelID.rawValue
    }
    return "\(account) · \(model)"
  }
}

private struct MacProjectWorkspaceDetailView: View {
  let project: ChatProject
  @Bindable var workspace: MacWorkspaceModel
  @Bindable var providers: MacProviderModel
  @Bindable var chats: MacChatSessionModel
  @Bindable var mcp: MacMCPModel
  let back: () -> Void
  let openChat: (ConversationID) -> Void
  let startNewChat: (String?) -> Void
  let requestDelete: () -> Void

  @State private var section: MacProjectWorkspaceSection = .overview

  var body: some View {
    VStack(spacing: 0) {
      detailHeader
      Divider()

      Picker("Section", selection: $section) {
        ForEach(MacProjectWorkspaceSection.allCases) { section in
          Text(section.rawValue).tag(section)
        }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal, 18)
      .padding(.vertical, 12)

      Group {
        switch section {
        case .overview:
          MacProjectOverviewView(
            project: project,
            workspace: workspace,
            providers: providers,
            mcp: mcp,
            startNewChat: startNewChat,
            requestDelete: requestDelete
          )
        case .chats:
          MacProjectChatsWorkspaceView(
            project: project,
            workspace: workspace,
            chats: chats,
            mcp: mcp,
            openChat: openChat,
            startNewChat: { startNewChat(nil) }
          )
        case .sources:
          MacProjectSourcesWorkspaceView(
            project: project,
            workspace: workspace,
            mcp: mcp
          )
        case .tools:
          MacProjectToolsWorkspaceView(
            project: project,
            workspace: workspace,
            mcp: mcp
          )
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(MacDesignTokens.Colors.canvas)
  }

  private var detailHeader: some View {
    HStack(spacing: 12) {
      Button(action: back) {
        Label("All Projects", systemImage: "chevron.left")
      }
      .buttonStyle(.plain)
      .foregroundStyle(MacDesignTokens.Colors.accent)

      Divider()
        .frame(height: 24)

      MacProjectWorkspaceIcon(project: project, size: 40)

      VStack(alignment: .leading, spacing: 2) {
        Text(project.name)
          .font(.title3.weight(.semibold))
          .lineLimit(1)
        Text(projectSummary)
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
      }

      Spacer()

      Button("New Chat", systemImage: "square.and.pencil") {
        startNewChat(nil)
      }

      Menu {
        Button("Overview", systemImage: "rectangle.grid.1x2") { section = .overview }
        Button("Chats", systemImage: "bubble.left.and.bubble.right") { section = .chats }
        Button("Sources", systemImage: "doc.on.doc") { section = .sources }
        Button("Tools", systemImage: "wrench.and.screwdriver") { section = .tools }
        Divider()
        Button("Delete Project…", systemImage: "trash", role: .destructive) {
          requestDelete()
        }
      } label: {
        Image(systemName: "ellipsis")
          .frame(width: 28, height: 28)
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
    }
    .padding(.horizontal, 18)
    .frame(height: 70)
    .background(MacDesignTokens.Colors.surface.opacity(0.45))
  }

  private var projectSummary: String {
    let chatCount = chats.conversationSummaries.filter {
      workspace.projectID(for: $0.id) == project.id
    }.count
    let sourceCount = project.projectFiles.count
    let serverCount = project.mcpConfiguration?.enabledServerIDs.count ?? 0
    return "\(chatCount) chat\(chatCount == 1 ? "" : "s") · \(sourceCount) source\(sourceCount == 1 ? "" : "s") · \(serverCount) MCP server\(serverCount == 1 ? "" : "s")"
  }
}

private struct MacProjectOverviewView: View {
  let project: ChatProject
  @Bindable var workspace: MacWorkspaceModel
  @Bindable var providers: MacProviderModel
  @Bindable var mcp: MacMCPModel
  let startNewChat: (String?) -> Void
  let requestDelete: () -> Void

  @State private var editor: OverviewEditor?
  @State private var promptToEdit: ProjectPromptPreset?
  @State private var showingNewPrompt = false

  private enum OverviewEditor: String, Identifiable {
    case identity
    case defaults
    case instructions
    var id: String { rawValue }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        overviewCard("Project", systemImage: "folder") {
          HStack(spacing: 12) {
            MacProjectWorkspaceIcon(project: project, size: 42)
            VStack(alignment: .leading, spacing: 3) {
              Text(project.name)
                .font(.headline)
              Text(MacProjectAccentOption(rawValue: project.accentID)?.title ?? "Default color")
                .font(.caption)
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
            }
            Spacer()
            Button("Edit") { editor = .identity }
          }
        }

        overviewCard("New Chat Defaults", systemImage: "sparkles") {
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              VStack(alignment: .leading, spacing: 5) {
                MacProjectValueRow(title: "Provider Account", value: accountLabel)
                MacProjectValueRow(title: "Model", value: modelLabel)
              }
              Spacer()
              Button("Edit") { editor = .defaults }
            }
            Text("These defaults apply when a new chat is created. Existing chats keep their current provider and model.")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }
        }

        overviewCard("Instructions", systemImage: "text.alignleft") {
          VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
              let value = project.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
              Text(value.isEmpty ? "App default system prompt." : value)
                .foregroundStyle(
                  value.isEmpty
                    ? MacDesignTokens.Colors.textMuted
                    : MacDesignTokens.Colors.textPrimary
                )
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
              Button("Edit") { editor = .instructions }
            }
          }
        }

        reusablePromptsCard

        VStack(alignment: .leading, spacing: 10) {
          Text("Danger Zone")
            .font(.headline)
          Text("Deleting a project keeps its chats and moves them back to standalone chats.")
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
          Button("Delete Project…", role: .destructive) { requestDelete() }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 11))
        .overlay {
          RoundedRectangle(cornerRadius: 11)
            .stroke(Color.red.opacity(0.25), lineWidth: 0.5)
        }
      }
      .padding(18)
      .frame(maxWidth: 760)
      .frame(maxWidth: .infinity)
    }
    .sheet(item: $editor) { editor in
      switch editor {
      case .identity:
        MacProjectIdentityEditor(
          project: project,
          workspace: workspace,
          mcp: mcp
        )
      case .defaults:
        MacProjectDefaultsEditor(
          project: project,
          workspace: workspace,
          providers: providers,
          mcp: mcp
        )
      case .instructions:
        MacProjectInstructionsEditor(
          project: project,
          workspace: workspace,
          mcp: mcp
        )
      }
    }
    .sheet(isPresented: $showingNewPrompt) {
      MacProjectPromptEditor(existing: nil) { preset in
        savePromptPreset(preset)
      }
    }
    .sheet(item: $promptToEdit) { preset in
      MacProjectPromptEditor(existing: preset) { value in
        savePromptPreset(value)
      }
    }
  }

  private func overviewCard<Content: View>(
    _ title: String,
    systemImage: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(title, systemImage: systemImage)
        .font(.headline)
        .foregroundStyle(MacDesignTokens.Colors.textPrimary)
      content()
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 11))
    .overlay {
      RoundedRectangle(cornerRadius: 11)
        .stroke(MacDesignTokens.Colors.separator.opacity(0.75), lineWidth: 0.5)
    }
  }

  private var reusablePromptsCard: some View {
    overviewCard("Reusable Prompts", systemImage: "text.badge.plus") {
      VStack(spacing: 8) {
        if project.projectPromptPresets.isEmpty {
          HStack {
            Text("No reusable prompts yet.")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
            Spacer()
            Button("Add Prompt", systemImage: "plus") { showingNewPrompt = true }
          }
        } else {
          ForEach(project.projectPromptPresets) { preset in
            HStack(alignment: .top, spacing: 10) {
              VStack(alignment: .leading, spacing: 3) {
                Text(preset.name)
                  .font(.system(size: 13.5, weight: .medium))
                Text(preset.prompt)
                  .font(.caption)
                  .foregroundStyle(MacDesignTokens.Colors.textMuted)
                  .lineLimit(2)
              }
              Spacer()
              Button("Use") { startNewChat(preset.prompt) }
              Menu {
                Button("Edit", systemImage: "pencil") { promptToEdit = preset }
                Button("Delete", systemImage: "trash", role: .destructive) {
                  deletePromptPreset(preset)
                }
              } label: {
                Image(systemName: "ellipsis")
              }
              .menuStyle(.borderlessButton)
              .fixedSize()
            }
            .padding(.vertical, 3)
          }

          HStack {
            Spacer()
            Button("Add Prompt", systemImage: "plus") { showingNewPrompt = true }
          }
        }
      }
    }
  }

  private var accountLabel: String {
    guard let accountID = project.accountID else { return "App Default" }
    return providers.account(accountID)?.label ?? "Unavailable Account"
  }

  private var modelLabel: String {
    guard let modelID = project.modelID else { return "Account Default" }
    if let accountID = project.accountID,
      let record = providers.models(for: accountID, includeHidden: true)
        .first(where: { $0.model.id == modelID })
    {
      return record.model.displayName
    }
    return modelID.rawValue
  }

  private func savePromptPreset(_ value: ProjectPromptPreset) {
    Task { @MainActor in
      if await workspace.upsertProjectPromptPreset(value, projectID: project.id) {
        await mcp.reloadFromStorage()
      }
    }
  }

  private func deletePromptPreset(_ preset: ProjectPromptPreset) {
    Task { @MainActor in
      if await workspace.deleteProjectPromptPreset(preset.id, projectID: project.id) {
        await mcp.reloadFromStorage()
      }
    }
  }
}

private struct MacProjectChatsWorkspaceView: View {
  let project: ChatProject
  @Bindable var workspace: MacWorkspaceModel
  @Bindable var chats: MacChatSessionModel
  @Bindable var mcp: MacMCPModel
  let openChat: (ConversationID) -> Void
  let startNewChat: () -> Void

  @State private var searchText = ""

  private var memberConversations: [ChatConversation] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let values = chats.conversationSummaries.filter {
      workspace.projectID(for: $0.id) == project.id
    }
    guard !query.isEmpty else { return values.sorted { $0.updatedAt > $1.updatedAt } }
    return values.filter { conversation in
      conversationTitle(conversation).localizedCaseInsensitiveContains(query)
        || (conversation.lastMessagePreview?.localizedCaseInsensitiveContains(query) ?? false)
    }
    .sorted { $0.updatedAt > $1.updatedAt }
  }

  private var otherConversations: [ChatConversation] {
    chats.conversationSummaries
      .filter { workspace.projectID(for: $0.id) != project.id }
      .sorted { $0.updatedAt > $1.updatedAt }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        MacProjectSearchField(placeholder: "Search chats", text: $searchText)
          .frame(maxWidth: 340)
        Spacer()
        if !otherConversations.isEmpty {
          Menu("Add Existing", systemImage: "folder.badge.plus") {
            ForEach(otherConversations) { conversation in
              Button(conversationTitle(conversation)) {
                Task { @MainActor in
                  if await workspace.assignConversation(conversation.id, to: project.id) {
                    await mcp.reloadFromStorage()
                  }
                }
              }
            }
          }
          .fixedSize()
        }
        Button("New Chat", systemImage: "plus") { startNewChat() }
      }
      .padding(.horizontal, 16)
      .frame(height: 52)

      Divider()

      if memberConversations.isEmpty {
        ContentUnavailableView {
          Label(searchText.isEmpty ? "No Chats Yet" : "No Matches", systemImage: "bubble.left.and.bubble.right")
        } description: {
          Text(
            searchText.isEmpty
              ? "New chats here use \(project.name) defaults and instructions."
              : "Try a different search."
          )
        } actions: {
          if searchText.isEmpty {
            Button("New Chat") { startNewChat() }
              .buttonStyle(.borderedProminent)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 16) {
            HStack {
              Text("\(memberConversations.count) chat\(memberConversations.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
              Spacer()
            }

            ForEach(MacProjectChatDateGrouper.sections(for: memberConversations), id: \.title) { section in
              VStack(alignment: .leading, spacing: 7) {
                Text(section.title.uppercased())
                  .font(.caption2.weight(.semibold))
                  .tracking(0.5)
                  .foregroundStyle(MacDesignTokens.Colors.textMuted)

                VStack(spacing: 0) {
                  ForEach(Array(section.conversations.enumerated()), id: \.element.id) { index, conversation in
                    conversationRow(conversation)
                    if index != section.conversations.count - 1 {
                      Divider().padding(.leading, 46)
                    }
                  }
                }
                .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                  RoundedRectangle(cornerRadius: 10)
                    .stroke(MacDesignTokens.Colors.separator.opacity(0.7), lineWidth: 0.5)
                }
              }
            }
          }
          .padding(16)
        }
      }
    }
  }

  private func conversationRow(_ conversation: ChatConversation) -> some View {
    Button {
      openChat(conversation.id)
    } label: {
      HStack(spacing: 10) {
        Image(systemName: "bubble.left")
          .foregroundStyle(MacDesignTokens.Colors.accent)
          .frame(width: 24)

        VStack(alignment: .leading, spacing: 3) {
          Text(conversationTitle(conversation))
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(MacDesignTokens.Colors.textPrimary)
            .lineLimit(1)
          Text(conversationPreview(conversation))
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
            .lineLimit(1)
        }

        Spacer()

        Text(conversation.updatedAt, format: .dateTime.month(.abbreviated).day())
          .font(.caption2)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)

        Image(systemName: "chevron.right")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(MacDesignTokens.Colors.textMuted.opacity(0.8))
      }
      .padding(.horizontal, 12)
      .frame(minHeight: 54)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .contextMenu {
      Button("Open", systemImage: "arrow.up.forward.app") { openChat(conversation.id) }
      Button("Remove from Project", systemImage: "folder.badge.minus") {
        Task { @MainActor in
          if await workspace.removeConversation(conversation.id) {
            await mcp.reloadFromStorage()
          }
        }
      }
    }
  }

  private func conversationTitle(_ conversation: ChatConversation) -> String {
    let title = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? "New Chat" : title
  }

  private func conversationPreview(_ conversation: ChatConversation) -> String {
    if let preview = conversation.lastMessagePreview?.trimmingCharacters(in: .whitespacesAndNewlines),
      !preview.isEmpty
    {
      return preview
    }
    return "\(conversation.messageCount) messages"
  }
}

private struct MacProjectSourcesWorkspaceView: View {
  let project: ChatProject
  @Bindable var workspace: MacWorkspaceModel
  @Bindable var mcp: MacMCPModel

  @State private var searchText = ""
  @State private var showingImporter = false
  @State private var isWorking = false

  private var visibleFiles: [ProjectFile] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return project.projectFiles }
    return project.projectFiles.filter { file in
      file.filename.localizedCaseInsensitiveContains(query)
        || file.mimeType.localizedCaseInsensitiveContains(query)
    }
  }

  private var totalBytes: Int {
    project.projectFiles.reduce(0) { $0 + $1.byteCount }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        MacProjectSearchField(placeholder: "Search sources", text: $searchText)
          .frame(maxWidth: 340)
        Spacer()
        Button("Add Files", systemImage: "doc.badge.plus") { showingImporter = true }
          .disabled(project.projectFiles.count >= 8 || isWorking || workspace.isBusy)
      }
      .padding(.horizontal, 16)
      .frame(height: 52)

      Divider()

      if project.projectFiles.isEmpty {
        ContentUnavailableView {
          Label("No Sources", systemImage: "doc.on.doc")
        } description: {
          Text("Add reference files that can be attached to chats in this project when needed.")
        } actions: {
          Button("Add Files", systemImage: "plus") { showingImporter = true }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if visibleFiles.isEmpty {
        ContentUnavailableView.search(text: searchText)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        VStack(spacing: 0) {
          HStack {
            Text("\(project.projectFiles.count) source\(project.projectFiles.count == 1 ? "" : "s") · \(formattedTotalBytes)")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
            Spacer()
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 10)

          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(Array(visibleFiles.enumerated()), id: \.element.id) { index, file in
                sourceRow(file)
                if index != visibleFiles.count - 1 {
                  Divider().padding(.leading, 54)
                }
              }
            }
            .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
              RoundedRectangle(cornerRadius: 10)
                .stroke(MacDesignTokens.Colors.separator.opacity(0.7), lineWidth: 0.5)
            }
            .padding(.horizontal, 16)
          }

          Divider()

          HStack {
            Text("\(project.projectFiles.count) of 8 files · \(formattedTotalBytes) of 40 MB")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
            Spacer()
          }
          .padding(.horizontal, 16)
          .frame(height: 42)
          .background(MacDesignTokens.Colors.surface.opacity(0.45))
        }
      }
    }
    .fileImporter(
      isPresented: $showingImporter,
      allowedContentTypes: [.item],
      allowsMultipleSelection: true
    ) { result in
      importFiles(result)
    }
  }

  private func sourceRow(_ file: ProjectFile) -> some View {
    HStack(spacing: 12) {
      Image(systemName: file.mimeType.hasPrefix("image/") ? "photo" : "doc.fill")
        .foregroundStyle(MacDesignTokens.Colors.accent)
        .frame(width: 30, height: 30)
        .background(MacDesignTokens.Colors.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))

      VStack(alignment: .leading, spacing: 3) {
        Text(file.filename)
          .font(.system(size: 13.5, weight: .medium))
          .lineLimit(1)
        Text("\(sourceType(file)) · \(macProjectFileDetail(file))")
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
          .lineLimit(1)
      }

      Spacer()

      Menu {
        Button("Remove from Project", systemImage: "trash", role: .destructive) {
          remove(file)
        }
      } label: {
        Image(systemName: "ellipsis")
          .frame(width: 28, height: 28)
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
    }
    .padding(.horizontal, 12)
    .frame(minHeight: 56)
    .contextMenu {
      Button("Remove from Project", role: .destructive) { remove(file) }
    }
  }

  private var formattedTotalBytes: String {
    ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
  }

  private func sourceType(_ file: ProjectFile) -> String {
    if file.mimeType.hasPrefix("image/") { return "Image" }
    if file.mimeType.lowercased().contains("pdf") { return "PDF" }
    let ext = (file.filename as NSString).pathExtension
    return ext.isEmpty ? "File" : ext.uppercased()
  }

  private func remove(_ file: ProjectFile) {
    Task { @MainActor in
      if await workspace.removeProjectFile(file.id, from: project.id) {
        await mcp.reloadFromStorage()
      }
    }
  }

  private func importFiles(_ result: Result<[URL], Error>) {
    switch result {
    case .failure(let error):
      workspace.errorMessage = error.localizedDescription
    case .success(let urls):
      guard !urls.isEmpty else { return }
      isWorking = true
      Task { @MainActor in
        defer { isWorking = false }
        do {
          var additions: [ProjectFile] = []
          for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }

            let values = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
            if let fileSize = values.fileSize, fileSize > 20 * 1_024 * 1_024 {
              throw ProviderError.invalidRequest("\(url.lastPathComponent) is larger than 20 MB.")
            }

            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count <= 20 * 1_024 * 1_024 else {
              throw ProviderError.invalidRequest("\(url.lastPathComponent) is larger than 20 MB.")
            }
            let type = values.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
            additions.append(
              ProjectFile(
                filename: url.lastPathComponent,
                mimeType: type.preferredMIMEType ?? "application/octet-stream",
                data: data
              )
            )
          }

          if await workspace.addProjectFiles(additions, to: project.id) {
            await mcp.reloadFromStorage()
          }
        } catch {
          workspace.errorMessage = error.localizedDescription
        }
      }
    }
  }
}

private struct MacProjectToolsWorkspaceView: View {
  let project: ChatProject
  @Bindable var workspace: MacWorkspaceModel
  @Bindable var mcp: MacMCPModel

  @State private var configuration: MCPChatToolConfiguration
  @State private var presets: [ProjectToolPreset]
  @State private var showingSavePreset = false
  @State private var isSaving = false

  init(
    project: ChatProject,
    workspace: MacWorkspaceModel,
    mcp: MacMCPModel
  ) {
    self.project = project
    self.workspace = workspace
    self.mcp = mcp
    _configuration = State(initialValue: project.mcpConfiguration ?? MCPChatToolConfiguration())
    _presets = State(initialValue: project.projectToolPresets)
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Project Tool Defaults")
            .font(.headline)
          Text("Chats inherit these MCP servers and permissions until that chat creates its own override.")
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }
        Spacer()
        Button("Save Changes") { saveChanges() }
          .disabled(isSaving || workspace.isBusy)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)

      Divider()

      HStack(spacing: 0) {
        MacProjectToolsConfigurationView(mcp: mcp, configuration: $configuration)
          .frame(maxWidth: .infinity, maxHeight: .infinity)

        Divider()

        toolPresets
          .frame(width: 250)
      }
    }
    .sheet(isPresented: $showingSavePreset) {
      MacProjectToolPresetNameSheet { name in
        savePreset(named: name)
      }
    }
    .onChange(of: project.id) { _, _ in
      configuration = project.mcpConfiguration ?? MCPChatToolConfiguration()
      presets = project.projectToolPresets
    }
  }

  private var toolPresets: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Tool Presets")
          .font(.headline)
        Spacer()
        Button {
          showingSavePreset = true
        } label: {
          Image(systemName: "plus")
        }
        .buttonStyle(.plain)
        .help("Save current configuration as preset")
      }

      Text("Quickly replace the current project tool defaults with a saved configuration.")
        .font(.caption)
        .foregroundStyle(MacDesignTokens.Colors.textMuted)

      if presets.isEmpty {
        ContentUnavailableView(
          "No Presets",
          systemImage: "slider.horizontal.3",
          description: Text("Save the current tool configuration to reuse it later.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(spacing: 8) {
            ForEach(presets) { preset in
              VStack(alignment: .leading, spacing: 7) {
                Text(preset.name)
                  .font(.system(size: 13.5, weight: .medium))
                Text(toolPresetSummary(preset))
                  .font(.caption)
                  .foregroundStyle(MacDesignTokens.Colors.textMuted)
                HStack {
                  Button("Apply") { configuration = preset.configuration }
                  Spacer()
                  Button(role: .destructive) {
                    presets.removeAll { $0.id == preset.id }
                  } label: {
                    Image(systemName: "trash")
                  }
                  .buttonStyle(.plain)
                  .help("Delete preset")
                }
              }
              .padding(10)
              .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 9))
              .overlay {
                RoundedRectangle(cornerRadius: 9)
                  .stroke(MacDesignTokens.Colors.separator.opacity(0.7), lineWidth: 0.5)
              }
            }
          }
        }
      }

      Button("Save Current as Preset…", systemImage: "plus") {
        showingSavePreset = true
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(14)
    .background(MacDesignTokens.Colors.canvas)
  }

  private func savePreset(named rawName: String) {
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    if let index = presets.firstIndex(where: {
      $0.name.caseInsensitiveCompare(name) == .orderedSame
    }) {
      presets[index].name = name
      presets[index].configuration = configuration
    } else {
      presets.append(ProjectToolPreset(name: name, configuration: configuration))
    }
  }

  private func saveChanges() {
    isSaving = true
    Task { @MainActor in
      defer { isSaving = false }
      if await workspace.replaceProjectToolSettings(
        id: project.id,
        mcpConfiguration: configuration,
        toolPresets: presets
      ) {
        await mcp.reloadFromStorage()
      }
    }
  }

  private func toolPresetSummary(_ preset: ProjectToolPreset) -> String {
    let count = preset.configuration.enabledServerIDs.count
    return "\(count) server\(count == 1 ? "" : "s")"
  }
}

private struct MacProjectCreateSheet: View {
  @Bindable var workspace: MacWorkspaceModel
  @Bindable var providers: MacProviderModel
  let created: (ProjectID) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var symbolName = "folder.fill"
  @State private var accentID = "blue"
  @State private var accountID: ProviderAccountID?
  @State private var modelID: ModelID?
  @State private var isSaving = false

  private let symbols = MacProjectWorkspaceEditorSupport.symbols

  private var enabledAccounts: [ProviderAccount] {
    providers.accounts.filter(\.isEnabled)
  }

  private var availableModels: [AccountModelRecord] {
    guard let accountID else { return [] }
    return providers.models(for: accountID).filter(\.isAvailable)
  }

  private var canCreate: Bool {
    !isSaving && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    VStack(spacing: 0) {
      MacProjectSheetHeader(
        title: "New Project",
        primaryTitle: "Create",
        primaryEnabled: canCreate,
        cancel: { dismiss() },
        primary: create
      )

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          HStack(spacing: 14) {
            Image(systemName: symbolName)
              .font(.system(size: 22, weight: .semibold))
              .foregroundStyle(selectedAccent)
              .frame(width: 52, height: 52)
              .background(selectedAccent.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))

            TextField("Project name", text: $name)
              .textFieldStyle(.roundedBorder)
          }

          VStack(alignment: .leading, spacing: 8) {
            Text("Icon")
              .font(.caption.weight(.semibold))
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 8) {
              ForEach(symbols, id: \.self) { symbol in
                Button {
                  symbolName = symbol
                } label: {
                  Image(systemName: symbol)
                    .frame(width: 34, height: 30)
                    .background(
                      symbolName == symbol ? selectedAccent.opacity(0.14) : Color.clear,
                      in: RoundedRectangle(cornerRadius: 7)
                    )
                }
                .buttonStyle(.plain)
              }
            }
          }

          VStack(alignment: .leading, spacing: 8) {
            Text("Color")
              .font(.caption.weight(.semibold))
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
            HStack(spacing: 10) {
              ForEach(MacProjectAccentOption.allCases) { option in
                Button {
                  accentID = option.rawValue
                } label: {
                  Circle()
                    .fill(option.color)
                    .frame(width: 20, height: 20)
                    .overlay {
                      if accentID == option.rawValue {
                        Circle().stroke(Color.primary, lineWidth: 2).padding(-3)
                      }
                    }
                }
                .buttonStyle(.plain)
                .help(option.title)
              }
            }
          }

          Divider()

          VStack(alignment: .leading, spacing: 10) {
            Text("New Chat Defaults")
              .font(.headline)

            Picker("Provider Account", selection: $accountID) {
              Text("App Default").tag(nil as ProviderAccountID?)
              ForEach(enabledAccounts) { account in
                Text(account.label).tag(Optional(account.id))
              }
            }

            if accountID != nil {
              Picker("Model", selection: $modelID) {
                Text("Account Default").tag(nil as ModelID?)
                ForEach(availableModels) { record in
                  Text(record.model.displayName).tag(Optional(record.model.id))
                }
              }
            }
          }

          Text("Instructions, sources, reusable prompts, and tool defaults can be configured after the project is created.")
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }
        .padding(20)
      }
    }
    .frame(width: 520, height: 500)
    .background(MacDesignTokens.Colors.canvas)
    .onChange(of: accountID) { _, value in
      guard let value else {
        modelID = nil
        return
      }
      if let modelID,
        !providers.models(for: value).contains(where: {
          $0.model.id == modelID && $0.isAvailable
        })
      {
        self.modelID = nil
      }
    }
  }

  private var selectedAccent: Color {
    MacProjectAccentOption(rawValue: accentID)?.color ?? .blue
  }

  private func create() {
    guard canCreate else { return }
    isSaving = true
    Task { @MainActor in
      defer { isSaving = false }
      if let projectID = await workspace.createProject(
        name: name,
        symbolName: symbolName,
        accentID: accentID,
        accountID: accountID,
        modelID: modelID,
        instructions: "",
        files: [],
        mcpConfiguration: MCPChatToolConfiguration(),
        promptPresets: [],
        toolPresets: []
      ) {
        created(projectID)
        dismiss()
      }
    }
  }
}

private struct MacProjectIdentityEditor: View {
  let project: ChatProject
  @Bindable var workspace: MacWorkspaceModel
  @Bindable var mcp: MacMCPModel

  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var symbolName: String
  @State private var accentID: String
  @State private var isSaving = false

  init(project: ChatProject, workspace: MacWorkspaceModel, mcp: MacMCPModel) {
    self.project = project
    self.workspace = workspace
    self.mcp = mcp
    _name = State(initialValue: project.name)
    _symbolName = State(initialValue: project.symbolName)
    _accentID = State(initialValue: project.accentID)
  }

  var body: some View {
    VStack(spacing: 0) {
      MacProjectSheetHeader(
        title: "Project",
        primaryTitle: "Save",
        primaryEnabled: !isSaving && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        cancel: { dismiss() },
        primary: save
      )
      Divider()
      Form {
        TextField("Name", text: $name)
        Picker("Icon", selection: $symbolName) {
          ForEach(MacProjectWorkspaceEditorSupport.symbols, id: \.self) { symbol in
            Label(MacProjectWorkspaceEditorSupport.symbolTitle(symbol), systemImage: symbol).tag(symbol)
          }
        }
        Picker("Color", selection: $accentID) {
          ForEach(MacProjectAccentOption.allCases) { option in
            Label {
              Text(option.title)
            } icon: {
              Image(systemName: "circle.fill").foregroundStyle(option.color)
            }
            .tag(option.rawValue)
          }
        }
      }
      .formStyle(.grouped)
      .padding(10)
    }
    .frame(width: 480, height: 330)
  }

  private func save() {
    isSaving = true
    Task { @MainActor in
      defer { isSaving = false }
      if await workspace.updateProjectIdentity(
        id: project.id,
        name: name,
        symbolName: symbolName,
        accentID: accentID
      ) {
        await mcp.reloadFromStorage()
        dismiss()
      }
    }
  }
}

private struct MacProjectDefaultsEditor: View {
  let project: ChatProject
  @Bindable var workspace: MacWorkspaceModel
  @Bindable var providers: MacProviderModel
  @Bindable var mcp: MacMCPModel

  @Environment(\.dismiss) private var dismiss
  @State private var accountID: ProviderAccountID?
  @State private var modelID: ModelID?
  @State private var isSaving = false

  init(
    project: ChatProject,
    workspace: MacWorkspaceModel,
    providers: MacProviderModel,
    mcp: MacMCPModel
  ) {
    self.project = project
    self.workspace = workspace
    self.providers = providers
    self.mcp = mcp
    _accountID = State(initialValue: project.accountID)
    _modelID = State(initialValue: project.modelID)
  }

  private var enabledAccounts: [ProviderAccount] {
    providers.accounts.filter(\.isEnabled)
  }

  private var availableModels: [AccountModelRecord] {
    guard let accountID else { return [] }
    return providers.models(for: accountID).filter(\.isAvailable)
  }

  var body: some View {
    VStack(spacing: 0) {
      MacProjectSheetHeader(
        title: "New Chat Defaults",
        primaryTitle: "Save",
        primaryEnabled: !isSaving,
        cancel: { dismiss() },
        primary: save
      )
      Divider()
      Form {
        Picker("Provider Account", selection: $accountID) {
          Text("App Default").tag(nil as ProviderAccountID?)
          ForEach(enabledAccounts) { account in
            Text(account.label).tag(Optional(account.id))
          }
        }
        if accountID != nil {
          Picker("Model", selection: $modelID) {
            Text("Account Default").tag(nil as ModelID?)
            ForEach(availableModels) { record in
              Text(record.model.displayName).tag(Optional(record.model.id))
            }
          }
        }
        Text("Changes apply to new chats. Existing chats keep their current provider and model.")
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
      }
      .formStyle(.grouped)
      .padding(10)
    }
    .frame(width: 520, height: 320)
    .onChange(of: accountID) { _, value in
      guard let value else {
        modelID = nil
        return
      }
      if let modelID,
        !providers.models(for: value).contains(where: {
          $0.model.id == modelID && $0.isAvailable
        })
      {
        self.modelID = nil
      }
    }
  }

  private func save() {
    isSaving = true
    Task { @MainActor in
      defer { isSaving = false }
      if await workspace.updateProjectDefaults(
        id: project.id,
        accountID: accountID,
        modelID: modelID
      ) {
        await mcp.reloadFromStorage()
        dismiss()
      }
    }
  }
}

private struct MacProjectInstructionsEditor: View {
  let project: ChatProject
  @Bindable var workspace: MacWorkspaceModel
  @Bindable var mcp: MacMCPModel

  @Environment(\.dismiss) private var dismiss
  @State private var instructions: String
  @State private var isSaving = false

  init(project: ChatProject, workspace: MacWorkspaceModel, mcp: MacMCPModel) {
    self.project = project
    self.workspace = workspace
    self.mcp = mcp
    _instructions = State(initialValue: project.instructions)
  }

  var body: some View {
    VStack(spacing: 0) {
      MacProjectSheetHeader(
        title: "Project Instructions",
        primaryTitle: "Save",
        primaryEnabled: !isSaving,
        cancel: { dismiss() },
        primary: save
      )
      Divider()
      VStack(alignment: .leading, spacing: 10) {
        TextEditor(text: $instructions)
          .font(.body)
          .padding(8)
          .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 8))
          .overlay {
            RoundedRectangle(cornerRadius: 8)
              .stroke(MacDesignTokens.Colors.separator.opacity(0.75), lineWidth: 0.5)
          }
        Text("Used as the system prompt for new chats in this project. Leave blank to use the app default system prompt.")
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
      }
      .padding(16)
    }
    .frame(width: 600, height: 420)
  }

  private func save() {
    isSaving = true
    Task { @MainActor in
      defer { isSaving = false }
      if await workspace.updateProjectInstructions(id: project.id, instructions: instructions) {
        await mcp.reloadFromStorage()
        dismiss()
      }
    }
  }
}

private struct MacProjectPromptEditor: View {
  let existing: ProjectPromptPreset?
  let save: (ProjectPromptPreset) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var prompt: String

  init(existing: ProjectPromptPreset?, save: @escaping (ProjectPromptPreset) -> Void) {
    self.existing = existing
    self.save = save
    _name = State(initialValue: existing?.name ?? "")
    _prompt = State(initialValue: existing?.prompt ?? "")
  }

  var body: some View {
    VStack(spacing: 0) {
      MacProjectSheetHeader(
        title: existing == nil ? "New Prompt" : "Edit Prompt",
        primaryTitle: "Save",
        primaryEnabled: canSave,
        cancel: { dismiss() },
        primary: saveValue
      )
      Divider()
      VStack(alignment: .leading, spacing: 12) {
        TextField("Name", text: $name)
        TextEditor(text: $prompt)
          .frame(minHeight: 190)
          .padding(8)
          .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 8))
          .overlay {
            RoundedRectangle(cornerRadius: 8)
              .stroke(MacDesignTokens.Colors.separator.opacity(0.75), lineWidth: 0.5)
          }
      }
      .padding(16)
    }
    .frame(width: 520, height: 360)
  }

  private var canSave: Bool {
    !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func saveValue() {
    guard canSave else { return }
    save(
      ProjectPromptPreset(
        id: existing?.id ?? UUID().uuidString.lowercased(),
        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
        prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines)
      )
    )
    dismiss()
  }
}

private struct MacProjectToolPresetNameSheet: View {
  let save: (String) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var name = ""

  var body: some View {
    VStack(spacing: 0) {
      MacProjectSheetHeader(
        title: "Save Tool Preset",
        primaryTitle: "Save",
        primaryEnabled: !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        cancel: { dismiss() },
        primary: saveValue
      )
      Divider()
      VStack(alignment: .leading, spacing: 10) {
        TextField("Preset name", text: $name)
        Text("Saving with an existing preset name replaces that preset.")
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
      }
      .padding(16)
    }
    .frame(width: 420, height: 180)
  }

  private func saveValue() {
    let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    save(value)
    dismiss()
  }
}

private struct MacProjectWorkspaceIcon: View {
  let project: ChatProject
  var size: CGFloat = 34

  private var color: Color {
    MacProjectAccentOption(rawValue: project.accentID)?.color ?? .blue
  }

  var body: some View {
    Image(systemName: project.symbolName)
      .font(.system(size: size * 0.45, weight: .semibold))
      .foregroundStyle(color)
      .frame(width: size, height: size)
      .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.3))
      .accessibilityHidden(true)
  }
}

private struct MacProjectValueRow: View {
  let title: String
  let value: String

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title)
        .font(.caption)
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
        .frame(width: 120, alignment: .leading)
      Text(value)
        .font(.system(size: 13.5, weight: .medium))
        .foregroundStyle(MacDesignTokens.Colors.textPrimary)
    }
  }
}

private struct MacProjectSearchField: View {
  let placeholder: String
  @Binding var text: String

  var body: some View {
    HStack(spacing: 7) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
      TextField(placeholder, text: $text)
        .textFieldStyle(.plain)
      if !text.isEmpty {
        Button {
          text = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear search")
      }
    }
    .padding(.horizontal, 10)
    .frame(height: 30)
    .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 7))
    .overlay {
      RoundedRectangle(cornerRadius: 7)
        .stroke(MacDesignTokens.Colors.separator.opacity(0.75), lineWidth: 0.5)
    }
  }
}

private struct MacProjectSheetHeader: View {
  let title: String
  let primaryTitle: String
  let primaryEnabled: Bool
  let cancel: () -> Void
  let primary: () -> Void

  var body: some View {
    HStack {
      Text(title)
        .font(.headline)
      Spacer()
      Button("Cancel", action: cancel)
        .keyboardShortcut(.cancelAction)
      Button(primaryTitle, action: primary)
        .keyboardShortcut(.defaultAction)
        .disabled(!primaryEnabled)
    }
    .padding(.horizontal, 16)
    .frame(height: 52)
    .background(MacDesignTokens.Colors.surface)
  }
}

private enum MacProjectWorkspaceEditorSupport {
  static let symbols = [
    "folder.fill",
    "briefcase.fill",
    "hammer.fill",
    "terminal.fill",
    "doc.text.fill",
    "lightbulb.fill",
    "paintbrush.fill",
    "shippingbox.fill",
  ]

  static func symbolTitle(_ symbol: String) -> String {
    switch symbol {
    case "folder.fill": "Folder"
    case "briefcase.fill": "Work"
    case "hammer.fill": "Build"
    case "terminal.fill": "Code"
    case "doc.text.fill": "Writing"
    case "lightbulb.fill": "Ideas"
    case "paintbrush.fill": "Creative"
    case "shippingbox.fill": "Product"
    default: "Project"
    }
  }
}
