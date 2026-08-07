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
    let backup = BYOKchatBackup(
      providerWorkspace: await providers.snapshot(),
      conversationWorkspace: await conversations.snapshot(),
      mcpWorkspace: await mcp?.snapshot(),
      preferences: .init(defaultSystemPrompt: defaultSystemPrompt)
    )
    return try JSONEncoder.providerEncoder.encode(backup)
  }

  public func importBackup(
    _ data: Data,
    strategy: ProviderImportStrategy
  ) async throws -> BYOKchatImportSummary {
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
    }
    try WorkspaceImportValidator.validateProviderWorkspace(backup.providerWorkspace)
    try WorkspaceImportValidator.validateConversationWorkspace(backup.conversationWorkspace)
    try await validateConversationTargets(in: backup, strategy: strategy)

    let previousProviders = try await providers.exportConfiguration()
    let previousConversations = try await conversations.exportWorkspace()
    let previousMCP = try await mcp?.exportConfiguration()
    let previousAccountIDs = await providers.allAccounts().map(\.id)
    let previousMCPServerIDs = await mcp?.allServers().map(\.id) ?? []

    do {
      let providerData = try JSONEncoder.providerEncoder.encode(backup.providerWorkspace)
      let conversationData = try JSONEncoder.providerEncoder.encode(backup.conversationWorkspace)
      try await providers.importConfiguration(providerData, strategy: strategy)
      try await conversations.importWorkspace(conversationData, strategy: strategy)
      if let mcp, let importedMCP = backup.mcpWorkspace {
        let mcpData = try JSONEncoder.providerEncoder.encode(importedMCP)
        try await mcp.importConfiguration(mcpData, strategy: strategy)
      } else if let mcp, case .replaceExisting = strategy {
        let empty = try JSONEncoder.providerEncoder.encode(MCPWorkspaceState())
        try await mcp.importConfiguration(empty, strategy: .replaceExisting)
      }
    } catch {
      try? await providers.importConfiguration(previousProviders, strategy: .replaceExisting)
      try? await conversations.importWorkspace(previousConversations, strategy: .replaceExisting)
      if let mcp, let previousMCP {
        try? await mcp.importConfiguration(previousMCP, strategy: .replaceExisting)
      }
      throw error
    }

    let cleanupFailures: [ProviderAccountID]
    let mcpCleanupFailures: [MCPServerID]
    if case .replaceExisting = strategy {
      let importedAccountIDs = await providers.allAccounts().map(\.id)
      cleanupFailures = await accounts.removeCredentialsBestEffort(
        accountIDs: previousAccountIDs + importedAccountIDs
      )
      let importedMCPServerIDs = await mcp?.allServers().map(\.id) ?? []
      mcpCleanupFailures = await removeMCPCredentialsBestEffort(
        serverIDs: previousMCPServerIDs + importedMCPServerIDs
      )
    } else {
      cleanupFailures = []
      mcpCleanupFailures = []
    }

    return BYOKchatImportSummary(
      providerCount: backup.providerWorkspace.customProviders.count,
      accountCount: backup.providerWorkspace.accounts.count,
      conversationCount: backup.conversationWorkspace.conversations.count,
      mcpServerCount: backup.mcpWorkspace?.servers.count ?? 0,
      defaultSystemPrompt: backup.preferences.defaultSystemPrompt,
      credentialCleanupFailures: cleanupFailures,
      mcpCredentialCleanupFailures: mcpCleanupFailures
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
