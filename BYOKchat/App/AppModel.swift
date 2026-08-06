import BYOKchatProviderCore
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
  let providers: ProviderManagementModel
  let chats: ChatManagementModel

  private(set) var hasLoaded = false

  init() {
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
    let chatRuntime = ChatRuntime(
      providerRuntime: providerRuntime,
      providerWorkspace: providerWorkspace,
      conversations: conversationStore
    )

    providers = ProviderManagementModel(
      registry: registry,
      workspace: providerWorkspace,
      vault: vault,
      accountManager: accountManager,
      runtime: providerRuntime
    )
    chats = ChatManagementModel(
      providerWorkspace: providerWorkspace,
      conversations: conversationStore,
      runtime: chatRuntime
    )
  }

  func load() async {
    guard !hasLoaded else { return }
    await providers.load()
    await chats.load()
    hasLoaded = true
  }
}
