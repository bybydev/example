import Foundation

/// Platform-neutral composition root for the BYOK data and runtime layer.
///
/// App targets provide only host policy (storage namespaces) and credential
/// vaults. This type owns construction of the shared stores/runtimes so iOS
/// and macOS cannot silently drift in how provider, chat, project, library,
/// MCP, telemetry, or portability services are wired.
public struct BYOKCoreServices {
  public let environment: BYOKStorageEnvironment
  public let telemetryRecorder: TelemetryRecorder

  public let providerRegistry: ProviderRegistry
  public let providerWorkspace: ProviderWorkspaceStore
  public let credentialVault: any CredentialVault
  public let accountManager: ProviderAccountManager
  public let providerRuntime: ProviderRuntime

  public let fileBlobStore: FileAttachmentBlobStore
  public let conversationStore: ConversationStore
  public let libraryStore: LibraryStore
  public let projectWorkspace: ProjectWorkspaceStore

  public let mcpWorkspace: MCPWorkspaceStore
  public let mcpCredentialVault: any MCPCredentialVault
  public let mcpRuntime: MCPRemoteRuntime
  public let approvalCenter: MCPToolApprovalCenter
  public let elicitationCenter: MCPElicitationCenter

  public let toolRuntime: ToolRuntime
  public let conversationToolRuntime: MCPConversationToolRuntime
  public let chatRuntime: ChatRuntime

  public let baseDataPortability: DataPortabilityService
  public let dataPortability: ProjectAwareDataPortabilityService

  public init(
    environment: BYOKStorageEnvironment,
    credentialVault: any CredentialVault,
    mcpCredentialVault: any MCPCredentialVault,
    toolRuntime: ToolRuntime = ToolRuntime(),
    telemetryRecorder: TelemetryRecorder? = nil
  ) throws {
    self.environment = environment
    let telemetryRecorder = telemetryRecorder ?? environment.makeTelemetryRecorder()
    self.telemetryRecorder = telemetryRecorder

    let layout = environment.layout
    let providerRegistry = try ProviderRegistry.builtIn()
    self.providerRegistry = providerRegistry

    let providerWorkspace = ProviderWorkspaceStore(
      persistence: JSONFileProviderWorkspacePersistence(fileURL: layout.providersFile)
    )
    self.providerWorkspace = providerWorkspace
    self.credentialVault = credentialVault

    let accountManager = ProviderAccountManager(
      registry: providerRegistry,
      workspace: providerWorkspace,
      vault: credentialVault
    )
    self.accountManager = accountManager

    let providerRuntime = ProviderRuntime(
      registry: providerRegistry,
      workspace: providerWorkspace,
      accounts: accountManager
    )
    self.providerRuntime = providerRuntime

    let fileBlobStore = FileAttachmentBlobStore(directory: layout.filesDirectory)
    self.fileBlobStore = fileBlobStore

    let conversationStore = ConversationStore(
      persistence: JSONFileConversationWorkspacePersistence(
        directory: layout.conversationsDirectory
      ),
      blobs: fileBlobStore
    )
    self.conversationStore = conversationStore

    let libraryStore = LibraryStore(
      persistence: JSONFileLibraryWorkspacePersistence(fileURL: layout.libraryFile),
      blobs: fileBlobStore
    )
    self.libraryStore = libraryStore

    let projectWorkspace = ProjectWorkspaceStore(
      persistence: JSONFileProjectWorkspacePersistence(fileURL: layout.projectsFile),
      blobs: fileBlobStore
    )
    self.projectWorkspace = projectWorkspace

    let mcpWorkspace = MCPWorkspaceStore(
      persistence: JSONFileMCPWorkspacePersistence(fileURL: layout.mcpServersFile)
    )
    self.mcpWorkspace = mcpWorkspace
    self.mcpCredentialVault = mcpCredentialVault

    let mcpRuntime = MCPRemoteRuntime(
      workspace: mcpWorkspace,
      vault: mcpCredentialVault,
      transport: MCPHTTPTransport(telemetryRecorder: telemetryRecorder)
    )
    self.mcpRuntime = mcpRuntime

    let approvalCenter = MCPToolApprovalCenter()
    self.approvalCenter = approvalCenter
    let elicitationCenter = MCPElicitationCenter()
    self.elicitationCenter = elicitationCenter

    self.toolRuntime = toolRuntime
    let conversationToolRuntime = MCPConversationToolRuntime(
      localRuntime: toolRuntime,
      mcpRuntime: mcpRuntime,
      workspace: mcpWorkspace,
      projectWorkspace: projectWorkspace,
      approvals: approvalCenter,
      elicitations: elicitationCenter,
      telemetryRecorder: telemetryRecorder
    )
    self.conversationToolRuntime = conversationToolRuntime

    let chatRuntime = ChatRuntime(
      providerRuntime: providerRuntime,
      providerWorkspace: providerWorkspace,
      conversations: conversationStore,
      toolRuntime: conversationToolRuntime,
      telemetryRecorder: telemetryRecorder
    )
    self.chatRuntime = chatRuntime

    let baseDataPortability = DataPortabilityService(
      providers: providerWorkspace,
      conversations: conversationStore,
      accounts: accountManager,
      mcp: mcpWorkspace,
      mcpCredentials: mcpCredentialVault
    )
    self.baseDataPortability = baseDataPortability
    self.dataPortability = ProjectAwareDataPortabilityService(
      base: baseDataPortability,
      projects: projectWorkspace,
      conversations: conversationStore,
      library: libraryStore
    )
  }

  /// Loads the platform-neutral persistent stores without probing providers or
  /// refreshing MCP servers. Conversation startup remains index-only and does
  /// not hydrate message shards.
  public func loadStoredState() async throws {
    try await providerWorkspace.load()
    try await projectWorkspace.load()
    try await mcpRuntime.load()
    try await conversationStore.load()
    try await libraryStore.load()
  }
}

#if canImport(Security)
  extension BYOKCoreServices {
    /// Production Apple-platform composition using the namespaces supplied by
    /// the host environment. Tests and non-Security platforms use the protocol
    /// based initializer above with in-memory vaults.
    public static func secure(
      environment: BYOKStorageEnvironment,
      toolRuntime: ToolRuntime = ToolRuntime(),
      telemetryRecorder: TelemetryRecorder? = nil
    ) throws -> BYOKCoreServices {
      try BYOKCoreServices(
        environment: environment,
        credentialVault: KeychainCredentialVault(service: environment.credentialService),
        mcpCredentialVault: KeychainMCPCredentialVault(
          service: environment.mcpCredentialService
        ),
        toolRuntime: toolRuntime,
        telemetryRecorder: telemetryRecorder
      )
    }
  }
#endif
