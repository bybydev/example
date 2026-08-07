import BYOKchatProviderCore
import Foundation

extension ProviderManagementModel {
  func attachmentCompatibilityIssue(
    accountID: ProviderAccountID,
    modelID: ModelID,
    attachments: [ChatAttachment]
  ) -> String? {
    guard !attachments.isEmpty else { return nil }
    guard let account = accounts.first(where: { $0.id == accountID }) else {
      return "The selected provider account is no longer available."
    }
    guard let definition = provider(for: account.providerID) else {
      return "The selected provider is no longer available."
    }

    let record = models(for: accountID, includeHidden: true)
      .first(where: { $0.model.id == modelID })
    let modelName = record?.model.displayName ?? modelID.rawValue
    let hasImage = attachments.contains(where: \.isImage)
    let hasBinaryFile = attachments.contains { attachment in
      !attachment.isImage && attachment.utf8Text == nil
    }

    switch definition.behavior {
    case .deepSeek:
      if hasImage {
        return "\(modelName) is text-only and cannot receive images. Choose a vision-capable model or provider before sending."
      }
      if hasBinaryFile {
        return "\(modelName) is text-only and cannot receive binary documents directly. Attach a text file or choose a file-capable model before sending."
      }

    case .openRouter, .anthropic, .gemini:
      if hasImage,
        let record,
        !record.isManual,
        !record.model.inputModalities.map({ $0.lowercased() }).contains("image")
      {
        return "\(modelName) does not advertise image input. Choose a vision-capable model before sending."
      }

      if definition.behavior == .anthropic,
        let unsupported = attachments.first(where: {
          !$0.isImage
            && $0.utf8Text == nil
            && $0.mimeType.lowercased() != "application/pdf"
        })
      {
        return "Anthropic native file input currently supports images, text files, and PDFs. \(unsupported.filename) is not supported by this provider path."
      }

    case .nvidia, .genericOpenAICompatible:
      // Capability metadata is not authoritative for these paths. Let the provider
      // validate the request instead of incorrectly blocking a manually configured
      // multimodal endpoint.
      break
    }

    return nil
  }
}
