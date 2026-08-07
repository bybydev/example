import AppFoundation
import BYOKchatProviderCore
import Foundation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ChatView: View {
  let conversationID: ConversationID
  let initialScrollMessageID: ChatMessageID?
  let openSidebar: () -> Void
  let startNewChat: () -> Void

  @Bindable var chats: ChatManagementModel
  @Bindable var providers: ProviderManagementModel

  @Environment(\.appFoundationTheme) private var theme
  @Environment(\.dismiss) var dismiss
  @State var draft = ""
  @State var restoredDraft = false
  @State var showTargetSettings = false
  @State var renameText = ""
  @State var showRename = false
  @State var editTarget: ChatMessage?
  @State var editText = ""
  @State var showRegenerateConfirmation = false
  @State var isNearBottom = true
  @State var followsLatest = true
  @State var isUserDraggingTimeline = false
  @State var showJumpToLatest = false
  @State var markdownDocument: MarkdownExportDocument?
  @State var showMarkdownExporter = false
  @State var pendingAttachments: [ChatAttachment] = []
  @State var showPhotoPicker = false
  @State var photoPickerItems: [PhotosPickerItem] = []
  @State var showFileImporter = false

  init(
    conversationID: ConversationID,
    initialScrollMessageID: ChatMessageID? = nil,
    chats: ChatManagementModel,
    providers: ProviderManagementModel,
    openSidebar: @escaping () -> Void = {},
    startNewChat: @escaping () -> Void = {}
  ) {
    self.conversationID = conversationID
    self.initialScrollMessageID = initialScrollMessageID
    self.chats = chats
    self.providers = providers
    self.openSidebar = openSidebar
    self.startNewChat = startNewChat
  }

  var conversation: ChatConversation? {
    chats.conversation(conversationID)
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
      if let conversation {
        chatContent(conversation)
      } else {
        ContentUnavailableView("Conversation Missing", systemImage: "exclamationmark.bubble")
      }
    }
    .background(theme.backgroundColor)
    .toolbar(.hidden, for: .navigationBar)
    .safeAreaInset(edge: .top, spacing: 0) {
      ChatTopBar(openSidebar: openSidebar, newChat: startNewChat) {
        Button("Chat Settings", systemImage: "slider.horizontal.3") {
          showTargetSettings = true
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
            startNewChat()
            dismiss()
          }
        }
      }
    }
    .sheet(isPresented: $showTargetSettings) {
      if let conversation {
        ConversationTargetView(
          conversation: conversation,
          chats: chats,
          providers: providers
        )
      }
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
      guard !restoredDraft else { return }
      draft = chats.draft(for: conversationID)
      restoredDraft = true
    }
    .onChange(of: draft) { _, value in
      guard restoredDraft else { return }
      chats.saveDraft(value, conversationID: conversationID)
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

  func removePendingAttachment(_ id: String) {
    pendingAttachments.removeAll { $0.id == id }
  }
}
