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

/// Context-menu entries that move a chat into, out of, or between projects.
struct ConversationProjectMenu: View {
  let conversationID: ConversationID
  let projects: ProjectManagementModel
  @Environment(BYOKToastCenter.self) private var toastCenter

  var body: some View {
    if let current = projects.project(for: conversationID) {
      Button("Remove from \(current.name)", systemImage: "folder.badge.minus") {
        Task {
          if await projects.removeConversation(conversationID) {
            toastCenter.success("Removed from \(current.name)")
          }
        }
      }
      let otherProjects = projects.projects.filter { $0.id != current.id }
      if !otherProjects.isEmpty {
        Menu("Move to Project…", systemImage: "folder.badge.plus") {
          ForEach(otherProjects) { project in
            Button(project.name) {
              Task {
                if await projects.assignConversation(conversationID, to: project.id) {
                  toastCenter.success("Moved to \(project.name)")
                }
              }
            }
          }
        }
      }
    } else if projects.projects.isEmpty {
      EmptyView()
    } else {
      Menu("Add to Project…", systemImage: "folder.badge.plus") {
        ForEach(projects.projects) { project in
          Button(project.name) {
            Task {
              if await projects.assignConversation(conversationID, to: project.id) {
                toastCenter.success("Added to \(project.name)")
              }
            }
          }
        }
      }
    }
  }
}

/// Nonisolated helpers for project reference-file metadata, summaries, and
/// off-main-thread file import processing.
enum ProjectFileImportSupport {
  private static let explicitTextMIMETypes: Set<String> = [
    "application/json",
    "application/ld+json",
    "application/xml",
    "application/xhtml+xml",
    "application/javascript",
    "application/ecmascript",
    "application/typescript",
    "application/x-yaml",
    "application/yaml",
    "application/toml",
    "application/sql",
    "application/csv",
    "application/x-sh",
    "application/x-python-code",
    "application/rtf",
  ]

  static func isImageMIMEType(_ mimeType: String) -> Bool {
    mimeType.lowercased().hasPrefix("image/")
  }

  static func isTextLikeMIMEType(_ mimeType: String) -> Bool {
    let normalized = mimeType
      .split(separator: ";", maxSplits: 1)
      .first?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() ?? ""
    guard !normalized.isEmpty else { return false }
    if normalized.hasPrefix("text/") { return true }
    if explicitTextMIMETypes.contains(normalized) { return true }
    if normalized.hasSuffix("+json") || normalized.hasSuffix("+xml") { return true }
    if let type = UTType(mimeType: normalized), type.conforms(to: .text) { return true }
    return false
  }

  /// Reads and validates security-scoped files off `@MainActor`, rejecting
  /// empty/oversized/non-regular items before committing and normalizing
  /// unsupported image formats (such as HEIC) to JPEG.
  static func importFiles(
    from urls: [URL],
    existingCount: Int,
    existingBytes: Int
  ) throws -> [ProjectFile] {
    guard urls.count <= ProjectWorkspaceStore.maxFileCount - existingCount else {
      throw ProjectWorkspaceError.tooManyFiles
    }
    let maximumFileBytes = ProjectWorkspaceStore.maxFileBytes
    let maximumTotalBytes = ProjectWorkspaceStore.maxTotalFileBytes
    guard existingBytes <= maximumTotalBytes else {
      throw ProjectWorkspaceError.filesTooLarge
    }

    var accessedURLs: [URL] = []
    defer { for url in accessedURLs { url.stopAccessingSecurityScopedResource() } }

    var inspected: [(url: URL, type: UTType)] = []
    var preflightBytes = existingBytes
    for url in urls {
      if url.startAccessingSecurityScopedResource() { accessedURLs.append(url) }
      let values = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .isRegularFileKey])
      guard values.isRegularFile == true else {
        throw ProviderError.invalidRequest("\(url.lastPathComponent) is not a readable regular file.")
      }
      guard let fileSize = values.fileSize, fileSize >= 0 else {
        throw ProviderError.invalidRequest(
          "The size of \(url.lastPathComponent) is unavailable. Download it locally and try again."
        )
      }
      guard fileSize > 0 else {
        throw ProjectWorkspaceError.emptyFile(url.lastPathComponent)
      }
      guard fileSize <= maximumFileBytes else {
        throw ProjectWorkspaceError.fileTooLarge(url.lastPathComponent)
      }
      guard fileSize <= maximumTotalBytes - preflightBytes else {
        throw ProjectWorkspaceError.filesTooLarge
      }
      preflightBytes += fileSize
      let type = values.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
      inspected.append((url, type))
    }

    var additions: [ProjectFile] = []
    var actualBytes = existingBytes
    for (url, type) in inspected {
      let rawData = try Data(contentsOf: url, options: [.mappedIfSafe])
      guard !rawData.isEmpty else {
        throw ProjectWorkspaceError.emptyFile(url.lastPathComponent)
      }

      let prepared = try preparedFile(url: url, type: type, rawData: rawData, maxBytes: maximumFileBytes)
      guard !prepared.data.isEmpty else {
        throw ProjectWorkspaceError.emptyFile(prepared.filename)
      }
      guard prepared.data.count <= maximumFileBytes else {
        throw ProjectWorkspaceError.fileTooLarge(prepared.filename)
      }
      guard prepared.data.count <= maximumTotalBytes - actualBytes else {
        throw ProjectWorkspaceError.filesTooLarge
      }
      actualBytes += prepared.data.count
      additions.append(
        ProjectFile(
          filename: prepared.filename,
          mimeType: prepared.mimeType,
          data: prepared.data
        )
      )
    }
    return additions
  }

  private static func preparedFile(
    url: URL,
    type: UTType,
    rawData: Data,
    maxBytes: Int
  ) throws -> (filename: String, mimeType: String, data: Data) {
    if type.conforms(to: .image) {
      let preservesOriginal = (type == .png || type == .jpeg || type == .gif || type == .webP)
        && rawData.count <= maxBytes
      if preservesOriginal {
        return (
          filename: url.lastPathComponent,
          mimeType: type.preferredMIMEType ?? "image/jpeg",
          data: rawData
        )
      }
      guard let jpeg = LibraryImportSupport.normalizedJPEG(from: rawData) else {
        throw ProviderError.invalidRequest(
          "The image '\(url.lastPathComponent)' could not be converted to a supported format."
        )
      }
      let stem = url.deletingPathExtension().lastPathComponent
      let base = stem.isEmpty ? "image" : stem
      return (filename: base + ".jpg", mimeType: "image/jpeg", data: jpeg)
    }
    return (
      filename: url.lastPathComponent,
      mimeType: type.preferredMIMEType ?? "application/octet-stream",
      data: rawData
    )
  }
}

/// Rough size context for attach decisions: text averages ~4 bytes per token, so the
/// estimate tells users why a large text reference file may exceed a model's context
/// window. Binary/image files omit the misleading byte-division token estimate.
func projectFileDetail(_ file: ProjectFile) -> String {
  let size = ByteCountFormatter.string(fromByteCount: Int64(file.byteCount), countStyle: .file)
  guard file.byteCount > 0, ProjectFileImportSupport.isTextLikeMIMEType(file.mimeType) else {
    return size
  }
  let estimatedTokens = max(1, file.byteCount / 4)
  return "\(size) · ~\(estimatedTokens.formatted()) tokens"
}

func projectToolsSummary(
  configuration: MCPChatToolConfiguration?,
  toolPresets: [ProjectToolPreset]
) -> String {
  let serverCount = configuration?.enabledServerIDs.count ?? 0
  let presetCount = toolPresets.count
  switch (serverCount, presetCount) {
  case (0, 0):
    return "None"
  case (_, 0):
    return "\(serverCount) server\(serverCount == 1 ? "" : "s")"
  case (0, _):
    return "\(presetCount) preset\(presetCount == 1 ? "" : "s")"
  default:
    return "\(serverCount) server\(serverCount == 1 ? "" : "s") · \(presetCount) preset\(presetCount == 1 ? "" : "s")"
  }
}

struct ProjectEditorView: View {
  private enum PromptEditorSession: Identifiable {
    case create
    case edit(ProjectPromptPreset)

    var id: String {
      switch self {
      case .create: "create"
      case .edit(let preset): preset.id
      }
    }

    var existing: ProjectPromptPreset? {
      if case .edit(let preset) = self { return preset }
      return nil
    }
  }

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
  @State private var isImportingFiles = false
  @State private var showFileImporter = false
  @State private var promptEditorSession: PromptEditorSession?

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

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var nameValidationError: String? {
    guard !trimmedName.isEmpty else { return nil }
    if trimmedName.count > ProjectWorkspaceStore.maxNameLength {
      return "Project names must be \(ProjectWorkspaceStore.maxNameLength) characters or fewer."
    }
    let hasDuplicate = projects.projects.contains {
      $0.id != existing?.id && $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame
    }
    if hasDuplicate {
      return "A project with this name already exists."
    }
    return nil
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

  private var effectiveMCPConfiguration: MCPChatToolConfiguration? {
    if mcpConfiguration.enabledServerIDs.isEmpty && mcpConfiguration.toolPolicies.isEmpty {
      return nil
    }
    return mcpConfiguration
  }

  private var hasUnsavedChanges: Bool {
    if let existing {
      let existingEffectiveMCP: MCPChatToolConfiguration?
      if let config = existing.mcpConfiguration,
        !(config.enabledServerIDs.isEmpty && config.toolPolicies.isEmpty)
      {
        existingEffectiveMCP = config
      } else {
        existingEffectiveMCP = nil
      }
      return trimmedName != existing.name
        || symbolName != existing.symbolName
        || accentID != existing.accentID
        || accountID != existing.accountID
        || (accountID == nil ? nil : modelID) != existing.modelID
        || instructions.trimmingCharacters(in: .whitespacesAndNewlines) != existing.instructions
        || projectFiles != existing.projectFiles
        || effectiveMCPConfiguration != existingEffectiveMCP
        || promptPresets != existing.projectPromptPresets
        || toolPresets != existing.projectToolPresets
    }
    return !trimmedName.isEmpty
      || symbolName != "folder.fill"
      || accentID != "blue"
      || accountID != nil
      || modelID != nil
      || !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !projectFiles.isEmpty
      || effectiveMCPConfiguration != nil
      || !promptPresets.isEmpty
      || !toolPresets.isEmpty
  }

  private var canSave: Bool {
    !isSaving
      && !isImportingFiles
      && !trimmedName.isEmpty
      && nameValidationError == nil
      && (accountID == nil || selectedAccount != nil)
      && (accountID == nil || modelID == nil || availableModels.contains(where: { $0.model.id == modelID }))
  }

  var body: some View {
    NavigationStack {
      editorForm
        .navigationTitle(existing == nil ? "New Project" : "Edit Project")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { editorToolbar }
        .onChange(of: accountID) { _, newValue in
          handleAccountChange(newValue)
        }
        .fileImporter(
          isPresented: $showFileImporter,
          allowedContentTypes: [.item],
          allowsMultipleSelection: true
        ) { result in
          importProjectFiles(result)
        }
        .sheet(item: $promptEditorSession) { session in
          let otherNames = Set(
            promptPresets
              .filter { $0.id != session.existing?.id }
              .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
          )
          ProjectPromptPresetEditor(
            existing: session.existing,
            existingNames: otherNames
          ) { value in
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
        .projectErrorPresenter(projects)
    }
    .interactiveDismissDisabled(hasUnsavedChanges || isSaving || isImportingFiles)
  }

  private var editorForm: some View {
    Form {
      projectIdentitySection
      defaultsSection
      instructionsSection
      filesSection
      promptPresetsSection
      toolsSection
    }
    .scrollContentBackground(.hidden)
    .foregroundStyle(theme.primaryForegroundColor)
    .background(AppThemeBackground(theme: theme))
  }

  @ToolbarContentBuilder
  private var editorToolbar: some ToolbarContent {
    ToolbarItem(placement: .cancellationAction) {
      Button("Cancel") { dismiss() }
        .disabled(isSaving)
    }
    ToolbarItem(placement: .confirmationAction) {
      Button("Save") { save() }
        .disabled(!canSave)
    }
  }

  private var selectedColor: Color {
    ProjectAccentOption(rawValue: accentID)?.color ?? .blue
  }

  private var selectedColorTitle: String {
    ProjectAccentOption(rawValue: accentID)?.title ?? accentID.capitalized
  }

  private var projectIdentitySection: some View {
    Section {
      HStack(spacing: 12) {
        Image(systemName: symbolName)
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(selectedColor)
          .frame(width: 36, height: 36)
          .background(
            selectedColor.opacity(0.14),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
          )
          .accessibilityHidden(true)

        TextField("Name", text: $name)
      }

      Picker("Icon", selection: $symbolName) {
        if !symbols.contains(symbolName) {
          Label("Custom", systemImage: symbolName)
            .tag(symbolName)
        }
        ForEach(symbols, id: \.self) { symbol in
          Label(symbolTitle(symbol), systemImage: symbol)
            .tag(symbol)
        }
      }

      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text("Color")
          Spacer()
          Text(selectedColorTitle)
            .foregroundStyle(theme.secondaryForegroundColor)
        }

        HStack(spacing: 0) {
          ForEach(ProjectAccentOption.allCases) { option in
            let isSelected = accentID == option.rawValue
            Button {
              accentID = option.rawValue
            } label: {
              ZStack {
                if isSelected {
                  Circle()
                    .strokeBorder(option.color, lineWidth: 2)
                    .frame(width: 34, height: 34)
                }
                Circle()
                  .fill(option.color)
                  .frame(width: 26, height: 26)
                if isSelected {
                  Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.white)
                }
              }
              .frame(maxWidth: .infinity, minHeight: 38)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(option.title)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
          }
        }
      }
      .padding(.vertical, 2)
    } header: {
      Text("Project")
        .foregroundStyle(theme.secondaryForegroundColor)
    } footer: {
      if let nameValidationError {
        Text(nameValidationError)
          .foregroundStyle(.red)
      }
    }
    .listRowBackground(theme.surfaceColor)
  }

  private var defaultsSection: some View {
    Section {
      Picker("Provider account", selection: $accountID) {
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
    } header: {
      Text("New Chat Defaults")
        .foregroundStyle(theme.secondaryForegroundColor)
    } footer: {
      VStack(alignment: .leading, spacing: 6) {
        if hasUnavailableDefaults {
          Text("The previously selected provider account or model is no longer available. Choose an active option or switch back to App Default / Account Default before saving.")
            .foregroundStyle(.orange)
        }
        Text("Project defaults apply when a new chat is created. Existing chats keep their current provider and model.")
          .foregroundStyle(theme.secondaryForegroundColor)
      }
    }
    .listRowBackground(theme.surfaceColor)
  }

  private var instructionsSection: some View {
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
  }

  private var filesSection: some View {
    Section {
      ForEach(projectFiles) { file in
        HStack(spacing: 10) {
          Image(systemName: ProjectFileImportSupport.isImageMIMEType(file.mimeType) ? "photo" : "doc.fill")
            .foregroundStyle(theme.secondaryForegroundColor)
          VStack(alignment: .leading, spacing: 2) {
            Text(file.filename)
              .lineLimit(1)
            Text(projectFileDetail(file))
              .font(.caption)
              .foregroundStyle(theme.secondaryForegroundColor)
          }
          Spacer()
          Button("Remove \(file.filename)", systemImage: "trash", role: .destructive) {
            projectFiles.removeAll { $0.id == file.id }
          }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
        }
        .swipeActions(edge: .trailing) {
          Button("Remove", systemImage: "trash", role: .destructive) {
            projectFiles.removeAll { $0.id == file.id }
          }
        }
      }

      Button {
        showFileImporter = true
      } label: {
        HStack(spacing: 8) {
          Label("Add Project Files", systemImage: "doc.badge.plus")
          if isImportingFiles {
            Spacer()
            ProgressView()
              .controlSize(.small)
          }
        }
      }
      .disabled(projectFiles.count >= ProjectWorkspaceStore.maxFileCount || isImportingFiles)
    } header: {
      Text("Project Files")
        .foregroundStyle(theme.secondaryForegroundColor)
    } footer: {
      Text("Up to 8 files, 20 MB each and 40 MB total. Files stay here as a library — attach them from the chat composer when a message needs one. Attached files are sent with that message only, so larger files increase the cost of that request.")
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }

  private var promptPresetsSection: some View {
    Section {
      ForEach(promptPresets) { preset in
        Button {
          promptEditorSession = .edit(preset)
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
        promptEditorSession = .create
      }
      .disabled(promptPresets.count >= ProjectWorkspaceStore.maxPresetCount)
    } header: {
      Text("Reusable Prompts")
        .foregroundStyle(theme.secondaryForegroundColor)
    } footer: {
      Text("Prompt presets appear in the composer for chats in this project (up to \(ProjectWorkspaceStore.maxPresetCount)).")
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }

  private var toolsSection: some View {
    Section {
      NavigationLink {
        ProjectToolsEditor(
          configuration: $mcpConfiguration,
          toolPresets: $toolPresets,
          mcp: mcp
        )
      } label: {
        LabeledContent("Default Tools") {
          Text(projectToolsSummary(configuration: effectiveMCPConfiguration, toolPresets: toolPresets))
            .foregroundStyle(theme.secondaryForegroundColor)
        }
      }
    } footer: {
      Text("Chats inherit these MCP servers and permissions until that chat creates its own override. Tool presets can be applied later to individual chats.")
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }

  private func handleAccountChange(_ newValue: ProviderAccountID?) {
    guard let newValue else {
      modelID = nil
      return
    }
    let models = providers.models(for: newValue).filter(\.isAvailable)
    if let modelID, !models.contains(where: { $0.model.id == modelID }) {
      self.modelID = nil
    }
  }

  private func save() {
    guard canSave else { return }
    isSaving = true
    let configToSave = effectiveMCPConfiguration
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
          mcpConfiguration: configToSave,
          clearMCPConfiguration: configToSave == nil,
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
          mcpConfiguration: configToSave,
          promptPresets: promptPresets,
          toolPresets: toolPresets
        ) != nil
      }
      if succeeded {
        dismiss()
      }
    }
  }

  private func importProjectFiles(_ result: Result<[URL], Error>) {
    switch result {
    case .failure(let error):
      BYOKAppAnalytics.reportError("project_file_picker_failed", component: "projects")
      projects.errorMessage = error.localizedDescription
    case .success(let urls):
      guard !urls.isEmpty else { return }
      let existingCount = projectFiles.count
      let existingBytes = projectFiles.reduce(0) { $0 + $1.byteCount }
      isImportingFiles = true
      Task { @MainActor in
        defer { isImportingFiles = false }
        do {
          let additions = try await Task.detached(priority: .userInitiated) {
            try ProjectFileImportSupport.importFiles(
              from: urls,
              existingCount: existingCount,
              existingBytes: existingBytes
            )
          }.value
          projectFiles.append(contentsOf: additions)
        } catch {
          BYOKAppAnalytics.reportError("project_file_import_failed", component: "projects")
          projects.errorMessage = error.localizedDescription
        }
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
  let existingNames: Set<String>
  let save: (ProjectPromptPreset) -> Void

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appFoundationTheme) private var theme
  @State private var name: String
  @State private var prompt: String

  init(
    existing: ProjectPromptPreset?,
    existingNames: Set<String>,
    save: @escaping (ProjectPromptPreset) -> Void
  ) {
    self.existing = existing
    self.existingNames = existingNames
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
    guard !trimmedName.isEmpty else { return nil }
    if trimmedName.count > ProjectWorkspaceStore.maxPresetNameLength {
      return "Preset names must be \(ProjectWorkspaceStore.maxPresetNameLength) characters or fewer."
    }
    if existingNames.contains(trimmedName.lowercased()) {
      return "A prompt preset with this name already exists."
    }
    return nil
  }

  private var canSave: Bool {
    !trimmedName.isEmpty && !trimmedPrompt.isEmpty && nameError == nil
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Name", text: $name)
        } footer: {
          if let nameError {
            Text(nameError)
              .foregroundStyle(.red)
          }
        }
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
              name: trimmedName,
              prompt: trimmedPrompt
            )
            save(value)
            dismiss()
          }
          .disabled(!canSave)
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
  @State private var pendingOverwriteName: String?

  private var trimmedPresetName: String {
    presetName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var matchingExistingPresetIndex: Int? {
    guard !trimmedPresetName.isEmpty else { return nil }
    return toolPresets.firstIndex {
      $0.name.caseInsensitiveCompare(trimmedPresetName) == .orderedSame
    }
  }

  private var canConfirmPresetName: Bool {
    guard !trimmedPresetName.isEmpty,
      trimmedPresetName.count <= ProjectWorkspaceStore.maxPresetNameLength
    else { return false }
    if matchingExistingPresetIndex != nil { return true }
    return toolPresets.count < ProjectWorkspaceStore.maxPresetCount
  }

  private var presetAlertMessage: String {
    if trimmedPresetName.count > ProjectWorkspaceStore.maxPresetNameLength {
      return "Preset names must be \(ProjectWorkspaceStore.maxPresetNameLength) characters or fewer."
    }
    if matchingExistingPresetIndex == nil && toolPresets.count >= ProjectWorkspaceStore.maxPresetCount {
      return "A project can contain at most \(ProjectWorkspaceStore.maxPresetCount) tool presets. Enter an existing preset name to update it, or delete one first."
    }
    return "Save the current server selection and tool permissions as a reusable preset."
  }

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
            description: Text("Add a remote MCP server in MCP Servers first.")
          )
        }
        .listRowBackground(theme.surfaceColor)
      } else {
        ForEach(mcp.servers) { server in
          serverSection(server)
        }
        .listRowBackground(theme.surfaceColor)
      }

      toolPresetsSection
    }
    .scrollContentBackground(.hidden)
    .foregroundStyle(theme.primaryForegroundColor)
    .background(AppThemeBackground(theme: theme))
    .navigationTitle("Default Tools")
    .navigationBarTitleDisplayMode(.inline)
    .alert("Save Tool Preset", isPresented: $showPresetName) {
      TextField("Preset name", text: $presetName)
      Button("Cancel", role: .cancel) {}
      Button("Save") { requestSavePreset() }
        .disabled(!canConfirmPresetName)
    } message: {
      Text(presetAlertMessage)
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
          commitSavePreset(nameToOverwrite)
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
  }

  private var toolPresetsSection: some View {
    Section("Tool Presets") {
      ForEach(toolPresets) { preset in
        let isApplied = preset.configuration == configuration
        Button {
          configuration = preset.configuration
        } label: {
          HStack {
            Label(preset.name, systemImage: "wrench.adjustable")
            Spacer()
            if isApplied {
              Image(systemName: "checkmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.accentColor)
            } else {
              Text("Apply")
                .font(.caption)
                .foregroundStyle(theme.secondaryForegroundColor)
            }
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
            Text("This server is disabled globally in MCP Servers.")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }
      }
      .disabled(!server.isEnabled && !enabled)

      if server.isEnabled && enabled {
        if bindings.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            Text("No tools are currently cached for this server.")
              .font(.footnote)
              .foregroundStyle(theme.secondaryForegroundColor)
            Button("Refresh Tools", systemImage: "arrow.clockwise") {
              Task { @MainActor in await mcp.refresh(server.id) }
            }
            .disabled(mcp.isBusy)
          }
        } else {
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
      }
    } header: {
      Text(server.name)
    }
  }

  private func requestSavePreset() {
    let normalized = trimmedPresetName
    guard !normalized.isEmpty, normalized.count <= ProjectWorkspaceStore.maxPresetNameLength else {
      return
    }
    if matchingExistingPresetIndex != nil {
      pendingOverwriteName = normalized
    } else {
      commitSavePreset(normalized)
    }
  }

  private func commitSavePreset(_ normalized: String) {
    if let index = toolPresets.firstIndex(where: {
      $0.name.caseInsensitiveCompare(normalized) == .orderedSame
    }) {
      toolPresets[index].name = normalized
      toolPresets[index].configuration = configuration
    } else if toolPresets.count < ProjectWorkspaceStore.maxPresetCount {
      toolPresets.append(ProjectToolPreset(name: normalized, configuration: configuration))
    }
  }
}

private struct ProjectFilePreviewPresentation: Identifiable {
  let id = UUID()
  let item: LibraryQuickLookItem
}

/// Landing screen for a single project: its chats, its reference-file library,
/// and a read-only summary of the defaults new chats inherit.
struct ProjectDetailView: View {
  let projectID: ProjectID
  let chats: ChatManagementModel
  let projects: ProjectManagementModel
  let providers: ProviderManagementModel
  let mcp: MCPManagementModel
  let newChat: (ProjectID?) -> Void
  let openChat: (ConversationID) -> Void
  /// Set when the detail view is *pushed* onto the stack: the composer pushes
  /// on top of it instead of swapping the main screen underneath. Back then
  /// returns to this project.
  var newChatInStack: (() -> Void)? = nil
  /// Set when the detail view sits at the root of the navigation stack (shown
  /// via a chat's back chevron) instead of being pushed in the sidebar sheet;
  /// renders a leading back chevron and replaces dismiss-on-delete.
  var homeExit: (() -> Void)? = nil

  private enum Segment: String, CaseIterable, Identifiable {
    case chats
    case files
    case settings

    var id: String { rawValue }

    var title: String {
      switch self {
      case .chats: "Chats"
      case .files: "Files"
      case .settings: "Settings"
      }
    }
  }

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appFoundationTheme) private var theme
  @Environment(BYOKToastCenter.self) private var toastCenter
  @State private var segment: Segment = .chats
  @State private var showEditor = false
  @State private var confirmDelete = false
  @State private var renameTarget: ChatConversation?
  @State private var renameText = ""
  @State private var loadingFileID: String?
  @State private var previewRequestID: UUID?
  @State private var filePreview: ProjectFilePreviewPresentation?

  private var project: ChatProject? {
    projects.project(projectID)
  }

  private var conversations: [ChatConversation] {
    chats.historyConversations.filter {
      projects.projectID(for: $0.id) == projectID
    }
  }

  private var isRenameAlertPresented: Binding<Bool> {
    Binding(
      get: { renameTarget != nil },
      set: { if !$0 { renameTarget = nil } }
    )
  }

  var body: some View {
    detailContent
      .foregroundStyle(theme.primaryForegroundColor)
      .background(AppThemeBackground(theme: theme))
      .navigationTitle(project?.name ?? "Project")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { detailToolbar }
      .sheet(isPresented: $showEditor) {
        if let project {
          ProjectEditorView(
            project: project,
            projects: projects,
            providers: providers,
            mcp: mcp
          )
          .presentationDragIndicator(.visible)
        }
      }
      .sheet(item: $filePreview) { preview in
        LibraryQuickLookView(files: [preview.item]) {
          filePreview = nil
        }
        .ignoresSafeArea()
      }
      .confirmationDialog(
        deleteConfirmationTitle,
        isPresented: $confirmDelete,
        titleVisibility: .visible
      ) {
        Button("Delete Project", role: .destructive) {
          Task { @MainActor in
            guard await projects.deleteProject(projectID) else { return }
            if let homeExit {
              homeExit()
            } else {
              dismiss()
            }
          }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("Chats in this project will be kept and moved back to standalone chats.")
      }
      .alert("Rename Chat", isPresented: isRenameAlertPresented) {
        TextField("Title", text: $renameText)
        Button("Cancel", role: .cancel) { renameTarget = nil }
        Button("Save") {
          guard let id = renameTarget?.id else { return }
          let title = renameText
          renameTarget = nil
          Task { @MainActor in
            await chats.renameConversation(id, title: title)
          }
        }
      }
      .projectErrorPresenter(projects)
  }

  private var deleteConfirmationTitle: String {
    guard let project else { return "Delete project?" }
    return "Delete \"\(project.name)\"?"
  }

  @ViewBuilder
  private var detailContent: some View {
    if let project {
      VStack(spacing: 0) {
        Picker("Section", selection: $segment) {
          ForEach(Segment.allCases) { value in
            Text(value.title).tag(value)
          }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)

        switch segment {
        case .chats:
          chatList(project)
        case .files:
          fileList(project)
        case .settings:
          settingsList(project)
        }
      }
    } else {
      ContentUnavailableView(
        "Project Removed",
        systemImage: "folder.badge.questionmark",
        description: Text("This project was deleted.")
      )
    }
  }

  @ToolbarContentBuilder
  private var detailToolbar: some ToolbarContent {
    if homeExit != nil {
      ToolbarItem(placement: .cancellationAction) {
        Button("Back", systemImage: "chevron.left") { homeExit?() }
          .labelStyle(.iconOnly)
          .accessibilityLabel("Back")
      }
    }
    if let project {
      ToolbarItem(placement: .principal) {
        HStack(spacing: 7) {
          ProjectIconView(project: project, size: 22)
          Text(project.name)
            .font(.headline)
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
      }
      ToolbarItemGroup(placement: .primaryAction) {
        Button("New Chat", systemImage: "square.and.pencil", action: startChatHere)
          .labelStyle(.iconOnly)

        Button("Edit Project", systemImage: "slider.horizontal.3") {
          showEditor = true
        }
        .labelStyle(.iconOnly)
      }
    }
  }

  /// Pushed details keep their context: the composer layers on top instead of
  /// swapping the main screen underneath.
  private func startChatHere() {
    guard project != nil else { return }
    if let newChatInStack {
      newChatInStack()
    } else {
      newChat(projectID)
    }
  }

  @ViewBuilder
  private func chatList(_ project: ChatProject) -> some View {
    if conversations.isEmpty {
      ContentUnavailableView {
        Label("No Chats Yet", systemImage: "bubble.left.and.bubble.right")
      } description: {
        Text("New chats here use \(project.name) defaults and instructions.")
      } actions: {
        Button("New Chat", action: startChatHere)
          .buttonStyle(.borderedProminent)
      }
    } else {
      List {
        Section {
          ForEach(conversations) { conversation in
            Button {
              openChat(conversation.id)
            } label: {
              ConversationRow(
                conversation: conversation,
                account: providers.accounts.first { $0.id == conversation.accountID },
                isGenerating: chats.isGenerating(conversation.id)
              )
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
              Button("Rename", systemImage: "pencil") {
                renameTarget = conversation
                renameText = conversation.title
              }
              ConversationProjectMenu(conversationID: conversation.id, projects: projects)
              Divider()
              Button("Delete", systemImage: "trash", role: .destructive) {
                deleteConversation(conversation.id)
              }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
              Button("Delete", systemImage: "trash", role: .destructive) {
                deleteConversation(conversation.id)
              }
              Button("Remove", systemImage: "folder.badge.minus") {
                Task { @MainActor in
                  if await projects.removeConversation(conversation.id) {
                    toastCenter.success("Removed from \(project.name)")
                  }
                }
              }
              .tint(.orange)
            }
          }
          .listRowSeparatorTint(theme.borderColor)
        }
        .listRowBackground(theme.surfaceColor)
      }
      .listStyle(.insetGrouped)
      .scrollContentBackground(.hidden)
    }
  }

  private func deleteConversation(_ id: ConversationID) {
    Task { @MainActor in
      await chats.deleteConversation(id)
      await projects.reloadFromStorage()
      await mcp.reloadFromStorage()
    }
  }

  @ViewBuilder
  private func fileList(_ project: ChatProject) -> some View {
    if project.projectFiles.isEmpty {
      ContentUnavailableView {
        Label("No Files", systemImage: "doc")
      } description: {
        Text("Add reference files with Edit Project, then attach them from the chat composer when a message needs one.")
      } actions: {
        Button("Edit Project") {
          showEditor = true
        }
        .buttonStyle(.borderedProminent)
      }
    } else {
      List {
        Section {
          ForEach(project.projectFiles) { file in
            Button {
              openFilePreview(file)
            } label: {
              HStack(spacing: 12) {
                ProjectFileIconView(
                  mimeType: file.mimeType,
                  color: project.projectColor,
                  size: 36
                )

                VStack(alignment: .leading, spacing: 3) {
                  Text(file.filename)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                  Text(projectFileDetail(file))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryForegroundColor)
                    .lineLimit(1)
                }

                Spacer(minLength: 8)

                if loadingFileID == file.id {
                  ProgressView()
                    .controlSize(.small)
                }
              }
              .padding(.vertical, 2)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
              Button("Preview", systemImage: "eye") {
                openFilePreview(file)
              }
              Divider()
              Button("Remove", systemImage: "trash", role: .destructive) {
                Task { @MainActor in
                  await projects.removeProjectFile(file.id, from: project.id)
                }
              }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
              Button("Remove", systemImage: "trash", role: .destructive) {
                Task { @MainActor in
                  await projects.removeProjectFile(file.id, from: project.id)
                }
              }
            }
          }
          .listRowSeparatorTint(theme.borderColor)
        } footer: {
          Text(projectFilesFooter(project.projectFiles))
            .foregroundStyle(theme.secondaryForegroundColor)
        }
        .listRowBackground(theme.surfaceColor)
      }
      .listStyle(.insetGrouped)
      .scrollContentBackground(.hidden)
    }
  }

  private func projectFilesFooter(_ files: [ProjectFile]) -> String {
    let totalBytes = files.reduce(Int64(0)) { $0 + Int64($1.byteCount) }
    let size = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    let countLabel = files.count == 1 ? "1 file" : "\(files.count) files"
    return "\(countLabel) · \(size). Attach project files from the chat composer when a message needs them."
  }

  private func openFilePreview(_ file: ProjectFile) {
    let requestID = UUID()
    previewRequestID = requestID
    loadingFileID = file.id
    Task { @MainActor in
      let data = await projects.fileData(file.id)
      guard previewRequestID == requestID else { return }
      loadingFileID = nil
      guard let data, !data.isEmpty else {
        projects.errorMessage = "The file '\(file.filename)' could not be loaded."
        return
      }
      filePreview = ProjectFilePreviewPresentation(
        item: LibraryQuickLookItem(id: file.id, filename: file.filename, data: data)
      )
    }
  }

  @ViewBuilder
  private func settingsList(_ project: ChatProject) -> some View {
    let accountDisplay = accountStatus(project)
    let modelDisplay = modelStatus(project)
    List {
      Section {
        LabeledContent("Provider Account") {
          Text(accountDisplay.label)
            .foregroundStyle(accountDisplay.isUnavailable ? Color.orange : theme.secondaryForegroundColor)
        }
        if project.accountID != nil {
          LabeledContent("Model") {
            Text(modelDisplay.label)
              .foregroundStyle(modelDisplay.isUnavailable ? Color.orange : theme.secondaryForegroundColor)
          }
        }
      } header: {
        Text("New Chat Defaults")
          .foregroundStyle(theme.secondaryForegroundColor)
      } footer: {
        Text("Applied when a chat is created. Existing chats keep their current provider and model.")
          .foregroundStyle(theme.secondaryForegroundColor)
      }
      .listRowSeparatorTint(theme.borderColor)
      .listRowBackground(theme.surfaceColor)

      Section {
        let instructions = project.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if instructions.isEmpty {
          Text("App default system prompt.")
            .foregroundStyle(theme.secondaryForegroundColor)
        } else {
          Text(instructions)
            .lineLimit(6)
        }
      } header: {
        Text("Instructions")
          .foregroundStyle(theme.secondaryForegroundColor)
      }
      .listRowSeparatorTint(theme.borderColor)
      .listRowBackground(theme.surfaceColor)

      if !project.projectPromptPresets.isEmpty {
        Section {
          ForEach(project.projectPromptPresets) { preset in
            VStack(alignment: .leading, spacing: 2) {
              Text(preset.name)
              Text(preset.prompt)
                .font(.caption)
                .foregroundStyle(theme.secondaryForegroundColor)
                .lineLimit(1)
            }
          }
          .listRowSeparatorTint(theme.borderColor)
        } header: {
          Text("Reusable Prompts")
            .foregroundStyle(theme.secondaryForegroundColor)
        }
        .listRowBackground(theme.surfaceColor)
      }

      Section {
        LabeledContent(
          "Default Tools",
          value: projectToolsSummary(
            configuration: project.mcpConfiguration,
            toolPresets: project.projectToolPresets
          )
        )
      } footer: {
        Text("Chats start with these MCP servers and permissions until they customize Tools themselves.")
          .foregroundStyle(theme.secondaryForegroundColor)
      }
      .listRowSeparatorTint(theme.borderColor)
      .listRowBackground(theme.surfaceColor)

      Section {
        Button {
          showEditor = true
        } label: {
          Label("Edit Project", systemImage: "slider.horizontal.3")
            .foregroundStyle(theme.accentColor)
        }
        Button(role: .destructive) {
          confirmDelete = true
        } label: {
          Label("Delete Project…", systemImage: "trash")
        }
      }
      .listRowSeparatorTint(theme.borderColor)
      .listRowBackground(theme.surfaceColor)
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
  }

  private func accountStatus(_ project: ChatProject) -> (label: String, isUnavailable: Bool) {
    guard let accountID = project.accountID else { return ("App Default", false) }
    guard let account = providers.accounts.first(where: { $0.id == accountID }) else {
      return ("Unavailable Account", true)
    }
    if !account.isEnabled {
      return ("\(account.label) (Disabled)", true)
    }
    return (account.label, false)
  }

  private func modelStatus(_ project: ChatProject) -> (label: String, isUnavailable: Bool) {
    guard let modelID = project.modelID else { return ("Account Default", false) }
    guard let accountID = project.accountID else { return (modelID.rawValue, true) }
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
}

private struct ProjectFileIconView: View {
  let mimeType: String
  let color: Color
  var size: CGFloat = 36

  private var symbolName: String {
    if ProjectFileImportSupport.isImageMIMEType(mimeType) {
      return "photo"
    }
    if ProjectFileImportSupport.isTextLikeMIMEType(mimeType) {
      return "doc.text.fill"
    }
    return "doc.fill"
  }

  var body: some View {
    Image(systemName: symbolName)
      .font(.system(size: size * 0.44, weight: .semibold))
      .foregroundStyle(color)
      .frame(width: size, height: size)
      .background(
        color.opacity(0.14),
        in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
      )
      .accessibilityHidden(true)
  }
}

/// The active Project surface owns its alert; root is a fallback. Capture the
/// error identity when presenting so dismissal cannot erase a newer failure.
private struct ProjectErrorPresenter: ViewModifier {
  let projects: ProjectManagementModel
  @State private var presenterID = UUID()
  @State private var presentedError: ProjectManagementModel.OperationError?

  func body(content: Content) -> some View {
    let alertError = presentedError
    return content
      .onAppear { projects.registerErrorPresenter(presenterID) }
      .onDisappear { projects.unregisterErrorPresenter(presenterID) }
      .onChange(of: projects.errorForPresenter(presenterID), initial: true) { _, error in
        if error == nil {
          presentedError = nil
        } else if presentedError == nil {
          presentedError = error
        }
      }
      .alert(
        "Project Error",
        isPresented: Binding(
          get: { presentedError != nil },
          set: { if !$0, let error = alertError { acknowledge(error) } }
        ),
        presenting: alertError
      ) { error in
        Button("OK") { acknowledge(error) }
      } message: { error in
        Text(error.message)
      }
  }

  private func acknowledge(_ error: ProjectManagementModel.OperationError) {
    guard presentedError?.id == error.id else { return }
    projects.acknowledgeError(error, in: presenterID)
    presentedError = nil
    // If another failure arrived while this alert was visible, its identity
    // did not change on dismissal. Present it on the next UI turn.
    Task { @MainActor in
      await Task.yield()
      if presentedError == nil { presentedError = projects.errorForPresenter(presenterID) }
    }
  }
}

extension View {
  func projectErrorPresenter(_ projects: ProjectManagementModel) -> some View {
    modifier(ProjectErrorPresenter(projects: projects))
  }
}
