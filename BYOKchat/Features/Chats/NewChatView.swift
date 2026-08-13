import AppFoundation
import BYOKchatProviderCore
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct NewChatView: View {
  @Bindable var chats: ChatManagementModel
  @Bindable var providers: ProviderManagementModel
  @Bindable var projects: ProjectManagementModel
  @Bindable var mcp: MCPManagementModel
  let projectID: ProjectID?

  let openSidebar: () -> Void
  let openSettings: () -> Void
  let selectConversation: (ConversationID) -> Void

  @Environment(\.appFoundationTheme) private var theme
  @State private var draft = ""
  @State private var isCreating = false
  @State private var pendingAttachments: [ChatAttachment] = []
  @State private var showPhotoPicker = false
  @State private var photoPickerItems: [PhotosPickerItem] = []
  @State private var showFileImporter = false
  @State private var showProjectEditor = false
  @State private var showTargetPicker = false
  @State private var showProviderList = false
  @State private var selectedSetupProvider: ProviderDefinition?
  @State private var selectedSetupAccount: ProviderAccount?
  @State private var targetOverride: NewChatTargetSelection?

  private enum Readiness {
    case noAccount
    case missingCredential
    case noModel
    case ready
  }

  private struct StarterAction: Identifiable {
    enum Kind {
      case draft(String)
      case photo
      case file
    }

    let id: String
    let title: String
    let systemImage: String
    let kind: Kind
  }

  private var project: ChatProject? {
    projects.project(projectID)
  }

  private var defaultAccount: ProviderAccount? {
    let enabled = providers.accounts.filter(\.isEnabled)
    if let targetOverride {
      return enabled.first { $0.id == targetOverride.accountID }
    }
    if let accountID = project?.accountID {
      return enabled.first { $0.id == accountID }
    }
    return enabled.first
  }

  private var defaultProvider: ProviderDefinition? {
    guard let account = defaultAccount else { return nil }
    return providers.provider(for: account.providerID)
  }

  private var defaultModelID: ModelID? {
    guard let account = defaultAccount else { return nil }
    let models = providers.models(for: account.id).filter(\.isAvailable)
    if let targetOverride, targetOverride.accountID == account.id {
      return models.contains(where: { $0.model.id == targetOverride.modelID })
        ? targetOverride.modelID
        : nil
    }
    if let projectModelID = project?.modelID {
      return models.contains(where: { $0.model.id == projectModelID }) ? projectModelID : nil
    }
    return account.defaultModelID ?? models.first?.model.id
  }

  private var selectedModel: ProviderModel? {
    guard let account = defaultAccount, let modelID = defaultModelID else { return nil }
    return providers.models(for: account.id, includeHidden: true)
      .first(where: { $0.model.id == modelID })?.model
  }

  private var readiness: Readiness {
    guard let account = defaultAccount else { return .noAccount }
    if providerRequiresCredential(account.providerID),
      !providers.credentialAccountIDs.contains(account.id)
    {
      return .missingCredential
    }
    guard defaultModelID != nil else { return .noModel }
    return .ready
  }

  private var canStartConversation: Bool {
    if case .ready = readiness { return true }
    return false
  }

  private var targetReasoning: ReasoningOptions? {
    if let targetOverride { return targetOverride.reasoning }
    guard let providerID = defaultAccount?.providerID else { return nil }
    switch providerID {
    case BuiltInProviders.deepSeekID, BuiltInProviders.anthropicID:
      return .init(enabled: true, effort: .high)
    case BuiltInProviders.geminiID:
      return .init(enabled: true, effort: .medium)
    default:
      return nil
    }
  }

  private var targetSummary: String {
    if project?.accountID != nil && defaultAccount == nil {
      return "Provider unavailable"
    }
    switch readiness {
    case .noAccount:
      return "Connect provider"
    case .missingCredential:
      return "Add API key"
    case .noModel:
      return "Choose model"
    case .ready:
      guard let account = defaultAccount, let modelID = defaultModelID else {
        return "Choose model"
      }
      let providerName = providers.provider(for: account.providerID)?.displayName ?? account.label
      let model = selectedModel
      return ComposerTargetLabelFormatter.make(
        providerID: account.providerID,
        providerName: providerName,
        modelName: model?.displayName ?? modelID.rawValue,
        modelID: modelID.rawValue,
        supportedParameters: model?.supportedParameters ?? [],
        reasoning: targetReasoning
      )
    }
  }

  private var targetDetails: String {
    guard let account = defaultAccount else { return "No provider configured" }
    switch readiness {
    case .missingCredential:
      return "\(account.label) · API key required"
    case .noModel:
      return "\(account.label) · No available model"
    case .noAccount:
      return "No provider configured"
    case .ready:
      let modelName = selectedModel?.displayName ?? defaultModelID?.rawValue ?? "No model"
      return "\(account.label) · \(modelName)"
    }
  }

  private var builtInProviders: [ProviderDefinition] {
    providers.definitions.filter(\.isBuiltIn)
  }

  private var starterActions: [StarterAction] {
    var actions = [
      StarterAction(id: "write", title: "Write", systemImage: "square.and.pencil", kind: .draft("Help me write a")),
      StarterAction(id: "brainstorm", title: "Brainstorm", systemImage: "lightbulb", kind: .draft("Give me ideas for")),
    ]
    if selectedModel?.inputModalities.contains("image") == true {
      actions.append(StarterAction(id: "photo", title: "Analyze a photo", systemImage: "photo", kind: .photo))
    } else if selectedModel?.inputModalities.contains("file") == true {
      actions.append(StarterAction(id: "file", title: "Summarize a file", systemImage: "doc.text", kind: .file))
    } else {
      actions.append(StarterAction(id: "explain", title: "Explain", systemImage: "text.magnifyingglass", kind: .draft("Explain this to me:")))
    }
    actions.append(StarterAction(id: "summarize", title: "Summarize", systemImage: "text.alignleft", kind: .draft("Summarize this for me:")))
    return actions
  }

  var body: some View {
    ZStack {
      theme.backgroundColor.ignoresSafeArea()
      VStack(spacing: 0) {
        Spacer(minLength: 52)
        emptyStateContent.padding(.horizontal, 24)
        Spacer(minLength: 24)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .contentShape(Rectangle())
    .onTapGesture {
      UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    .toolbarBackground(.hidden, for: .navigationBar)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button("Open Sidebar", systemImage: "text.alignleft", action: openSidebar)
          .labelStyle(.iconOnly)
          .accessibilityLabel("Open sidebar")
      }
      ToolbarItemGroup(placement: .topBarTrailing) {
        Button("New Chat", systemImage: "square.and.pencil") {
          draft = ""
          pendingAttachments = []
          photoPickerItems = []
        }
        .labelStyle(.iconOnly)
        Menu {
          if let project, !project.projectPromptPresets.isEmpty {
            Menu("Prompts", systemImage: "text.bubble") {
              ForEach(project.projectPromptPresets) { preset in
                Button(preset.name) { applyPromptPreset(preset) }
              }
            }
          }
          if project != nil {
            Button("Project Settings", systemImage: "folder.badge.gearshape") { showProjectEditor = true }
          }
          Button("Settings", systemImage: "gearshape", action: openSettings)
          Button("Providers & Accounts", systemImage: "key.horizontal") { showProviderList = true }
        } label: {
          Image(systemName: "ellipsis")
        }
        .accessibilityLabel("More options")
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      ChatComposer(
        draft: $draft,
        attachments: pendingAttachments,
        activity: isCreating ? .creating : .idle,
        canSend: !isCreating && canStartConversation,
        targetSummary: targetSummary,
        targetDetails: targetDetails,
        openTarget: openCurrentTarget,
        pickPhoto: { showPhotoPicker = true },
        pickFile: { showFileImporter = true },
        removeAttachment: removePendingAttachment,
        send: startConversation
      )
    }
    .sheet(isPresented: $showTargetPicker) {
      if let account = defaultAccount, let modelID = defaultModelID {
        NewChatTargetPickerView(initialAccountID: account.id, initialModelID: modelID, initialReasoning: targetReasoning, providers: providers) { selection in
          targetOverride = selection
        }
      }
    }
    .sheet(isPresented: $showProjectEditor) {
      if let project {
        ProjectEditorView(project: project, projects: projects, providers: providers, mcp: mcp)
          .presentationDragIndicator(.visible)
      }
    }
    .sheet(isPresented: $showProviderList) {
      NavigationStack {
        ProviderListView(model: providers)
          .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { showProviderList = false } } }
      }
      .presentationDragIndicator(.visible)
    }
    .sheet(item: $selectedSetupProvider) { provider in
      NavigationStack {
        ProviderDetailView(model: providers, providerID: provider.id)
          .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { selectedSetupProvider = nil } } }
      }
      .presentationDragIndicator(.visible)
    }
    .sheet(item: $selectedSetupAccount) { account in
      NavigationStack {
        AccountDetailView(model: providers, accountID: account.id)
          .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { selectedSetupAccount = nil } } }
      }
      .presentationDragIndicator(.visible)
    }
    .photosPicker(isPresented: $showPhotoPicker, selection: $photoPickerItems, maxSelectionCount: 8, matching: .images)
    .onChange(of: photoPickerItems) { _, items in importPhotos(items) }
    .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
      importFiles(result)
    }
  }

  @ViewBuilder
  private var emptyStateContent: some View {
    switch readiness {
    case .ready:
      if let project { projectReadyContent(project) } else { readyChatContent }
    case .noAccount, .missingCredential, .noModel:
      setupContent
    }
  }

  private var readyChatContent: some View {
    VStack(spacing: 18) {
      Image(systemName: "bubble.left.and.bubble.right")
        .font(.system(size: 30, weight: .medium))
        .foregroundStyle(theme.accentColor)
        .accessibilityHidden(true)
      Text("How can I help?")
        .font(.system(size: 30, weight: .semibold))
        .multilineTextAlignment(.center)
      targetChip
      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
        ForEach(starterActions) { action in starterActionButton(action) }
      }
      .frame(maxWidth: 480)
    }
    .frame(maxWidth: .infinity)
  }

  private func projectReadyContent(_ project: ChatProject) -> some View {
    VStack(spacing: 14) {
      ProjectIconView(project: project, size: 44)
      Text(project.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(project.projectColor)
      Text("What are we working on?").font(.system(size: 28, weight: .semibold)).multilineTextAlignment(.center)
      Text(projectContextSummary).font(.system(size: 15)).multilineTextAlignment(.center).foregroundStyle(.secondary)
      targetChip
      if !project.projectPromptPresets.isEmpty {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
          ForEach(Array(project.projectPromptPresets.prefix(4))) { preset in
            Button { applyPromptPreset(preset) } label: {
              HStack(spacing: 9) {
                Image(systemName: "text.bubble").foregroundStyle(theme.accentColor)
                Text(preset.name).lineLimit(2)
                Spacer(minLength: 0)
              }
              .font(.system(size: 14, weight: .medium))
              .multilineTextAlignment(.leading)
              .padding(.horizontal, 14)
              .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
              .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
              .overlay { RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08), lineWidth: 1) }
            }
            .buttonStyle(.plain)
          }
        }
        .frame(maxWidth: 480)
      }
    }
    .frame(maxWidth: .infinity)
  }

  @ViewBuilder
  private var setupContent: some View {
    VStack(spacing: 16) {
      Image(systemName: setupIcon).font(.system(size: 32, weight: .medium)).foregroundStyle(theme.accentColor).accessibilityHidden(true)
      Text(setupTitle).font(.system(size: 28, weight: .semibold)).multilineTextAlignment(.center)
      Text(setupDescription).font(.system(size: 15)).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 440)
      if case .noAccount = readiness, !builtInProviders.isEmpty {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
          ForEach(builtInProviders) { provider in
            Button { selectedSetupProvider = provider } label: {
              HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(theme.accentColor)
                Text(provider.displayName).lineLimit(1)
                Spacer(minLength: 0)
              }
              .font(.system(size: 14, weight: .medium))
              .padding(.horizontal, 12)
              .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
              .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
              .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 1) }
            }
            .buttonStyle(.plain)
          }
        }
        .frame(maxWidth: 440)
      }
      Button { primarySetupAction() } label: {
        Label(primarySetupTitle, systemImage: primarySetupIcon)
          .font(.system(size: 16, weight: .semibold))
          .frame(maxWidth: 320)
          .padding(.vertical, 12)
      }
      .buttonStyle(.borderedProminent)
      .tint(theme.accentColor)
      if case .noAccount = readiness {
        Button("Use a custom provider") { showProviderList = true }.font(.system(size: 14, weight: .medium))
        Text("API keys are stored in Keychain. Requests go directly to your selected provider.")
          .font(.caption)
          .multilineTextAlignment(.center)
          .foregroundStyle(.tertiary)
          .frame(maxWidth: 420)
      }
    }
    .frame(maxWidth: .infinity)
  }

  private var targetChip: some View {
    Button { showTargetPicker = true } label: {
      HStack(spacing: 7) {
        Image(systemName: "sparkles")
        Text(targetSummary).lineLimit(1)
        Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
      }
      .font(.system(size: 13, weight: .medium))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
      .background(.thinMaterial, in: Capsule())
    }
    .buttonStyle(.plain)
  }

  private func starterActionButton(_ action: StarterAction) -> some View {
    Button { applyStarterAction(action) } label: {
      HStack(spacing: 9) {
        Image(systemName: action.systemImage).foregroundStyle(theme.accentColor)
        Text(action.title).lineLimit(2)
        Spacer(minLength: 0)
      }
      .font(.system(size: 14, weight: .medium))
      .multilineTextAlignment(.leading)
      .padding(.horizontal, 14)
      .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
      .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
      .overlay { RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08), lineWidth: 1) }
    }
    .buttonStyle(.plain)
  }

  private var setupIcon: String {
    switch readiness {
    case .noAccount: "key.horizontal"
    case .missingCredential: "key.slash"
    case .noModel: "rectangle.stack.badge.plus"
    case .ready: "bubble.left.and.bubble.right"
    }
  }

  private var setupTitle: String {
    switch readiness {
    case .noAccount: return project == nil ? "Connect your AI" : "Connect a provider"
    case .missingCredential: return "Finish setting up \(defaultProvider?.displayName ?? defaultAccount?.label ?? "provider")"
    case .noModel: return "Choose a model"
    case .ready: return "How can I help?"
    }
  }

  private var setupDescription: String {
    switch readiness {
    case .noAccount:
      if let project { return "Add a provider account before starting a chat in \(project.name)." }
      return "Connect an AI provider to start chatting with your own account."
    case .missingCredential: return "Add an API key to \(defaultAccount?.label ?? "this account") before starting a chat."
    case .noModel: return "Select an available model for \(defaultAccount?.label ?? "this account") before starting a chat."
    case .ready: return ""
    }
  }

  private var primarySetupTitle: String {
    switch readiness {
    case .noAccount: "Connect a Provider"
    case .missingCredential: "Open Account"
    case .noModel: "Choose Model"
    case .ready: "Start Chatting"
    }
  }

  private var primarySetupIcon: String {
    switch readiness {
    case .noAccount: "plus.circle.fill"
    case .missingCredential: "key.fill"
    case .noModel: "rectangle.stack.fill"
    case .ready: "arrow.up.circle.fill"
    }
  }

  private func primarySetupAction() {
    switch readiness {
    case .noAccount:
      showProviderList = true
    case .missingCredential, .noModel:
      if let account = defaultAccount { selectedSetupAccount = account } else { showProviderList = true }
    case .ready:
      break
    }
  }

  private func openCurrentTarget() {
    switch readiness {
    case .ready:
      showTargetPicker = true
    case .missingCredential, .noModel:
      if let account = defaultAccount { selectedSetupAccount = account } else { showProviderList = true }
    case .noAccount:
      if project?.accountID != nil { showProjectEditor = true } else { showProviderList = true }
    }
  }

  private func providerRequiresCredential(_ providerID: ProviderID) -> Bool {
    guard let provider = providers.provider(for: providerID) else { return true }
    switch provider.authentication {
    case .none: return false
    case .bearer, .header: return true
    }
  }

  private func applyStarterAction(_ action: StarterAction) {
    switch action.kind {
    case .draft(let value): draft = value
    case .photo: showPhotoPicker = true
    case .file: showFileImporter = true
    }
  }

  private var projectContextSummary: String {
    guard let project else { return "" }
    var parts = ["Uses project defaults and instructions"]
    if !project.projectFiles.isEmpty {
      parts.append("\(project.projectFiles.count) reference file\(project.projectFiles.count == 1 ? "" : "s")")
    }
    if let configuration = project.mcpConfiguration, !configuration.enabledServerIDs.isEmpty {
      parts.append("project tools")
    }
    return parts.joined(separator: " · ")
  }

  private func applyPromptPreset(_ preset: ProjectPromptPreset) {
    let value = preset.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      draft = value
    } else {
      draft += "\n\n" + value
    }
  }

  private func startConversation() {
    let normalized = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    let attachments = pendingAttachments
    guard !normalized.isEmpty || !attachments.isEmpty else { return }
    guard !isCreating else { return }
    guard canStartConversation, defaultAccount != nil, defaultModelID != nil else { return }

    isCreating = true
    Task { @MainActor in
      defer { isCreating = false }
      guard let id = await chats.createConversation(projectID: projectID) else { return }
      await projects.reloadFromStorage()
      await mcp.reloadFromStorage()

      if let targetOverride,
        let account = providers.accounts.first(where: { $0.id == targetOverride.accountID }),
        let created = chats.conversation(id)
      {
        var options = created.options
        options.reasoning = targetOverride.reasoning
        guard await chats.updateTarget(
          conversationID: id,
          account: account,
          modelID: targetOverride.modelID,
          systemPrompt: created.systemPrompt,
          options: options
        ) else { return }
      }

      draft = ""
      pendingAttachments = []
      photoPickerItems = []
      chats.send(conversationID: id, text: normalized, attachments: attachments)
      selectConversation(id)
    }
  }

  private func importPhotos(_ items: [PhotosPickerItem]) {
    guard !items.isEmpty else { return }
    Task { @MainActor in
      var imported: [ChatAttachment] = []
      for item in items {
        do {
          guard let data = try await item.loadTransferable(type: Data.self) else { continue }
          let attachment = try normalizedImageAttachment(data: data, suggestedName: "image-\(pendingAttachments.count + imported.count + 1)")
          imported.append(attachment)
        } catch {
          chats.errorMessage = error.localizedDescription
        }
      }
      appendAttachments(imported)
      photoPickerItems = []
    }
  }

  private func importFiles(_ result: Result<[URL], Error>) {
    switch result {
    case .failure(let error):
      chats.errorMessage = error.localizedDescription
    case .success(let urls):
      do {
        let attachments = try urls.map(loadFileAttachment)
        appendAttachments(attachments)
      } catch {
        chats.errorMessage = error.localizedDescription
      }
    }
  }

  private func loadFileAttachment(_ url: URL) throws -> ChatAttachment {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    let values = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
    if let fileSize = values.fileSize, fileSize > 20 * 1_024 * 1_024 {
      throw ProviderError.invalidRequest("\(url.lastPathComponent) is larger than 20 MB.")
    }
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    let type = values.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
    if type.conforms(to: .image) {
      return try normalizedImageAttachment(data: data, suggestedName: url.deletingPathExtension().lastPathComponent)
    }
    return ChatAttachment(kind: .file, filename: url.lastPathComponent, mimeType: type.preferredMIMEType ?? "application/octet-stream", data: data)
  }

  private func normalizedImageAttachment(data: Data, suggestedName: String) throws -> ChatAttachment {
    guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.9) else {
      throw ProviderError.invalidRequest("The selected image could not be read.")
    }
    return ChatAttachment(kind: .image, filename: suggestedName + ".jpg", mimeType: "image/jpeg", data: jpeg)
  }

  private func appendAttachments(_ additions: [ChatAttachment]) {
    guard !additions.isEmpty else { return }
    let combined = pendingAttachments + additions
    guard combined.count <= 8 else {
      chats.errorMessage = "A message can include at most 8 attachments."
      return
    }
    guard combined.allSatisfy({ $0.byteCount <= 20 * 1_024 * 1_024 }) else {
      chats.errorMessage = "Each attachment must be no larger than 20 MB."
      return
    }
    guard combined.reduce(0, { $0 + $1.byteCount }) <= 40 * 1_024 * 1_024 else {
      chats.errorMessage = "Attachments in one message cannot exceed 40 MB total."
      return
    }
    pendingAttachments = combined
  }

  private func removePendingAttachment(_ id: String) {
    pendingAttachments.removeAll { $0.id == id }
  }
}
