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
  public var preferences: BYOKchatBackupPreferences

  public init(
    schemaVersion: Int = Self.currentSchemaVersion,
    exportedAt: Date = .now,
    providerWorkspace: ProviderWorkspaceState,
    conversationWorkspace: ConversationWorkspaceState,
    preferences: BYOKchatBackupPreferences
  ) {
    self.schemaVersion = schemaVersion
    self.exportedAt = exportedAt
    self.providerWorkspace = providerWorkspace
    self.conversationWorkspace = conversationWorkspace
    self.preferences = preferences
  }
}

public struct BYOKchatImportSummary: Sendable, Equatable {
  public var providerCount: Int
  public var accountCount: Int
  public var conversationCount: Int
  public var defaultSystemPrompt: String

  public init(
    providerCount: Int,
    accountCount: Int,
    conversationCount: Int,
    defaultSystemPrompt: String
  ) {
    self.providerCount = providerCount
    self.accountCount = accountCount
    self.conversationCount = conversationCount
    self.defaultSystemPrompt = defaultSystemPrompt
  }
}

public actor DataPortabilityService {
  private let providers: ProviderWorkspaceStore
  private let conversations: ConversationStore
  private let accounts: ProviderAccountManager

  public init(
    providers: ProviderWorkspaceStore,
    conversations: ConversationStore,
    accounts: ProviderAccountManager
  ) {
    self.providers = providers
    self.conversations = conversations
    self.accounts = accounts
  }

  public func exportBackup(defaultSystemPrompt: String) async throws -> Data {
    let backup = BYOKchatBackup(
      providerWorkspace: await providers.snapshot(),
      conversationWorkspace: await conversations.snapshot(),
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
    try await validateConversationTargets(in: backup, strategy: strategy)

    let previousProviders = try await providers.exportConfiguration()
    let previousConversations = try await conversations.exportWorkspace()
    let previousAccountIDs = await providers.allAccounts().map(\.id)
    do {
      let providerData = try JSONEncoder.providerEncoder.encode(backup.providerWorkspace)
      let conversationData = try JSONEncoder.providerEncoder.encode(backup.conversationWorkspace)
      try await providers.importConfiguration(providerData, strategy: strategy)
      try await conversations.importWorkspace(conversationData, strategy: strategy)
      if case .replaceExisting = strategy {
        let importedAccountIDs = await providers.allAccounts().map(\.id)
        try await accounts.removeCredentials(
          accountIDs: previousAccountIDs + importedAccountIDs)
      }
    } catch {
      try? await providers.importConfiguration(previousProviders, strategy: .replaceExisting)
      try? await conversations.importWorkspace(previousConversations, strategy: .replaceExisting)
      throw error
    }

    return BYOKchatImportSummary(
      providerCount: backup.providerWorkspace.customProviders.count,
      accountCount: backup.providerWorkspace.accounts.count,
      conversationCount: backup.conversationWorkspace.conversations.count,
      defaultSystemPrompt: backup.preferences.defaultSystemPrompt
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
    let existingAccounts = await providers.allAccounts()
    var effectiveAccounts: [ProviderAccountID: ProviderAccount]
    switch strategy {
    case .replaceExisting:
      effectiveAccounts = Dictionary(
        uniqueKeysWithValues: backup.providerWorkspace.accounts.map { ($0.id, $0) })
    case .keepExisting:
      effectiveAccounts = Dictionary(uniqueKeysWithValues: existingAccounts.map { ($0.id, $0) })
      for account in backup.providerWorkspace.accounts where effectiveAccounts[account.id] == nil {
        effectiveAccounts[account.id] = account
      }
    }

    for conversation in backup.conversationWorkspace.conversations {
      guard let account = effectiveAccounts[conversation.accountID] else {
        throw ProviderError.importConflict(
          "Conversation \(conversation.title) references an unknown provider account."
        )
      }
      guard account.providerID == conversation.providerID else {
        throw ProviderError.importConflict(
          "Conversation \(conversation.title) does not match its provider account."
        )
      }
    }
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
