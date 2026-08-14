import BYOKchatProviderCore
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension NewChatView {
  func importPhotos(_ items: [PhotosPickerItem]) {
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

  func importFiles(_ result: Result<[URL], Error>) {
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

  func loadFileAttachment(_ url: URL) throws -> ChatAttachment {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
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

  func normalizedImageAttachment(data: Data, suggestedName: String) throws -> ChatAttachment {
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
