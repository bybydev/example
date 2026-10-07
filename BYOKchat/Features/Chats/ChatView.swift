import AppFoundation
import BYOKchatProviderCore
import Foundation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Which chat surface `ChatView` presents. There is exactly one chat view in
/// the app; new chats use real conversations before their first send.
enum ChatSubject {
  /// A persisted conversation (root-selected or stack-pushed).
  case existing(ConversationID)
  /// Setup-only fallback when no usable account/model exists yet. Once ready,
  /// the root creates a real conversation and presents the existing surface.
  case fresh(projectID: ProjectID?)

  var existingID: ConversationID? {
    if case .existing(let id) = self { return id }
    return nil
  }
}

enum ChatReadiness: String {
  case ready
  case noConnection
  case missingCredential
  case noModel
}

struct ChatView: View {
  /// Identity of the backing conversation. Only meaningful for `.existing`;
  /// fresh mode never touches the store under this ID.
  let conversationID: ConversationID
  let subject: ChatSubject
  let initialScrollMessageID: ChatMessageID?
  /// True when the chat was reached through its project's chat list; swaps the
  /// leading hamburger for a back chevron next to the project pill.
  let enteredFromProject: Bool
  let openSidebar: () -> Void
  let startNewChat: () -> Void
  let openProject: () -> Void
  /// Setup-only fallback asks the root coordinator to open a real conversation.
  var onReadyForConversation: () -> Void = {}

  @Bindable var chats: ChatManagementModel
  @Bindable var providers: ProviderManagementModel
  @Bindable var projects: ProjectManagementModel
  @Bindable var mcp: MCPManagementModel
  let library: LibraryManagementModel
  /// Chat lives inside the navigation stack (pushed from a project): the
  /// leading slot stays empty so the system back button shows.
  var pushedFromStack: Bool = false

  // Non-private: the chat content extension in ChatView+Content.swift uses it.
  @Environment(\.appFoundationTheme) var theme
  @Environment(\.dismiss) var dismiss
  @State var draft = ""
  @State var restoredDraft = false
  @State var showConnections = false
  @State var showProjectEditorSheet = false
  @State var showTargetSettings = false
  @State var showToolSettings = false
  @State var showUsage = false
  @State var renameText = ""
  @State var showRename = false
  @State var editTarget: ChatMessage?
  @State var editText = ""
  @State var showRegenerateConfirmation = false
  @State var isNearBottom = true
  @State var followsLatest = true
  @State var isUserDraggingTimeline = false
  @State var showJumpToLatest = false
  @State var hasCompletedInitialScroll = false
  @State var chatScrollPosition = ScrollPosition(idType: String.self)
  @State var markdownDocument: MarkdownExportDocument?
  @State var showMarkdownExporter = false
  @State var pendingAttachments: [ChatAttachment] = []
  @State var showPhotoPicker = false
  @State var photoPickerItems: [PhotosPickerItem] = []
  @State var showFileImporter = false
  @State var showLibraryPicker = false
  @State var libraryErrorMessage: String?
  @State var showLibraryUpsell = false

  init(
    subject: ChatSubject,
    initialScrollMessageID: ChatMessageID? = nil,
    enteredFromProject: Bool = false,
    chats: ChatManagementModel,
    providers: ProviderManagementModel,
    projects: ProjectManagementModel,
    mcp: MCPManagementModel,
    library: LibraryManagementModel,
    pushedFromStack: Bool = false,
    onReadyForConversation: @escaping () -> Void = {},
    openSidebar: @escaping () -> Void = {},
    startNewChat: @escaping () -> Void = {},
    openProject: @escaping () -> Void = {}
  ) {
    self.subject = subject
    // Setup never uses this editor identity for storage or configuration.
    self.conversationID =
      subject.existingID ?? ConversationID()
    self.initialScrollMessageID = initialScrollMessageID
    self.enteredFromProject = enteredFromProject
    self.chats = chats
    self.providers = providers
    self.projects = projects
    self.mcp = mcp
    self.library = library
    self.pushedFromStack = pushedFromStack
    self.onReadyForConversation = onReadyForConversation
    self.openSidebar = openSidebar
    self.startNewChat = startNewChat
    self.openProject = openProject
  }

  var isFresh: Bool {
    if case .fresh = subject { return true }
    return false
  }

  var conversation: ChatConversation? {
    guard !isFresh else { return nil }
    return chats.conversation(conversationID)
  }

  var project: ChatProject? {
    if case .fresh(let projectID) = subject {
      return projectID.flatMap { projects.project($0) }
    }
    return projects.project(for: conversationID)
  }

  var latestAssistantID: ChatMessageID? {
    conversation?.messages.last(where: { $0.role == .assistant })?.id
  }

  var markdownFilename: String {
    let title = conversation?.title ?? "BYOKchat-conversation"
    let safe = title.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
    return String(safe).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
  }

  var body: some View {
    Group {
      switch subject {
      case .fresh(let projectID):
        freshContent(projectID)
      case .existing:
        existingContent
      }
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
    .sheet(isPresented: $showLibraryPicker) {
      LibraryAttachmentPickerView(
        library: library,
        chats: chats,
        pendingAttachments: pendingAttachments
      ) { attachments in
        appendAttachments(attachments)
      }
      .presentationDragIndicator(.visible)
    }
    .sheet(isPresented: $showLibraryUpsell) {
      BYOKProUpsellFlow(feature: .libraryItems)
    }
    .alert("Library Error", isPresented: Binding(
      get: { libraryErrorMessage != nil },
      set: { if !$0 { libraryErrorMessage = nil } }
    )) {
      Button("OK") { libraryErrorMessage = nil }
    } message: {
      Text(libraryErrorMessage ?? "Unknown error")
    }
  }

  /// Message actions report only to this chat; root and LibraryView errors
  /// remain untouched. Save Images owns its errors while its sheet is active.
  func handleLibraryError(_ error: Error) {
    if error is LibraryCapacityError {
      showLibraryUpsell = true
    } else {
      libraryErrorMessage = error.localizedDescription
    }
  }

  /// The persisted-conversation surface. Everything here assumes the store
  /// knows this conversation.
  private var existingContent: some View {
    Group {
      if let conversation {
        chatContent(conversation)
      } else {
        if chats.hasConversation(conversationID) && !chats.failedToLoad(conversationID) {
          ProgressView("Loading chat…")
        } else {
          ContentUnavailableView("Conversation Missing", systemImage: "exclamationmark.bubble")
        }
      }
    }
    .background(theme.backgroundColor)
    .toolbarBackground(.hidden, for: .navigationBar)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        if pushedFromStack {
          // System back owns the leading slot for stack-pushed chats.
        } else if let project, enteredFromProject {
          Button("Back to Project", systemImage: "chevron.left", action: openProject)
            .labelStyle(.iconOnly)
            .accessibilityLabel("Back to \(project.name)")
        } else {
          Button("Open Sidebar", systemImage: "text.alignleft", action: openSidebar)
            .labelStyle(.iconOnly)
            .accessibilityLabel("Open sidebar")
        }
      }

      // Project context as the centered title — its own placement, so it
      // can't merge with the leading control.
      if let project {
        ToolbarItem(placement: .principal) {
          HStack(spacing: 6) {
            ProjectIconView(project: project, size: 20)
            Text(project.name)
              .font(.subheadline.weight(.semibold))
              .lineLimit(1)
          }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("Project \(project.name)")
        }
      }

      ToolbarItemGroup(placement: .topBarTrailing) {
        Button("New Chat", systemImage: "square.and.pencil", action: startNewChat)
          .labelStyle(.iconOnly)

        Menu {
          if let project, !project.projectPromptPresets.isEmpty {
            Menu("Prompts", systemImage: "text.bubble") {
              ForEach(project.projectPromptPresets) { preset in
                Button(preset.name) { applyPromptPreset(preset) }
              }
            }
          }
          Button("Chat Settings", systemImage: "slider.horizontal.3") {
            showTargetSettings = true
          }
          Button("Tools", systemImage: "wrench.and.screwdriver") {
            showToolSettings = true
          }
          if let project {
            Button("Project Settings", systemImage: "folder.badge.gearshape") {
              showProjectEditorSheet = true
            }
          }
          // Use committed history state, so drafts and optimistic UI edits
          // cannot expose actions that need saved conversation content.
          if chats.historyConversations.contains(where: { $0.id == conversationID }) {
            Button("Usage", systemImage: "chart.bar.xaxis") {
              showUsage = true
            }
            Button("Rename", systemImage: "pencil") {
              renameText = conversation?.title ?? ""
              showRename = true
            }
            Button("Export Markdown", systemImage: "square.and.arrow.up") {
              prepareMarkdownExport()
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
              Task { @MainActor in
                await chats.deleteConversation(conversationID)
                await projects.reloadFromStorage()
                await mcp.reloadFromStorage()
                if pushedFromStack {
                  // Popping lands on the screen beneath; starting a "next" chat
                  // here would push and immediately pop it.
                  dismiss()
                } else {
                  startNewChat()
                  dismiss()
                }
              }
            }
          }
        } label: {
          Image(systemName: "ellipsis")
        }
        .accessibilityLabel("More options")
      }
    }
    .sheet(isPresented: $showTargetSettings) {
      if let conversation {
        TargetPickerView(
          providers: providers,
          initialAccountID: conversation.accountID,
          initialModelID: conversation.modelID,
          initialReasoning: conversation.options.reasoning,
          mode: .existingChat(conversation: conversation, chats: chats)
        )
      }
    }
    .sheet(isPresented: $showToolSettings) {
      ConversationToolsView(
        conversationID: conversationID,
        projects: projects,
        mcp: mcp
      )
    }
    .sheet(isPresented: $showProjectEditorSheet) {
      if let project {
        ProjectEditorView(project: project, projects: projects, providers: providers, mcp: mcp)
          .presentationDragIndicator(.visible)
      }
    }
    .sheet(isPresented: $showUsage) {
      UsageDashboardView(
        conversations: chats.conversations,
        currentConversationID: conversationID
      )
    }
    .sheet(item: $editTarget) { message in
      MessageEditorSheet(
        original: message.content,
        text: $editText,
        save: {
          followsLatest = true
          showJumpToLatest = false
          chats.editAndResend(
            conversationID: conversationID,
            messageID: message.id,
            text: editText
          )
          editTarget = nil
        },
        cancel: { editTarget = nil }
      )
    }
    .alert("Rename Chat", isPresented: $showRename) {
      TextField("Title", text: $renameText)
      Button("Cancel", role: .cancel) {}
      Button("Save") {
        Task { @MainActor in
          await chats.renameConversation(conversationID, title: renameText)
        }
      }
    }
    .alert("Regenerate response?", isPresented: $showRegenerateConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Regenerate Anyway", role: .destructive) {
        followsLatest = true
        showJumpToLatest = false
        chats.regenerate(
          conversationID: conversationID,
          confirmingUncertainCompletion: true
        )
      }
    } message: {
      Text(
        "The previous request may have completed at the provider. Regenerating could create another billable request."
      )
    }
    .fileExporter(
      isPresented: $showMarkdownExporter,
      document: markdownDocument,
      contentType: .byokMarkdown,
      defaultFilename: markdownFilename
    ) { result in
      if case .failure(let error) = result {
        chats.errorMessage = error.localizedDescription
      }
    }
    .task(id: conversationID) {
      pendingAttachments = []
      photoPickerItems = []
      await chats.loadConversation(conversationID)
      guard !restoredDraft else { return }
      draft = chats.draft(for: conversationID)
      restoredDraft = true
    }
    .onChange(of: draft) { _, value in
      guard restoredDraft else { return }
      chats.saveDraft(value, conversationID: conversationID)
    }
  }

  // MARK: Connection setup fallback (no configurable staged chat)

  private func freshContent(_ projectID: ProjectID?) -> some View {
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
        if !pushedFromStack {
          Button("Open Sidebar", systemImage: "text.alignleft", action: openSidebar)
            .labelStyle(.iconOnly)
            .accessibilityLabel("Open sidebar")
        }
      }

      if let project {
        ToolbarItemGroup(placement: .topBarTrailing) {
          Menu {
            if !project.projectPromptPresets.isEmpty {
              Menu("Prompts", systemImage: "text.bubble") {
                ForEach(project.projectPromptPresets) { preset in
                  Button(preset.name) { applyPromptPreset(preset) }
                }
              }
            }
            Button("Project Settings", systemImage: "folder.badge.gearshape") {
              showProjectEditorSheet = true
            }
          } label: {
            Image(systemName: "ellipsis")
          }
          .accessibilityLabel("More options")
        }
      } else {
        ToolbarItemGroup(placement: .topBarTrailing) {
          Button("New Chat", systemImage: "square.and.pencil", action: onReadyForConversation)
            .labelStyle(.iconOnly)
        }
      }
    }
    .sheet(isPresented: $showConnections) {
      NavigationStack {
        // Repair/setup from the chat: finishing returns straight to the
        // now-ready composer instead of opening Settings.
        ProvidersView(model: providers) {
          // Intentionally no further navigation; the sheet dismissal is the
          // return path.
        }
      }
      .presentationDragIndicator(.visible)
    }
    .sheet(isPresented: $showProjectEditorSheet) {
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
    .onChange(of: readiness, initial: true) { _, value in
      if value == .ready { onReadyForConversation() }
    }
  }

  /// Internal: also called from the empty-state preset grid in
  /// ChatView+Content.swift.
  func applyPromptPreset(_ preset: ProjectPromptPreset) {
    let value = preset.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      draft = value
    } else {
      draft += "\n\n" + value
    }
  }

  private func prepareMarkdownExport() {
    guard let conversation else { return }
    let accountLabel = providers.accounts.first { $0.id == conversation.accountID }?.label
    markdownDocument = MarkdownExportDocument(
      data: Data(
        ConversationMarkdownFormatter.render(
          conversation,
          accountLabel: accountLabel
        ).utf8
      )
    )
    showMarkdownExporter = true
  }

  private func importPhotos(_ items: [PhotosPickerItem]) {
    guard !items.isEmpty else { return }
    Task { @MainActor in
      var imported: [ChatAttachment] = []
      for item in items {
        do {
          guard let data = try await item.loadTransferable(type: Data.self) else { continue }
          let attachment = try normalizedImageAttachment(
            data: data,
            suggestedName: "image-\(pendingAttachments.count + imported.count + 1)"
          )
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
    defer {
      if access { url.stopAccessingSecurityScopedResource() }
    }

    let values = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
    if let fileSize = values.fileSize, fileSize > 20 * 1_024 * 1_024 {
      throw ProviderError.invalidRequest("\(url.lastPathComponent) is larger than 20 MB.")
    }
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    let type = values.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data

    if type.conforms(to: .image) {
      return try normalizedImageAttachment(data: data, suggestedName: url.deletingPathExtension().lastPathComponent)
    }

    return ChatAttachment(
      kind: .file,
      filename: url.lastPathComponent,
      mimeType: type.preferredMIMEType ?? "application/octet-stream",
      data: data
    )
  }

  private func normalizedImageAttachment(data: Data, suggestedName: String) throws -> ChatAttachment {
    guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.9) else {
      throw ProviderError.invalidRequest("The selected image could not be read.")
    }
    return ChatAttachment(
      kind: .image,
      filename: suggestedName + ".jpg",
      mimeType: "image/jpeg",
      data: jpeg
    )
  }

  func appendAttachments(_ additions: [ChatAttachment]) {
    guard !additions.isEmpty else { return }
    let combined = pendingAttachments + additions
    guard Set(combined.map(\.id)).count == combined.count else {
      chats.errorMessage = "This attachment is already in the message."
      return
    }
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

  /// Attaches a project reference file to the composer. Rows are
  /// metadata-only, so the original bytes are fetched on demand; a missing
  /// blob surfaces an error instead of a silent empty attachment.
  func attachProjectFile(_ file: ProjectFile) async {
    guard let data = await projects.fileData(file.id), !data.isEmpty else {
      chats.errorMessage = "The file '\(file.filename)' could not be loaded."
      return
    }
    var attachment = file.attachment
    attachment.data = data
    appendAttachments([attachment])
  }

  func removePendingAttachment(_ id: String) {
    pendingAttachments.removeAll { $0.id == id }
  }
}

private struct ConversationToolsView: View {
  let conversationID: ConversationID
  @Bindable var projects: ProjectManagementModel
  @Bindable var mcp: MCPManagementModel
  @State private var errorPresenterID = UUID()

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appFoundationTheme) private var theme

  private var project: ChatProject? {
    projects.project(for: conversationID)
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          Label(
            "Only tools enabled here are sent to the model for this chat. New tools default to Ask.",
            systemImage: "hand.raised"
          )
          .font(.footnote)
          .foregroundStyle(theme.secondaryForegroundColor)

          if mcp.inheritsProjectTools(conversationID), let project {
            Label("Inheriting defaults from \(project.name)", systemImage: "arrow.triangle.branch")
              .font(.footnote)
              .foregroundStyle(theme.secondaryForegroundColor)
          } else if mcp.hasChatOverride(conversationID), project != nil {
            Button("Reset to Project Defaults", systemImage: "arrow.uturn.backward") {
              Task { @MainActor in
                await mcp.removeChatConfiguration(conversationID)
              }
            }
          }
        }
        .listRowBackground(theme.surfaceColor)

        if let project, !project.projectToolPresets.isEmpty {
          Section("Project Tool Presets") {
            ForEach(project.projectToolPresets) { preset in
              Button {
                Task { @MainActor in
                  await mcp.applyChatConfiguration(
                    preset.configuration,
                    conversationID: conversationID
                  )
                }
              } label: {
                Label(preset.name, systemImage: "wrench.adjustable")
              }
            }
          }
          .listRowBackground(theme.surfaceColor)
        }

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
      }
      .scrollContentBackground(.hidden)
      .foregroundStyle(theme.primaryForegroundColor)
      .background(AppThemeBackground(theme: theme))
      .navigationTitle("Tools")
      .disabled(mcp.isBusy)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .alert(
      "MCP Error",
      isPresented: Binding(
        get: { mcp.shouldPresentError(in: errorPresenterID) },
        set: { if !$0, mcp.shouldPresentError(in: errorPresenterID) { mcp.errorMessage = nil } }
      )
    ) {
      Button("OK") { mcp.errorMessage = nil }
    } message: {
      Text(mcp.errorMessage ?? "Unknown error")
    }
    .onAppear { mcp.registerErrorPresenter(errorPresenterID) }
    .onDisappear { mcp.unregisterErrorPresenter(errorPresenterID) }
  }

  @ViewBuilder
  private func serverSection(_ server: MCPRemoteServer) -> some View {
    let enabledForChat = mcp.isServerEnabled(server.id, for: conversationID)
    let bindings = mcp.tools(for: server.id)

    Section {
      Toggle(
        isOn: Binding(
          get: { mcp.isServerEnabled(server.id, for: conversationID) },
          set: { value in
            Task { @MainActor in
              await mcp.setChatServerEnabled(
                value,
                serverID: server.id,
                conversationID: conversationID
              )
            }
          }
        )
      ) {
        VStack(alignment: .leading, spacing: 3) {
          Text("Enable for This Chat")
          if !server.isEnabled {
            Text("This server is disabled globally in Settings.")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }
      }
      .disabled(!server.isEnabled || mcp.isBusy)

      if server.isEnabled && enabledForChat {
        if bindings.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            Text("No tools are currently cached for this server.")
              .font(.footnote)
              .foregroundStyle(theme.secondaryForegroundColor)
            Button("Refresh Tools", systemImage: "arrow.clockwise") {
              Task { @MainActor in await mcp.refresh(server.id) }
            }
          }
        } else {
          ForEach(bindings) { binding in
            toolRow(binding)
          }
        }
      }
    } header: {
      HStack {
        Text(server.name)
        Spacer()
        if let snapshot = mcp.snapshot(for: server.id) {
          Text("\(snapshot.tools.count) tools")
        }
      }
    } footer: {
      if let snapshot = mcp.snapshot(for: server.id) {
        Text("MCP \(snapshot.protocolVersion)")
      }
    }
  }

  private func toolRow(_ binding: MCPToolBinding) -> some View {
    let tool = binding.remoteTool
    return VStack(alignment: .leading, spacing: 7) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        VStack(alignment: .leading, spacing: 3) {
          Text(tool.title ?? tool.remoteName)
            .font(.body.weight(.medium))
          Text(tool.description)
            .font(.caption)
            .foregroundStyle(theme.secondaryForegroundColor)
            .lineLimit(3)
        }

        Spacer(minLength: 8)

        Picker(
          "Permission",
          selection: Binding(
            get: { mcp.toolPolicy(binding.exposedName, for: conversationID) },
            set: { policy in
              Task { @MainActor in
                await mcp.setChatToolPolicy(
                  policy,
                  exposedToolName: binding.exposedName,
                  conversationID: conversationID
                )
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

      HStack(spacing: 8) {
        if annotationBool("readOnlyHint", tool: tool) == true {
          Label("Read-only", systemImage: "eye")
        }
        if annotationBool("destructiveHint", tool: tool) == true {
          Label("Destructive", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
        }
      }
      .font(.caption2)
      .foregroundStyle(theme.secondaryForegroundColor.opacity(0.72))
    }
    .padding(.vertical, 3)
  }

  private func annotationBool(_ key: String, tool: MCPRemoteTool) -> Bool? {
    guard case .object(let annotations)? = tool.annotations,
      case .bool(let value)? = annotations[key]
    else { return nil }
    return value
  }
}
