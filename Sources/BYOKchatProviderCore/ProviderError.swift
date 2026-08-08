import Foundation

public enum ProviderError: Error, LocalizedError, Sendable, Equatable {
  case invalidDefinition(String)
  case duplicateProvider(ProviderID)
  case providerNotFound(ProviderID)
  case accountNotFound(ProviderAccountID)
  case duplicateAccount(ProviderAccountID)
  case unsupportedAPIFamily(String)
  case invalidBaseURL
  case invalidModel
  case invalidMessages
  case missingCredential(ProviderID)
  case unsafeHeader(String)
  case authenticationFailed
  case permissionDenied
  case insufficientCredits
  case rateLimited(retryAfter: String?)
  case modelUnavailable
  case invalidEndpoint
  case invalidRequest(String)
  case provider(status: Int, message: String)
  case midStreamProvider(code: String?, message: String)
  case transport(message: String, completionUnknown: Bool)
  case invalidResponse
  case emptyOutput
  case prematureStreamEnd
  case contextWindowExceeded(estimatedInputTokens: Int, limit: Int)
  case workspaceVersionUnsupported(Int)
  case conversationVersionUnsupported(Int)
  case backupVersionUnsupported(Int)
  case conversationNotFound(ConversationID)
  case conversationBusy(ConversationID)
  case chatMessageNotFound(ChatMessageID)
  case uncertainCompletionConfirmationRequired
  case importConflict(String)
  case credentialCleanupFailed([ProviderAccountID])

  public var errorDescription: String? {
    switch self {
    case .invalidDefinition(let message): message
    case .duplicateProvider(let id): "Duplicate provider ID: \(id.rawValue)"
    case .providerNotFound(let id): "Provider not found: \(id.rawValue)"
    case .accountNotFound(let id): "Provider account not found: \(id.rawValue)"
    case .duplicateAccount(let id): "Duplicate provider account: \(id.rawValue)"
    case .unsupportedAPIFamily(let family): "Unsupported API family: \(family)"
    case .invalidBaseURL: "The provider base URL is invalid."
    case .invalidModel: "A model ID is required."
    case .invalidMessages: "At least one non-empty message is required."
    case .missingCredential: "An API key is required for this provider account."
    case .unsafeHeader(let name): "The custom header \(name) is not allowed."
    case .authenticationFailed: "The provider rejected the API key."
    case .permissionDenied: "The provider denied this request."
    case .insufficientCredits: "The provider account has insufficient credit or quota."
    case .rateLimited: "The provider rate limited this request."
    case .modelUnavailable: "The selected model is unavailable."
    case .invalidEndpoint: "The provider endpoint could not be found."
    case .invalidRequest(let message): message
    case .provider(_, let message): message
    case .midStreamProvider(_, let message): message
    case .transport(let message, _): message
    case .invalidResponse: "The provider returned an invalid response."
    case .emptyOutput: "The provider returned an empty response."
    case .prematureStreamEnd: "The provider stream ended before completion."
    case .contextWindowExceeded(let estimated, let limit):
      "The current prompt needs about \(estimated) input tokens, but only \(limit) input tokens are available under this model’s context budget after estimation headroom. Shorten the system prompt or latest message, or remove large attachments or tools. For models with a combined input/output window, lowering the maximum output tokens can also free input capacity."
    case .workspaceVersionUnsupported(let version):
      "Provider workspace version \(version) is unsupported."
    case .conversationVersionUnsupported(let version):
      "Conversation workspace version \(version) is unsupported."
    case .backupVersionUnsupported(let version):
      "BYOKchat backup version \(version) is unsupported."
    case .conversationNotFound(let id): "Conversation not found: \(id.rawValue)"
    case .conversationBusy: "This conversation is already generating a response."
    case .chatMessageNotFound(let id): "Chat message not found: \(id.rawValue)"
    case .uncertainCompletionConfirmationRequired:
      "The previous request may have completed. Confirm before regenerating to avoid a duplicate charge."
    case .importConflict(let message): message
    case .credentialCleanupFailed(let accountIDs):
      "The configuration change was saved, but Keychain cleanup failed for: \(accountIDs.map(\.rawValue).sorted().joined(separator: ", ")). The cleanup can be retried safely."
    }
  }
}
