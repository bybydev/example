import AppFoundation
import BYOKchatProviderCore
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct NewChatView: View {
  @Bindable var chats: ChatManagementModel
  @Bindable var providers: ProviderManagementModel

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

  private var defaultAccount: ProviderAccount? {
    providers.accounts.first(where: \.isEnabled)
  }

  private var defaultModelID: ModelID? {
    guard let account = defaultAccount else { return nil }
    return account.defaultModelID ?? providers.models(for: account.id).first?.model.id
  }

  private var targetLabel: String {
    guard let account = defaultAccount else { return "Configure a provider" }
    guard let modelID = defaultModelID else { return "Choose model" }
    let modelName = providers.models(for: account.id)
      .first(where: { $0.model.id == modelID })?.model.displayName
      ?? modelID.rawValue
    return "\(account.label) · \(modelName)"
  }

  var body: some View {
    ZStack {
      theme.backgroundColor
        .ignoresSafeArea()

      VStack(spacing: 0) {
        Spacer(minLength: 72)

        VStack(spacing: 12) {
          Image(systemName: "bubble.left.and.bubble.right")
            .font(.system(size: 30, weight: .medium))
            .foregroundStyle(theme.accentColor)
            .accessibilityHidden(true)

          Text("How can I help?")
            .font(.system(size: 30, weight: .semibold))
            .multilineTextAlignment(.center)

          Text("Send a message to start a new conversation.")
            .font(.system(size: 16))
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 32)

        Spacer()
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .contentShape(Rectangle())
    .simultaneousGesture(
      TapGesture().onEnded {
        dismissKeyboard()
      }
    )
    .toolbar(.hidden, for: .navigationBar)
    .safeAreaInset(edge: .top, spacing: 0) {
      ChatTopBar(
        openSidebar: openSidebar,
        newChat: {
          draft = ""
          pendingAttachments = []
          photoPickerItems = []
        }
      ) {
        Button("Settings", systemImage: "gearshape", action: openSettings)
        Button("Providers & Accounts", systemImage: "key.horizontal", action: openSettings)
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      ChatComposer(
        draft: $draft,
        attachments: pendingAttachments,
        isGenerating: false,
        canSend: !isCreating && defaultAccount != nil && defaultModelID != nil,
        targetLabel: targetLabel,
        openTarget: openSettings,
        pickPhoto: { showPhotoPicker = true },
        pickFile: { showFileImporter = true },
        removeAttachment: removePendingAttachment,
        send: startConversation,
        stop: {}
      )
      .overlay {
        if isCreating {
          ProgressView()
            .padding(10)
            .background(.regularMaterial, in: Capsule())
        }
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
  }

  private func startConversation() {
    let normalized = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    let attachments = pendingAttachments
    guard !normalized.isEmpty || !attachments.isEmpty else { return }
    guard !isCreating else { return }

    isCreating = true
    Task { @MainActor in
      defer { isCreating = false }
      guard let id = await chats.createConversation() else { return }
      draft = ""
      pendingAttachments = []
      photoPickerItems = []
      chats.send(
        conversationID: id,
        text: normalized,
        attachments: attachments
      )
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
      return try normalizedImageAttachment(
        data: data,
        suggestedName: url.deletingPathExtension().lastPathComponent
      )
    }

    return ChatAttachment(
      kind: .file,
      filename: url.lastPathComponent,
      mimeType: type.preferredMIMEType ?? "application/octet-stream",
      data: data
    )
  }

  private func normalizedImageAttachment(data: Data, suggestedName: String) throws
    -> ChatAttachment
  {
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

  private func removePendingAttachment(_ id: String) {
    pendingAttachments.removeAll { $0.id == id }
  }

  private func dismissKeyboard() {
    UIApplication.shared.sendAction(
      #selector(UIResponder.resignFirstResponder),
      to: nil,
      from: nil,
      for: nil
    )
  }
}
