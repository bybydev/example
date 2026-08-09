import Foundation

public enum ChatFailureOrigin: String, Sendable, Equatable {
  case local
  case remote
}

extension ChatMessage {
  /// Classifies a persisted failed turn without relying on its user-facing error text.
  /// `ConversationStore` persists `ProviderError` case names in `errorCode`, so this
  /// remains stable when a conversation is reloaded from disk.
  public var failureOrigin: ChatFailureOrigin? {
    guard status == .failed else { return nil }
    guard let errorCode else { return .local }

    let remotePrefixes = [
      "authenticationFailed",
      "permissionDenied",
      "insufficientCredits",
      "rateLimited",
      "modelUnavailable",
      "invalidEndpoint",
      "provider(",
      "midStreamProvider(",
      "transport(",
      "invalidResponse",
      "emptyOutput",
      "prematureStreamEnd",
    ]

    return remotePrefixes.contains(where: { errorCode.hasPrefix($0) }) ? .remote : .local
  }
}
