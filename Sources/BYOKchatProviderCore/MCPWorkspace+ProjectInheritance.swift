import Foundation

extension MCPWorkspaceStore {
  public func explicitChatConfiguration(for conversationID: ConversationID) -> MCPChatToolConfiguration? {
    snapshot().chatConfigurations?[conversationID.rawValue]
  }

  public func replaceChatConfiguration(
    _ configuration: MCPChatToolConfiguration,
    conversationID: ConversationID
  ) async throws {
    try await removeChatConfiguration(conversationID: conversationID)

    let knownServerIDs = Set(snapshot().servers.map(\.id))
    for serverID in configuration.enabledServerIDs where knownServerIDs.contains(serverID) {
      try await setChatServerEnabled(
        true,
        serverID: serverID,
        conversationID: conversationID
      )
    }

    for (name, policy) in configuration.toolPolicies.sorted(by: { $0.key < $1.key }) {
      try await setChatToolPolicy(
        policy,
        exposedToolName: name,
        conversationID: conversationID
      )
    }
  }
}
