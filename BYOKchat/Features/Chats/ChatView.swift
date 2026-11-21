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

enum ChatViewSupport {
  static func markdownFilename(for title: String?) -> String {
    let raw = title ?? "BYOKchat-conversation"
    var result = ""
    var previousWasDash = false
    for character in raw {
      if character.isLetter || character.isNumber || character == "_" {
        result.append(character)
        previousWasDash = false
      } else if !previousWasDash {
        result.append("-")
        previousWasDash = true
      }
    }
    let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return trimmed.isEmpty ? "BYOKchat-conversation" : trimmed
  }

  static func canSaveRename(draft: String, currentTitle: String?) -> Bool {
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    if let current = currentTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
      trimmed == current
    {
      return false
    }
    return true
  }

  static func canSaveEditedMessage(draft: String, original: String) -> Bool {
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    return trimmed != original.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

struct ChatAttachmentImagePreview: Identifiable {
  let id = UUID()
  let entry: LibraryEntry
  let image: UIImage
  let shareFileURL: URL?
  let tempDirectory: URL?
}

struct ChatAttachmentQuickLookPreview: Identifiable {
  let id = UUID()
  let item: LibraryQuickLookItem
}

struct ChatScrollToBottomRequest: Equatable {
  var id = 0
  var animated = false
}

/// Full-frame loading placeholder that waits briefly before showing a spinner
/// so fast local shard reads (<150ms) never flash a spinner, while slow cold
/// opens still present clear centered feedback.
private struct DelayedChatLoadingView: View {
  @Environment(\.appFoundationTheme) private var theme
  @State private var showSpinner = false

  var body: some View {
    ZStack {
      theme.backgroundColor.ignoresSafeArea()
      if showSpinner {
        ProgressView("Loading chat…")
          .foregroundStyle(theme.secondaryForegroundColor)
          .transition(.opacity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task {
      do {
        try await Task.sleep(for: .milliseconds(150))
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      withAnimation(.easeOut(duration: 0.15)) {
        showSpinner = true
      }
    }
  }
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
  /// Called after deleting a root-level conversation, passing the project it
  /// belonged to before deletion so the coordinator can return to that project
  /// or start a replacement chat in the same scope.
  var onDeleted: (ProjectID?) -> Void = { _ in }
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
  @Environment(\.displayScale) var displayScale
  @State var draft = ""
  @State var restoredDraftConversationID: ConversationID?
  @State var activeAttachmentImportCount = 0
  @State var attachmentImportGeneration = 0
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
  @State var showDeleteConfirmation = false
  @State var isDeleting = false
  @State var scrollCoordinator = ChatScrollCoordinator()
  @State var showJumpToLatest = false
  @State var hasCompletedInitialScroll = false
  @State var scrollToBottomRequest = ChatScrollToBottomRequest()
  @State var visibleMessageLimit = ChatMessageWindowPolicy.initialVisibleCount
  @State var isLoadingEarlierMessages = false
  @State var pendingEarlierAnchorID: ChatMessageID?
  @State var markdownDocument: MarkdownExportDocument?
  @State var showMarkdownExporter = false
  @State var pendingAttachments: [ChatAttachment] = []
  @State var showPhotoPicker = false
  @State var photoPickerItems: [PhotosPickerItem] = []
  @State var showFileImporter = false
  @State var showLibraryPicker = false
  @State var libraryErrorMessage: String?
  @State var attachmentImagePreview: ChatAttachmentImagePreview?
  @State var attachmentImagePreviewTempDirectory: URL?
  @State var attachmentQuickLookPreview: ChatAttachmentQuickLookPreview?
  @State var isLoadingAttachmentPreview = false
  @State var attachmentPreviewGeneration = 0

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
    openProject: @escaping () -> Void = {},
    onDeleted: @escaping (ProjectID?) -> Void = { _ in }
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
    self.onDeleted = onDeleted
  }

  var isFresh: Bool {
    if case .fresh = subject { return true }
    return false
  }

  var isImportingAttachments: Bool {
    activeAttachmentImportCount > 0
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
    ChatViewSupport.markdownFilename(for: conversation?.title)
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
      maxSelectionCount: max(
        1,
        ChatComposerLayoutPolicy.maxAttachmentCount - pendingAttachments.count
      ),
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
    .sheet(item: $attachmentImagePreview, onDismiss: {
      cleanupAttachmentImagePreviewTempDirectory()
    }) { preview in
      LibraryImageViewerView(
        entry: preview.entry,
        image: preview.image,
        shareFileURL: preview.shareFileURL,
        onSaveToPhotos: {
          try await LibraryPhotoWriter.save(preview.image)
        }
      )
    }
    .sheet(item: $attachmentQuickLookPreview) { preview in
      LibraryQuickLookView(files: [preview.item]) {
        attachmentQuickLookPreview = nil
      }
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
    libraryErrorMessage = error.localizedDescription
  }

  func openAttachment(_ attachment: ChatAttachment) {
    guard !isLoadingAttachmentPreview else { return }
    let generation = attachmentPreviewGeneration
    isLoadingAttachmentPreview = true
    Task { @MainActor in
      defer {
        if attachmentPreviewGeneration == generation {
          isLoadingAttachmentPreview = false
        }
      }
      let data: Data?
      if !attachment.data.isEmpty {
        data = attachment.data
      } else {
        data = await chats.attachmentData(attachment.id)
      }
      guard attachmentPreviewGeneration == generation else { return }
      guard let data, !data.isEmpty else {
        chats.errorMessage = "The attachment '\(attachment.filename)' is unavailable."
        return
      }

      if attachment.isImage {
        let filename = attachment.filename
        let prepared = await Task.detached(priority: .userInitiated) {
          () -> (image: UIImage?, materialized: LibraryTempFileSupport.MaterializedFile?) in
          guard let image = UIImage(data: data) else { return (nil, nil) }
          let materialized = try? LibraryTempFileSupport.materializeTempFile(
            directoryPrefix: "byok-chat-preview",
            filename: filename,
            data: data
          )
          return (image, materialized)
        }.value
        guard attachmentPreviewGeneration == generation else {
          if let directory = prepared.materialized?.directory {
            LibraryTempFileSupport.cleanupDirectory(directory)
          }
          return
        }
        if let image = prepared.image {
          cleanupAttachmentImagePreviewTempDirectory()
          attachmentImagePreviewTempDirectory = prepared.materialized?.directory
          let entry = LibraryEntry(
            id: LibraryEntryID(rawValue: attachment.id),
            filename: attachment.filename,
            kind: attachment.kind,
            mimeType: attachment.mimeType,
            byteCount: data.count,
            source: .manual
          )
          attachmentImagePreview = ChatAttachmentImagePreview(
            entry: entry,
            image: image,
            shareFileURL: prepared.materialized?.fileURL,
            tempDirectory: prepared.materialized?.directory
          )
          return
        }
      }

      attachmentQuickLookPreview = ChatAttachmentQuickLookPreview(
        item: LibraryQuickLookItem(
          id: attachment.id,
          filename: attachment.filename,
          data: data
        )
      )
    }
  }

  private func cleanupAttachmentImagePreviewTempDirectory() {
    if let directory = attachmentImagePreviewTempDirectory {
      attachmentImagePreviewTempDirectory = nil
      LibraryTempFileSupport.cleanupDirectory(directory)
    }
  }

  /// The persisted-conversation surface. Everything here assumes the store
  /// knows this conversation.
  private var existingContent: some View {
    Group {
      if let conversation {
        chatContent(conversation)
      } else if chats.hasConversation(conversationID) && chats.failedToLoad(conversationID) {
        ContentUnavailableView {
          Label("Could Not Load Chat", systemImage: "exclamationmark.bubble")
        } description: {
          Text("This conversation could not be loaded from storage.")
        } actions: {
          Button("Try Again") {
            Task { @MainActor in
              await chats.loadConversation(conversationID, displayScale: displayScale)
            }
          }
          .buttonStyle(.borderedProminent)
          .tint(theme.accentColor)
        }
      } else if chats.hasConversation(conversationID) {
        DelayedChatLoadingView()
      } else {
        ContentUnavailableView("Conversation Missing", systemImage: "exclamationmark.bubble")
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
          .disabled(conversation == nil)
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
              renameText = conversation?.title ?? chats.summary(conversationID)?.title ?? ""
              showRename = true
            }
            Button("Export Markdown", systemImage: "square.and.arrow.up") {
              prepareMarkdownExport()
            }
            .disabled(conversation == nil)
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
              showDeleteConfirmation = true
            }
            .disabled(isDeleting)
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
        .presentationDragIndicator(.visible)
      } else {
        NavigationStack {
          ContentUnavailableView("Chat Unavailable", systemImage: "exclamationmark.bubble")
            .toolbar {
              ToolbarItem(placement: .confirmationAction) {
                Button("Done") { showTargetSettings = false }
              }
            }
        }
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
      } else {
        NavigationStack {
          ContentUnavailableView("Project Unavailable", systemImage: "folder")
            .toolbar {
              ToolbarItem(placement: .confirmationAction) {
                Button("Done") { showProjectEditorSheet = false }
              }
            }
        }
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
          guard let currentConversation = conversation,
            configurationIssue(currentConversation) == nil,
            chats.canSend(conversationID)
          else {
            chats.errorMessage = "Fix the chat configuration before editing and resending."
            return
          }
          scrollCoordinator.followsLatest = true
          showJumpToLatest = false
          chats.editAndResend(
            conversationID: conversationID,
            messageID: message.id,
            text: editText
          )
          editTarget = nil
          scrollToBottom(animated: !scrollCoordinator.isNearBottom)
        },
        cancel: { editTarget = nil }
      )
    }
    .alert("Rename Chat", isPresented: $showRename) {
      TextField("Title", text: $renameText)
      Button("Cancel", role: .cancel) {}
      Button("Save") {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { @MainActor in
          await chats.renameConversation(conversationID, title: trimmed)
        }
      }
      .disabled(
        !ChatViewSupport.canSaveRename(
          draft: renameText,
          currentTitle: conversation?.title ?? chats.summary(conversationID)?.title
        )
      )
    }
    .alert("Delete Chat?", isPresented: $showDeleteConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Delete", role: .destructive) {
        deleteCurrentConversation()
      }
    } message: {
      Text("This permanently deletes this conversation and its messages.")
    }
    .alert("Regenerate response?", isPresented: $showRegenerateConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Regenerate Anyway", role: .destructive) {
        scrollCoordinator.followsLatest = true
        showJumpToLatest = false
        chats.regenerate(
          conversationID: conversationID,
          confirmingUncertainCompletion: true
        )
        scrollToBottom(animated: !scrollCoordinator.isNearBottom)
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
      let isSwitchingConversation = restoredDraftConversationID != nil
        && restoredDraftConversationID != conversationID
      if isSwitchingConversation {
        draft = ""
      }
      restoredDraftConversationID = nil
      attachmentImportGeneration &+= 1
      activeAttachmentImportCount = 0
      pendingAttachments = []
      photoPickerItems = []
      attachmentPreviewGeneration &+= 1
      isLoadingAttachmentPreview = false
      attachmentImagePreview = nil
      attachmentQuickLookPreview = nil
      cleanupAttachmentImagePreviewTempDirectory()

      await chats.loadConversation(conversationID, displayScale: displayScale)
      guard !Task.isCancelled else { return }

      let savedDraft = chats.draft(for: conversationID)
      restoredDraftConversationID = conversationID
      if draft.isEmpty {
        if !savedDraft.isEmpty {
          draft = savedDraft
        }
      } else {
        chats.saveDraft(draft, conversationID: conversationID)
      }
    }
    .onChange(of: draft) { _, value in
      guard restoredDraftConversationID == conversationID else { return }
      chats.saveDraft(value, conversationID: conversationID)
    }
  }

  private func deleteCurrentConversation() {
    guard !isDeleting else { return }
    isDeleting = true
    let sourceProjectID = project?.id
    let targetConversationID = conversationID
    Task { @MainActor in
      defer { isDeleting = false }
      await chats.deleteConversation(targetConversationID)
      await projects.reloadFromStorage()
      await mcp.reloadFromStorage()
      guard !chats.hasConversation(targetConversationID) else { return }
      if pushedFromStack {
        // Popping lands on the screen beneath; starting a "next" chat
        // here would push and immediately pop it.
        dismiss()
      } else {
        onDeleted(sourceProjectID)
      }
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
      dismissKeyboard()
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

        ToolbarItemGroup(placement: .topBarTrailing) {
          Button("Project Settings", systemImage: "folder.badge.gearshape") {
            showProjectEditorSheet = true
          }
          .labelStyle(.iconOnly)
          .accessibilityLabel("Project settings")
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
      } else {
        NavigationStack {
          ContentUnavailableView("Project Unavailable", systemImage: "folder")
            .toolbar {
              ToolbarItem(placement: .confirmationAction) {
                Button("Done") { showProjectEditorSheet = false }
              }
            }
        }
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

  func openPhotoPicker() {
    guard pendingAttachments.count < ChatComposerLayoutPolicy.maxAttachmentCount else {
      chats.errorMessage = "A message can include at most \(ChatComposerLayoutPolicy.maxAttachmentCount) attachments."
      return
    }
    showPhotoPicker = true
  }

  func openFileImporter() {
    guard pendingAttachments.count < ChatComposerLayoutPolicy.maxAttachmentCount else {
      chats.errorMessage = "A message can include at most \(ChatComposerLayoutPolicy.maxAttachmentCount) attachments."
      return
    }
    showFileImporter = true
  }

  func openLibraryPicker() {
    guard pendingAttachments.count < ChatComposerLayoutPolicy.maxAttachmentCount else {
      chats.errorMessage = "A message can include at most \(ChatComposerLayoutPolicy.maxAttachmentCount) attachments."
      return
    }
    showLibraryPicker = true
  }

  private func importPhotos(_ items: [PhotosPickerItem]) {
    guard !items.isEmpty else { return }
    photoPickerItems = []

    let generation = attachmentImportGeneration
    Task { @MainActor in
      activeAttachmentImportCount += 1
      defer {
        if attachmentImportGeneration == generation {
          activeAttachmentImportCount = max(0, activeAttachmentImportCount - 1)
        }
      }

      let stamp = LibraryImportSupport.importStamp()
      var batchIndex = 0
      var imported: [ChatAttachment] = []
      var failures: [String] = []

      for item in items {
        guard attachmentImportGeneration == generation else { return }
        do {
          guard let rawData = try await item.loadTransferable(type: Data.self), !rawData.isEmpty else {
            failures.append("One of the selected photos could not be read.")
            continue
          }
          let prepared = await Task.detached(priority: .userInitiated) {
            LibraryImportSupport.preparedPhotoPayload(from: rawData)
          }.value
          guard attachmentImportGeneration == generation else { return }
          guard let prepared else {
            failures.append("One of the selected photos could not be decoded.")
            continue
          }
          guard prepared.data.count <= ChatComposerLayoutPolicy.maxAttachmentByteCount else {
            failures.append("One of the selected photos is larger than 20 MB.")
            continue
          }
          batchIndex += 1
          let filename = LibraryImportSupport.importFilename(
            stamp: stamp,
            index: batchIndex,
            fileExtension: prepared.fileExtension
          )
          imported.append(
            ChatAttachment(
              kind: .image,
              filename: filename,
              mimeType: prepared.mimeType,
              data: prepared.data
            )
          )
        } catch {
          failures.append(error.localizedDescription)
        }
      }

      guard attachmentImportGeneration == generation else { return }
      if let validationError = appendAttachmentsReturningError(imported) {
        failures.append(validationError)
      }
      if !failures.isEmpty {
        BYOKAppAnalytics.reportError("attachment_import_failed", component: "attachments")
        chats.errorMessage = LibraryImportSupport.formattedBatchErrors(failures)
      }
    }
  }

  private func importFiles(_ result: Result<[URL], Error>) {
    switch result {
    case .failure(let error):
      BYOKAppAnalytics.reportError("attachment_import_failed", component: "attachments")
      chats.errorMessage = error.localizedDescription
    case .success(let urls):
      guard !urls.isEmpty else { return }
      if pendingAttachments.count + urls.count > ChatComposerLayoutPolicy.maxAttachmentCount {
        BYOKAppAnalytics.reportError("attachment_import_failed", component: "attachments")
        chats.errorMessage =
          "A message can include at most \(ChatComposerLayoutPolicy.maxAttachmentCount) attachments."
        return
      }

      let generation = attachmentImportGeneration
      Task { @MainActor in
        activeAttachmentImportCount += 1
        defer {
          if attachmentImportGeneration == generation {
            activeAttachmentImportCount = max(0, activeAttachmentImportCount - 1)
          }
        }

        var imported: [ChatAttachment] = []
        var failures: [String] = []

        for url in urls {
          guard attachmentImportGeneration == generation else { return }
          do {
            let prepared = try await Task.detached(priority: .userInitiated) {
              try LibraryImportSupport.readImportedFile(
                at: url,
                folderErrorMessage: "Folders cannot be attached.",
                rejectEmptyFiles: true
              )
            }.value
            guard attachmentImportGeneration == generation else { return }
            imported.append(
              ChatAttachment(
                kind: prepared.isImage ? .image : .file,
                filename: prepared.filename,
                mimeType: prepared.mimeType,
                data: prepared.data
              )
            )
          } catch {
            failures.append(error.localizedDescription)
          }
        }

        guard attachmentImportGeneration == generation else { return }
        if let validationError = appendAttachmentsReturningError(imported) {
          failures.append(validationError)
        }
        if !failures.isEmpty {
          BYOKAppAnalytics.reportError("attachment_import_failed", component: "attachments")
          chats.errorMessage = LibraryImportSupport.formattedBatchErrors(failures)
        }
      }
    }
  }

  func appendAttachments(_ additions: [ChatAttachment]) {
    if let error = appendAttachmentsReturningError(additions) {
      chats.errorMessage = error
    }
  }

  private func appendAttachmentsReturningError(_ additions: [ChatAttachment]) -> String? {
    guard !additions.isEmpty else { return nil }
    if let error = ChatComposerLayoutPolicy.attachmentValidationError(
      existing: pendingAttachments,
      additions: additions
    ) {
      return error
    }
    pendingAttachments.append(contentsOf: additions)
    return nil
  }

  /// Attaches a project reference file to the composer. Rows are
  /// metadata-only, so the original bytes are fetched on demand; a missing
  /// blob surfaces an error instead of a silent empty attachment.
  func attachProjectFile(_ file: ProjectFile) async {
    guard !pendingAttachments.contains(where: { $0.id == file.id }) else { return }
    guard pendingAttachments.count < ChatComposerLayoutPolicy.maxAttachmentCount else {
      chats.errorMessage =
        "A message can include at most \(ChatComposerLayoutPolicy.maxAttachmentCount) attachments."
      return
    }
    let generation = attachmentImportGeneration
    activeAttachmentImportCount += 1
    defer {
      if attachmentImportGeneration == generation {
        activeAttachmentImportCount = max(0, activeAttachmentImportCount - 1)
      }
    }
    guard let data = await projects.fileData(file.id), !data.isEmpty else {
      guard attachmentImportGeneration == generation else { return }
      BYOKAppAnalytics.reportError("attachment_import_failed", component: "attachments")
      chats.errorMessage = "The file '\(file.filename)' could not be loaded."
      return
    }
    guard attachmentImportGeneration == generation else { return }
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
          let activeConfig = normalizedToolConfiguration(mcp.chatConfiguration(for: conversationID))
          Section("Project Tool Presets") {
            ForEach(project.projectToolPresets) { preset in
              let isApplied = normalizedToolConfiguration(preset.configuration) == activeConfig
              Button {
                Task { @MainActor in
                  await mcp.applyChatConfiguration(
                    preset.configuration,
                    conversationID: conversationID
                  )
                }
              } label: {
                HStack {
                  Label(preset.name, systemImage: "wrench.adjustable")
                  Spacer()
                  if isApplied {
                    Image(systemName: "checkmark")
                      .font(.footnote.weight(.semibold))
                      .foregroundStyle(.tint)
                  }
                }
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
            Text("This server is disabled globally in MCP Servers.")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }
      }
      .disabled((!server.isEnabled && !enabledForChat) || mcp.isBusy)

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
          Text(mcpToolCountLabel(snapshot.tools.count))
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
    let isReadOnly = annotationBool("readOnlyHint", tool: tool) == true
    let isDestructive = annotationBool("destructiveHint", tool: tool) == true
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

      if isReadOnly || isDestructive {
        HStack(spacing: 8) {
          if isReadOnly {
            Label("Read-only", systemImage: "eye")
          }
          if isDestructive {
            Label("Destructive", systemImage: "exclamationmark.triangle")
              .foregroundStyle(.orange)
          }
        }
        .font(.caption2)
        .foregroundStyle(theme.secondaryForegroundColor.opacity(0.72))
      }
    }
    .padding(.vertical, 3)
  }

  private func normalizedToolConfiguration(
    _ configuration: MCPChatToolConfiguration
  ) -> MCPChatToolConfiguration {
    MCPChatToolConfiguration(
      enabledServerIDs: Array(Set(configuration.enabledServerIDs)).sorted { $0.rawValue < $1.rawValue },
      toolPolicies: configuration.toolPolicies.filter { $0.value != .ask }
    )
  }

  private func annotationBool(_ key: String, tool: MCPRemoteTool) -> Bool? {
    guard case .object(let annotations)? = tool.annotations,
      case .bool(let value)? = annotations[key]
    else { return nil }
    return value
  }
}
