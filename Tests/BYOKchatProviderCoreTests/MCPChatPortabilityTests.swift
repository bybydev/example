import Foundation
import Testing

@testable import BYOKchatProviderCore

@Test func fullBackupRemapsPerChatMCPPolicyToRestoredConversationID() async throws {
  let providers = ProviderWorkspaceStore(persistence: InMemoryProviderWorkspacePersistence())
  try await providers.load()
  let account = ProviderAccount(
    id: "portable-account",
    providerID: "deepseek",
    label: "DeepSeek",
    defaultModelID: "portable-model"
  )
  try await providers.upsertAccount(account)
  try await providers.addManualModel(
    ProviderModel(
      providerID: "deepseek",
      id: "portable-model",
      displayName: "Portable Model"
    ),
    for: account.id
  )

  let conversations = ConversationStore(persistence: InMemoryConversationWorkspacePersistence())
  try await conversations.load()
  let sourceConversation = try await conversations.createConversation(
    providerID: account.providerID,
    accountID: account.id,
    modelID: "portable-model"
  )
  let turn = try await conversations.beginTurn(
    conversationID: sourceConversation.id,
    userText: "Hello"
  )
  _ = try await conversations.completeMessage(
    conversationID: sourceConversation.id,
    messageID: turn.assistantMessage.id,
    response: ProviderResponse(
      text: "Hi",
      providerID: account.providerID,
      accountID: account.id,
      modelID: "portable-model"
    )
  )

  let mcp = MCPWorkspaceStore(persistence: InMemoryMCPWorkspacePersistence())
  try await mcp.load()
  let server = MCPRemoteServer(
    id: "portable-mcp",
    name: "Portable MCP",
    endpoint: URL(string: "https://portable.example.com/mcp")!
  )
  try await mcp.upsertServer(server)
  let exposedTool = MCPToolNamespace.exposedName(serverID: server.id, remoteName: "write_value")
  try await mcp.setChatServerEnabled(
    true,
    serverID: server.id,
    conversationID: sourceConversation.id
  )
  try await mcp.setChatToolPolicy(
    .alwaysAllow,
    exposedToolName: exposedTool,
    conversationID: sourceConversation.id
  )

  let accountManager = ProviderAccountManager(
    registry: try ProviderRegistry.builtIn(),
    workspace: providers,
    vault: InMemoryCredentialVault()
  )
  let service = DataPortabilityService(
    providers: providers,
    conversations: conversations,
    accounts: accountManager,
    mcp: mcp,
    mcpCredentials: InMemoryMCPCredentialVault()
  )

  let backup = try await service.exportBackup(defaultSystemPrompt: "")
  _ = try await service.importBackup(backup, strategy: .replaceExisting)

  let restored = try #require(await conversations.allConversations().first)
  #expect(restored.id != sourceConversation.id)

  let restoredConfiguration = await mcp.chatConfiguration(for: restored.id)
  #expect(restoredConfiguration.enabledServerIDs == [server.id])
  #expect(restoredConfiguration.policy(for: exposedTool) == .alwaysAllow)

  let staleConfiguration = await mcp.chatConfiguration(for: sourceConversation.id)
  #expect(staleConfiguration.enabledServerIDs.isEmpty)
  #expect(staleConfiguration.toolPolicies.isEmpty)
}
