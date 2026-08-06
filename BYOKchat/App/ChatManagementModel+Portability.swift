import Foundation

extension ChatManagementModel {
  func stopAllGenerations() async {
    let ids = Array(activeConversationIDs)
    for id in ids {
      await stop(id)
    }
    await persistActiveMessages()
  }

  func reloadFromStorage() async {
    await load()
  }
}
