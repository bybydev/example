import BYOKchatProviderCore
import Foundation

enum MacAttachmentCompatibility {
  static func validate(
    _ attachments: [ChatAttachment],
    providerKind: ProviderKind,
    inputModalities: Set<String>
  ) throws {
    var evidence = ModelCapabilityEvidence()
    if providerKind == .anthropic {
      evidence.modalities(Array(inputModalities), input: true)
    }
    let model = ProviderModel(providerID: providerKind.defaultProviderID ?? "custom", id: "",
      displayName: "", inputModalities: inputModalities, capabilityEvidence: evidence)
    try ModelRequestPolicy.validateAttachments(attachments, kind: providerKind,
      capabilities: ModelCapabilityResolver.resolve(kind: providerKind, modelID: "", model: model))
  }
}

extension MacProviderModel {
  func validateAttachments(_ attachments: [ChatAttachment], for target: MacChatTarget) throws {
    guard !attachments.isEmpty else { return }
    guard let account = account(target.accountID) else {
      throw ProviderError.accountNotFound(target.accountID)
    }

    try ModelRequestPolicy.validateAttachments(attachments, kind: account.kind,
      capabilities: capabilities(accountID: target.accountID, modelID: target.modelID))
  }
}

