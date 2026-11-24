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
                MacProjectValueRow(
                  title: "Provider Account",
                  value: accountStatus.label,
                  valueColor: accountStatus.isUnavailable ? Color.orange : nil
                )
                MacProjectValueRow(
                  title: "Model",
                  value: modelStatus.label,
                  valueColor: modelStatus.isUnavailable ? Color.orange : nil
                )
              }
              Spacer()
              Button("Edit") { editor = .defaults }
            }
            if accountStatus.isUnavailable || modelStatus.isUnavailable {
              Label(
                "One or more saved defaults are no longer available. Edit defaults to choose an active provider account or model.",
                systemImage: "exclamationmark.triangle.fill"
              )
              .font(.caption)
              .foregroundStyle(.orange)
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
      let existingNames = Set(
        project.projectPromptPresets.map {
          $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
      )
      MacProjectPromptEditor(
        existing: nil,
        existingNames: existingNames,
        atLimit: project.projectPromptPresets.count >= ProjectWorkspaceStore.maxPresetCount
      ) { preset in
        savePromptPreset(preset)
      }
    }
    .sheet(item: $promptToEdit) { preset in
      let otherNames = Set(
        project.projectPromptPresets
          .filter { $0.id != preset.id }
          .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
      )
      MacProjectPromptEditor(
        existing: preset,
        existingNames: otherNames
      ) { value in
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
    let atPromptLimit = project.projectPromptPresets.count >= ProjectWorkspaceStore.maxPresetCount
    return overviewCard("Reusable Prompts", systemImage: "text.badge.plus") {
      VStack(spacing: 8) {
        if project.projectPromptPresets.isEmpty {
          HStack {
            Text("No reusable prompts yet.")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
            Spacer()
            Button("Add Prompt", systemImage: "plus") { showingNewPrompt = true }
              .disabled(atPromptLimit)
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
            if atPromptLimit {
              Text("Maximum of \(ProjectWorkspaceStore.maxPresetCount) reusable prompts reached.")
                .font(.caption)
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
            }
            Spacer()
            Button("Add Prompt", systemImage: "plus") { showingNewPrompt = true }
              .disabled(atPromptLimit)
          }
        }
      }
    }
  }

  private var accountStatus: (label: String, isUnavailable: Bool) {
    guard let accountID = project.accountID else { return ("App Default", false) }
    guard let account = providers.account(accountID) else {
      return ("Unavailable Account", true)
    }
    if !account.isEnabled {
      return ("\(account.label) (Disabled)", true)
    }
    return (account.label, false)
  }

  private var modelStatus: (label: String, isUnavailable: Bool) {
    guard let modelID = project.modelID else { return ("Account Default", false) }
    guard let accountID = project.accountID else { return ("\(modelID.rawValue) (Unavailable)", true) }
    if let record = providers.models(for: accountID, includeHidden: true)
      .first(where: { $0.model.id == modelID })
    {
      if record.isAvailable {
        return (record.model.displayName, false)
      }
      return ("\(record.model.displayName) (Unavailable)", true)
    }
    return ("\(modelID.rawValue) (Unavailable)", true)
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
  @State private var renameTarget: ChatConversation?
  @State private var deleteTarget: ChatConversation?

  private var otherProjects: [ChatProject] {
    workspace.projects.filter { $0.id != project.id }
  }

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
    .sheet(item: $renameTarget) { conversation in
      MacProjectChatRenameSheet(conversation: conversation) { newTitle in
        let renamed = await chats.renameConversation(conversation.id, title: newTitle)
        if !renamed, let error = chats.errorMessage {
          workspace.errorMessage = error
          chats.errorMessage = nil
        }
        return renamed
      }
    }
    .confirmationDialog(
      deleteTarget.map { "Delete \"\(conversationTitle($0))\"?" } ?? "Delete conversation?",
      isPresented: Binding(
        get: { deleteTarget != nil },
        set: { if !$0 { deleteTarget = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete Conversation", role: .destructive) {
        guard let target = deleteTarget else { return }
        deleteTarget = nil
        deleteConversation(target.id)
      }
      Button("Cancel", role: .cancel) {
        deleteTarget = nil
      }
    } message: {
      Text("This removes the conversation and its chat-specific project/tool references. This cannot be undone.")
    }
  }

  private func conversationRow(_ conversation: ChatConversation) -> some View {
    HStack(spacing: 8) {
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
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      Menu {
        conversationActions(conversation)
      } label: {
        Image(systemName: "ellipsis")
          .frame(width: 28, height: 28)
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help("Chat actions")
    }
    .padding(.horizontal, 12)
    .frame(minHeight: 54)
    .contextMenu {
      conversationActions(conversation)
    }
  }

  @ViewBuilder
  private func conversationActions(_ conversation: ChatConversation) -> some View {
    Button("Open", systemImage: "arrow.up.forward.app") {
      openChat(conversation.id)
    }
    Button("Rename…", systemImage: "pencil") {
      renameTarget = conversation
    }
    if !otherProjects.isEmpty {
      Menu("Move to Project", systemImage: "folder.badge.plus") {
        ForEach(otherProjects) { targetProject in
          Button(targetProject.name) {
            moveConversation(conversation.id, to: targetProject.id)
          }
        }
      }
    }
    Button("Remove from Project", systemImage: "folder.badge.minus") {
      removeConversation(conversation.id)
    }
    Divider()
    Button("Delete…", systemImage: "trash", role: .destructive) {
      deleteTarget = conversation
    }
  }

  private func moveConversation(_ conversationID: ConversationID, to targetProjectID: ProjectID) {
    Task { @MainActor in
      if await workspace.assignConversation(conversationID, to: targetProjectID) {
        await mcp.reloadFromStorage()
      }
    }
  }

  private func removeConversation(_ conversationID: ConversationID) {
    Task { @MainActor in
      if await workspace.removeConversation(conversationID) {
        await mcp.reloadFromStorage()
      }
    }
  }

  private func deleteConversation(_ conversationID: ConversationID) {
    Task { @MainActor in
      let deleted = await chats.deleteConversation(conversationID)
      if let error = chats.errorMessage {
        workspace.errorMessage = error
        chats.errorMessage = nil
      }
      if deleted {
        await workspace.reload()
        await mcp.reloadFromStorage()
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
  @State private var previewFile: ProjectFile?
  @State private var previewURL: URL?
  @State private var previewLoadingID: String?
  @State private var previewRequestID = UUID()
  @State private var showingPreview = false

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
          .disabled(
            project.projectFiles.count >= ProjectWorkspaceStore.maxFileCount
              || isWorking
              || workspace.isBusy
          )
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
            Text(
              "\(project.projectFiles.count) of \(ProjectWorkspaceStore.maxFileCount) files · \(formattedTotalBytes) of 40 MB"
            )
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
    .onChange(of: project.id) { _, _ in
      showingPreview = false
      cleanupPreview()
      previewFile = nil
    }
    .onDisappear {
      cleanupPreview()
    }
    .fileImporter(
      isPresented: $showingImporter,
      allowedContentTypes: [.item],
      allowsMultipleSelection: true
    ) { result in
      importFiles(result)
    }
    .sheet(
      isPresented: $showingPreview,
      onDismiss: {
        cleanupPreview()
        previewFile = nil
      }
    ) {
      previewSheet
    }
  }

  private func sourceRow(_ file: ProjectFile) -> some View {
    HStack(spacing: 12) {
      Button {
        preview(file)
      } label: {
        HStack(spacing: 12) {
          Image(systemName: sourceSymbol(file))
            .foregroundStyle(MacDesignTokens.Colors.accent)
            .frame(width: 30, height: 30)
            .background(MacDesignTokens.Colors.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))

          VStack(alignment: .leading, spacing: 3) {
            Text(file.filename)
              .font(.system(size: 13.5, weight: .medium))
              .foregroundStyle(MacDesignTokens.Colors.textPrimary)
              .lineLimit(1)
            Text("\(sourceType(file)) · \(macProjectFileDetail(file))")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
              .lineLimit(1)
          }

          Spacer()

          if previewLoadingID == file.id {
            ProgressView()
              .controlSize(.small)
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      Menu {
        Button("Preview", systemImage: "eye") {
          preview(file)
        }
        Divider()
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
      Button("Preview", systemImage: "eye") { preview(file) }
      Divider()
      Button("Remove from Project", systemImage: "trash", role: .destructive) { remove(file) }
    }
  }

  @ViewBuilder
  private var previewSheet: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Text(previewFile?.filename ?? "Preview")
            .font(.headline)
          if let previewFile {
            Text("\(sourceType(previewFile)) · \(macProjectFileDetail(previewFile))")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }
        }

        Spacer()

        Button("Done") {
          showingPreview = false
        }
        .keyboardShortcut(.cancelAction)
      }
      .padding(.horizontal, 16)
      .frame(height: 52)

      Divider()

      if let previewURL {
        MacLibraryQuickLookView(url: previewURL)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ProgressView()
          .controlSize(.large)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(minWidth: 760, idealWidth: 900, minHeight: 560, idealHeight: 680)
    .background(MacDesignTokens.Colors.canvas)
  }

  private var formattedTotalBytes: String {
    ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
  }

  private func sourceSymbol(_ file: ProjectFile) -> String {
    if MacProjectFileImportSupport.isImageMIMEType(file.mimeType) { return "photo" }
    if MacProjectFileImportSupport.isTextLikeMIMEType(file.mimeType) { return "doc.text.fill" }
    return "doc.fill"
  }

  private func sourceType(_ file: ProjectFile) -> String {
    if MacProjectFileImportSupport.isImageMIMEType(file.mimeType) { return "Image" }
    if file.mimeType.lowercased().contains("pdf") { return "PDF" }
    let ext = (file.filename as NSString).pathExtension
    return ext.isEmpty ? "File" : ext.uppercased()
  }

  private func preview(_ file: ProjectFile) {
    let requestID = UUID()
    previewRequestID = requestID
    previewLoadingID = file.id
    let fileID = file.id
    let filename = file.filename

    Task { @MainActor in
      guard let data = await workspace.fileData(fileID), !data.isEmpty else {
        if previewRequestID == requestID {
          previewLoadingID = nil
          workspace.errorMessage = "The file '\(filename)' could not be loaded."
        }
        return
      }
      guard previewRequestID == requestID else { return }

      do {
        let tempURL = try await Task.detached(priority: .userInitiated) {
          let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
              "BYOKchat-project-preview-\(requestID.uuidString)",
              isDirectory: true
            )
          try? FileManager.default.removeItem(at: directory)
          try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
          )
          let safeName = MacProjectFileImportSupport.safePreviewFilename(filename)
          let url = directory.appendingPathComponent(safeName, isDirectory: false)
          try data.write(to: url, options: .atomic)
          return url
        }.value

        guard previewRequestID == requestID else {
          try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
          return
        }

        cleanupPreviewFileOnly()
        previewFile = file
        previewURL = tempURL
        previewLoadingID = nil
        showingPreview = true
      } catch {
        if previewRequestID == requestID {
          previewLoadingID = nil
          MacAppAnalytics.reportError("project_file_preview_failed", component: "projects")
          workspace.errorMessage = error.localizedDescription
        }
      }
    }
  }

  private func cleanupPreviewFileOnly() {
    if let previewURL {
      try? FileManager.default.removeItem(at: previewURL.deletingLastPathComponent())
    }
    self.previewURL = nil
  }

  private func cleanupPreview() {
    previewRequestID = UUID()
    cleanupPreviewFileOnly()
    previewLoadingID = nil
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
      MacAppAnalytics.reportError("project_file_picker_failed", component: "projects")
      workspace.errorMessage = error.localizedDescription
    case .success(let urls):
      guard !urls.isEmpty else { return }
      let existingCount = project.projectFiles.count
      let existingBytes = totalBytes
      isWorking = true
      Task { @MainActor in
        defer { isWorking = false }
        do {
          let additions = try await Task.detached(priority: .userInitiated) {
            try MacProjectFileImportSupport.importFiles(
              from: urls,
              existingCount: existingCount,
              existingBytes: existingBytes
            )
          }.value

          if await workspace.addProjectFiles(additions, to: project.id) {
            await mcp.reloadFromStorage()
          }
        } catch {
          MacAppAnalytics.reportError("project_file_import_failed", component: "projects")
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
  @State private var pendingOverwriteOnDismiss: String?
  @State private var pendingOverwriteName: String?
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
    .sheet(
      isPresented: $showingSavePreset,
      onDismiss: {
        if let nameToOverwrite = pendingOverwriteOnDismiss {
          pendingOverwriteOnDismiss = nil
          pendingOverwriteName = nameToOverwrite
        }
      }
    ) {
      MacProjectToolPresetNameSheet(existingPresets: presets) { name in
        requestSavePreset(named: name)
      }
    }
    .confirmationDialog(
      "Replace Tool Preset?",
      isPresented: Binding(
        get: { pendingOverwriteName != nil },
        set: { if !$0 { pendingOverwriteName = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Replace", role: .destructive) {
        if let nameToOverwrite = pendingOverwriteName {
          commitSavePreset(named: nameToOverwrite)
        }
        pendingOverwriteName = nil
      }
      Button("Cancel", role: .cancel) {
        pendingOverwriteName = nil
      }
    } message: {
      if let nameToOverwrite = pendingOverwriteName {
        Text("A tool preset named \"\(nameToOverwrite)\" already exists. Replace it with the current tool settings?")
      }
    }
    .onChange(of: project.id) { _, _ in
      configuration = project.mcpConfiguration ?? MCPChatToolConfiguration()
      presets = project.projectToolPresets
      pendingOverwriteOnDismiss = nil
      pendingOverwriteName = nil
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

  private func requestSavePreset(named rawName: String) {
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= ProjectWorkspaceStore.maxPresetNameLength else { return }
    if presets.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
      pendingOverwriteOnDismiss = name
    } else if presets.count < ProjectWorkspaceStore.maxPresetCount {
      commitSavePreset(named: name)
    }
  }

  private func commitSavePreset(named name: String) {
    if let index = presets.firstIndex(where: {
      $0.name.caseInsensitiveCompare(name) == .orderedSame
    }) {
      presets[index].name = name
      presets[index].configuration = configuration
    } else if presets.count < ProjectWorkspaceStore.maxPresetCount {
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

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var nameValidationError: String? {
    guard !trimmedName.isEmpty else { return nil }
    if trimmedName.count > ProjectWorkspaceStore.maxNameLength {
      return "Project names must be \(ProjectWorkspaceStore.maxNameLength) characters or fewer."
    }
    let hasDuplicate = workspace.projects.contains {
      $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame
    }
    if hasDuplicate {
      return "A project with this name already exists."
    }
    return nil
  }

  private var enabledAccounts: [ProviderAccount] {
    providers.accounts.filter(\.isEnabled)
  }

  private var availableModels: [AccountModelRecord] {
    guard let accountID else { return [] }
    return providers.models(for: accountID).filter(\.isAvailable)
  }

  private var canCreate: Bool {
    !isSaving && !trimmedName.isEmpty && nameValidationError == nil
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
          VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
              Image(systemName: symbolName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(selectedAccent)
                .frame(width: 52, height: 52)
                .background(selectedAccent.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))

              TextField("Project name", text: $name)
                .textFieldStyle(.roundedBorder)
            }

            if let nameValidationError {
              Text(nameValidationError)
                .font(.caption)
                .foregroundStyle(.red)
            }
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

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var nameValidationError: String? {
    guard !trimmedName.isEmpty else { return nil }
    if trimmedName.count > ProjectWorkspaceStore.maxNameLength {
      return "Project names must be \(ProjectWorkspaceStore.maxNameLength) characters or fewer."
    }
    let hasDuplicate = workspace.projects.contains {
      $0.id != project.id && $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame
    }
    if hasDuplicate {
      return "A project with this name already exists."
    }
    return nil
  }

  private var canSave: Bool {
    !isSaving && !trimmedName.isEmpty && nameValidationError == nil
  }

  var body: some View {
    VStack(spacing: 0) {
      MacProjectSheetHeader(
        title: "Project",
        primaryTitle: "Save",
        primaryEnabled: canSave,
        cancel: { dismiss() },
        primary: save
      )
      Divider()
      Form {
        TextField("Name", text: $name)
        if let nameValidationError {
          Text(nameValidationError)
            .font(.caption)
            .foregroundStyle(.red)
        }
        Picker("Icon", selection: $symbolName) {
          if !MacProjectWorkspaceEditorSupport.symbols.contains(symbolName) {
            Label("Custom", systemImage: symbolName).tag(symbolName)
          }
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
    .frame(width: 480, height: 350)
  }

  private func save() {
    guard canSave else { return }
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

  private var selectedAccount: ProviderAccount? {
    guard let accountID else { return nil }
    return enabledAccounts.first { $0.id == accountID }
  }

  private var unavailableAccountLabel: String? {
    guard let accountID, selectedAccount == nil else { return nil }
    if let disabled = providers.accounts.first(where: { $0.id == accountID }) {
      return "\(disabled.label) (Disabled)"
    }
    return "Unavailable Account"
  }

  private var availableModels: [AccountModelRecord] {
    guard let accountID else { return [] }
    return providers.models(for: accountID).filter(\.isAvailable)
  }

  private var unavailableModelLabel: String? {
    guard let accountID, let modelID,
      !availableModels.contains(where: { $0.model.id == modelID })
    else { return nil }
    if let record = providers.models(for: accountID, includeHidden: true)
      .first(where: { $0.model.id == modelID })
    {
      return "\(record.model.displayName) (Unavailable)"
    }
    return "\(modelID.rawValue) (Unavailable)"
  }

  private var hasUnavailableDefaults: Bool {
    unavailableAccountLabel != nil || unavailableModelLabel != nil
  }

  private var canSave: Bool {
    !isSaving
      && (accountID == nil || selectedAccount != nil)
      && (accountID == nil || modelID == nil || availableModels.contains(where: { $0.model.id == modelID }))
  }

  var body: some View {
    VStack(spacing: 0) {
      MacProjectSheetHeader(
        title: "New Chat Defaults",
        primaryTitle: "Save",
        primaryEnabled: canSave,
        cancel: { dismiss() },
        primary: save
      )
      Divider()
      Form {
        Picker("Provider Account", selection: $accountID) {
          Text("App Default").tag(nil as ProviderAccountID?)
          if let unavailableAccountLabel, let accountID {
            Text(unavailableAccountLabel).tag(Optional(accountID))
          }
          ForEach(enabledAccounts) { account in
            Text(account.label).tag(Optional(account.id))
          }
        }
        if accountID != nil {
          Picker("Model", selection: $modelID) {
            Text("Account Default").tag(nil as ModelID?)
            if let unavailableModelLabel, let modelID {
              Text(unavailableModelLabel).tag(Optional(modelID))
            }
            ForEach(availableModels) { record in
              Text(record.model.displayName).tag(Optional(record.model.id))
            }
          }
        }
        if hasUnavailableDefaults {
          Label(
            "The previously selected provider account or model is no longer available. Choose an active option or switch back to App Default / Account Default before saving.",
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.caption)
          .foregroundStyle(.orange)
        }
        Text("Changes apply to new chats. Existing chats keep their current provider and model.")
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
      }
      .formStyle(.grouped)
      .padding(10)
    }
    .frame(width: 520, height: 360)
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
    guard canSave else { return }
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
  let existingNames: Set<String>
  let atLimit: Bool
  let save: (ProjectPromptPreset) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var prompt: String

  init(
    existing: ProjectPromptPreset?,
    existingNames: Set<String>,
    atLimit: Bool = false,
    save: @escaping (ProjectPromptPreset) -> Void
  ) {
    self.existing = existing
    self.existingNames = existingNames
    self.atLimit = atLimit
    self.save = save
    _name = State(initialValue: existing?.name ?? "")
    _prompt = State(initialValue: existing?.prompt ?? "")
  }

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var trimmedPrompt: String {
    prompt.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var nameError: String? {
    if atLimit {
      return "A project can contain at most \(ProjectWorkspaceStore.maxPresetCount) presets."
    }
    guard !trimmedName.isEmpty else { return nil }
    if trimmedName.count > ProjectWorkspaceStore.maxPresetNameLength {
      return "Preset names must be \(ProjectWorkspaceStore.maxPresetNameLength) characters or fewer."
    }
    if existingNames.contains(trimmedName.lowercased()) {
      return "A prompt preset with this name already exists."
    }
    return nil
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
      VStack(alignment: .leading, spacing: 10) {
        TextField("Name", text: $name)
        if let nameError {
          Text(nameError)
            .font(.caption)
            .foregroundStyle(.red)
        }
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
    .frame(width: 520, height: 380)
  }

  private var canSave: Bool {
    !atLimit
      && !trimmedName.isEmpty
      && !trimmedPrompt.isEmpty
      && nameError == nil
  }

  private func saveValue() {
    guard canSave else { return }
    save(
      ProjectPromptPreset(
        id: existing?.id ?? UUID().uuidString.lowercased(),
        name: trimmedName,
        prompt: trimmedPrompt
      )
    )
    dismiss()
  }
}

private struct MacProjectToolPresetNameSheet: View {
  let existingPresets: [ProjectToolPreset]
  let save: (String) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var name = ""

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var matchesExistingPreset: Bool {
    guard !trimmedName.isEmpty else { return false }
    return existingPresets.contains {
      $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame
    }
  }

  private var validationError: String? {
    if trimmedName.count > ProjectWorkspaceStore.maxPresetNameLength {
      return "Preset names must be \(ProjectWorkspaceStore.maxPresetNameLength) characters or fewer."
    }
    if !matchesExistingPreset && existingPresets.count >= ProjectWorkspaceStore.maxPresetCount {
      return "A project can contain at most \(ProjectWorkspaceStore.maxPresetCount) tool presets. Enter an existing preset name to update it, or delete one first."
    }
    return nil
  }

  private var canSave: Bool {
    !trimmedName.isEmpty && validationError == nil
  }

  var body: some View {
    VStack(spacing: 0) {
      MacProjectSheetHeader(
        title: "Save Tool Preset",
        primaryTitle: "Save",
        primaryEnabled: canSave,
        cancel: { dismiss() },
        primary: saveValue
      )
      Divider()
      VStack(alignment: .leading, spacing: 10) {
        TextField("Preset name", text: $name)
          .onSubmit { saveValue() }
        if let validationError {
          Text(validationError)
            .font(.caption)
            .foregroundStyle(.red)
        } else {
          Text("Saving with an existing preset name will ask before replacing that preset.")
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }
      }
      .padding(16)
    }
    .frame(width: 440, height: 190)
  }

  private func saveValue() {
    guard canSave else { return }
    save(trimmedName)
    dismiss()
  }
}

private struct MacProjectChatRenameSheet: View {
  let conversation: ChatConversation
  let save: (String) async -> Bool

  @Environment(\.dismiss) private var dismiss
  @FocusState private var titleFocused: Bool
  @State private var title: String
  @State private var isSaving = false

  init(
    conversation: ChatConversation,
    save: @escaping (String) async -> Bool
  ) {
    self.conversation = conversation
    self.save = save
    _title = State(initialValue: conversation.title)
  }

  private var trimmedTitle: String {
    title.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var canSave: Bool {
    let original = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmedTitle.isEmpty && trimmedTitle != original && !isSaving
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Rename Conversation")
        .font(.headline)

      TextField("Conversation name", text: $title)
        .textFieldStyle(.roundedBorder)
        .focused($titleFocused)
        .onSubmit { commit() }

      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Rename") { commit() }
          .keyboardShortcut(.defaultAction)
          .disabled(!canSave)
      }
    }
    .padding(20)
    .frame(width: 380)
    .onAppear {
      titleFocused = true
    }
  }

  private func commit() {
    guard canSave else { return }
    let value = trimmedTitle
    isSaving = true
    Task { @MainActor in
      if await save(value) {
        dismiss()
      } else {
        isSaving = false
      }
    }
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
  var valueColor: Color? = nil

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title)
        .font(.caption)
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
        .frame(width: 120, alignment: .leading)
      Text(value)
        .font(.system(size: 13.5, weight: .medium))
        .foregroundStyle(valueColor ?? MacDesignTokens.Colors.textPrimary)
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
