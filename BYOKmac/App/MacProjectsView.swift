import BYOKchatProviderCore
import SwiftUI
import UniformTypeIdentifiers

struct MacProjectsView: View {
  @Bindable var workspace: MacWorkspaceModel
  @Bindable var providers: MacProviderModel
  @Bindable var chats: MacChatSessionModel
  @Bindable var mcp: MacMCPModel
  let startNewChat: (ProjectID, String?) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var selectedProjectID: ProjectID?
  @State private var editingProject: ChatProject?
  @State private var showingNewProject = false
  @State private var deleteProject: ChatProject?

  private var selectedProject: ChatProject? { workspace.project(selectedProjectID) }

  var body: some View {
    NavigationSplitView {
      List(selection: $selectedProjectID) {
        ForEach(workspace.projects) { project in
          Label(project.name, systemImage: project.symbolName)
            .tag(project.id)
            .contextMenu {
              Button("Edit", systemImage: "pencil") { editingProject = project }
              Button("Delete", systemImage: "trash", role: .destructive) { deleteProject = project }
            }
        }
      }
      .navigationTitle("Projects")
      .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 300)
      .toolbar {
        ToolbarItem {
          Button("New Project", systemImage: "plus") { showingNewProject = true }
        }
      }
    } detail: {
      if let project = selectedProject {
        MacProjectDetailView(
          project: project,
          workspace: workspace,
          chats: chats,
          mcp: mcp,
          edit: { editingProject = project },
          startNewChat: { prompt in
            startNewChat(project.id, prompt)
            dismiss()
          }
        )
      } else {
        ContentUnavailableView(
          workspace.projects.isEmpty ? "No Projects" : "Select a Project",
          systemImage: "folder",
          description: Text(workspace.projects.isEmpty ? "Create a project for reusable instructions, defaults, files, prompts, and tools." : "Choose a project from the sidebar.")
        )
      }
    }
    .frame(minWidth: 860, minHeight: 580)
    .background(MacDesignTokens.Colors.canvas)
    .onAppear {
      if selectedProjectID == nil { selectedProjectID = workspace.projects.first?.id }
    }
    .sheet(isPresented: $showingNewProject) {
      MacProjectEditorView(workspace: workspace, providers: providers, mcp: mcp, project: nil)
    }
    .sheet(item: $editingProject) { project in
      MacProjectEditorView(workspace: workspace, providers: providers, mcp: mcp, project: project)
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
            if selectedProjectID == project.id {
              selectedProjectID = workspace.projects.first?.id
            }
          }
        }
      }
      Button("Cancel", role: .cancel) { deleteProject = nil }
    } message: {
      Text("Conversations remain available and become standalone.")
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
}

private struct MacProjectDetailView: View {
  let project: ChatProject
  @Bindable var workspace: MacWorkspaceModel
  @Bindable var chats: MacChatSessionModel
  @Bindable var mcp: MacMCPModel
  let edit: () -> Void
  let startNewChat: (String?) -> Void

  private var memberConversations: [ChatConversation] {
    chats.conversationSummaries.filter { workspace.projectID(for: $0.id) == project.id }
  }

  private var otherConversations: [ChatConversation] {
    chats.conversationSummaries.filter { workspace.projectID(for: $0.id) != project.id }
  }

  private var enabledToolCount: Int {
    let enabled = Set(project.mcpConfiguration?.enabledServerIDs ?? [])
    return enabled.reduce(0) { total, id in total + mcp.tools(for: id).count }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 6) {
            Label(project.name, systemImage: project.symbolName)
              .font(.title2.weight(.semibold))
              .foregroundStyle(projectAccent(project.accentID))
            Text(project.instructions.isEmpty ? "No project instructions" : project.instructions)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
              .textSelection(.enabled)
              .lineLimit(5)
          }
          Spacer()
          Button("Edit Project", action: edit)
        }

        GroupBox("New Chat Defaults") {
          VStack(alignment: .leading, spacing: 7) {
            LabeledContent("Provider") { Text(project.accountID?.rawValue ?? "App Default") }
            LabeledContent("Model") { Text(project.modelID?.rawValue ?? "Account Default") }
          }
          .padding(8)
        }

        GroupBox("Default Tools") {
          VStack(alignment: .leading, spacing: 7) {
            LabeledContent("MCP Servers") {
              Text((project.mcpConfiguration?.enabledServerIDs.count ?? 0).formatted())
            }
            LabeledContent("Discovered Tools") {
              Text(enabledToolCount.formatted())
            }
            LabeledContent("Custom Permissions") {
              Text((project.mcpConfiguration?.toolPolicies.count ?? 0).formatted())
            }
            Text("Chats inherit these tools until they create their own override.")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }
          .padding(8)
        }

        GroupBox("Reference Files") {
          VStack(alignment: .leading, spacing: 8) {
            if project.projectFiles.isEmpty {
              Text("No reference files")
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
            } else {
              ForEach(project.projectFiles) { file in
                HStack {
                  Image(systemName: file.mimeType.hasPrefix("image/") ? "photo" : "doc")
                  Text(file.filename).lineLimit(1)
                  Spacer()
                  Text(ByteCountFormatter.string(fromByteCount: Int64(file.byteCount), countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(MacDesignTokens.Colors.textMuted)
                }
              }
            }
          }
          .padding(8)
        }

        GroupBox("Reusable Prompts") {
          VStack(alignment: .leading, spacing: 8) {
            if project.projectPromptPresets.isEmpty {
              Text("No prompt presets")
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
            } else {
              ForEach(project.projectPromptPresets) { preset in
                HStack(alignment: .top) {
                  VStack(alignment: .leading, spacing: 3) {
                    Text(preset.name).fontWeight(.medium)
                    Text(preset.prompt)
                      .font(.caption)
                      .foregroundStyle(MacDesignTokens.Colors.textMuted)
                      .lineLimit(2)
                  }
                  Spacer()
                  Button("Use") { startNewChat(preset.prompt) }
                }
              }
            }
          }
          .padding(8)
        }

        GroupBox("Tool Presets") {
          VStack(alignment: .leading, spacing: 8) {
            if project.projectToolPresets.isEmpty {
              Text("No tool presets")
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
            } else {
              ForEach(project.projectToolPresets) { preset in
                HStack {
                  Image(systemName: "wrench.and.screwdriver")
                  Text(preset.name)
                  Spacer()
                  Text("\(preset.configuration.enabledServerIDs.count) servers")
                    .font(.caption)
                    .foregroundStyle(MacDesignTokens.Colors.textMuted)
                }
              }
            }
          }
          .padding(8)
        }

        GroupBox("Conversations") {
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Button("New Chat in Project", systemImage: "square.and.pencil") { startNewChat(nil) }
              Spacer()
              if !otherConversations.isEmpty {
                Menu("Add Conversation…") {
                  ForEach(otherConversations) { conversation in
                    Button(conversation.title.isEmpty ? "New Chat" : conversation.title) {
                      Task {
                        if await workspace.assignConversation(conversation.id, to: project.id) {
                          await mcp.reloadFromStorage()
                        }
                      }
                    }
                  }
                }
              }
            }

            if memberConversations.isEmpty {
              Text("No conversations in this project")
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
            } else {
              ForEach(memberConversations) { conversation in
                HStack {
                  Image(systemName: "bubble.left")
                  Text(conversation.title.isEmpty ? "New Chat" : conversation.title).lineLimit(1)
                  Spacer()
                  Button("Remove", systemImage: "folder.badge.minus") {
                    Task {
                      if await workspace.removeConversation(conversation.id) {
                        await mcp.reloadFromStorage()
                      }
                    }
                  }
                  .labelStyle(.iconOnly)
                  .help("Remove from project")
                }
              }
            }
          }
          .padding(8)
        }
      }
      .frame(maxWidth: 720, alignment: .leading)
      .padding(24)
    }
    .background(MacDesignTokens.Colors.canvas)
  }

  private func projectAccent(_ raw: String) -> Color {
    switch raw {
    case "indigo": .indigo
    case "purple": .purple
    case "pink": .pink
    case "orange": .orange
    case "teal": .teal
    case "green": .green
    default: .blue
    }
  }
}

private struct MacProjectEditorView: View {
  @Bindable var workspace: MacWorkspaceModel
  @Bindable var providers: MacProviderModel
  @Bindable var mcp: MacMCPModel
  let project: ChatProject?

  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var symbolName: String
  @State private var accentID: String
  @State private var accountID: ProviderAccountID?
  @State private var modelID: ModelID?
  @State private var instructions: String
  @State private var files: [ProjectFile]
  @State private var mcpConfiguration: MCPChatToolConfiguration
  @State private var promptPresets: [ProjectPromptPreset]
  @State private var toolPresets: [ProjectToolPreset]
  @State private var showingFileImporter = false
  @State private var promptPresetToEdit: ProjectPromptPreset?
  @State private var showingNewPromptPreset = false
  @State private var showingNewToolPreset = false
  @State private var isSaving = false

  private let symbols = ["folder.fill", "briefcase.fill", "hammer.fill", "terminal.fill", "doc.text.fill", "lightbulb.fill", "paintbrush.fill", "shippingbox.fill"]
  private let accents = ["blue", "indigo", "purple", "pink", "orange", "teal", "green"]

  init(
    workspace: MacWorkspaceModel,
    providers: MacProviderModel,
    mcp: MacMCPModel,
    project: ChatProject?
  ) {
    self.workspace = workspace
    self.providers = providers
    self.mcp = mcp
    self.project = project
    _name = State(initialValue: project?.name ?? "")
    _symbolName = State(initialValue: project?.symbolName ?? "folder.fill")
    _accentID = State(initialValue: project?.accentID ?? "blue")
    _accountID = State(initialValue: project?.accountID)
    _modelID = State(initialValue: project?.modelID)
    _instructions = State(initialValue: project?.instructions ?? "")
    _files = State(initialValue: project?.projectFiles ?? [])
    _mcpConfiguration = State(initialValue: project?.mcpConfiguration ?? MCPChatToolConfiguration())
    _promptPresets = State(initialValue: project?.projectPromptPresets ?? [])
    _toolPresets = State(initialValue: project?.projectToolPresets ?? [])
  }

  private var enabledAccounts: [ProviderAccount] { providers.accounts.filter(\.isEnabled) }
  private var availableModels: [AccountModelRecord] {
    guard let accountID else { return [] }
    return providers.models(for: accountID).filter(\.isAvailable)
  }

  private var canSave: Bool {
    !isSaving && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(project == nil ? "New Project" : "Edit Project")
          .font(.headline)
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Save") { save() }
          .keyboardShortcut(.defaultAction)
          .disabled(!canSave)
      }
      .padding(16)

      Divider()

      Form {
        Section("Project") {
          TextField("Name", text: $name)
          Picker("Icon", selection: $symbolName) {
            ForEach(symbols, id: \.self) { Label($0, systemImage: $0).tag($0) }
          }
          Picker("Color", selection: $accentID) {
            ForEach(accents, id: \.self) { Text($0.capitalized).tag($0) }
          }
        }

        Section("New Chat Defaults") {
          Picker("Provider Account", selection: $accountID) {
            Text("App Default").tag(nil as ProviderAccountID?)
            ForEach(enabledAccounts) { Text($0.label).tag(Optional($0.id)) }
          }
          if accountID != nil {
            Picker("Model", selection: $modelID) {
              Text("Account Default").tag(nil as ModelID?)
              ForEach(availableModels) { Text($0.model.displayName).tag(Optional($0.model.id)) }
            }
          }
        }

        Section("Instructions") {
          TextEditor(text: $instructions)
            .frame(minHeight: 110)
          Text("Used as the system prompt for new chats in this project. Blank falls back to the app default prompt.")
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }

        Section("Reference Files") {
          ForEach(files) { file in
            HStack {
              Image(systemName: file.mimeType.hasPrefix("image/") ? "photo" : "doc")
              VStack(alignment: .leading) {
                Text(file.filename).lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: Int64(file.byteCount), countStyle: .file))
                  .font(.caption)
                  .foregroundStyle(MacDesignTokens.Colors.textMuted)
              }
              Spacer()
              Button("Remove", systemImage: "trash", role: .destructive) { files.removeAll { $0.id == file.id } }
                .labelStyle(.iconOnly)
            }
          }
          Button("Add Files…", systemImage: "doc.badge.plus") { showingFileImporter = true }
            .disabled(files.count >= 8)
        }

        Section("Default Tools") {
          MacProjectToolsConfigurationView(mcp: mcp, configuration: $mcpConfiguration)
            .frame(minHeight: 180, idealHeight: 280, maxHeight: 360)
          Text("Chats inherit these MCP servers and permissions until that chat creates its own override.")
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }

        Section("Reusable Prompts") {
          ForEach(promptPresets) { preset in
            HStack {
              VStack(alignment: .leading) {
                Text(preset.name)
                Text(preset.prompt).font(.caption).foregroundStyle(MacDesignTokens.Colors.textMuted).lineLimit(1)
              }
              Spacer()
              Button("Edit") { promptPresetToEdit = preset }
              Button("Delete", role: .destructive) { promptPresets.removeAll { $0.id == preset.id } }
            }
          }
          Button("Add Prompt Preset…", systemImage: "text.badge.plus") { showingNewPromptPreset = true }
        }

        Section("Tool Presets") {
          ForEach(toolPresets) { preset in
            HStack {
              Text(preset.name)
              Spacer()
              Text("\(preset.configuration.enabledServerIDs.count) servers")
                .font(.caption)
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
              Button("Delete", role: .destructive) { toolPresets.removeAll { $0.id == preset.id } }
            }
          }
          Button("Save Current Tool Defaults as Preset…", systemImage: "wrench.adjustable") { showingNewToolPreset = true }
        }
      }
      .formStyle(.grouped)
      .padding(10)
    }
    .frame(width: 720, height: 780)
    .background(MacDesignTokens.Colors.canvas)
    .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
      switch result {
      case .failure(let error): workspace.errorMessage = error.localizedDescription
      case .success(let urls): importFiles(urls)
      }
    }
    .sheet(isPresented: $showingNewPromptPreset) {
      MacPromptPresetEditor(existing: nil) { promptPresets.append($0) }
    }
    .sheet(item: $promptPresetToEdit) { preset in
      MacPromptPresetEditor(existing: preset) { value in
        if let index = promptPresets.firstIndex(where: { $0.id == value.id }) { promptPresets[index] = value }
      }
    }
    .sheet(isPresented: $showingNewToolPreset) {
      MacToolPresetNameSheet { name in
        toolPresets.append(ProjectToolPreset(name: name, configuration: mcpConfiguration))
      }
    }
    .onChange(of: accountID) { _, value in
      guard let value else { modelID = nil; return }
      if let modelID, !providers.models(for: value).contains(where: { $0.model.id == modelID && $0.isAvailable }) {
        self.modelID = nil
      }
    }
  }

  private func importFiles(_ urls: [URL]) {
    Task { @MainActor in
      do {
        let attachments = try await MacAttachmentImporter.importURLs(urls)
        let additions = attachments.map {
          ProjectFile(id: $0.id, filename: $0.filename, mimeType: $0.mimeType, data: $0.data, declaredByteCount: $0.byteCount)
        }
        let combined = files + additions
        guard combined.count <= 8 else { throw ProviderError.invalidRequest("A project can contain at most 8 reference files.") }
        guard combined.allSatisfy({ $0.byteCount <= 20 * 1_024 * 1_024 }) else { throw ProviderError.invalidRequest("Each project file must be no larger than 20 MB.") }
        guard combined.reduce(0, { $0 + $1.byteCount }) <= 40 * 1_024 * 1_024 else { throw ProviderError.invalidRequest("Project reference files cannot exceed 40 MB total.") }
        files = combined
      } catch {
        workspace.errorMessage = error.localizedDescription
      }
    }
  }

  private func save() {
    guard canSave else { return }
    isSaving = true
    Task { @MainActor in
      let success: Bool
      if let project {
        success = await workspace.updateProject(
          id: project.id,
          name: name,
          symbolName: symbolName,
          accentID: accentID,
          accountID: accountID,
          modelID: modelID,
          instructions: instructions,
          files: files,
          mcpConfiguration: mcpConfiguration,
          promptPresets: promptPresets,
          toolPresets: toolPresets
        )
      } else {
        success = await workspace.createProject(
          name: name,
          symbolName: symbolName,
          accentID: accentID,
          accountID: accountID,
          modelID: modelID,
          instructions: instructions,
          files: files,
          mcpConfiguration: mcpConfiguration,
          promptPresets: promptPresets,
          toolPresets: toolPresets
        ) != nil
      }
      if success { await mcp.reloadFromStorage() }
      isSaving = false
      if success { dismiss() }
    }
  }
}

private struct MacPromptPresetEditor: View {
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
    VStack(alignment: .leading, spacing: 14) {
      Text(existing == nil ? "New Prompt Preset" : "Edit Prompt Preset").font(.headline)
      TextField("Name", text: $name)
      TextEditor(text: $prompt).frame(height: 150)
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Save") {
          let value = ProjectPromptPreset(id: existing?.id ?? UUID().uuidString.lowercased(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines))
          save(value)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 460)
  }
}

private struct MacToolPresetNameSheet: View {
  let save: (String) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Save Tool Preset").font(.headline)
      TextField("Preset name", text: $name)
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Save") {
          save(name.trimmingCharacters(in: .whitespacesAndNewlines))
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 380)
  }
}
