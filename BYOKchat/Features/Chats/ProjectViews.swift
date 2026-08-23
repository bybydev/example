import AppFoundation
import BYOKchatProviderCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

private enum ProjectAccentOption: String, CaseIterable, Identifiable {
  case blue, indigo, purple, pink, orange, teal, green

  var id: String { rawValue }
  var title: String { rawValue.capitalized }

  var color: Color {
    switch self {
    case .blue: .blue
    case .indigo: .indigo
    case .purple: .purple
    case .pink: .pink
    case .orange: .orange
    case .teal: .teal
    case .green: .green
    }
  }
}

extension ChatProject {
  var projectColor: Color {
    ProjectAccentOption(rawValue: accentID)?.color ?? .blue
  }
}

struct ProjectIconView: View {
  let project: ChatProject
  var size: CGFloat = 28

  var body: some View {
    Image(systemName: project.symbolName)
      .font(.system(size: size * 0.45, weight: .semibold))
      .foregroundStyle(project.projectColor)
      .frame(width: size, height: size)
      .background(project.projectColor.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.3))
      .accessibilityHidden(true)
  }
}

struct ProjectEditorView: View {
  let existing: ChatProject?
  @Bindable var projects: ProjectManagementModel
  @Bindable var providers: ProviderManagementModel
  @Bindable var mcp: MCPManagementModel

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appFoundationTheme) private var theme
  @State private var name: String
  @State private var symbolName: String
  @State private var accentID: String
  @State private var accountID: ProviderAccountID?
  @State private var modelID: ModelID?
  @State private var instructions: String
  @State private var projectFiles: [ProjectFile]
  @State private var mcpConfiguration: MCPChatToolConfiguration
  @State private var promptPresets: [ProjectPromptPreset]
  @State private var toolPresets: [ProjectToolPreset]
  @State private var isSaving = false
  @State private var showFileImporter = false
  @State private var showPromptEditor = false
  @State private var editingPromptPreset: ProjectPromptPreset?

  private let symbols = [
    "folder.fill",
    "briefcase.fill",
    "hammer.fill",
    "terminal.fill",
    "doc.text.fill",
    "lightbulb.fill",
    "paintbrush.fill",
    "shippingbox.fill",
  ]

  init(
    project: ChatProject? = nil,
    projects: ProjectManagementModel,
    providers: ProviderManagementModel,
    mcp: MCPManagementModel
  ) {
    self.existing = project
    self.projects = projects
    self.providers = providers
    self.mcp = mcp
    _name = State(initialValue: project?.name ?? "")
    _symbolName = State(initialValue: project?.symbolName ?? "folder.fill")
    _accentID = State(initialValue: project?.accentID ?? "blue")
    _accountID = State(initialValue: project?.accountID)
    _modelID = State(initialValue: project?.modelID)
    _instructions = State(initialValue: project?.instructions ?? "")
    _projectFiles = State(initialValue: project?.projectFiles ?? [])
    _mcpConfiguration = State(initialValue: project?.mcpConfiguration ?? MCPChatToolConfiguration())
    _promptPresets = State(initialValue: project?.projectPromptPresets ?? [])
    _toolPresets = State(initialValue: project?.projectToolPresets ?? [])
  }

  private var enabledAccounts: [ProviderAccount] {
    providers.accounts.filter(\.isEnabled)
  }

  private var selectedAccount: ProviderAccount? {
    guard let accountID else { return nil }
    return enabledAccounts.first { $0.id == accountID }
  }

  private var availableModels: [AccountModelRecord] {
    guard let accountID else { return [] }
    return providers.models(for: accountID).filter(\.isAvailable)
  }

  private var canSave: Bool {
    !isSaving && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && (accountID == nil || selectedAccount != nil)
      && (accountID == nil || modelID == nil || availableModels.contains(where: { $0.model.id == modelID }))
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Project") {
          TextField("Name", text: $name)

          Picker("Icon", selection: $symbolName) {
            ForEach(symbols, id: \.self) { symbol in
              Label(symbolTitle(symbol), systemImage: symbol)
                .tag(symbol)
            }
          }

          Picker("Color", selection: $accentID) {
            ForEach(ProjectAccentOption.allCases) { option in
              Label {
                Text(option.title)
              } icon: {
                Image(systemName: "circle.fill")
                  .foregroundStyle(option.color)
              }
              .tag(option.rawValue)
            }
          }
        }
        .listRowBackground(theme.surfaceColor)

        Section {
          Picker("Provider account", selection: $accountID) {
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
        } header: {
          Text("New Chat Defaults")
            .foregroundStyle(theme.secondaryForegroundColor)
        } footer: {
          Text("Project defaults apply when a new chat is created. Existing chats keep their current provider and model.")
            .foregroundStyle(theme.secondaryForegroundColor)
        }
        .listRowBackground(theme.surfaceColor)

        Section {
          TextEditor(text: $instructions)
            .frame(minHeight: 130)
        } header: {
          Text("Instructions")
            .foregroundStyle(theme.secondaryForegroundColor)
        } footer: {
          Text("Used as the system prompt for new chats in this project. Leave blank to use the app default system prompt.")
            .foregroundStyle(theme.secondaryForegroundColor)
        }
        .listRowBackground(theme.surfaceColor)

        Section {
          ForEach(projectFiles) { file in
            HStack(spacing: 10) {
              Image(systemName: file.mimeType.hasPrefix("image/") ? "photo" : "doc.fill")
                .foregroundStyle(theme.secondaryForegroundColor)
              VStack(alignment: .leading, spacing: 2) {
                Text(file.filename)
                  .lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: Int64(file.byteCount), countStyle: .file))
                  .font(.caption)
                  .foregroundStyle(theme.secondaryForegroundColor)
              }
              Spacer()
              Button("Remove \(file.filename)", systemImage: "trash", role: .destructive) {
                projectFiles.removeAll { $0.id == file.id }
              }
              .labelStyle(.iconOnly)
            }
          }

          Button("Add Project Files", systemImage: "doc.badge.plus") {
            showFileImporter = true
          }
          .disabled(projectFiles.count >= 8)
        } header: {
          Text("Project Files")
            .foregroundStyle(theme.secondaryForegroundColor)
        } footer: {
          Text("Up to 8 files, 20 MB each and 40 MB total. These files are sent as persistent reference context for every chat in this project without being copied into message history.")
            .foregroundStyle(theme.secondaryForegroundColor)
        }
        .listRowBackground(theme.surfaceColor)

        Section {
          ForEach(promptPresets) { preset in
            Button {
              editingPromptPreset = preset
              showPromptEditor = true
            } label: {
              HStack {
                VStack(alignment: .leading, spacing: 3) {
                  Text(preset.name)
                  Text(preset.prompt)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryForegroundColor)
                    .lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(theme.secondaryForegroundColor.opacity(0.72))
              }
            }
            .swipeActions {
              Button("Delete", systemImage: "trash", role: .destructive) {
                promptPresets.removeAll { $0.id == preset.id }
              }
            }
          }

          Button("Add Prompt Preset", systemImage: "text.badge.plus") {
            editingPromptPreset = nil
            showPromptEditor = true
          }
        } header: {
          Text("Reusable Prompts")
            .foregroundStyle(theme.secondaryForegroundColor)
        } footer: {
          Text("Prompt presets appear in the composer for chats in this project.")
            .foregroundStyle(theme.secondaryForegroundColor)
        }
        .listRowBackground(theme.surfaceColor)

        Section {
          NavigationLink {
            ProjectToolsEditor(
              configuration: $mcpConfiguration,
              toolPresets: $toolPresets,
              mcp: mcp
            )
          } label: {
            LabeledContent("Default Tools") {
              Text(toolSummary)
                .foregroundStyle(theme.secondaryForegroundColor)
            }
          }
        } footer: {
          Text("Chats inherit these MCP servers and permissions until that chat creates its own override. Tool presets can be applied later to individual chats.")
            .foregroundStyle(theme.secondaryForegroundColor)
        }
        .listRowBackground(theme.surfaceColor)
      }
      .scrollContentBackground(.hidden)
      .foregroundStyle(theme.primaryForegroundColor)
      .background(AppThemeBackground(theme: theme))
      .navigationTitle(existing == nil ? "New Project" : "Edit Project")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { save() }
            .disabled(!canSave)
        }
      }
      .onChange(of: accountID) { _, newValue in
        guard let newValue else {
          modelID = nil
          return
        }
        let models = providers.models(for: newValue).filter(\.isAvailable)
        if let modelID, !models.contains(where: { $0.model.id == modelID }) {
          self.modelID = nil
        }
      }
      .fileImporter(
        isPresented: $showFileImporter,
        allowedContentTypes: [.item],
        allowsMultipleSelection: true
      ) { result in
        importProjectFiles(result)
      }
      .sheet(isPresented: $showPromptEditor) {
        ProjectPromptPresetEditor(existing: editingPromptPreset) { value in
          if let index = promptPresets.firstIndex(where: { $0.id == value.id }) {
            promptPresets[index] = value
          } else {
            promptPresets.append(value)
          }
        }
        .presentationDragIndicator(.visible)
      }
      .overlay {
        if isSaving {
          ProgressView()
            .padding(12)
            .background(.regularMaterial, in: Capsule())
        }
      }
    }
  }

  private var toolSummary: String {
    let count = mcpConfiguration.enabledServerIDs.count
    if count == 0 { return toolPresets.isEmpty ? "None" : "\(toolPresets.count) presets" }
    return "\(count) server\(count == 1 ? "" : "s")"
  }

  private func save() {
    guard canSave else { return }
    isSaving = true
    Task { @MainActor in
      defer { isSaving = false }
      let succeeded: Bool
      if let existing {
        succeeded = await projects.updateProject(
          id: existing.id,
          name: name,
          symbolName: symbolName,
          accentID: accentID,
          accountID: accountID,
          modelID: modelID,
          instructions: instructions,
          files: projectFiles,
          mcpConfiguration: mcpConfiguration,
          promptPresets: promptPresets,
          toolPresets: toolPresets
        )
      } else {
        succeeded = await projects.createProject(
          name: name,
          symbolName: symbolName,
          accentID: accentID,
          accountID: accountID,
          modelID: modelID,
          instructions: instructions,
          files: projectFiles,
          mcpConfiguration: mcpConfiguration,
          promptPresets: promptPresets,
          toolPresets: toolPresets
        ) != nil
      }
      if succeeded {
        await mcp.reloadFromStorage()
        dismiss()
      }
    }
  }

  private func importProjectFiles(_ result: Result<[URL], Error>) {
    switch result {
    case .failure(let error):
      projects.errorMessage = error.localizedDescription
    case .success(let urls):
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
          let type = values.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
          additions.append(
            ProjectFile(
              filename: url.lastPathComponent,
              mimeType: type.preferredMIMEType ?? "application/octet-stream",
              data: data
            )
          )
        }
        let combined = projectFiles + additions
        guard combined.count <= 8 else {
          throw ProviderError.invalidRequest("A project can contain at most 8 reference files.")
        }
        guard combined.reduce(0, { $0 + $1.byteCount }) <= 40 * 1_024 * 1_024 else {
          throw ProviderError.invalidRequest("Project reference files cannot exceed 40 MB total.")
        }
        projectFiles = combined
      } catch {
        projects.errorMessage = error.localizedDescription
      }
    }
  }

  private func symbolTitle(_ symbol: String) -> String {
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

private struct ProjectPromptPresetEditor: View {
  let existing: ProjectPromptPreset?
  let save: (ProjectPromptPreset) -> Void

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appFoundationTheme) private var theme
  @State private var name: String
  @State private var prompt: String

  init(existing: ProjectPromptPreset?, save: @escaping (ProjectPromptPreset) -> Void) {
    self.existing = existing
    self.save = save
    _name = State(initialValue: existing?.name ?? "")
    _prompt = State(initialValue: existing?.prompt ?? "")
  }

  var body: some View {
    NavigationStack {
      Form {
        TextField("Name", text: $name)
          .listRowBackground(theme.surfaceColor)
        Section("Prompt") {
          TextEditor(text: $prompt)
            .frame(minHeight: 180)
        }
        .listRowBackground(theme.surfaceColor)
      }
      .scrollContentBackground(.hidden)
      .foregroundStyle(theme.primaryForegroundColor)
      .background(AppThemeBackground(theme: theme))
      .navigationTitle(existing == nil ? "New Prompt" : "Edit Prompt")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            let value = ProjectPromptPreset(
              id: existing?.id ?? UUID().uuidString.lowercased(),
              name: name.trimmingCharacters(in: .whitespacesAndNewlines),
              prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            save(value)
            dismiss()
          }
          .disabled(
            name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          )
        }
      }
    }
  }
}

private struct ProjectToolsEditor: View {
  @Binding var configuration: MCPChatToolConfiguration
  @Binding var toolPresets: [ProjectToolPreset]
  @Bindable var mcp: MCPManagementModel

  @Environment(\.appFoundationTheme) private var theme
  @State private var showPresetName = false
  @State private var presetName = ""

  var body: some View {
    List {
      Section {
        Label(
          "These are project defaults. Chats inherit them until they customize Tools themselves.",
          systemImage: "arrow.triangle.branch"
        )
        .font(.footnote)
        .foregroundStyle(theme.secondaryForegroundColor)
      }
      .listRowBackground(theme.surfaceColor)

      if mcp.servers.isEmpty {
        Section {
          ContentUnavailableView(
            "No MCP Servers",
            systemImage: "server.rack",
            description: Text("Add a remote MCP server in Settings first.")
          )
        }
        .listRowBackground(theme.surfaceColor)
      } else {
        ForEach(mcp.servers) { server in
          serverSection(server)
        }
        .listRowBackground(theme.surfaceColor)
      }

      Section("Tool Presets") {
        ForEach(toolPresets) { preset in
          Button {
            configuration = preset.configuration
          } label: {
            HStack {
              Label(preset.name, systemImage: "wrench.adjustable")
              Spacer()
              Text("Apply")
                .font(.caption)
                .foregroundStyle(theme.secondaryForegroundColor)
            }
          }
          .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive) {
              toolPresets.removeAll { $0.id == preset.id }
            }
          }
        }

        Button("Save Current as Preset", systemImage: "plus") {
          presetName = ""
          showPresetName = true
        }
      }
      .listRowBackground(theme.surfaceColor)
    }
    .scrollContentBackground(.hidden)
    .foregroundStyle(theme.primaryForegroundColor)
    .background(AppThemeBackground(theme: theme))
    .navigationTitle("Default Tools")
    .navigationBarTitleDisplayMode(.inline)
    .alert("Save Tool Preset", isPresented: $showPresetName) {
      TextField("Preset name", text: $presetName)
      Button("Cancel", role: .cancel) {}
      Button("Save") { savePreset() }
        .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
  }

  @ViewBuilder
  private func serverSection(_ server: MCPRemoteServer) -> some View {
    let enabled = configuration.isServerEnabled(server.id)
    let bindings = mcp.tools(for: server.id)

    Section {
      Toggle(
        isOn: Binding(
          get: { configuration.isServerEnabled(server.id) },
          set: { value in
            configuration.enabledServerIDs.removeAll { $0 == server.id }
            if value { configuration.enabledServerIDs.append(server.id) }
            configuration.enabledServerIDs.sort { $0.rawValue < $1.rawValue }
          }
        )
      ) {
        VStack(alignment: .leading, spacing: 3) {
          Text("Enable in Project")
          if !server.isEnabled {
            Text("This server is disabled globally in Settings.")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }
      }
      .disabled(!server.isEnabled)

      if enabled {
        ForEach(bindings) { binding in
          HStack {
            VStack(alignment: .leading, spacing: 3) {
              Text(binding.remoteTool.title ?? binding.remoteTool.remoteName)
              Text(binding.remoteTool.description)
                .font(.caption)
                .foregroundStyle(theme.secondaryForegroundColor)
                .lineLimit(2)
            }
            Spacer()
            Picker(
              "Permission",
              selection: Binding(
                get: { configuration.policy(for: binding.exposedName) },
                set: { value in
                  if value == .ask {
                    configuration.toolPolicies.removeValue(forKey: binding.exposedName)
                  } else {
                    configuration.toolPolicies[binding.exposedName] = value
                  }
                }
              )
            ) {
              ForEach(ChatToolPermissionPolicy.allCases, id: \.self) { policy in
                Text(policy.displayName).tag(policy)
              }
            }
            .labelsHidden()
            .pickerStyle(.menu)
          }
        }
      }
    } header: {
      Text(server.name)
    }
  }

  private func savePreset() {
    let normalized = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return }
    if let index = toolPresets.firstIndex(where: {
      $0.name.caseInsensitiveCompare(normalized) == .orderedSame
    }) {
      toolPresets[index].name = normalized
      toolPresets[index].configuration = configuration
    } else {
      toolPresets.append(ProjectToolPreset(name: normalized, configuration: configuration))
    }
  }
}
