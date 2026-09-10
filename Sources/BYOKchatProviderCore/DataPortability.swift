import Foundation

public struct BYOKchatBackupPreferences: Codable, Sendable, Equatable {
  public var defaultSystemPrompt: String

  public init(defaultSystemPrompt: String = "") {
    self.defaultSystemPrompt = defaultSystemPrompt
  }
}

public struct BYOKchatBackup: Codable, Sendable, Equatable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var exportedAt: Date
  public var providerWorkspace: ProviderWorkspaceState
  public var conversationWorkspace: ConversationWorkspaceState
  public var mcpWorkspace: MCPWorkspaceState?
  public var preferences: BYOKchatBackupPreferences

  public init(
    schemaVersion: Int = Self.currentSchemaVersion,
    exportedAt: Date = .now,
    providerWorkspace: ProviderWorkspaceState,
    conversationWorkspace: ConversationWorkspaceState,
    mcpWorkspace: MCPWorkspaceState? = nil,
    preferences: BYOKchatBackupPreferences
  ) {
    self.schemaVersion = schemaVersion
    self.exportedAt = exportedAt
    self.providerWorkspace = providerWorkspace
    self.conversationWorkspace = conversationWorkspace
    self.mcpWorkspace = mcpWorkspace
    self.preferences = preferences
  }
}

public struct BYOKchatImportSummary: Sendable, Equatable {
  public var providerCount: Int
  public var accountCount: Int
  public var conversationCount: Int
  public var mcpServerCount: Int
  public var defaultSystemPrompt: String
  public var credentialCleanupFailures: [ProviderAccountID]
  public var mcpCredentialCleanupFailures: [MCPServerID]

  public init(
    providerCount: Int,
    accountCount: Int,
    conversationCount: Int,
    mcpServerCount: Int = 0,
    defaultSystemPrompt: String,
    credentialCleanupFailures: [ProviderAccountID] = [],
    mcpCredentialCleanupFailures: [MCPServerID] = []
  ) {
    self.providerCount = providerCount
    self.accountCount = accountCount
    self.conversationCount = conversationCount
    self.mcpServerCount = mcpServerCount
    self.defaultSystemPrompt = defaultSystemPrompt
    self.credentialCleanupFailures = credentialCleanupFailures
    self.mcpCredentialCleanupFailures = mcpCredentialCleanupFailures
  }
}

/// Internal two-phase import state. The core provider/chat/MCP workspaces are committed
/// first, but credential cleanup is intentionally delayed until the Project/Library layer
/// confirms the whole full-backup restore succeeded.
struct DataPortabilityImportTransaction: Sendable {
  var summary: BYOKchatImportSummary
  var conversationIDMapping: [ConversationID: ConversationID]
  var previousProviders: Data
  var previousConversations: Data
  var previousMCP: Data?
  var previousAccountIDs: [ProviderAccountID]
  var previousMCPServerIDs: [MCPServerID]
  var strategy: ProviderImportStrategy
}

/// A core import can fail after its conversation store was already mutated. Core rollback
/// reconstructs those conversations and may assign new local IDs; the Project layer must be
/// given that exact rollback mapping so its pre-import memberships do not become stale.
struct DataPortabilityRolledBackImportError: LocalizedError, Sendable {
  var importDescription: String
  var conversationIDMapping: [ConversationID: ConversationID]

  var errorDescription: String? { importDescription }
}

public actor DataPortabilityService {
  private let providers: ProviderWorkspaceStore
  private let conversations: ConversationStore
  private let accounts: ProviderAccountManager
  private let mcp: MCPWorkspaceStore?
  private let mcpCredentials: (any MCPCredentialVault)?

  public init(
    providers: ProviderWorkspaceStore,
    conversations: ConversationStore,
    accounts: ProviderAccountManager,
    mcp: MCPWorkspaceStore? = nil,
    mcpCredentials: (any MCPCredentialVault)? = nil
  ) {
    self.providers = providers
    self.conversations = conversations
    self.accounts = accounts
    self.mcp = mcp
    self.mcpCredentials = mcpCredentials
  }

  public func exportBackup(defaultSystemPrompt: String) async throws -> Data {
    // ConversationStore keeps attachment rows metadata-only in normal runtime state.
    // Its portability export is the authoritative self-contained form because it
    // hydrates attachment payloads from the blob store and drops only confirmed-missing blobs.
    let conversationData = try await conversations.exportWorkspace()
    let conversationWorkspace = try JSONDecoder.provider.decode(
      ConversationWorkspaceState.self,
      from: conversationData
    )
    let backup = BYOKchatBackup(
      providerWorkspace: await providers.snapshot(),
      conversationWorkspace: conversationWorkspace,
      mcpWorkspace: await mcp?.snapshot(),
      preferences: .init(defaultSystemPrompt: defaultSystemPrompt)
    )
    return try JSONEncoder.providerEncoder.encode(backup)
  }

  public func importBackup(
    _ data: Data,
    strategy: ProviderImportStrategy
  ) async throws -> BYOKchatImportSummary {
    let transaction = try await beginImportBackup(data, strategy: strategy)
    return await commitImport(transaction)
  }

  /// Commits provider/chat/MCP workspace data and returns a rollback-capable transaction.
  /// No provider or MCP credential is deleted here; destructive Keychain cleanup is delayed
  /// until `commitImport` after every higher-level workspace has committed.
  func beginImportBackup(
    _ data: Data,
    strategy: ProviderImportStrategy
  ) async throws -> DataPortabilityImportTransaction {
    let backup = try JSONDecoder.provider.decode(BYOKchatBackup.self, from: data)
    guard backup.schemaVersion == BYOKchatBackup.currentSchemaVersion else {
      throw ProviderError.backupVersionUnsupported(backup.schemaVersion)
    }
    guard
      backup.providerWorkspace.schemaVersion == ProviderWorkspaceState.currentSchemaVersion,
      backup.conversationWorkspace.schemaVersion == ConversationWorkspaceState.currentSchemaVersion
    else {
      throw ProviderError.invalidRequest("The backup contains an unsupported workspace version.")
    }
    if let importedMCP = backup.mcpWorkspace {
      guard importedMCP.schemaVersion == MCPWorkspaceState.currentSchemaVersion else {
        throw ProviderError.invalidRequest("The backup contains an unsupported MCP workspace version.")
      }
      try MCPWorkspaceStore.validate(importedMCP)
      try validateMCPConversationReferences(
        importedMCP,
        conversations: backup.conversationWorkspace.conversations
      )
    }
    try WorkspaceImportValidator.validateProviderWorkspace(backup.providerWorkspace)
    try WorkspaceImportValidator.validateConversationWorkspace(backup.conversationWorkspace)
    try await validateConversationTargets(in: backup, strategy: strategy)

    let previousProviders = try await providers.exportConfiguration()
    let previousConversations = try await conversations.exportWorkspace()
    let previousMCP = try await mcp?.exportConfiguration()
    let previousAccountIDs = await providers.allAccounts().map(\.id)
    let previousMCPServerIDs = await mcp?.allServers().map(\.id) ?? []

    let providerData = try JSONEncoder.providerEncoder.encode(backup.providerWorkspace)
    let conversationData = try JSONEncoder.providerEncoder.encode(backup.conversationWorkspace)
    let conversationIDMapping: [ConversationID: ConversationID]

    do {
      try await providers.importConfiguration(providerData, strategy: strategy)
      conversationIDMapping = try await conversations.importWorkspace(
        conversationData,
        strategy: strategy
      )
      if let mcp, let importedMCP = backup.mcpWorkspace {
        let remappedMCP = try remapMCPWorkspace(
          importedMCP,
          conversationIDMapping: conversationIDMapping
        )
        let mcpData = try JSONEncoder.providerEncoder.encode(remappedMCP)
        try await mcp.importConfiguration(mcpData, strategy: strategy)
      } else if let mcp, case .replaceExisting = strategy {
        let empty = try JSONEncoder.providerEncoder.encode(MCPWorkspaceState())
        try await mcp.importConfiguration(empty, strategy: .replaceExisting)
      }
    } catch let importError {
      let rollbackMapping: [ConversationID: ConversationID]
      do {
        rollbackMapping = try await restoreCore(
          providers: previousProviders,
          conversations: previousConversations,
          mcp: previousMCP
        )
      } catch let rollbackError {
        throw ProviderError.importConflict(
          "Import failed: \(importError.localizedDescription) Rollback also failed: \(rollbackError.localizedDescription)"
        )
      }
      throw DataPortabilityRolledBackImportError(
        importDescription: importError.localizedDescription,
        conversationIDMapping: rollbackMapping
      )
    }

    return DataPortabilityImportTransaction(
      summary: BYOKchatImportSummary(
        providerCount: backup.providerWorkspace.customProviders.count,
        accountCount: backup.providerWorkspace.accounts.count,
        conversationCount: backup.conversationWorkspace.conversations.count,
        mcpServerCount: backup.mcpWorkspace?.servers.count ?? 0,
        defaultSystemPrompt: backup.preferences.defaultSystemPrompt
      ),
      conversationIDMapping: conversationIDMapping,
      previousProviders: previousProviders,
      previousConversations: previousConversations,
      previousMCP: previousMCP,
      previousAccountIDs: previousAccountIDs,
      previousMCPServerIDs: previousMCPServerIDs,
      strategy: strategy
    )
  }

  /// Finalizes a previously committed core import. This cannot invalidate workspace data;
  /// credential removal is best-effort and is reported as cleanup warnings in the summary.
  func commitImport(_ transaction: DataPortabilityImportTransaction) async -> BYOKchatImportSummary {
    var summary = transaction.summary
    guard case .replaceExisting = transaction.strategy else { return summary }

    let importedAccountIDs = await providers.allAccounts().map(\.id)
    summary.credentialCleanupFailures = await accounts.removeCredentialsBestEffort(
      accountIDs: transaction.previousAccountIDs + importedAccountIDs
    )
    let importedMCPServerIDs = await mcp?.allServers().map(\.id) ?? []
    summary.mcpCredentialCleanupFailures = await removeMCPCredentialsBestEffort(
      serverIDs: transaction.previousMCPServerIDs + importedMCPServerIDs
    )
    return summary
  }

  /// Restores the exact core workspace snapshots captured before `beginImportBackup`.
  /// Conversation restore can regenerate local IDs, so the returned mapping is the only
  /// authoritative bridge higher-level workspaces should use when restoring memberships.
  @discardableResult
  func rollbackImport(
    _ transaction: DataPortabilityImportTransaction
  ) async throws -> [ConversationID: ConversationID] {
    try await restoreCore(
      providers: transaction.previousProviders,
      conversations: transaction.previousConversations,
      mcp: transaction.previousMCP
    )
  }

  public func importProviderConfiguration(
    _ data: Data,
    strategy: ProviderImportStrategy
  ) async throws -> [ProviderAccountID] {
    let imported = try JSONDecoder.provider.decode(ProviderWorkspaceState.self, from: data)
    guard imported.schemaVersion == ProviderWorkspaceState.currentSchemaVersion else {
      throw ProviderError.workspaceVersionUnsupported(imported.schemaVersion)
    }
    try WorkspaceImportValidator.validateProviderWorkspace(imported)

    if case .replaceExisting = strategy {
      try WorkspaceImportValidator.validateConversationTargets(
        await conversations.allConversations(),
        accounts: imported.accounts
      )
    }

    let previousAccountIDs = await providers.allAccounts().map(\.id)
    try await providers.importConfiguration(data, strategy: strategy)

    guard case .replaceExisting = strategy else { return [] }
    let importedAccountIDs = await providers.allAccounts().map(\.id)
    return await accounts.removeCredentialsBestEffort(
      accountIDs: previousAccountIDs + importedAccountIDs
    )
  }

  public func exportConversationMarkdown(
    conversationID: ConversationID,
    accountLabel: String? = nil
  ) async throws -> Data {
    let conversation = try await conversations.conversation(id: conversationID)
    return Data(ConversationMarkdownFormatter.render(conversation, accountLabel: accountLabel).utf8)
  }

  private func restoreCore(
    providers previousProviders: Data,
    conversations previousConversations: Data,
    mcp previousMCP: Data?
  ) async throws -> [ConversationID: ConversationID] {
    try await providers.importConfiguration(previousProviders, strategy: .replaceExisting)
    let rollbackMapping = try await conversations.importWorkspace(
      previousConversations,
      strategy: .replaceExisting
    )
    if let mcp, let previousMCP {
      let previousMCPState = try JSONDecoder.provider.decode(MCPWorkspaceState.self, from: previousMCP)
      let remappedPreviousMCP = try remapMCPWorkspace(
        previousMCPState,
        conversationIDMapping: rollbackMapping
      )
      let remappedPreviousMCPData = try JSONEncoder.providerEncoder.encode(remappedPreviousMCP)
      try await mcp.importConfiguration(remappedPreviousMCPData, strategy: .replaceExisting)
    }
    return rollbackMapping
  }

  private func validateConversationTargets(
    in backup: BYOKchatBackup,
    strategy: ProviderImportStrategy
  ) async throws {
    let effectiveAccounts: [ProviderAccount]
    switch strategy {
    case .replaceExisting:
      effectiveAccounts = backup.providerWorkspace.accounts
    case .keepExisting:
      var values = Dictionary(
        uniqueKeysWithValues: await providers.allAccounts().map { ($0.id, $0) }
      )
      for account in backup.providerWorkspace.accounts where values[account.id] == nil {
        values[account.id] = account
      }
      effectiveAccounts = Array(values.values)
    }
    try WorkspaceImportValidator.validateConversationTargets(
      backup.conversationWorkspace.conversations,
      accounts: effectiveAccounts
    )
  }

  private func validateMCPConversationReferences(
    _ workspace: MCPWorkspaceState,
    conversations: [ChatConversation]
  ) throws {
    let conversationIDs = Set(conversations.map { $0.id.rawValue })
    let configuredConversationIDs = workspace.chatConfigurations.map { Array($0.keys) } ?? []
    for conversationID in configuredConversationIDs {
      guard conversationIDs.contains(conversationID) else {
        throw ProviderError.importConflict(
          "MCP tool settings reference conversation \(conversationID), which is not present in the backup."
        )
      }
    }
  }

  private func remapMCPWorkspace(
    _ workspace: MCPWorkspaceState,
    conversationIDMapping: [ConversationID: ConversationID]
  ) throws -> MCPWorkspaceState {
    var result = workspace
    guard let sourceConfigurations = workspace.chatConfigurations else { return result }

    var remapped: [String: MCPChatToolConfiguration] = [:]
    for (sourceIDValue, configuration) in sourceConfigurations {
      let sourceID = ConversationID(rawValue: sourceIDValue)
      guard let destinationID = conversationIDMapping[sourceID] else {
        throw ProviderError.importConflict(
          "MCP tool settings could not be mapped to restored conversation \(sourceIDValue)."
        )
      }
      if let existing = remapped[destinationID.rawValue], existing != configuration {
        throw ProviderError.importConflict(
          "Multiple imported MCP tool settings map to the same restored conversation."
        )
      }
      remapped[destinationID.rawValue] = configuration
    }
    result.chatConfigurations = remapped.isEmpty ? nil : remapped
    return result
  }

  private func removeMCPCredentialsBestEffort(serverIDs: [MCPServerID]) async -> [MCPServerID] {
    guard let mcpCredentials else { return [] }
    var failures: [MCPServerID] = []
    for serverID in Set(serverIDs) {
      do {
        try await mcpCredentials.removeCredential(serverID: serverID)
      } catch {
        failures.append(serverID)
      }
    }
    return failures.sorted { $0.rawValue < $1.rawValue }
  }
}

public enum ConversationMarkdownFormatter {
  public static func render(_ conversation: ChatConversation, accountLabel: String?) -> String {
    var lines: [String] = [
      "# \(conversation.title)",
      "",
      "- Exported: \(ISO8601DateFormatter().string(from: .now))",
      "- Provider: \(conversation.providerID.rawValue)",
      "- Account: \(accountLabel ?? conversation.accountID.rawValue)",
      "- Model: \(conversation.modelID.rawValue)",
    ]
    if !conversation.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      lines += ["", "## System Prompt", "", conversation.systemPrompt]
    }
    lines += ["", "## Conversation"]
    for message in conversation.messages {
      lines += ["", message.role == .user ? "### User" : "### Assistant", ""]
      if !message.reasoning.isEmpty {
        lines += [
          "<details>",
          "<summary>Reasoning</summary>",
          "",
          message.reasoning,
          "",
          "</details>",
          "",
        ]
      }
      lines.append(message.content.isEmpty ? "_No visible content_" : message.content)
      if message.status != .complete {
        lines += ["", "_Status: \(message.status.rawValue)_"]
      }
    }
    return lines.joined(separator: "\n") + "\n"
  }
}
