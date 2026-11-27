import AppKit
import BYOKchatProviderCore
import Foundation
import MacAppFoundation
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
    now: Date = .now,
    calendar: Calendar = .current
  ) -> [Section] {
    let startOfToday = calendar.startOfDay(for: now)
    let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
    let startOfWeekAgo = calendar.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfToday
    let sorted = conversations.sorted { lhs, rhs in
      if lhs.updatedAt != rhs.updatedAt {
        return lhs.updatedAt > rhs.updatedAt
      }
      return lhs.id.rawValue > rhs.id.rawValue
    }

    func title(for date: Date) -> String {
      if date >= startOfToday { return "Today" }
      if date >= startOfYesterday { return "Yesterday" }
      if date >= startOfWeekAgo { return "Previous 7 Days" }
      return date.formatted(.dateTime.month(.wide).year())
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

@MainActor
enum MacProjectDefaultsSummary {
  struct Status: Equatable {
    let accountLabel: String
    let isAccountUnavailable: Bool
    let modelLabel: String
    let isModelUnavailable: Bool

    var hasIssue: Bool {
      isAccountUnavailable || isModelUnavailable
    }

    var cardSummary: String {
      if accountLabel == "App Default" {
        return "App defaults"
      }
      return "\(accountLabel) · \(modelLabel)"
    }
  }

  static func evaluate(
    project: ChatProject,
    providers: MacProviderModel
  ) -> Status {
    let accountStatus: (label: String, isUnavailable: Bool)
    if let accountID = project.accountID {
      if let account = providers.account(accountID) {
        if !account.isEnabled {
          accountStatus = ("\(account.label) (Disabled)", true)
        } else {
          accountStatus = (account.label, false)
        }
      } else {
        accountStatus = ("Unavailable Account", true)
      }
    } else {
      accountStatus = ("App Default", false)
    }

    let modelStatus: (label: String, isUnavailable: Bool)
    if let modelID = project.modelID {
      if let accountID = project.accountID,
        let record = providers.models(for: accountID, includeHidden: true)
          .first(where: { $0.model.id == modelID })
      {
        if record.isAvailable {
          modelStatus = (record.model.displayName, false)
        } else {
          modelStatus = ("\(record.model.displayName) (Unavailable)", true)
        }
      } else {
        modelStatus = ("\(modelID.rawValue) (Unavailable)", true)
      }
    } else {
      modelStatus = ("Account Default", false)
    }

    return Status(
      accountLabel: accountStatus.label,
      isAccountUnavailable: accountStatus.isUnavailable,
      modelLabel: modelStatus.label,
      isModelUnavailable: modelStatus.isUnavailable
    )
  }
}

struct MacProjectsWorkspaceView: View {
  @Bindable var workspace: MacWorkspaceModel
  @Bindable var providers: MacProviderModel
  @Bindable var chats: MacChatSessionModel
  @Bindable var mcp: MacMCPModel
  let initialProjectID: ProjectID?
  let openChat: (ConversationID) -> Void
  let startNewChat: (ProjectID, String?) -> Bool

  @Environment(PurchaseManager.self) private var purchaseManager
  @State private var selectedProjectID: ProjectID?
  @State private var searchText = ""
  @State private var showingNewProject = false
  @State private var editIdentityProject: ChatProject?
  @State private var deleteProject: ChatProject?

  init(
    workspace: MacWorkspaceModel,
    providers: MacProviderModel,
    chats: MacChatSessionModel,
    mcp: MacMCPModel,
    initialProjectID: ProjectID? = nil,
    openChat: @escaping (ConversationID) -> Void,
    startNewChat: @escaping (ProjectID, String?) -> Bool
  ) {
    self.workspace = workspace
    self.providers = providers
    self.chats = chats
    self.mcp = mcp
    self.initialProjectID = initialProjectID
    self.openChat = openChat
    self.startNewChat = startNewChat
    _selectedProjectID = State(initialValue: initialProjectID)
  }

  private var selectedProject: ChatProject? {
    workspace.project(selectedProjectID)
  }

  private var trimmedSearchQuery: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var visibleProjects: [ChatProject] {
    let query = trimmedSearchQuery
    guard !query.isEmpty else { return workspace.projects }
    return workspace.projects.filter { project in
      let status = MacProjectDefaultsSummary.evaluate(project: project, providers: providers)
      return project.name.localizedCaseInsensitiveContains(query)
        || status.cardSummary.localizedCaseInsensitiveContains(query)
    }
  }

  private var isCheckingEntitlement: Bool {
    purchaseManager.entitlementState == .checking
  }

  private var activeErrorMessage: String? {
    workspace.errorMessage ?? mcp.errorMessage
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
          },
          startNewChat: { prompt in
            _ = startNewChat(project.id, prompt)
          },
          requestDelete: { deleteProject = project }
        )
      } else {
        projectsHome
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(MacDesignTokens.Colors.canvas)
    .onChange(of: initialProjectID) { _, projectID in
      if let projectID {
        selectedProjectID = projectID
      }
    }
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
    .sheet(item: $editIdentityProject) { project in
      MacProjectIdentityEditor(
        project: project,
        workspace: workspace
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
        get: { activeErrorMessage != nil },
        set: {
          if !$0 {
            workspace.errorMessage = nil
            mcp.errorMessage = nil
          }
        }
      )
    ) {
      Button("OK") {
        workspace.errorMessage = nil
        mcp.errorMessage = nil
      }
    } message: {
      Text(activeErrorMessage ?? "Unknown error")
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
          .buttonStyle(MacActionButtonStyle(.primary))
          .disabled(isCheckingEntitlement)
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
              ContentUnavailableView.search(text: trimmedSearchQuery)
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
            } else {
              ForEach(visibleProjects) { project in
                let defaultsStatus = MacProjectDefaultsSummary.evaluate(
                  project: project,
                  providers: providers
                )
                MacProjectHomeCard(
                  project: project,
                  activitySummary: projectActivitySummary(project),
                  defaultsStatus: defaultsStatus,
                  openProject: { selectedProjectID = project.id },
                  startNewChat: { _ = startNewChat(project.id, nil) },
                  editProject: { editIdentityProject = project },
                  requestDelete: { deleteProject = project }
                )
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
        .buttonStyle(MacActionButtonStyle(.primary))
        .disabled(isCheckingEntitlement)
    }
    .padding(.horizontal, 16)
    .frame(height: 54)
    .background(MacDesignTokens.Colors.surface.opacity(0.45))
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
}

private struct MacProjectHomeCard: View {
  let project: ChatProject
  let activitySummary: String
  let defaultsStatus: MacProjectDefaultsSummary.Status
  let openProject: () -> Void
  let startNewChat: () -> Void
  let editProject: () -> Void
  let requestDelete: () -> Void

  @State private var isHovered = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
    HStack(spacing: 14) {
      Button(action: openProject) {
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

            Text(activitySummary)
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
              .lineLimit(1)

            HStack(spacing: 4) {
              if defaultsStatus.hasIssue {
                Image(systemName: "exclamationmark.triangle.fill")
                  .font(.caption2)
                  .foregroundStyle(.orange)
              }
              Text(defaultsStatus.cardSummary)
                .font(.caption2)
                .foregroundStyle(
                  defaultsStatus.hasIssue
                    ? Color.orange
                    : MacDesignTokens.Colors.textMuted.opacity(0.85)
                )
                .lineLimit(1)
            }
          }

          Spacer(minLength: 12)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      Button("New Chat", systemImage: "square.and.pencil", action: startNewChat)
        .buttonStyle(MacActionButtonStyle(.secondary, size: .small))

      Menu {
        Button("Open Project", systemImage: "arrow.right.circle", action: openProject)
        Button("New Chat", systemImage: "square.and.pencil", action: startNewChat)
        Button("Edit Project…", systemImage: "pencil", action: editProject)
        Divider()
        Button("Delete Project…", systemImage: "trash", role: .destructive, action: requestDelete)
      } label: {
        MacIconMenuLabel(systemImage: "ellipsis")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Project actions")
    }
    .padding(14)
    .background(MacDesignTokens.Colors.surface, in: shape)
    .overlay {
      if isHovered {
        shape.fill(Color.primary.opacity(0.025))
          .allowsHitTesting(false)
      }
    }
    .overlay {
      shape.stroke(
        isHovered
          ? MacDesignTokens.Colors.accent.opacity(0.35)
          : MacDesignTokens.Colors.separator.opacity(0.75),
        lineWidth: 0.75
      )
    }
    .onHover { isHovered = $0 }
    .animation(.easeOut(duration: MacDesignTokens.Control.interactionDuration), value: isHovered)
    .contextMenu {
      Button("Open Project", action: openProject)
      Button("New Chat", action: startNewChat)
      Button("Edit Project…", action: editProject)
      Divider()
      Button("Delete Project", role: .destructive, action: requestDelete)
    }
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

      MacSegmentedControl(
        options: MacProjectWorkspaceSection.allCases,
        selection: $section,
        title: \.rawValue
      )
      .padding(.horizontal, 18)
      .padding(.vertical, 12)

      Group {
        switch section {
        case .overview:
          MacProjectOverviewView(
            project: project,
            workspace: workspace,
            providers: providers,
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
            workspace: workspace
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
    .onChange(of: project.id) { _, _ in
      section = .overview
    }
  }

  private var detailHeader: some View {
    HStack(spacing: 12) {
      Button(action: back) {
        Label("All Projects", systemImage: "chevron.left")
          .foregroundStyle(MacDesignTokens.Colors.accent)
      }
      .buttonStyle(MacActionButtonStyle(.subtle, size: .small))

      Divider()
        .frame(height: 24)

      MacProjectWorkspaceIcon(project: project, size: 40)

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(project.name)
            .font(.title3.weight(.semibold))
            .lineLimit(1)
        }
        Text(projectSummary)
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
      }

      Spacer()

      Button("New Chat", systemImage: "square.and.pencil") {
        startNewChat(nil)
      }
      .buttonStyle(MacActionButtonStyle(.primary))

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
        MacIconMenuLabel(systemImage: "ellipsis")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
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
    var parts = [
      "\(chatCount) chat\(chatCount == 1 ? "" : "s")",
      "\(sourceCount) source\(sourceCount == 1 ? "" : "s")",
    ]
    if serverCount > 0 {
      parts.append("\(serverCount) MCP server\(serverCount == 1 ? "" : "s")")
    }
    return parts.joined(separator: " · ")
  }
}

private struct MacProjectOverviewView: View {
  let project: ChatProject
  @Bindable var workspace: MacWorkspaceModel
  @Bindable var providers: MacProviderModel
  let startNewChat: (String?) -> Void
  let requestDelete: () -> Void

  @State private var editor: OverviewEditor?
  @State private var promptToEdit: ProjectPromptPreset?
  @State private var promptToDelete: ProjectPromptPreset?
  @State private var showingNewPrompt = false

  private enum OverviewEditor: String, Identifiable {
    case identity
    case defaults
    case instructions
    var id: String { rawValue }
  }

  private var defaultsStatus: MacProjectDefaultsSummary.Status {
    MacProjectDefaultsSummary.evaluate(project: project, providers: providers)
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
              .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
          }
        }

        overviewCard("New Chat Defaults", systemImage: "sparkles") {
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              VStack(alignment: .leading, spacing: 5) {
                MacProjectValueRow(
                  title: "Provider Account",
                  value: defaultsStatus.accountLabel,
                  valueColor: defaultsStatus.isAccountUnavailable ? Color.orange : nil
                )
                MacProjectValueRow(
                  title: "Model",
                  value: defaultsStatus.modelLabel,
                  valueColor: defaultsStatus.isModelUnavailable ? Color.orange : nil
                )
              }
              Spacer()
              Button("Edit") { editor = .defaults }
                .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
            }
            if defaultsStatus.hasIssue {
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
                .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
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
            .buttonStyle(MacActionButtonStyle(.destructive))
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
          workspace: workspace
        )
      case .defaults:
        MacProjectDefaultsEditor(
          project: project,
          workspace: workspace,
          providers: providers
        )
      case .instructions:
        MacProjectInstructionsEditor(
          project: project,
          workspace: workspace
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
        await savePromptPreset(preset)
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
        await savePromptPreset(value)
      }
    }
    .confirmationDialog(
      promptToDelete.map { "Delete \"\($0.name)\"?" } ?? "Delete prompt?",
      isPresented: Binding(
        get: { promptToDelete != nil },
        set: { if !$0 { promptToDelete = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete Prompt", role: .destructive) {
        guard let target = promptToDelete else { return }
        promptToDelete = nil
        deletePromptPreset(target)
      }
      Button("Cancel", role: .cancel) { promptToDelete = nil }
    } message: {
      Text("This removes the reusable prompt from \(project.name).")
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
      VStack(spacing: 0) {
        if project.projectPromptPresets.isEmpty {
          HStack {
            Text("No reusable prompts yet.")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
            Spacer()
            Button("Add Prompt", systemImage: "plus") { showingNewPrompt = true }
              .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
              .disabled(atPromptLimit)
          }
        } else {
          ForEach(Array(project.projectPromptPresets.enumerated()), id: \.element.id) { index, preset in
            MacProjectPromptRow(
              preset: preset,
              usePrompt: { startNewChat(preset.prompt) },
              editPrompt: { promptToEdit = preset },
              deletePrompt: { promptToDelete = preset }
            )
            if index != project.projectPromptPresets.count - 1 {
              Divider()
            }
          }

          HStack {
            if atPromptLimit {
              Text("Maximum of \(ProjectWorkspaceStore.maxPresetCount) reusable prompts reached.")
                .font(.caption)
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
            }
            Spacer()
            Button("Add Prompt", systemImage: "plus") { showingNewPrompt = true }
              .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
              .disabled(atPromptLimit)
          }
          .padding(.top, 10)
        }
      }
    }
  }

  private func savePromptPreset(_ value: ProjectPromptPreset) async -> String? {
    if await workspace.upsertProjectPromptPreset(value, projectID: project.id) {
      return nil
    }
    return workspace.consumeErrorMessage() ?? "Could not save prompt preset."
  }

  private func deletePromptPreset(_ preset: ProjectPromptPreset) {
    Task { @MainActor in
      _ = await workspace.deleteProjectPromptPreset(preset.id, projectID: project.id)
    }
  }
}

private struct MacProjectPromptRow: View {
  let preset: ProjectPromptPreset
  let usePrompt: () -> Void
  let editPrompt: () -> Void
  let deletePrompt: () -> Void

  @State private var isHovered = false

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      Button {
        editPrompt()
      } label: {
        VStack(alignment: .leading, spacing: 3) {
          Text(preset.name)
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(MacDesignTokens.Colors.textPrimary)
          Text(preset.prompt)
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      Button("Use", action: usePrompt)
        .buttonStyle(MacActionButtonStyle(.secondary, size: .small))

      Menu {
        Button("Use in New Chat", systemImage: "square.and.pencil", action: usePrompt)
        Button("Edit…", systemImage: "pencil", action: editPrompt)
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive, action: deletePrompt)
      } label: {
        MacIconMenuLabel(systemImage: "ellipsis")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 8)
    .background(
      isHovered ? Color.primary.opacity(0.03) : Color.clear,
      in: RoundedRectangle(cornerRadius: 7, style: .continuous)
    )
    .onHover { isHovered = $0 }
    .animation(.easeOut(duration: MacDesignTokens.Control.interactionDuration), value: isHovered)
    .contextMenu {
      Button("Use in New Chat", systemImage: "square.and.pencil", action: usePrompt)
      Button("Edit…", systemImage: "pencil", action: editPrompt)
      Divider()
      Button("Delete…", systemImage: "trash", role: .destructive, action: deletePrompt)
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
  @State private var showingAddExisting = false
  @State private var renameTarget: ChatConversation?
  @State private var deleteTarget: ChatConversation?

  private var trimmedSearchQuery: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var otherProjects: [ChatProject] {
    workspace.projects.filter { $0.id != project.id }
  }

  private var memberConversations: [ChatConversation] {
    let query = trimmedSearchQuery
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
          Button("Add Existing…", systemImage: "folder.badge.plus") {
            showingAddExisting = true
          }
          .buttonStyle(MacActionButtonStyle(.secondary))
          .disabled(workspace.isBusy)
        }
        Button("New Chat", systemImage: "plus") { startNewChat() }
          .buttonStyle(MacActionButtonStyle(.primary))
      }
      .padding(.horizontal, 16)
      .frame(height: 52)

      Divider()

      if memberConversations.isEmpty {
        ContentUnavailableView {
          Label(
            trimmedSearchQuery.isEmpty ? "No Chats Yet" : "No Matches",
            systemImage: trimmedSearchQuery.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass"
          )
        } description: {
          Text(
            trimmedSearchQuery.isEmpty
              ? "New chats here use \(project.name) defaults and instructions."
              : "Try a different search."
          )
        } actions: {
          if trimmedSearchQuery.isEmpty {
            HStack(spacing: 8) {
              if !otherConversations.isEmpty {
                Button("Add Existing…", systemImage: "folder.badge.plus") {
                  showingAddExisting = true
                }
                .buttonStyle(MacActionButtonStyle(.secondary))
                .disabled(workspace.isBusy)
              }
              Button("New Chat", systemImage: "plus") { startNewChat() }
                .buttonStyle(MacActionButtonStyle(.primary))
            }
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
                    MacProjectConversationRow(
                      title: conversationTitle(conversation),
                      preview: conversationPreview(conversation),
                      updatedAt: conversation.updatedAt,
                      open: { openChat(conversation.id) },
                      actions: { conversationActions(conversation) }
                    )
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
    .onChange(of: project.id) { _, _ in
      searchText = ""
    }
    .sheet(isPresented: $showingAddExisting) {
      MacProjectAddChatsSheet(
        targetProject: project,
        conversations: otherConversations,
        workspace: workspace
      ) { conversationIDs in
        await addExistingConversations(conversationIDs)
      }
    }
    .sheet(item: $renameTarget) { conversation in
      MacProjectChatRenameSheet(conversation: conversation) { newTitle in
        let renamed = await chats.renameConversation(conversation.id, title: newTitle)
        if !renamed {
          let error = chats.errorMessage ?? "Could not rename conversation."
          chats.errorMessage = nil
          return error
        }
        return nil
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

  private func addExistingConversations(_ ids: [ConversationID]) async -> String? {
    guard !ids.isEmpty else { return nil }
    if await workspace.assignConversations(ids, to: project.id) {
      await mcp.reloadFromStorage()
      if !trimmedSearchQuery.isEmpty {
        searchText = ""
      }
      return nil
    }
    return workspace.consumeErrorMessage() ?? "Could not add chats to \(project.name)."
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
    return "\(conversation.messageCount) \(conversation.messageCount == 1 ? "message" : "messages")"
  }
}

private struct MacProjectConversationRow<Actions: View>: View {
  let title: String
  let preview: String
  let updatedAt: Date
  let open: () -> Void
  @ViewBuilder let actions: () -> Actions

  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 8) {
      Button(action: open) {
        HStack(spacing: 10) {
          Image(systemName: "bubble.left")
            .foregroundStyle(MacDesignTokens.Colors.accent)
            .frame(width: 24)

          VStack(alignment: .leading, spacing: 3) {
            Text(title)
              .font(.system(size: 13.5, weight: .medium))
              .foregroundStyle(MacDesignTokens.Colors.textPrimary)
              .lineLimit(1)
            Text(preview)
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
              .lineLimit(1)
          }

          Spacer()

          Text(updatedAt, format: .dateTime.month(.abbreviated).day())
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
        actions()
      } label: {
        MacIconMenuLabel(systemImage: "ellipsis")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Chat actions")
    }
    .padding(.horizontal, 12)
    .frame(minHeight: 54)
    .background(isHovered ? Color.primary.opacity(0.03) : Color.clear)
    .onHover { isHovered = $0 }
    .animation(.easeOut(duration: MacDesignTokens.Control.interactionDuration), value: isHovered)
    .contextMenu {
      actions()
    }
  }
}

private struct MacProjectAddChatsSheet: View {
  let targetProject: ChatProject
  let conversations: [ChatConversation]
  @Bindable var workspace: MacWorkspaceModel
  let commitSelection: ([ConversationID]) async -> String?

  @Environment(\.dismiss) private var dismiss
  @FocusState private var searchFocused: Bool
  @State private var searchText = ""
  @State private var selectedIDs: Set<ConversationID> = []
  @State private var isSaving = false
  @State private var errorMessage: String?

  private var trimmedQuery: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var filteredConversations: [ChatConversation] {
    let query = trimmedQuery
    guard !query.isEmpty else { return conversations }
    return conversations.filter { conversation in
      let title = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
      let displayTitle = title.isEmpty ? "New Chat" : title
      let projectName = workspace.project(for: conversation.id)?.name ?? ""
      return displayTitle.localizedCaseInsensitiveContains(query)
        || (conversation.lastMessagePreview?.localizedCaseInsensitiveContains(query) ?? false)
        || projectName.localizedCaseInsensitiveContains(query)
    }
  }

  private var standaloneConversations: [ChatConversation] {
    filteredConversations.filter { workspace.project(for: $0.id) == nil }
  }

  private var otherProjectConversations: [ChatConversation] {
    filteredConversations.filter { workspace.project(for: $0.id) != nil }
  }

  private var activeSelectedIDs: [ConversationID] {
    conversations.map(\.id).filter { selectedIDs.contains($0) }
  }

  private var movingFromOtherProjectCount: Int {
    activeSelectedIDs.filter { workspace.project(for: $0) != nil }.count
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Add Chats to \(targetProject.name)")
            .font(.headline)
            .lineLimit(1)
          Text(subtitleText)
            .font(.caption)
            .foregroundStyle(
              movingFromOtherProjectCount > 0 ? Color.orange : MacDesignTokens.Colors.textMuted
            )
        }
        Spacer()
        Button("Cancel") { dismiss() }
          .buttonStyle(MacActionButtonStyle(.secondary))
          .keyboardShortcut(.cancelAction)
          .disabled(isSaving)
        Button(activeSelectedIDs.isEmpty ? "Add" : "Add (\(activeSelectedIDs.count))") {
          commit()
        }
        .buttonStyle(MacActionButtonStyle(.primary))
        .keyboardShortcut(.defaultAction)
        .disabled(activeSelectedIDs.isEmpty || isSaving)
      }
      .padding(16)
      .background(MacDesignTokens.Colors.surface)

      Divider()

      VStack(spacing: 8) {
        HStack(spacing: 7) {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(.secondary)
          TextField("Search chats or projects", text: $searchText)
            .textFieldStyle(.plain)
            .focused($searchFocused)
          if !searchText.isEmpty {
            Button {
              searchText = ""
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

        if let errorMessage {
          MacProjectInlineErrorBanner(message: errorMessage) {
            self.errorMessage = nil
          }
        }
      }
      .padding(12)

      Divider()

      if filteredConversations.isEmpty {
        ContentUnavailableView(
          trimmedQuery.isEmpty ? "No Other Chats" : "No Matching Chats",
          systemImage: trimmedQuery.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass",
          description: Text(
            trimmedQuery.isEmpty
              ? "All existing conversations are already in \(targetProject.name)."
              : "Try a different search term."
          )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 14) {
            if !standaloneConversations.isEmpty {
              chatGroupSection(
                title: "Standalone Chats",
                items: standaloneConversations,
                showCurrentProject: false
              )
            }
            if !otherProjectConversations.isEmpty {
              chatGroupSection(
                title: "In Other Projects (Will Move)",
                items: otherProjectConversations,
                showCurrentProject: true
              )
            }
          }
          .padding(12)
        }
      }
    }
    .frame(
      width: MacDesignTokens.Sheet.standardWidth,
      height: MacDesignTokens.Sheet.standardHeight
    )
    .background(MacDesignTokens.Colors.canvas)
    .overlay {
      if isSaving {
        ProgressView()
          .padding(12)
          .background(.regularMaterial, in: Capsule())
      }
    }
    .onAppear {
      searchFocused = true
    }
  }

  private var subtitleText: String {
    if movingFromOtherProjectCount > 0 {
      return "\(movingFromOtherProjectCount) selected chat\(movingFromOtherProjectCount == 1 ? "" : "s") will move from another project."
    }
    return "Select existing chats to include in this project."
  }

  private func chatGroupSection(
    title: String,
    items: [ChatConversation],
    showCurrentProject: Bool
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title.uppercased())
        .font(.caption2.weight(.semibold))
        .tracking(0.4)
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
        .padding(.horizontal, 4)

      VStack(spacing: 2) {
        ForEach(items) { conversation in
          let isSelected = selectedIDs.contains(conversation.id)
          let currentProject = showCurrentProject ? workspace.project(for: conversation.id) : nil
          MacProjectSelectableChatRow(
            conversation: conversation,
            currentProject: currentProject,
            isSelected: isSelected,
            isDisabled: isSaving
          ) {
            toggle(conversation.id)
          }
        }
      }
    }
  }

  private func toggle(_ id: ConversationID) {
    if selectedIDs.contains(id) {
      selectedIDs.remove(id)
    } else {
      selectedIDs.insert(id)
    }
  }

  private func commit() {
    let ids = activeSelectedIDs
    guard !ids.isEmpty, !isSaving else { return }
    isSaving = true
    errorMessage = nil
    Task { @MainActor in
      if let error = await commitSelection(ids) {
        isSaving = false
        errorMessage = error
      } else {
        dismiss()
      }
    }
  }
}

private struct MacProjectSelectableChatRow: View {
  let conversation: ChatConversation
  let currentProject: ChatProject?
  let isSelected: Bool
  let isDisabled: Bool
  let action: () -> Void

  @State private var isHovered = false

  private var displayTitle: String {
    let trimmed = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "New Chat" : trimmed
  }

  private var detailText: String {
    if let preview = conversation.lastMessagePreview?.trimmingCharacters(in: .whitespacesAndNewlines),
      !preview.isEmpty
    {
      return preview
    }
    return "\(conversation.messageCount) \(conversation.messageCount == 1 ? "message" : "messages")"
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 16))
          .foregroundStyle(isSelected ? MacDesignTokens.Colors.accent : MacDesignTokens.Colors.textMuted)

        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            Text(displayTitle)
              .font(.system(size: 13, weight: .medium))
              .foregroundStyle(MacDesignTokens.Colors.textPrimary)
              .lineLimit(1)

            if let currentProject {
              let accent = MacProjectAccentOption(rawValue: currentProject.accentID)?.color ?? .blue
              HStack(spacing: 3) {
                Image(systemName: currentProject.symbolName)
                  .font(.system(size: 9, weight: .semibold))
                  .foregroundStyle(accent)
                Text(currentProject.name)
                  .font(.caption2.weight(.medium))
                  .foregroundStyle(MacDesignTokens.Colors.textMuted)
                  .lineLimit(1)
              }
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(MacDesignTokens.Colors.surface, in: Capsule())
              .overlay {
                Capsule().stroke(MacDesignTokens.Colors.separator.opacity(0.7), lineWidth: 0.5)
              }
            }
          }

          Text(detailText)
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
            .lineLimit(1)
        }

        Spacer(minLength: 8)

        Text(conversation.updatedAt, format: .dateTime.month(.abbreviated).day())
          .font(.caption2)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(rowBackground, in: shape)
      .contentShape(shape)
    }
    .buttonStyle(.plain)
    .disabled(isDisabled)
    .onHover { isHovered = $0 }
    .animation(.easeOut(duration: MacDesignTokens.Control.interactionDuration), value: isHovered)
  }

  private var rowBackground: Color {
    if isSelected { return MacDesignTokens.Colors.accent.opacity(0.11) }
    if isHovered { return Color.primary.opacity(0.035) }
    return Color.clear
  }
}

private struct MacProjectSourcesWorkspaceView: View {
  let project: ChatProject
  @Bindable var workspace: MacWorkspaceModel

  private static let minPreviewZoom: CGFloat = 1.0
  private static let maxPreviewZoom: CGFloat = 5.0

  @Environment(\.macToastCenter) private var toastCenter
  @State private var searchText = ""
  @State private var showingImporter = false
  @State private var showingLibraryPicker = false
  @State private var isWorking = false
  @State private var isDropTargeted = false
  @State private var fileToRemove: ProjectFile?
  @State private var previewFile: ProjectFile?
  @State private var previewURL: URL?
  @State private var previewImage: NSImage?
  @State private var previewZoomScale: CGFloat = 1.0
  @State private var previewLoadingID: String?
  @State private var previewRequestID = UUID()
  @State private var showingPreview = false
  @State private var previewSavedStatus: String?
  @State private var previewErrorMessage: String?

  private var trimmedSearchQuery: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var visibleFiles: [ProjectFile] {
    let query = trimmedSearchQuery
    guard !query.isEmpty else { return project.projectFiles }
    return project.projectFiles.filter { file in
      file.filename.localizedCaseInsensitiveContains(query)
        || file.mimeType.localizedCaseInsensitiveContains(query)
    }
  }

  private var totalBytes: Int {
    project.projectFiles.reduce(0) { $0 + $1.byteCount }
  }

  private var canAddMoreFiles: Bool {
    project.projectFiles.count < ProjectWorkspaceStore.maxFileCount
      && !isWorking
      && !workspace.isBusy
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        MacProjectSearchField(placeholder: "Search sources", text: $searchText)
          .frame(maxWidth: 340)
        Spacer()
        Button("From Library…", systemImage: "books.vertical") { showingLibraryPicker = true }
          .buttonStyle(MacActionButtonStyle(.secondary))
          .disabled(!canAddMoreFiles)
        Button("Add Files", systemImage: "doc.badge.plus") { showingImporter = true }
          .buttonStyle(MacActionButtonStyle(.primary))
          .disabled(!canAddMoreFiles)
      }
      .padding(.horizontal, 16)
      .frame(height: 52)

      Divider()

      Group {
        if project.projectFiles.isEmpty {
          ContentUnavailableView {
            Label("No Sources", systemImage: "doc.on.doc")
          } description: {
            Text("Add or drop reference files that can be attached to chats in this project when needed.")
          } actions: {
            HStack(spacing: 8) {
              Button("From Library…", systemImage: "books.vertical") { showingLibraryPicker = true }
                .buttonStyle(MacActionButtonStyle(.secondary))
                .disabled(!canAddMoreFiles)
              Button("Add Files", systemImage: "plus") { showingImporter = true }
                .buttonStyle(MacActionButtonStyle(.primary))
                .disabled(!canAddMoreFiles)
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visibleFiles.isEmpty {
          ContentUnavailableView.search(text: trimmedSearchQuery)
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
                  MacProjectSourceRow(
                    file: file,
                    subtitle: "\(sourceType(file)) · \(macProjectFileDetail(file))",
                    isInLibrary: workspace.isFileInLibrary(file.id),
                    isLoadingPreview: previewLoadingID == file.id,
                    workspace: workspace,
                    preview: { preview(file) },
                    export: { export(file) },
                    saveToLibrary: { saveToLibrary(file) },
                    requestRemove: { fileToRemove = file }
                  )
                  if index != visibleFiles.count - 1 {
                    Divider().padding(.leading, 58)
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
              if project.projectFiles.count < ProjectWorkspaceStore.maxFileCount {
                Text("Drop files here to add")
                  .font(.caption)
                  .foregroundStyle(MacDesignTokens.Colors.textMuted.opacity(0.75))
              }
            }
            .padding(.horizontal, 16)
            .frame(height: 42)
            .background(MacDesignTokens.Colors.surface.opacity(0.45))
          }
        }
      }
      .overlay {
        if isDropTargeted && canAddMoreFiles {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(
              MacDesignTokens.Colors.accent,
              style: StrokeStyle(lineWidth: 2, dash: [7, 5])
            )
            .background(
              MacDesignTokens.Colors.accent.opacity(0.06),
              in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
              Label("Drop files to add to \(project.name)", systemImage: "doc.badge.plus")
                .font(.headline)
                .foregroundStyle(MacDesignTokens.Colors.accent)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
            }
            .padding(12)
            .allowsHitTesting(false)
        }
      }
      .dropDestination(for: URL.self) { urls, _ in
        guard canAddMoreFiles, !urls.isEmpty else { return false }
        importURLs(urls)
        return true
      } isTargeted: { targeted in
        isDropTargeted = targeted
      }
      .dropDestination(for: MacDroppedImage.self) { images, _ in
        guard canAddMoreFiles, !images.isEmpty else { return false }
        importDroppedImages(images)
        return true
      } isTargeted: { targeted in
        isDropTargeted = targeted
      }
    }
    .onChange(of: project.id) { _, _ in
      searchText = ""
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
    .sheet(isPresented: $showingLibraryPicker) {
      MacProjectLibrarySourcePickerSheet(
        workspace: workspace,
        excludedIDs: Set(project.projectFiles.map(\.id)),
        existingFileCount: project.projectFiles.count,
        existingByteCount: totalBytes
      ) { additions in
        await addLibraryFiles(additions)
      }
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
    .confirmationDialog(
      fileToRemove.map { "Remove \"\($0.filename)\"?" } ?? "Remove source?",
      isPresented: Binding(
        get: { fileToRemove != nil },
        set: { if !$0 { fileToRemove = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Remove from Project", role: .destructive) {
        guard let target = fileToRemove else { return }
        fileToRemove = nil
        remove(target)
      }
      Button("Cancel", role: .cancel) { fileToRemove = nil }
    } message: {
      if let target = fileToRemove, workspace.isFileInLibrary(target.id) {
        Text("This removes the file from \(project.name). A copy remains saved in your Library.")
      } else {
        Text("This removes the source file from \(project.name). Save it to Library first if you want to keep a reusable copy.")
      }
    }
  }

  @ViewBuilder
  private var previewSheet: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          Text(previewFile?.filename ?? "Preview")
            .font(.headline)
            .lineLimit(1)
          if let previewFile {
            Text("\(sourceType(previewFile)) · \(macProjectFileDetail(previewFile))")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }
        }

        Spacer()

        if previewImage != nil {
          HStack(spacing: 4) {
            Button {
              withAnimation(.easeOut(duration: 0.14)) {
                previewZoomScale = max(Self.minPreviewZoom, previewZoomScale / 1.25)
              }
            } label: {
              Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(MacIconButtonStyle())
            .disabled(previewZoomScale <= Self.minPreviewZoom + 0.01)
            .help("Zoom out")

            Button {
              withAnimation(.easeOut(duration: 0.14)) {
                previewZoomScale = Self.minPreviewZoom
              }
            } label: {
              Text("\(Int((previewZoomScale * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .frame(minWidth: 42)
            }
            .buttonStyle(MacActionButtonStyle(.subtle, size: .small))
            .help("Reset zoom")

            Button {
              withAnimation(.easeOut(duration: 0.14)) {
                previewZoomScale = min(Self.maxPreviewZoom, previewZoomScale * 1.25)
              }
            } label: {
              Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(MacIconButtonStyle())
            .disabled(previewZoomScale >= Self.maxPreviewZoom - 0.01)
            .help("Zoom in")
          }
        }

        if let previewFile {
          Button("Export…", systemImage: "square.and.arrow.down") {
            export(previewFile, fromPreview: true)
          }
          .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
          .disabled(isWorking)

          if let previewSavedStatus {
            Label(previewSavedStatus, systemImage: "checkmark.circle.fill")
              .font(.caption.weight(.medium))
              .foregroundStyle(MacDesignTokens.Colors.accent)
              .padding(.horizontal, 8)
              .padding(.vertical, 5)
              .background(MacDesignTokens.Colors.accent.opacity(0.12), in: Capsule())
          } else {
            let alreadyInLibrary = workspace.isFileInLibrary(previewFile.id)
            Button(
              alreadyInLibrary ? "In Library" : "Save to Library",
              systemImage: alreadyInLibrary ? "checkmark.circle" : "books.vertical"
            ) {
              savePreviewFileToLibrary(previewFile)
            }
            .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
            .disabled(workspace.isBusy || alreadyInLibrary)
          }
        }

        Button("Done") {
          showingPreview = false
        }
        .buttonStyle(MacActionButtonStyle(.secondary))
        .keyboardShortcut(.cancelAction)
      }
      .padding(.horizontal, 16)
      .frame(height: 54)
      .background(MacDesignTokens.Colors.surface)

      Divider()

      if let previewErrorMessage {
        MacProjectInlineErrorBanner(message: previewErrorMessage) {
          self.previewErrorMessage = nil
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        Divider()
      }

      if let previewImage {
        MacZoomableImageView(
          image: previewImage,
          scale: $previewZoomScale,
          minScale: Self.minPreviewZoom,
          maxScale: Self.maxPreviewZoom
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let previewURL {
        MacLibraryQuickLookView(url: previewURL)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ProgressView()
          .controlSize(.large)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(
      minWidth: MacDesignTokens.Sheet.previewMinWidth,
      idealWidth: MacDesignTokens.Sheet.previewIdealWidth,
      minHeight: MacDesignTokens.Sheet.previewMinHeight,
      idealHeight: MacDesignTokens.Sheet.previewIdealHeight
    )
    .background(MacDesignTokens.Colors.canvas)
  }

  private var formattedTotalBytes: String {
    ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
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
    previewSavedStatus = nil
    previewErrorMessage = nil
    previewZoomScale = Self.minPreviewZoom
    let fileID = file.id
    let filename = file.filename
    let isImage = MacProjectFileImportSupport.isImageMIMEType(file.mimeType)
    let isGIF = file.mimeType.lowercased() == "image/gif"
      || filename.lowercased().hasSuffix(".gif")

    Task { @MainActor in
      guard let data = await workspace.fileData(fileID), !data.isEmpty else {
        if previewRequestID == requestID {
          previewLoadingID = nil
          workspace.errorMessage = "The file '\(filename)' could not be loaded."
        }
        return
      }
      guard previewRequestID == requestID else { return }

      if isImage && !isGIF {
        let bitmap = await Task.detached(priority: .userInitiated) {
          MacLibraryThumbnailCache.decodeFullImage(from: data)
        }.value

        guard previewRequestID == requestID else { return }
        if let bitmap {
          cleanupPreviewFileOnly()
          previewFile = file
          previewImage = NSImage(cgImage: bitmap.cgImage, size: bitmap.pointSize)
          previewLoadingID = nil
          showingPreview = true
          return
        }
      }

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
        previewImage = nil
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
    previewImage = nil
    previewZoomScale = Self.minPreviewZoom
    previewLoadingID = nil
    previewSavedStatus = nil
    previewErrorMessage = nil
  }

  private func export(_ file: ProjectFile, fromPreview: Bool = false) {
    guard !isWorking else { return }
    Task { @MainActor in
      let panel = NSSavePanel()
      panel.nameFieldStringValue = file.filename
      panel.canCreateDirectories = true
      let response: NSApplication.ModalResponse
      if let window = NSApp.keyWindow {
        response = await panel.beginSheetModal(for: window)
      } else {
        response = panel.runModal()
      }
      guard response == .OK, let destination = panel.url else { return }

      isWorking = true
      defer { isWorking = false }

      guard let data = await workspace.fileData(file.id), !data.isEmpty else {
        let message = "The file '\(file.filename)' could not be loaded."
        if fromPreview {
          previewErrorMessage = message
        } else {
          workspace.errorMessage = message
        }
        return
      }

      do {
        try await Task.detached(priority: .userInitiated) {
          try data.write(to: destination, options: .atomic)
        }.value
        if fromPreview {
          previewSavedStatus = "Exported"
        } else {
          toastCenter?.success("Exported \"\(destination.lastPathComponent)\"")
        }
      } catch {
        MacAppAnalytics.reportError("project_file_export_failed", component: "projects")
        if fromPreview {
          previewErrorMessage = error.localizedDescription
        } else {
          workspace.errorMessage = error.localizedDescription
        }
      }
    }
  }

  private func remove(_ file: ProjectFile) {
    Task { @MainActor in
      _ = await workspace.removeProjectFile(file.id, from: project.id)
    }
  }

  private func saveToLibrary(_ file: ProjectFile) {
    Task { @MainActor in
      _ = await workspace.saveProjectFileToLibrary(file, projectID: project.id)
    }
  }

  private func savePreviewFileToLibrary(_ file: ProjectFile) {
    previewErrorMessage = nil
    Task { @MainActor in
      let wasListed = workspace.isFileInLibrary(file.id)
      if await workspace.saveProjectFileToLibrary(file, projectID: project.id) {
        previewSavedStatus = wasListed ? "Already in Library" : "Saved to Library"
      } else {
        previewErrorMessage = workspace.consumeErrorMessage() ?? "Could not save file to Library."
      }
    }
  }

  private func addLibraryFiles(_ additions: [ProjectFile]) async -> String? {
    guard !additions.isEmpty else { return nil }
    if await workspace.addProjectFiles(additions, to: project.id) {
      if !trimmedSearchQuery.isEmpty {
        searchText = ""
      }
      return nil
    }
    return workspace.consumeErrorMessage() ?? "Could not add files from Library."
  }

  private func importFiles(_ result: Result<[URL], Error>) {
    switch result {
    case .failure(let error):
      MacAppAnalytics.reportError("project_file_picker_failed", component: "projects")
      workspace.errorMessage = error.localizedDescription
    case .success(let urls):
      importURLs(urls)
    }
  }

  private func importURLs(_ urls: [URL]) {
    guard !urls.isEmpty, canAddMoreFiles else { return }
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

        if await workspace.addProjectFiles(additions, to: project.id),
          !trimmedSearchQuery.isEmpty
        {
          searchText = ""
        }
      } catch {
        MacAppAnalytics.reportError("project_file_import_failed", component: "projects")
        workspace.errorMessage = error.localizedDescription
      }
    }
  }

  private func importDroppedImages(_ images: [MacDroppedImage]) {
    guard !images.isEmpty, canAddMoreFiles else { return }
    let existingCount = project.projectFiles.count
    let existingBytes = totalBytes
    isWorking = true
    Task { @MainActor in
      defer { isWorking = false }
      do {
        let additions = try await Task.detached(priority: .userInitiated) {
          try MacProjectFileImportSupport.importDroppedImages(
            images,
            existingCount: existingCount,
            existingBytes: existingBytes
          )
        }.value

        if await workspace.addProjectFiles(additions, to: project.id),
          !trimmedSearchQuery.isEmpty
        {
          searchText = ""
        }
      } catch {
        MacAppAnalytics.reportError("project_file_import_failed", component: "projects")
        workspace.errorMessage = error.localizedDescription
      }
    }
  }
}

private struct MacProjectSourceRow: View {
  let file: ProjectFile
  let subtitle: String
  let isInLibrary: Bool
  let isLoadingPreview: Bool
  @Bindable var workspace: MacWorkspaceModel
  let preview: () -> Void
  let export: () -> Void
  let saveToLibrary: () -> Void
  let requestRemove: () -> Void

  @State private var isHovered = false

  private var thumbnailAttachment: ChatAttachment {
    ChatAttachment(
      id: file.id,
      kind: MacProjectFileImportSupport.isImageMIMEType(file.mimeType) ? .image : .file,
      filename: file.filename,
      mimeType: file.mimeType,
      data: Data(),
      declaredByteCount: file.byteCount
    )
  }

  var body: some View {
    HStack(spacing: 12) {
      Button(action: preview) {
        HStack(spacing: 12) {
          MacLibraryPickerThumbnail(
            attachment: thumbnailAttachment,
            loadThumbnail: { _, _ in
              await workspace.fileData(file.id)
            }
          )

          VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
              Text(file.filename)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(MacDesignTokens.Colors.textPrimary)
                .lineLimit(1)
              if isInLibrary {
                Text("In Library")
                  .font(.caption2.weight(.medium))
                  .foregroundStyle(MacDesignTokens.Colors.accent)
                  .padding(.horizontal, 6)
                  .padding(.vertical, 1.5)
                  .background(MacDesignTokens.Colors.accent.opacity(0.11), in: Capsule())
              }
            }
            Text(subtitle)
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
              .lineLimit(1)
          }

          Spacer()

          if isLoadingPreview {
            ProgressView()
              .controlSize(.small)
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      Menu {
        rowActions
      } label: {
        MacIconMenuLabel(systemImage: "ellipsis")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Source actions")
    }
    .padding(.horizontal, 12)
    .frame(minHeight: 58)
    .background(isHovered ? Color.primary.opacity(0.03) : Color.clear)
    .onHover { isHovered = $0 }
    .animation(.easeOut(duration: MacDesignTokens.Control.interactionDuration), value: isHovered)
    .contextMenu {
      rowActions
    }
  }

  @ViewBuilder
  private var rowActions: some View {
    Button("Preview", systemImage: "eye", action: preview)
    Button("Export…", systemImage: "square.and.arrow.down", action: export)
    Button(
      isInLibrary ? "Already in Library" : "Save to Library",
      systemImage: isInLibrary ? "checkmark.circle" : "books.vertical",
      action: saveToLibrary
    )
    .disabled(isInLibrary)
    Divider()
    Button("Remove from Project…", systemImage: "trash", role: .destructive, action: requestRemove)
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
  @State private var presetToDelete: ProjectToolPreset?
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

  private var controlsDisabled: Bool {
    isSaving || workspace.isBusy
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
        if isSaving {
          HStack(spacing: 6) {
            ProgressView()
              .controlSize(.small)
            Text("Saving…")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }
        } else {
          Label("Saves automatically", systemImage: "checkmark.circle")
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)

      Divider()

      HStack(spacing: 0) {
        MacProjectToolsConfigurationView(
          mcp: mcp,
          configuration: configuration,
          isDisabled: controlsDisabled
        ) { updated in
          persist(configuration: updated, presets: presets, successMessage: nil)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        Divider()

        toolPresets
          .frame(width: 260)
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
    .confirmationDialog(
      presetToDelete.map { "Delete \"\($0.name)\"?" } ?? "Delete tool preset?",
      isPresented: Binding(
        get: { presetToDelete != nil },
        set: { if !$0 { presetToDelete = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete Preset", role: .destructive) {
        guard let target = presetToDelete else { return }
        presetToDelete = nil
        var nextPresets = presets
        nextPresets.removeAll { $0.id == target.id }
        persist(
          configuration: configuration,
          presets: nextPresets,
          successMessage: "Tool preset deleted"
        )
      }
      Button("Cancel", role: .cancel) { presetToDelete = nil }
    } message: {
      Text("This removes the saved tool preset from \(project.name).")
    }
    .onChange(of: project.id) { _, _ in
      syncFromProject()
      pendingOverwriteOnDismiss = nil
      pendingOverwriteName = nil
      presetToDelete = nil
    }
    .onChange(of: project.mcpConfiguration) { _, _ in
      if !isSaving {
        configuration = project.mcpConfiguration ?? MCPChatToolConfiguration()
      }
    }
    .onChange(of: project.projectToolPresets) { _, _ in
      if !isSaving {
        presets = project.projectToolPresets
      }
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
        .buttonStyle(MacIconButtonStyle())
        .disabled(controlsDisabled)
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
                  Button("Apply") { applyPreset(preset) }
                    .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
                    .disabled(controlsDisabled)
                  Spacer()
                  Button(role: .destructive) {
                    presetToDelete = preset
                  } label: {
                    Image(systemName: "trash")
                      .foregroundStyle(MacDesignTokens.Colors.textMuted)
                  }
                  .buttonStyle(MacIconButtonStyle())
                  .disabled(controlsDisabled)
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
      .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
      .disabled(controlsDisabled)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(14)
    .background(MacDesignTokens.Colors.canvas)
  }

  private func syncFromProject() {
    configuration = project.mcpConfiguration ?? MCPChatToolConfiguration()
    presets = project.projectToolPresets
  }

  private func applyPreset(_ preset: ProjectToolPreset) {
    persist(
      configuration: preset.configuration,
      presets: presets,
      successMessage: "Applied \"\(preset.name)\""
    )
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
    var nextPresets = presets
    if let index = nextPresets.firstIndex(where: {
      $0.name.caseInsensitiveCompare(name) == .orderedSame
    }) {
      nextPresets[index].name = name
      nextPresets[index].configuration = configuration
    } else if nextPresets.count < ProjectWorkspaceStore.maxPresetCount {
      nextPresets.append(ProjectToolPreset(name: name, configuration: configuration))
    } else {
      return
    }
    persist(
      configuration: configuration,
      presets: nextPresets,
      successMessage: "Tool preset saved"
    )
  }

  private func persist(
    configuration nextConfiguration: MCPChatToolConfiguration,
    presets nextPresets: [ProjectToolPreset],
    successMessage: String?
  ) {
    guard !controlsDisabled else { return }
    let previousConfiguration = configuration
    let previousPresets = presets
    configuration = nextConfiguration
    presets = nextPresets
    isSaving = true
    Task { @MainActor in
      defer { isSaving = false }
      let saved = await workspace.replaceProjectToolSettings(
        id: project.id,
        mcpConfiguration: nextConfiguration,
        toolPresets: nextPresets,
        successMessage: successMessage
      )
      if saved {
        await mcp.reloadFromStorage()
      } else {
        configuration = previousConfiguration
        presets = previousPresets
      }
    }
  }

  private func toolPresetSummary(_ preset: ProjectToolPreset) -> String {
    let count = preset.configuration.enabledServerIDs.count
    return "\(count) server\(count == 1 ? "" : "s")"
  }
}

private struct MacProjectIconColorPicker: View {
  @Binding var symbolName: String
  @Binding var accentID: String

  private let symbols = MacProjectWorkspaceEditorSupport.symbols

  private var selectedAccent: Color {
    MacProjectAccentOption(rawValue: accentID)?.color ?? .blue
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
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
                .foregroundStyle(
                  symbolName == symbol ? selectedAccent : MacDesignTokens.Colors.textPrimary
                )
                .frame(width: 34, height: 30)
                .background(
                  symbolName == symbol ? selectedAccent.opacity(0.16) : Color.clear,
                  in: RoundedRectangle(cornerRadius: 7)
                )
                .overlay {
                  if symbolName == symbol {
                    RoundedRectangle(cornerRadius: 7)
                      .stroke(selectedAccent.opacity(0.45), lineWidth: 1)
                  }
                }
            }
            .buttonStyle(.plain)
            .help(MacProjectWorkspaceEditorSupport.symbolTitle(symbol))
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
    }
  }
}

private struct MacProjectCreateSheet: View {
  @Bindable var workspace: MacWorkspaceModel
  @Bindable var providers: MacProviderModel
  let created: (ProjectID) -> Void

  @Environment(\.dismiss) private var dismiss
  @FocusState private var nameFocused: Bool
  @State private var name = ""
  @State private var symbolName = "folder.fill"
  @State private var accentID = "blue"
  @State private var accountID: ProviderAccountID?
  @State private var modelID: ModelID?
  @State private var isSaving = false
  @State private var saveError: String?

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
          if let saveError {
            MacProjectInlineErrorBanner(message: saveError) {
              self.saveError = nil
            }
          }

          VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
              Image(systemName: symbolName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(selectedAccent)
                .frame(width: 52, height: 52)
                .background(selectedAccent.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))

              TextField("Project name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit { create() }
            }

            if let nameValidationError {
              Text(nameValidationError)
                .font(.caption)
                .foregroundStyle(.red)
            }
          }

          MacProjectIconColorPicker(symbolName: $symbolName, accentID: $accentID)

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
    .frame(
      width: MacDesignTokens.Sheet.standardWidth,
      height: MacDesignTokens.Sheet.standardHeight
    )
    .background(MacDesignTokens.Colors.canvas)
    .onAppear {
      nameFocused = true
    }
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
    saveError = nil
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
      } else {
        saveError = workspace.consumeErrorMessage() ?? "Could not create project."
      }
    }
  }
}

private struct MacProjectIdentityEditor: View {
  let project: ChatProject
  @Bindable var workspace: MacWorkspaceModel

  @Environment(\.dismiss) private var dismiss
  @FocusState private var nameFocused: Bool
  @State private var name: String
  @State private var symbolName: String
  @State private var accentID: String
  @State private var isSaving = false
  @State private var saveError: String?

  init(project: ChatProject, workspace: MacWorkspaceModel) {
    self.project = project
    self.workspace = workspace
    _name = State(initialValue: project.name)
    _symbolName = State(initialValue: project.symbolName)
    _accentID = State(initialValue: project.accentID)
  }

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var selectedAccent: Color {
    MacProjectAccentOption(rawValue: accentID)?.color ?? .blue
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
        title: "Edit Project",
        primaryTitle: "Save",
        primaryEnabled: canSave,
        cancel: { dismiss() },
        primary: save
      )
      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          if let saveError {
            MacProjectInlineErrorBanner(message: saveError) {
              self.saveError = nil
            }
          }

          VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
              Image(systemName: symbolName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(selectedAccent)
                .frame(width: 52, height: 52)
                .background(selectedAccent.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))

              TextField("Project name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit { save() }
            }

            if let nameValidationError {
              Text(nameValidationError)
                .font(.caption)
                .foregroundStyle(.red)
            }
          }

          MacProjectIconColorPicker(symbolName: $symbolName, accentID: $accentID)
        }
        .padding(20)
      }
    }
    .frame(
      width: MacDesignTokens.Sheet.standardWidth,
      height: MacDesignTokens.Sheet.compactHeight
    )
    .background(MacDesignTokens.Colors.canvas)
    .onAppear {
      nameFocused = true
    }
  }

  private func save() {
    guard canSave else { return }
    isSaving = true
    saveError = nil
    Task { @MainActor in
      defer { isSaving = false }
      if await workspace.updateProjectIdentity(
        id: project.id,
        name: name,
        symbolName: symbolName,
        accentID: accentID
      ) {
        dismiss()
      } else {
        saveError = workspace.consumeErrorMessage() ?? "Could not update project."
      }
    }
  }
}

private struct MacProjectDefaultsEditor: View {
  let project: ChatProject
  @Bindable var workspace: MacWorkspaceModel
  @Bindable var providers: MacProviderModel

  @Environment(\.dismiss) private var dismiss
  @State private var accountID: ProviderAccountID?
  @State private var modelID: ModelID?
  @State private var isSaving = false
  @State private var saveError: String?

  init(
    project: ChatProject,
    workspace: MacWorkspaceModel,
    providers: MacProviderModel
  ) {
    self.project = project
    self.workspace = workspace
    self.providers = providers
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
    if let existing = providers.accounts.first(where: { $0.id == accountID }) {
      return "\(existing.label) (Disabled)"
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

      VStack(spacing: 0) {
        if let saveError {
          MacProjectInlineErrorBanner(message: saveError) {
            self.saveError = nil
          }
          .padding([.horizontal, .top], 16)
        }

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
        .scrollContentBackground(.hidden)
        .padding(10)
      }
    }
    .frame(
      width: MacDesignTokens.Sheet.standardWidth,
      height: MacDesignTokens.Sheet.compactHeight
    )
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

  private func save() {
    guard canSave else { return }
    isSaving = true
    saveError = nil
    Task { @MainActor in
      defer { isSaving = false }
      if await workspace.updateProjectDefaults(
        id: project.id,
        accountID: accountID,
        modelID: modelID
      ) {
        dismiss()
      } else {
        saveError = workspace.consumeErrorMessage() ?? "Could not update project defaults."
      }
    }
  }
}

private struct MacProjectInstructionsEditor: View {
  let project: ChatProject
  @Bindable var workspace: MacWorkspaceModel

  @Environment(\.dismiss) private var dismiss
  @FocusState private var editorFocused: Bool
  @State private var instructions: String
  @State private var isSaving = false
  @State private var saveError: String?

  init(project: ChatProject, workspace: MacWorkspaceModel) {
    self.project = project
    self.workspace = workspace
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
        if let saveError {
          MacProjectInlineErrorBanner(message: saveError) {
            self.saveError = nil
          }
        }

        ZStack(alignment: .topLeading) {
          TextEditor(text: $instructions)
            .font(.body)
            .scrollContentBackground(.hidden)
            .focused($editorFocused)
            .padding(8)
            .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
              RoundedRectangle(cornerRadius: 8)
                .stroke(MacDesignTokens.Colors.separator.opacity(0.75), lineWidth: 0.75)
            }

          if instructions.isEmpty {
            Text("Custom system prompt for new chats in this project…")
              .font(.body)
              .foregroundStyle(MacDesignTokens.Colors.textMuted.opacity(0.65))
              .padding(.top, 13)
              .padding(.leading, 13)
              .allowsHitTesting(false)
              .accessibilityHidden(true)
          }
        }

        HStack {
          Text("Used as the system prompt for new chats in this project. Leave blank to use the app default.")
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
          Spacer(minLength: 8)
          if !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Button("Clear", role: .destructive) {
              instructions = ""
            }
            .buttonStyle(MacActionButtonStyle(.subtle, size: .small))
            .disabled(isSaving)
          }
        }
      }
      .padding(16)
    }
    .frame(
      width: MacDesignTokens.Sheet.standardWidth,
      height: MacDesignTokens.Sheet.compactHeight
    )
    .background(MacDesignTokens.Colors.canvas)
    .onAppear {
      editorFocused = true
    }
  }

  private func save() {
    isSaving = true
    saveError = nil
    Task { @MainActor in
      defer { isSaving = false }
      if await workspace.updateProjectInstructions(id: project.id, instructions: instructions) {
        dismiss()
      } else {
        saveError = workspace.consumeErrorMessage() ?? "Could not save project instructions."
      }
    }
  }
}

private struct MacProjectPromptEditor: View {
  let existing: ProjectPromptPreset?
  let existingNames: Set<String>
  let atLimit: Bool
  let save: (ProjectPromptPreset) async -> String?

  @Environment(\.dismiss) private var dismiss
  @FocusState private var nameFocused: Bool
  @State private var name: String
  @State private var prompt: String
  @State private var isSaving = false
  @State private var saveError: String?

  init(
    existing: ProjectPromptPreset?,
    existingNames: Set<String>,
    atLimit: Bool = false,
    save: @escaping (ProjectPromptPreset) async -> String?
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
        if let saveError {
          MacProjectInlineErrorBanner(message: saveError) {
            self.saveError = nil
          }
        }

        TextField("Prompt name", text: $name)
          .textFieldStyle(.roundedBorder)
          .focused($nameFocused)

        if let nameError {
          Text(nameError)
            .font(.caption)
            .foregroundStyle(.red)
        }

        ZStack(alignment: .topLeading) {
          TextEditor(text: $prompt)
            .font(.body)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 190)
            .padding(8)
            .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
              RoundedRectangle(cornerRadius: 8)
                .stroke(MacDesignTokens.Colors.separator.opacity(0.75), lineWidth: 0.75)
            }

          if prompt.isEmpty {
            Text("Write a reusable prompt to insert into chats…")
              .font(.body)
              .foregroundStyle(MacDesignTokens.Colors.textMuted.opacity(0.65))
              .padding(.top, 13)
              .padding(.leading, 13)
              .allowsHitTesting(false)
              .accessibilityHidden(true)
          }
        }
      }
      .padding(16)
    }
    .frame(
      width: MacDesignTokens.Sheet.standardWidth,
      height: MacDesignTokens.Sheet.compactHeight
    )
    .background(MacDesignTokens.Colors.canvas)
    .onAppear {
      nameFocused = true
    }
  }

  private var canSave: Bool {
    !isSaving
      && !atLimit
      && !trimmedName.isEmpty
      && !trimmedPrompt.isEmpty
      && nameError == nil
  }

  private func saveValue() {
    guard canSave else { return }
    let value = ProjectPromptPreset(
      id: existing?.id ?? UUID().uuidString.lowercased(),
      name: trimmedName,
      prompt: trimmedPrompt
    )
    isSaving = true
    saveError = nil
    Task { @MainActor in
      if let error = await save(value) {
        isSaving = false
        saveError = error
      } else {
        dismiss()
      }
    }
  }
}

private struct MacProjectToolPresetNameSheet: View {
  let existingPresets: [ProjectToolPreset]
  let save: (String) -> Void

  @Environment(\.dismiss) private var dismiss
  @FocusState private var nameFocused: Bool
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
          .textFieldStyle(.roundedBorder)
          .focused($nameFocused)
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
    .frame(width: 440, height: 195)
    .background(MacDesignTokens.Colors.canvas)
    .onAppear {
      nameFocused = true
    }
  }

  private func saveValue() {
    guard canSave else { return }
    save(trimmedName)
    dismiss()
  }
}

private struct MacProjectChatRenameSheet: View {
  let conversation: ChatConversation
  let save: (String) async -> String?

  @Environment(\.dismiss) private var dismiss
  @FocusState private var titleFocused: Bool
  @State private var title: String
  @State private var isSaving = false
  @State private var saveError: String?

  init(
    conversation: ChatConversation,
    save: @escaping (String) async -> String?
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
    VStack(alignment: .leading, spacing: 14) {
      Text("Rename Conversation")
        .font(.headline)

      if let saveError {
        MacProjectInlineErrorBanner(message: saveError) {
          self.saveError = nil
        }
      }

      TextField("Conversation name", text: $title)
        .textFieldStyle(.roundedBorder)
        .focused($titleFocused)
        .onSubmit { commit() }

      HStack(spacing: 8) {
        Spacer()
        Button("Cancel") { dismiss() }
          .buttonStyle(MacActionButtonStyle(.secondary))
          .keyboardShortcut(.cancelAction)
        Button("Rename") { commit() }
          .buttonStyle(MacActionButtonStyle(.primary))
          .keyboardShortcut(.defaultAction)
          .disabled(!canSave)
      }
    }
    .padding(20)
    .frame(width: 390)
    .background(MacDesignTokens.Colors.canvas)
    .onAppear {
      titleFocused = true
    }
  }

  private func commit() {
    guard canSave else { return }
    let value = trimmedTitle
    isSaving = true
    saveError = nil
    Task { @MainActor in
      if let error = await save(value) {
        isSaving = false
        saveError = error
      } else {
        dismiss()
      }
    }
  }
}

private struct MacProjectInlineErrorBanner: View {
  let message: String
  let dismiss: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.red)
        .padding(.top, 1)
      Text(message)
        .font(.caption)
        .foregroundStyle(MacDesignTokens.Colors.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 4)
      Button(action: dismiss) {
        Image(systemName: "xmark")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Dismiss error")
    }
    .padding(10)
    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color.red.opacity(0.28), lineWidth: 0.75)
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
    HStack(spacing: 8) {
      Text(title)
        .font(.headline)
      Spacer()
      Button("Cancel", action: cancel)
        .buttonStyle(MacActionButtonStyle(.secondary))
        .keyboardShortcut(.cancelAction)
      Button(primaryTitle, action: primary)
        .buttonStyle(MacActionButtonStyle(.primary))
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

private struct MacProjectLibrarySourcePickerSheet: View {
  @Bindable var workspace: MacWorkspaceModel
  let excludedIDs: Set<String>
  let existingFileCount: Int
  let existingByteCount: Int
  let addFiles: ([ProjectFile]) async -> String?

  @Environment(\.dismiss) private var dismiss
  @State private var selection: Set<LibraryEntryID> = []
  @State private var searchText = ""
  @State private var isLoading = false
  @State private var errorMessage: String?

  private var trimmedSearchQuery: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var allAvailableEntries: [LibraryEntry] {
    workspace.libraryEntries
      .filter { !excludedIDs.contains($0.id.rawValue) }
      .sorted { $0.createdAt > $1.createdAt }
  }

  private var visibleEntries: [LibraryEntry] {
    let query = trimmedSearchQuery
    guard !query.isEmpty else { return allAvailableEntries }
    return allAvailableEntries.filter {
      $0.filename.localizedCaseInsensitiveContains(query)
        || $0.mimeType.localizedCaseInsensitiveContains(query)
    }
  }

  private var activeSelection: Set<LibraryEntryID> {
    selection.intersection(Set(allAvailableEntries.map(\.id)))
  }

  private var selectedEntries: [LibraryEntry] {
    allAvailableEntries.filter { activeSelection.contains($0.id) }
  }

  private var remainingSlots: Int {
    max(0, ProjectWorkspaceStore.maxFileCount - existingFileCount - activeSelection.count)
  }

  private var projectedBytes: Int {
    existingByteCount + selectedEntries.reduce(0) { $0 + $1.byteCount }
  }

  private var exceedsByteLimit: Bool {
    projectedBytes > ProjectWorkspaceStore.maxTotalFileBytes
      || selectedEntries.contains { $0.byteCount > ProjectWorkspaceStore.maxFileBytes }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Text("Add Sources from Library")
          .font(.headline)
        Spacer()
        Button("Cancel") { dismiss() }
          .buttonStyle(MacActionButtonStyle(.secondary))
          .keyboardShortcut(.cancelAction)
          .disabled(isLoading)
        Button(activeSelection.isEmpty ? "Add" : "Add (\(activeSelection.count))") {
          commit()
        }
        .buttonStyle(MacActionButtonStyle(.primary))
        .keyboardShortcut(.defaultAction)
        .disabled(activeSelection.isEmpty || exceedsByteLimit || isLoading)
      }
      .padding(16)
      .background(MacDesignTokens.Colors.surface)

      Divider()

      VStack(spacing: 8) {
        MacProjectSearchField(placeholder: "Search Library files", text: $searchText)

        HStack(spacing: 8) {
          Text(capacityMessage)
            .font(.caption)
            .foregroundStyle(
              (exceedsByteLimit || remainingSlots == 0)
                ? Color.orange
                : MacDesignTokens.Colors.textMuted
            )
          Spacer(minLength: 8)
          Text(
            "\(ByteCountFormatter.string(fromByteCount: Int64(projectedBytes), countStyle: .file)) / 40 MB"
          )
          .font(.caption.monospacedDigit())
          .foregroundStyle(
            projectedBytes > ProjectWorkspaceStore.maxTotalFileBytes
              ? Color.orange
              : MacDesignTokens.Colors.textMuted
          )
        }
      }
      .padding(12)

      Divider()

      if visibleEntries.isEmpty {
        ContentUnavailableView(
          trimmedSearchQuery.isEmpty ? "No Available Library Items" : "No Matches",
          systemImage: trimmedSearchQuery.isEmpty ? "books.vertical" : "magnifyingglass",
          description: Text(
            trimmedSearchQuery.isEmpty
              ? "Import files into Library or remove an existing source file from this project."
              : "Try a different file name."
          )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(spacing: 2) {
            ForEach(visibleEntries) { entry in
              let isSelected = activeSelection.contains(entry.id)
              let exceedsLimit = !isSelected
                && (entry.byteCount > ProjectWorkspaceStore.maxFileBytes
                  || projectedBytes + entry.byteCount > ProjectWorkspaceStore.maxTotalFileBytes)
              MacLibraryPickerSelectableRow(
                title: entry.filename,
                detail: "\(entry.byteCountText) · \(entry.mimeType)",
                isSelected: isSelected,
                isDisabled: isLoading || (!isSelected && (remainingSlots == 0 || exceedsLimit)),
                action: { toggle(entry.id) }
              ) {
                MacLibraryPickerThumbnail(
                  attachment: ChatAttachment(
                    id: entry.id.rawValue,
                    kind: entry.kind,
                    filename: entry.filename,
                    mimeType: entry.mimeType,
                    data: Data(),
                    declaredByteCount: entry.byteCount
                  ),
                  loadThumbnail: { _, size in
                    await workspace.libraryThumbnail(entry, maxPixelSize: size)
                  }
                )
              }
            }
          }
          .padding(10)
        }
      }
    }
    .frame(
      width: MacDesignTokens.Sheet.standardWidth,
      height: MacDesignTokens.Sheet.standardHeight
    )
    .background(MacDesignTokens.Colors.canvas)
    .overlay {
      if isLoading {
        ProgressView()
          .padding(12)
          .background(.regularMaterial, in: Capsule())
      }
    }
    .alert(
      "Project Source Error",
      isPresented: Binding(
        get: { errorMessage != nil },
        set: { if !$0 { errorMessage = nil } }
      )
    ) {
      Button("OK", role: .cancel) { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "Unknown error")
    }
  }

  private var capacityMessage: String {
    if projectedBytes > ProjectWorkspaceStore.maxTotalFileBytes {
      return "Project reference files cannot exceed 40 MB total."
    }
    if remainingSlots == 0 {
      return "Maximum of \(ProjectWorkspaceStore.maxFileCount) project files reached."
    }
    let noun = remainingSlots == 1 ? "file" : "files"
    return "You can add up to \(remainingSlots) more \(noun)."
  }

  private func toggle(_ id: LibraryEntryID) {
    if selection.contains(id) {
      selection.remove(id)
    } else if remainingSlots > 0 {
      selection.insert(id)
    }
  }

  private func commit() {
    let entries = selectedEntries
    guard !entries.isEmpty, !isLoading else { return }
    isLoading = true
    Task { @MainActor in
      defer { isLoading = false }

      var additions: [ProjectFile] = []
      additions.reserveCapacity(entries.count)
      for entry in entries {
        guard let data = await workspace.libraryData(entry), !data.isEmpty else {
          errorMessage = "The file '\(entry.filename)' could not be loaded."
          return
        }
        additions.append(
          ProjectFile(
            id: entry.id.rawValue,
            filename: entry.filename,
            mimeType: entry.mimeType,
            data: data,
            declaredByteCount: data.count,
            createdAt: entry.createdAt
          )
        )
      }

      if let error = await addFiles(additions) {
        errorMessage = error
      } else {
        dismiss()
      }
    }
  }
}
