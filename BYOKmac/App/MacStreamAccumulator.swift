import BYOKchatProviderCore

/// Keeps raw provider deltas and growing string concatenation off the main actor.
/// It also owns the per-message presentation gate so only one delta per
/// presentation window needs to wake the UI actor.
actor MacStreamAccumulator {
  struct Snapshot: Equatable, Sendable {
    var content = ""
    var reasoning = ""
    var usage: ProviderUsage?
  }

  private var snapshots: [ChatMessageID: Snapshot] = [:]
  private var presentationScheduled: Set<ChatMessageID> = []

  func reset(_ messageID: ChatMessageID, seed: Snapshot = .init()) {
    snapshots[messageID] = seed
    presentationScheduled.remove(messageID)
  }

  /// Returns true only for the first mutation in the current presentation
  /// window. Later raw deltas stay entirely on this actor until UI pickup.
  func appendText(_ value: String, to messageID: ChatMessageID) -> Bool {
    snapshots[messageID, default: .init()].content += value
    return markPresentationNeeded(messageID)
  }

  func appendReasoning(_ value: String, to messageID: ChatMessageID) -> Bool {
    snapshots[messageID, default: .init()].reasoning += value
    return markPresentationNeeded(messageID)
  }

  func setUsage(_ usage: ProviderUsage?, for messageID: ChatMessageID) -> Bool {
    snapshots[messageID, default: .init()].usage = usage
    return markPresentationNeeded(messageID)
  }

  /// Clears the presentation gate and returns the latest coalesced state.
  func takeSnapshot(for messageID: ChatMessageID) -> Snapshot? {
    presentationScheduled.remove(messageID)
    return snapshots[messageID]
  }

  func remove(_ messageID: ChatMessageID) {
    snapshots.removeValue(forKey: messageID)
    presentationScheduled.remove(messageID)
  }

  func remove(_ messageIDs: Set<ChatMessageID>) {
    for messageID in messageIDs {
      snapshots.removeValue(forKey: messageID)
      presentationScheduled.remove(messageID)
    }
  }

  private func markPresentationNeeded(_ messageID: ChatMessageID) -> Bool {
    presentationScheduled.insert(messageID).inserted
  }
}
