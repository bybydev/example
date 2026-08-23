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

  @Environment(\.appFoundationTheme) var theme
  @State var draft = ""
  @State var isCreating = false
  @State var pendingAttachments: [ChatAttachment] = []
  @State var showPhotoPicker = false
  @State var photoPickerItems: [PhotosPickerItem] = []
  @State var showFileImporter = false
  @State var showProjectEditor = false
  @State var showTargetPicker = false
  @State var showConnections = false
  @State var targetOverride: NewChatTargetSelection?

  enum Readiness {
    case noConnection
    case missingCredential
    case noModel
    case ready
  }

  struct StarterAction: Identifiable {
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

  var project: ChatProject? {
    projects.project(projectID)
  }

  var defaultAccount: ProviderAccount? {
    let enabled = providers.accounts.filter(\.isEnabled)

    if let targetOverride {
      return enabled.first { $0.id == targetOverride.accountID }
    }

    if let accountID = project?.accountID {
      return enabled.first { $0.id == accountID }
    }

    if let ready = enabled.first(where: isConnectionReady) {
      return ready
    }

    return enabled.first
  }

  var defaultProvider: ProviderDefinition? {
    guard let account = defaultAccount else { return nil }
    return providers.provider(for: account.providerID)
  }

  var defaultModelID: ModelID? {
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

    if let accountModelID = account.defaultModelID,
      models.contains(where: { $0.model.id == accountModelID })
    {
      return accountModelID
    }

    return models.first?.model.id
  }

  var selectedModel: ProviderModel? {
    guard let account = defaultAccount, let modelID = defaultModelID else { return nil }
    return providers.models(for: account.id, includeHidden: true)
      .first(where: { $0.model.id == modelID })?.model
  }

  var readiness: Readiness {
    guard let account = defaultAccount else { return .noConnection }
    if providerRequiresCredential(account.providerID),
      !providers.credentialAccountIDs.contains(account.id)
    {
      return .missingCredential
    }
    guard defaultModelID != nil else { return .noModel }
    return .ready
  }

  var canStartConversation: Bool {
    if case .ready = readiness { return true }
    return false
  }

  var targetReasoning: ReasoningOptions? {
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

  var targetSummary: String {
    if project?.accountID != nil && defaultAccount == nil {
      return "Project connection unavailable"
    }
    if project?.modelID != nil && defaultAccount != nil && defaultModelID == nil {
      return "Project model unavailable"
    }
    switch readiness {
    case .noConnection:
      return "Set up connection"
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

  var targetDetails: String {
    guard let account = defaultAccount else { return "No connection configured" }
    switch readiness {
    case .missingCredential:
      return "\(account.label) · API key required"
    case .noModel:
      return "\(account.label) · No available model"
    case .noConnection:
      return "No connection configured"
    case .ready:
      let modelName = selectedModel?.displayName ?? defaultModelID?.rawValue ?? "No model"
      return "\(account.label) · \(modelName)"
    }
  }

  var starterActions: [StarterAction] {
    var actions = [
      StarterAction(
        id: "write",
        title: "Write",
        systemImage: "square.and.pencil",
        kind: .draft("Help me write a")
      ),
      StarterAction(
        id: "brainstorm",
        title: "Brainstorm",
        systemImage: "lightbulb",
        kind: .draft("Give me ideas for")
      ),
    ]

    if selectedModel?.inputModalities.contains("image") == true {
      actions.append(
        StarterAction(id: "photo", title: "Analyze a photo", systemImage: "photo", kind: .photo)
      )
    }
    if selectedModel?.inputModalities.contains("file") == true {
      actions.append(
        StarterAction(id: "file", title: "Summarize a file", systemImage: "doc.text", kind: .file)
      )
    }
    if actions.count < 4 {
      actions.append(
        StarterAction(
          id: "explain",
          title: "Explain",
          systemImage: "text.magnifyingglass",
          kind: .draft("Explain this to me:")
        )
      )
    }
    if actions.count < 4 {
      actions.append(
        StarterAction(
          id: "summarize",
          title: "Summarize",
          systemImage: "text.alignleft",
          kind: .draft("Summarize this for me:")
        )
      )
    }
    return Array(actions.prefix(4))
  }

  var body: some View {
    ZStack {
      theme.backgroundColor.ignoresSafeArea()
      VStack(spacing: 0) {
        Spacer(minLength: 52)
        emptyStateContent
          .padding(.horizontal, 24)
        Spacer(minLength: 24)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .contentShape(Rectangle())
    .onTapGesture {
      UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder),
        to: nil,
        from: nil,
        for: nil
      )
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
            Button("Project Settings", systemImage: "folder.badge.gearshape") {
              showProjectEditor = true
            }
          }
          Button("Settings", systemImage: "gearshape", action: openSettings)
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
        projectFiles: project?.projectFiles ?? [],
        attachProjectFile: { file in appendAttachments([file.attachment]) },
        removeAttachment: removePendingAttachment,
        send: startConversation
      )
    }
    .sheet(isPresented: $showTargetPicker) {
      if let account = defaultAccount, let modelID = defaultModelID {
        NewChatTargetPickerView(
          initialAccountID: account.id,
          initialModelID: modelID,
          initialReasoning: targetReasoning,
          providers: providers
        ) { selection in
          targetOverride = selection
        }
      }
    }
    .sheet(isPresented: $showProjectEditor) {
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
    .sheet(isPresented: $showConnections) {
      NavigationStack {
        ConnectionsView(model: providers) {
          showConnections = false
        }
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Close") { showConnections = false }
          }
        }
      }
      .presentationDragIndicator(.visible)
    }
    .photosPicker(
      isPresented: $showPhotoPicker,
      selection: $photoPickerItems,
      maxSelectionCount: 8,
      matching: .images
    )
    .onChange(of: photoPickerItems) { _, items in
      importPhotos(items)
    }
    .fileImporter(
      isPresented: $showFileImporter,
      allowedContentTypes: [.item],
      allowsMultipleSelection: true
    ) { result in
      importFiles(result)
    }
  }

}
