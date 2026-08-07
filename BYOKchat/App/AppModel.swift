import AppFoundation
import BYOKchatProviderCore
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
  let providers: ProviderManagementModel
  let chats: ChatManagementModel
  let mcp: MCPManagementModel
  let preferences: AppPreferencesModel
  let dataPortability: DataPortabilityModel
  let themeManager: ThemeManager
  let toolRuntime: ToolRuntime

  private(set) var hasLoaded = false

  init() {
    let preferences = AppPreferencesModel()
    self.preferences = preferences
    themeManager = ThemeManager(
      catalog: BYOKchatThemes.catalog,
      stateStore: UserDefaultsThemeStateStore(storageKey: "byokchat.themeState.v1"),
      hasPro: false,
      previewBehavior: .disabled
    )

    let registry = try! ProviderRegistry.builtIn()
    let supportDirectory = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first!
    .appendingPathComponent("BYOKchat", isDirectory: true)

    let providerWorkspace = ProviderWorkspaceStore(
      persistence: JSONFileProviderWorkspacePersistence(
        fileURL: supportDirectory.appendingPathComponent("providers-v1.json")
      )
    )
    let vault = KeychainCredentialVault()
    let accountManager = ProviderAccountManager(
      registry: registry,
      workspace: providerWorkspace,
      vault: vault
    )
    let providerRuntime = ProviderRuntime(
      registry: registry,
      workspace: providerWorkspace,
      accounts: accountManager
    )
    let conversationStore = ConversationStore(
      persistence: JSONFileConversationWorkspacePersistence(
        fileURL: supportDirectory.appendingPathComponent("conversations-v1.json")
      )
    )

    let mcpWorkspace = MCPWorkspaceStore(
      persistence: JSONFileMCPWorkspacePersistence(
        fileURL: supportDirectory.appendingPathComponent("mcp-servers-v1.json")
      )
    )
    let mcpVault = KeychainMCPCredentialVault()
    let mcpRuntime = MCPRemoteRuntime(
      workspace: mcpWorkspace,
      vault: mcpVault,
      transport: MCPHTTPTransport()
    )
    let approvalCenter = MCPToolApprovalCenter()
    let elicitationCenter = MCPElicitationCenter()

    let toolRuntime = ToolRuntime()
    self.toolRuntime = toolRuntime
    let conversationToolRuntime = MCPConversationToolRuntime(
      localRuntime: toolRuntime,
      mcpRuntime: mcpRuntime,
      workspace: mcpWorkspace,
      approvals: approvalCenter,
      elicitations: elicitationCenter
    )
    let chatRuntime = ChatRuntime(
      providerRuntime: providerRuntime,
      providerWorkspace: providerWorkspace,
      conversations: conversationStore,
      toolRuntime: conversationToolRuntime
    )

    let providerModel = ProviderManagementModel(
      registry: registry,
      workspace: providerWorkspace,
      vault: vault,
      accountManager: accountManager,
      runtime: providerRuntime
    )
    let chatModel = ChatManagementModel(
      providerWorkspace: providerWorkspace,
      conversations: conversationStore,
      runtime: chatRuntime,
      preferences: preferences,
      mcpWorkspace: mcpWorkspace
    )
    let mcpModel = MCPManagementModel(
      runtime: mcpRuntime,
      workspace: mcpWorkspace,
      approvals: approvalCenter,
      elicitations: elicitationCenter
    )

    providers = providerModel
    chats = chatModel
    mcp = mcpModel
    dataPortability = DataPortabilityModel(
      service: DataPortabilityService(
        providers: providerWorkspace,
        conversations: conversationStore,
        accounts: accountManager,
        mcp: mcpWorkspace,
        mcpCredentials: mcpVault
      ),
      providerWorkspace: providerWorkspace,
      conversations: conversationStore,
      accountManager: accountManager,
      preferences: preferences,
      providersModel: providerModel,
      chatsModel: chatModel,
      mcpModel: mcpModel
    )
  }

  func load() async {
    guard !hasLoaded else { return }
    await providers.load()
    await mcp.load()
    await chats.load()
    hasLoaded = true
  }
}
