import Foundation
import Testing

@testable import BYOKchatProviderCore

@Test func fullBackupIncludesMCPConfigurationButNeverCredential() async throws {
  let providers = ProviderWorkspaceStore(persistence: InMemoryProviderWorkspacePersistence())
  try await providers.load()
  let conversations = ConversationStore(persistence: InMemoryConversationWorkspacePersistence())
  try await conversations.load()
  let providerVault = InMemoryCredentialVault()
  let accountManager = ProviderAccountManager(
    registry: try ProviderRegistry.builtIn(),
    workspace: providers,
    vault: providerVault
  )

  let mcp = MCPWorkspaceStore(persistence: InMemoryMCPWorkspacePersistence())
  try await mcp.load()
  let server = MCPRemoteServer(
    id: "backup-mcp",
    name: "Backup MCP",
    endpoint: URL(string: "https://mcp.example.com/mcp")!,
    authentication: MCPAuthentication(kind: .bearer)
  )
  try await mcp.upsertServer(server)
  let mcpVault = InMemoryMCPCredentialVault()
  try await mcpVault.setCredential("mcp-super-secret", serverID: server.id)

  let service = DataPortabilityService(
    providers: providers,
    conversations: conversations,
    accounts: accountManager,
    mcp: mcp,
    mcpCredentials: mcpVault
  )

  let backupData = try await service.exportBackup(defaultSystemPrompt: "Be concise.")
  let serialized = String(decoding: backupData, as: UTF8.self)
  #expect(!serialized.contains("mcp-super-secret"))

  let backup = try JSONDecoder.provider.decode(BYOKchatBackup.self, from: backupData)
  let persistedServer = try await mcp.server(id: server.id)
  #expect(backup.mcpWorkspace?.servers == [persistedServer])
  #expect(backup.preferences.defaultSystemPrompt == "Be concise.")

  let summary = try await service.importBackup(backupData, strategy: .replaceExisting)
  #expect(summary.mcpServerCount == 1)
  #expect(summary.mcpCredentialCleanupFailures.isEmpty)
  let credentialAfterReplace = try await mcpVault.credential(serverID: server.id)
  #expect(credentialAfterReplace == nil)
}

@Test func removeAllChatConfigurationsClearsOverridesWhileKeepingServers() async throws {
  let persistence = InMemoryMCPWorkspacePersistence()
  let mcp = MCPWorkspaceStore(persistence: persistence)
  try await mcp.load()

  let server = MCPRemoteServer(
    id: "server-1",
    name: "Docs",
    endpoint: try #require(URL(string: "https://mcp.example.com/mcp")),
    authentication: MCPAuthentication(kind: .none)
  )
  try await mcp.upsertServer(server)

  let firstChat = ConversationID(rawValue: "chat-1")
  let secondChat = ConversationID(rawValue: "chat-2")
  try await mcp.setChatServerEnabled(true, serverID: server.id, conversationID: firstChat)
  try await mcp.setChatServerEnabled(true, serverID: server.id, conversationID: secondChat)
  #expect(await mcp.snapshot().chatConfigurations?.count == 2)

  try await mcp.removeAllChatConfigurations()
  #expect(await mcp.snapshot().chatConfigurations == nil)
  #expect(await mcp.allServers().map(\.id) == [server.id])

  // Calling again when already empty is a clean no-op.
  try await mcp.removeAllChatConfigurations()
  #expect(await mcp.snapshot().chatConfigurations == nil)
}
