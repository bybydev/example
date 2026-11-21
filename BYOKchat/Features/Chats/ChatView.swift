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
  @State var showChatSettings = false
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
            showChatSettings = true
          }
          .disabled(conversation == nil)
          Button("Tools", systemImage: "wrench.and.screwdriver") {
            showToolSettings = true
          }
          .disabled(conversation == nil)
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
    .sheet(isPresented: $showChatSettings) {
      if let conversation {
        ChatSettingsView(
          conversation: conversation,
          chats: chats,
          providers: providers,
          projects: projects
        )
        .presentationDragIndicator(.visible)
      } else {
        NavigationStack {
          ContentUnavailableView("Chat Unavailable", systemImage: "slider.horizontal.3")
            .toolbar {
              ToolbarItem(placement: .confirmationAction) {
                Button("Done") { showChatSettings = false }
              }
            }
        }
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
      if conversation != nil {
        ConversationToolsView(
          conversationID: conversationID,
          chats: chats,
          providers: providers,
          projects: projects,
          mcp: mcp
        )
        .presentationDragIndicator(.visible)
      } else {
        NavigationStack {
          ContentUnavailableView("Chat Unavailable", systemImage: "wrench.and.screwdriver")
            .toolbar {
              ToolbarItem(placement: .confirmationAction) {
                Button("Done") { showToolSettings = false }
              }
            }
        }
      }
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
      if let targetConversation = conversation ?? chats.conversations.first(where: { $0.id == conversationID }) {
        ConversationAnalyticsView(conversation: targetConversation)
      } else {
        NavigationStack {
          ContentUnavailableView("Chat Unavailable", systemImage: "chart.bar.xaxis")
            .toolbar {
              ToolbarItem(placement: .confirmationAction) {
                Button("Done") { showUsage = false }
              }
            }
        }
      }
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
  @Bindable var chats: ChatManagementModel
  @Bindable var providers: ProviderManagementModel
  @Bindable var projects: ProjectManagementModel
  @Bindable var mcp: MCPManagementModel
  @State private var errorPresenterID = UUID()
  @State private var showAddServer = false
  @State private var showProUpsell = false
  @State private var toastCenter = BYOKToastCenter()

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appFoundationTheme) private var theme
  @Environment(PurchaseManager.self) private var purchaseManager

  private var project: ChatProject? {
    projects.project(for: conversationID)
  }

  private var conversation: ChatConversation? {
    chats.conversation(conversationID)
  }

  private var isGenerating: Bool {
    chats.isGenerating(conversationID)
  }

  private var isMutationDisabled: Bool {
    mcp.isBusy || isGenerating
  }

  private var modelDoesNotSupportTools: Bool {
    guard let conversation,
      !conversation.modelID.rawValue.isEmpty,
      let account = providers.accounts.first(where: { $0.id == conversation.accountID })
    else { return false }
    let record = providers.models(for: conversation.accountID, includeHidden: true)
      .first { $0.model.id == conversation.modelID }
    let capabilities = ModelCapabilityResolver.resolve(
      kind: account.kind,
      modelID: conversation.modelID,
      model: record?.model
    )
    return capabilities[.tools] == .unsupported
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

          if isGenerating {
            Label(
              "Wait for the current response to finish before changing tools.",
              systemImage: "hourglass"
            )
            .font(.footnote)
            .foregroundStyle(.orange)
          }

          if modelDoesNotSupportTools {
            Label(
              "The current model does not support tools. Enabled tools will not be sent until you switch models.",
              systemImage: "exclamationmark.triangle"
            )
            .font(.footnote)
            .foregroundStyle(.orange)
          }

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
            .disabled(isMutationDisabled)
          }
        }
        .listRowBackground(theme.surfaceColor)

        if let project, !project.projectToolPresets.isEmpty {
          let activeConfig = normalizedToolConfiguration(mcp.chatConfiguration(for: conversationID))
          Section {
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
                    .foregroundStyle(theme.primaryForegroundColor)
                  Spacer()
                  if isApplied {
                    Image(systemName: "checkmark")
                      .font(.footnote.weight(.semibold))
                      .foregroundStyle(theme.accentColor)
                  }
                }
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .disabled(isMutationDisabled)
            }
          } header: {
            Text("Project Tool Presets")
              .foregroundStyle(theme.secondaryForegroundColor)
          }
          .listRowBackground(theme.surfaceColor)
        }

        if mcp.servers.isEmpty {
          Section {
            ContentUnavailableView {
              Label("No MCP Servers", systemImage: "server.rack")
            } description: {
              Text("Add a remote MCP server to discover and enable tools for this chat.")
            } actions: {
              Button("Add MCP Server") {
                requestAddServer()
              }
              .buttonStyle(.borderedProminent)
              .tint(theme.accentColor)
              .disabled(mcp.isBusy)
            }
          }
          .listRowBackground(theme.surfaceColor)
        } else {
          ForEach(mcp.servers) { server in
            serverSection(server)
          }
        }
      }
      .listStyle(.insetGrouped)
      .scrollContentBackground(.hidden)
      .refreshable {
        await refreshEnabledServers()
      }
      .foregroundStyle(theme.primaryForegroundColor)
      .background(AppThemeBackground(theme: theme))
      .navigationTitle("Tools")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        if mcp.isBusy {
          ToolbarItem(placement: .topBarLeading) {
            ProgressView()
              .controlSize(.small)
              .accessibilityLabel("Updating MCP tools")
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .byokToastOverlay(toastCenter)
    .sheet(isPresented: $showAddServer) {
      NavigationStack {
        MCPServerEditorView(model: mcp, server: nil)
      }
      .presentationDragIndicator(.visible)
    }
    .sheet(isPresented: $showProUpsell) {
      BYOKProUpsellFlow(feature: .mcpServers)
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
    .onChange(of: mcp.statusMessage) { _, message in
      guard let message else { return }
      mcp.statusMessage = nil
      guard mcp.errorMessage == nil else { return }
      toastCenter.success(message)
    }
    .onAppear {
      mcp.statusMessage = nil
      mcp.registerErrorPresenter(errorPresenterID)
    }
    .onDisappear {
      toastCenter.dismiss()
      mcp.unregisterErrorPresenter(errorPresenterID)
    }
  }

  private func requestAddServer() {
    if BYOKProAccess.canCreateMCPServer(
      currentCount: mcp.servers.count,
      hasPro: purchaseManager.hasPro
    ) {
      showAddServer = true
    } else {
      showProUpsell = true
    }
  }

  private func refreshEnabledServers() async {
    let targets = mcp.servers.filter {
      $0.isEnabled && mcp.isServerEnabled($0.id, for: conversationID)
    }
    for server in targets {
      guard !Task.isCancelled else { return }
      await mcp.refresh(server.id)
    }
  }

  @ViewBuilder
  private func serverSection(_ server: MCPRemoteServer) -> some View {
    let enabledForChat = mcp.isServerEnabled(server.id, for: conversationID)
    let missingCredential = server.authentication.kind != .none && !mcp.hasCredential(server.id)
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
          } else if missingCredential {
            Text("Missing credential. Add it in MCP Servers before enabling.")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }
      }
      .disabled(((!server.isEnabled || missingCredential) && !enabledForChat) || isMutationDisabled)

      if server.isEnabled && enabledForChat {
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
            toolRow(binding)
          }
        }
      }
    } header: {
      HStack(spacing: 8) {
        Text(server.name)
          .foregroundStyle(theme.secondaryForegroundColor)
        Spacer()
        if let snapshot = mcp.snapshot(for: server.id) {
          Text(mcpToolCountLabel(snapshot.tools.count))
            .foregroundStyle(theme.secondaryForegroundColor)
        }
        if server.isEnabled && !missingCredential {
          Button {
            Task { @MainActor in await mcp.refresh(server.id) }
          } label: {
            Image(systemName: "arrow.clockwise")
              .font(.caption.weight(.semibold))
              .foregroundStyle(theme.accentColor)
          }
          .buttonStyle(.plain)
          .disabled(mcp.isBusy)
          .accessibilityLabel("Refresh tools for \(server.name)")
        }
      }
    } footer: {
      if let snapshot = mcp.snapshot(for: server.id) {
        Text("MCP \(snapshot.protocolVersion)")
          .foregroundStyle(theme.secondaryForegroundColor)
      }
    }
    .listRowBackground(theme.surfaceColor)
  }

  private func toolRow(_ binding: MCPToolBinding) -> some View {
    let tool = binding.remoteTool
    let description = tool.description.trimmingCharacters(in: .whitespacesAndNewlines)
    let isReadOnly = annotationBool("readOnlyHint", tool: tool) == true
    let isDestructive = annotationBool("destructiveHint", tool: tool) == true
    return VStack(alignment: .leading, spacing: 7) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        VStack(alignment: .leading, spacing: 3) {
          Text(tool.title ?? tool.remoteName)
            .font(.body.weight(.medium))
          if !description.isEmpty {
            Text(description)
              .font(.caption)
              .foregroundStyle(theme.secondaryForegroundColor)
              .lineLimit(3)
          }
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
        .disabled(isMutationDisabled)
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

nonisolated enum ChatSettingsSupport {
  static func temperatureRange(for kind: ProviderKind?) -> ClosedRange<Double> {
    kind == .minimax ? 0.01...1.0 : 0.0...2.0
  }

  static func clampedTemperature(_ value: Double, for kind: ProviderKind?) -> Double {
    let range = temperatureRange(for: kind)
    let clamped = min(max(value, range.lowerBound), range.upperBound)
    return (clamped * 100).rounded() / 100
  }

  static func clampedTopP(_ value: Double) -> Double {
    let clamped = min(max(value, 0.05), 1.0)
    return (clamped * 100).rounded() / 100
  }

  static func supportsSamplingControls(
    kind: ProviderKind?,
    modelID: ModelID?,
    reasoning: ReasoningOptions?,
    reasoningControl: ModelReasoningControl
  ) -> Bool {
    guard let kind else { return true }
    switch kind {
    case .anthropic:
      return false
    case .openai:
      if reasoningControl.kind != .unsupported && reasoningControl.kind != .unknown {
        return reasoningControl.allowsOff && reasoning?.enabled == false
      }
      return true
    case .gemini:
      let id = (modelID?.rawValue ?? "").lowercased()
      return !id.hasPrefix("gemini-4")
        && !id.hasPrefix("gemini-3.8")
        && !id.hasPrefix("gemini-3.7")
        && !id.hasPrefix("gemini-3.6")
        && !id.hasPrefix("gemini-3.5-flash-lite")
    case .deepSeek:
      return reasoning?.enabled == false
    case .moonshot:
      let id = (modelID?.rawValue ?? "").lowercased().replacingOccurrences(of: "_", with: "-")
      return !id.hasPrefix("kimi-k3")
        && !id.hasPrefix("kimi-k2.6")
        && !id.hasPrefix("kimi-k2.5")
    case .xAI, .openRouter, .zAI, .minimax, .mistral, .nvidia, .ollama, .lmStudio, .openAICompatible:
      return true
    }
  }

  static func parseMaxOutputTokens(
    _ raw: String,
    maxAllowed: Int?,
    anthropicReasoningBudget: Int?
  ) -> (value: Int?, error: String?) {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return (nil, nil) }
    guard let parsed = Int(trimmed), parsed > 0 else {
      return (nil, "Enter a positive whole number of tokens.")
    }
    if let maxAllowed, parsed > maxAllowed {
      return (nil, "This model supports at most \(maxAllowed.formatted()) output tokens.")
    }
    if let budget = anthropicReasoningBudget, parsed <= budget {
      return (
        nil,
        "Max output tokens must exceed the thinking budget (\((budget + 1).formatted()) or higher)."
      )
    }
    return (parsed, nil)
  }

  static func parseProviderOrder(_ raw: String) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for token in raw.split(whereSeparator: { $0 == "," || $0 == "\n" }) {
      let cleaned = token.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !cleaned.isEmpty, seen.insert(cleaned).inserted else { continue }
      result.append(cleaned)
    }
    return result
  }

  static func normalizedOpenRouterRouting(
    _ routing: OpenRouterRoutingOptions
  ) -> OpenRouterRoutingOptions? {
    let hasValue =
      !routing.providerOrder.isEmpty
      || routing.allowFallbacks != nil
      || routing.requireParameters != nil
      || routing.dataCollection != nil
      || routing.zeroDataRetention != nil
      || routing.sort != nil
    return hasValue ? routing : nil
  }
}

private struct ChatSettingsView: View {
  private enum FocusField: Hashable {
    case systemPrompt
    case maxOutputTokens
    case openRouterOrder
  }

  private enum FallbackChoice: String, CaseIterable, Identifiable {
    case `default`
    case allow
    case disable

    var id: String { rawValue }

    var label: String {
      switch self {
      case .default: "Default"
      case .allow: "Allow"
      case .disable: "Disable"
      }
    }

    var boolValue: Bool? {
      switch self {
      case .default: nil
      case .allow: true
      case .disable: false
      }
    }

    init(boolValue: Bool?) {
      switch boolValue {
      case true: self = .allow
      case false: self = .disable
      case nil: self = .default
      }
    }
  }

  let initialConversation: ChatConversation
  @Bindable var chats: ChatManagementModel
  @Bindable var providers: ProviderManagementModel
  @Bindable var projects: ProjectManagementModel

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appFoundationTheme) private var theme
  @Environment(AppModel.self) private var appModel

  @State private var systemPrompt: String
  @State private var useCustomTemperature: Bool
  @State private var temperature: Double
  @State private var useCustomTopP: Bool
  @State private var topP: Double
  @State private var maxOutputTokensText: String
  @State private var openRouterSort: OpenRouterSort?
  @State private var openRouterDataCollection: OpenRouterDataCollection?
  @State private var openRouterFallbacks: FallbackChoice
  @State private var openRouterRequireParameters: Bool
  @State private var openRouterZeroDataRetention: Bool
  @State private var openRouterProviderOrderText: String

  @State private var showTargetPicker = false
  @State private var isSaving = false
  @State private var saveError: String?
  @FocusState private var focusedField: FocusField?

  init(
    conversation: ChatConversation,
    chats: ChatManagementModel,
    providers: ProviderManagementModel,
    projects: ProjectManagementModel
  ) {
    self.initialConversation = conversation
    self.chats = chats
    self.providers = providers
    self.projects = projects

    let accountKind = providers.accounts.first { $0.id == conversation.accountID }?.kind
    let initialTemp = conversation.options.temperature
    let initialTopP = conversation.options.topP
    let routing = conversation.options.openRouterRouting

    _systemPrompt = State(initialValue: conversation.systemPrompt)
    _useCustomTemperature = State(initialValue: initialTemp != nil)
    _temperature = State(
      initialValue: ChatSettingsSupport.clampedTemperature(initialTemp ?? 0.7, for: accountKind)
    )
    _useCustomTopP = State(initialValue: initialTopP != nil)
    _topP = State(initialValue: ChatSettingsSupport.clampedTopP(initialTopP ?? 1.0))
    _maxOutputTokensText = State(
      initialValue: conversation.options.maxOutputTokens.map(String.init) ?? ""
    )
    _openRouterSort = State(initialValue: routing?.sort)
    _openRouterDataCollection = State(initialValue: routing?.dataCollection)
    _openRouterFallbacks = State(initialValue: FallbackChoice(boolValue: routing?.allowFallbacks))
    _openRouterRequireParameters = State(initialValue: routing?.requireParameters == true)
    _openRouterZeroDataRetention = State(initialValue: routing?.zeroDataRetention == true)
    _openRouterProviderOrderText = State(
      initialValue: routing?.providerOrder.joined(separator: ", ") ?? ""
    )
  }

  private var liveConversation: ChatConversation {
    chats.conversation(initialConversation.id) ?? initialConversation
  }

  private var project: ChatProject? {
    projects.project(for: initialConversation.id)
  }

  private var account: ProviderAccount? {
    providers.accounts.first { $0.id == liveConversation.accountID && $0.isEnabled }
  }

  private var hasModelID: Bool {
    !liveConversation.modelID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var modelRecord: AccountModelRecord? {
    guard hasModelID else { return nil }
    return providers.models(for: liveConversation.accountID, includeHidden: true)
      .first { $0.model.id == liveConversation.modelID }
  }

  private var capabilities: ResolvedModelCapabilities? {
    guard let account, hasModelID else { return nil }
    return ModelCapabilityResolver.resolve(
      kind: account.kind,
      modelID: liveConversation.modelID,
      model: modelRecord?.model
    )
  }

  private var reasoningControl: ModelReasoningControl {
    capabilities?.reasoning ?? .init()
  }

  private var supportsSamplingControls: Bool {
    ChatSettingsSupport.supportsSamplingControls(
      kind: account?.kind,
      modelID: liveConversation.modelID,
      reasoning: liveConversation.options.reasoning,
      reasoningControl: reasoningControl
    )
  }

  private var temperatureRange: ClosedRange<Double> {
    ChatSettingsSupport.temperatureRange(for: account?.kind)
  }

  private var anthropicReasoningBudget: Int? {
    guard account?.kind == .anthropic else { return nil }
    let normalized = reasoningControl.normalize(liveConversation.options.reasoning)
    guard normalized?.enabled != false else { return nil }
    return normalized?.maxTokens
  }

  private var maxOutputTokensValidation: (value: Int?, error: String?) {
    ChatSettingsSupport.parseMaxOutputTokens(
      maxOutputTokensText,
      maxAllowed: capabilities?.maxOutputTokens,
      anthropicReasoningBudget: anthropicReasoningBudget
    )
  }

  private var normalizedSystemPrompt: String {
    AppPreferencesModel.normalizedSystemPrompt(systemPrompt)
  }

  private var normalizedProjectInstructions: String {
    AppPreferencesModel.normalizedSystemPrompt(project?.instructions ?? "")
  }

  private var normalizedDefaultPrompt: String {
    AppPreferencesModel.normalizedSystemPrompt(appModel.preferences.defaultSystemPrompt)
  }

  private var hasCustomParameters: Bool {
    (supportsSamplingControls && (useCustomTemperature || useCustomTopP))
      || !maxOutputTokensText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var hasCustomOpenRouterRouting: Bool {
    buildOpenRouterRouting() != nil
  }

  private var isGenerating: Bool {
    chats.isGenerating(liveConversation.id)
  }

  private var canSave: Bool {
    !isSaving
      && !isGenerating
      && account != nil
      && hasModelID
      && maxOutputTokensValidation.error == nil
  }

  private var modelDisplayTitle: String {
    if let record = modelRecord {
      return record.model.displayName
    }
    if hasModelID {
      return liveConversation.modelID.rawValue
    }
    return "Select Model"
  }

  private var modelSubtitle: String {
    var parts: [String] = []
    if let account {
      parts.append(account.label)
    } else {
      parts.append("No connection")
    }
    let reasoningLabel = reasoningControl.label(for: liveConversation.options.reasoning)
    if !reasoningLabel.isEmpty {
      parts.append("Reasoning: \(reasoningLabel)")
    }
    return parts.joined(separator: " · ")
  }

  var body: some View {
    NavigationStack {
      List {
        modelSection
        systemPromptSection
        parametersSection
        if account?.kind == .openRouter {
          openRouterRoutingSection
        }
      }
      .listStyle(.insetGrouped)
      .scrollDismissesKeyboard(.interactively)
      .scrollContentBackground(.hidden)
      .foregroundStyle(theme.primaryForegroundColor)
      .background(AppThemeBackground(theme: theme))
      .navigationTitle("Chat Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .disabled(isSaving)
        }
        ToolbarItem(placement: .confirmationAction) {
          if isSaving {
            ProgressView()
              .controlSize(.small)
              .accessibilityLabel("Saving chat settings")
          } else {
            Button("Save") {
              Task { await save() }
            }
            .fontWeight(.semibold)
            .disabled(!canSave)
          }
        }
        if focusedField != nil {
          ToolbarItem(placement: .keyboard) {
            HStack {
              Spacer()
              Button("Done") { focusedField = nil }
                .fontWeight(.semibold)
            }
          }
        }
      }
      .sheet(isPresented: $showTargetPicker) {
        TargetPickerView(
          providers: providers,
          initialAccountID: liveConversation.accountID,
          initialModelID: liveConversation.modelID,
          initialReasoning: liveConversation.options.reasoning,
          mode: .existingChat(conversation: liveConversation, chats: chats)
        )
        .presentationDragIndicator(.visible)
      }
      .onChange(of: account?.kind) { _, newKind in
        temperature = ChatSettingsSupport.clampedTemperature(temperature, for: newKind)
      }
      .alert(
        "Chat Settings Error",
        isPresented: Binding(
          get: { saveError != nil },
          set: { if !$0 { saveError = nil } }
        )
      ) {
        Button("OK") { saveError = nil }
      } message: {
        Text(saveError ?? "Unable to save chat settings.")
      }
    }
    .interactiveDismissDisabled(isSaving)
  }

  private var modelSection: some View {
    Section {
      Button {
        focusedField = nil
        showTargetPicker = true
      } label: {
        HStack(spacing: 12) {
          VStack(alignment: .leading, spacing: 3) {
            Text(modelDisplayTitle)
              .font(.body.weight(.medium))
              .foregroundStyle(theme.primaryForegroundColor)
              .lineLimit(1)
            Text(modelSubtitle)
              .font(.caption)
              .foregroundStyle(theme.secondaryForegroundColor)
              .lineLimit(1)
          }
          Spacer(minLength: 8)
          Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(theme.secondaryForegroundColor.opacity(0.65))
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(isSaving)
    } header: {
      Text("Model & Reasoning")
        .foregroundStyle(theme.secondaryForegroundColor)
    } footer: {
      if account == nil || !hasModelID {
        Text("Choose an enabled connection and model before saving chat settings.")
          .foregroundStyle(.orange)
      } else if isGenerating {
        Text("Wait for the current response to finish before saving changes.")
          .foregroundStyle(theme.secondaryForegroundColor)
      }
    }
    .listRowBackground(theme.surfaceColor)
  }

  private var systemPromptSection: some View {
    Section {
      ZStack(alignment: .topLeading) {
        TextEditor(text: $systemPrompt)
          .font(.body)
          .scrollContentBackground(.hidden)
          .frame(minHeight: 130)
          .focused($focusedField, equals: .systemPrompt)
          .accessibilityLabel("Chat System Prompt")

        if systemPrompt.isEmpty {
          Text("Optional instructions for this conversation…")
            .font(.body)
            .foregroundStyle(theme.secondaryForegroundColor.opacity(0.65))
            .padding(.top, 8)
            .padding(.leading, 5)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
      }

      if !normalizedProjectInstructions.isEmpty,
        normalizedSystemPrompt != normalizedProjectInstructions
      {
        Button("Reset to Project Instructions") {
          focusedField = nil
          systemPrompt = normalizedProjectInstructions
        }
        .disabled(isSaving)
      } else if normalizedProjectInstructions.isEmpty,
        !normalizedDefaultPrompt.isEmpty,
        normalizedSystemPrompt != normalizedDefaultPrompt
      {
        Button("Reset to Default Prompt") {
          focusedField = nil
          systemPrompt = normalizedDefaultPrompt
        }
        .disabled(isSaving)
      }

      if !normalizedSystemPrompt.isEmpty {
        Button("Clear System Prompt", role: .destructive) {
          focusedField = nil
          systemPrompt = ""
        }
        .disabled(isSaving)
      }
    } header: {
      Text("System Prompt")
        .foregroundStyle(theme.secondaryForegroundColor)
    } footer: {
      if let project, !normalizedProjectInstructions.isEmpty {
        Text(
          "Applies only to this conversation. Instructions from \(project.name) were copied when this chat started."
        )
        .foregroundStyle(theme.secondaryForegroundColor)
      } else {
        Text("Applies only to this conversation and overrides your global default system prompt.")
          .foregroundStyle(theme.secondaryForegroundColor)
      }
    }
    .listRowBackground(theme.surfaceColor)
  }

  private var parametersSection: some View {
    Section {
      if supportsSamplingControls {
        VStack(alignment: .leading, spacing: 8) {
          Toggle(isOn: $useCustomTemperature) {
            HStack {
              Text("Temperature")
              Spacer()
              Text(useCustomTemperature ? String(format: "%.2f", temperature) : "Default")
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(theme.secondaryForegroundColor)
            }
          }
          .disabled(isSaving)

          if useCustomTemperature {
            Slider(value: $temperature, in: temperatureRange, step: 0.05)
              .tint(theme.accentColor)
              .disabled(isSaving)
              .accessibilityLabel("Temperature value")
          }
        }

        VStack(alignment: .leading, spacing: 8) {
          Toggle(isOn: $useCustomTopP) {
            HStack {
              Text("Top-P")
              Spacer()
              Text(useCustomTopP ? String(format: "%.2f", topP) : "Default")
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(theme.secondaryForegroundColor)
            }
          }
          .disabled(isSaving)

          if useCustomTopP {
            Slider(value: $topP, in: 0.05...1.0, step: 0.05)
              .tint(theme.accentColor)
              .disabled(isSaving)
              .accessibilityLabel("Top-P value")
          }
        }
      }

      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text("Max Output Tokens")
          Spacer(minLength: 12)
          TextField("Default", text: $maxOutputTokensText)
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .focused($focusedField, equals: .maxOutputTokens)
            .frame(maxWidth: 120)
            .disabled(isSaving)
        }

        if let error = maxOutputTokensValidation.error {
          Text(error)
            .font(.caption)
            .foregroundStyle(.red)
        }
      }

      if hasCustomParameters {
        Button("Reset Parameters") {
          focusedField = nil
          useCustomTemperature = false
          useCustomTopP = false
          maxOutputTokensText = ""
        }
        .disabled(isSaving)
      }
    } header: {
      Text("Parameters")
        .foregroundStyle(theme.secondaryForegroundColor)
    } footer: {
      Text(parametersFooter)
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }

  private var parametersFooter: String {
    var parts: [String] = []
    if let maximum = capabilities?.maxOutputTokens {
      parts.append(
        "Leave Max Output Tokens blank to use the model default (up to \(maximum.formatted()) tokens)."
      )
    } else {
      parts.append("Leave Max Output Tokens blank to use the provider default.")
    }
    if !supportsSamplingControls {
      parts.append("Temperature and Top-P are managed automatically by this model.")
    }
    return parts.joined(separator: " ")
  }

  private var openRouterRoutingSection: some View {
    Section {
      Picker("Sort", selection: $openRouterSort) {
        Text("Default").tag(OpenRouterSort?.none)
        Text("Price").tag(OpenRouterSort?.some(.price))
        Text("Throughput").tag(OpenRouterSort?.some(.throughput))
        Text("Latency").tag(OpenRouterSort?.some(.latency))
      }
      .disabled(isSaving)

      Picker("Data Collection", selection: $openRouterDataCollection) {
        Text("Default").tag(OpenRouterDataCollection?.none)
        Text("Allow").tag(OpenRouterDataCollection?.some(.allow))
        Text("Deny").tag(OpenRouterDataCollection?.some(.deny))
      }
      .disabled(isSaving)

      Picker("Allow Fallbacks", selection: $openRouterFallbacks) {
        ForEach(FallbackChoice.allCases) { choice in
          Text(choice.label).tag(choice)
        }
      }
      .disabled(isSaving)

      Toggle("Require Parameter Support", isOn: $openRouterRequireParameters)
        .disabled(isSaving)

      Toggle("Zero Data Retention", isOn: $openRouterZeroDataRetention)
        .disabled(isSaving)

      VStack(alignment: .leading, spacing: 4) {
        Text("Provider Order")
          .font(.subheadline)
        TextField("e.g. anthropic, openai", text: $openRouterProviderOrderText)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .focused($focusedField, equals: .openRouterOrder)
          .disabled(isSaving)
      }

      if hasCustomOpenRouterRouting {
        Button("Reset Routing") {
          focusedField = nil
          openRouterSort = nil
          openRouterDataCollection = nil
          openRouterFallbacks = .default
          openRouterRequireParameters = false
          openRouterZeroDataRetention = false
          openRouterProviderOrderText = ""
        }
        .disabled(isSaving)
      }
    } header: {
      Text("OpenRouter Routing")
        .foregroundStyle(theme.secondaryForegroundColor)
    } footer: {
      Text("Optional routing preferences sent to OpenRouter for this conversation.")
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }

  private func buildOpenRouterRouting() -> OpenRouterRoutingOptions? {
    let routing = OpenRouterRoutingOptions(
      providerOrder: ChatSettingsSupport.parseProviderOrder(openRouterProviderOrderText),
      allowFallbacks: openRouterFallbacks.boolValue,
      requireParameters: openRouterRequireParameters ? true : nil,
      dataCollection: openRouterDataCollection,
      zeroDataRetention: openRouterZeroDataRetention ? true : nil,
      sort: openRouterSort
    )
    return ChatSettingsSupport.normalizedOpenRouterRouting(routing)
  }

  private func save() async {
    guard canSave, let account, hasModelID else { return }
    let modelID = liveConversation.modelID
    focusedField = nil
    isSaving = true
    defer { isSaving = false }

    // Start from the live conversation's options so any model/reasoning changes
    // committed via the embedded Model picker are preserved.
    var updatedOptions = liveConversation.options
    if supportsSamplingControls {
      updatedOptions.temperature = useCustomTemperature
        ? ChatSettingsSupport.clampedTemperature(temperature, for: account.kind)
        : nil
      updatedOptions.topP = useCustomTopP
        ? ChatSettingsSupport.clampedTopP(topP)
        : nil
    }
    updatedOptions.maxOutputTokens = maxOutputTokensValidation.value
    updatedOptions.openRouterRouting = account.kind == .openRouter
      ? buildOpenRouterRouting()
      : nil

    let saved = await chats.updateTarget(
      conversationID: liveConversation.id,
      account: account,
      modelID: modelID,
      systemPrompt: normalizedSystemPrompt,
      options: updatedOptions
    )

    if saved {
      dismiss()
    } else {
      saveError = chats.errorMessage ?? "Unable to save chat settings."
    }
  }
}
