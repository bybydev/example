import Foundation

extension ChatManagementModel {
  func stopAllGenerations() async {
    let ids = Array(activeConversationIDs)
    for id in ids { stop(id) }
    for _ in 0..<100 where !activeConversationIDs.isEmpty {
      try? await Task.sleep(for: .milliseconds(20))
    }
    await persistActiveMessages()
  }

  func reloadFromStorage() async {
    await load()
  }
}
