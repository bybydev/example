import BYOKchatProviderCore
import Foundation

enum MacAttachmentCompatibility {
  static func validate(
    _ attachments: [ChatAttachment],
    providerKind: ProviderKind,
    inputModalities: Set<String>
  ) throws {
    guard !attachments.isEmpty else { return }

    // Anthropic/Gemini discovery exposes reliable modality metadata. Several
    // OpenAI-compatible catalogs default missing architecture metadata to
    // text-only, so treating those defaults as a hard capability boundary
    // would reject valid vision/file models.
    let modalities = Set(inputModalities.map { $0.lowercased() })
    let hasReliableModalityMetadata = providerKind == .anthropic || providerKind == .gemini
    if hasReliableModalityMetadata, !modalities.isEmpty {
      for attachment in attachments {
        if attachment.isImage {
          guard modalities.contains("image") else {
            throw ProviderError.invalidRequest(
              "\(attachment.filename) is an image, but the selected model does not advertise image input."
            )
          }
        } else if attachment.isTextLike {
          guard modalities.contains("text") || modalities.contains("file") else {
            throw ProviderError.invalidRequest(
              "\(attachment.filename) is not supported by the selected model."
            )
          }
        } else {
          guard modalities.contains("file") else {
            throw ProviderError.invalidRequest(
              "\(attachment.filename) requires file input support from the selected model."
            )
          }
        }
      }
    }

    if providerKind == .anthropic,
      let unsupported = attachments.first(where: {
        !$0.isImage && !$0.isTextLike && $0.mimeType.lowercased() != "application/pdf"
      })
    {
      throw ProviderError.invalidRequest(
        "Anthropic currently supports text files, images, and PDFs. \(unsupported.filename) must be converted first."
      )
    }
  }
}

extension MacProviderModel {
  func validateAttachments(_ attachments: [ChatAttachment], for target: MacChatTarget) throws {
    guard !attachments.isEmpty else { return }
    guard let account = account(target.accountID) else {
      throw ProviderError.accountNotFound(target.accountID)
    }

    let model = models(for: target.accountID, includeHidden: true)
      .first { $0.model.id == target.modelID }?.model
    try MacAttachmentCompatibility.validate(
      attachments,
      providerKind: account.kind,
      inputModalities: Set(model?.inputModalities ?? [])
    )
  }
}
