import Foundation

/// Backward-compatible full-backup envelope. `projectWorkspace` is optional so backups
/// written before Projects Phase 3 continue to decode as schema v1.
public struct ProjectAwareBYOKchatBackup: Codable, Sendable, Equatable {
  public var schemaVersion: Int
  public var exportedAt: Date
  public var providerWorkspace: ProviderWorkspaceState
  public var conversationWorkspace: ConversationWorkspaceState
  public var mcpWorkspace: MCPWorkspaceState?
  public var projectWorkspace: ProjectWorkspaceState?
  public var preferences: BYOKchatBackupPreferences

  public init(
    schemaVersion: Int = BYOKchatBackup.currentSchemaVersion,
    exportedAt: Date = .now,
    providerWorkspace: ProviderWorkspaceState,
    conversationWorkspace: ConversationWorkspaceState,
    mcpWorkspace: MCPWorkspaceState? = nil,
    projectWorkspace: ProjectWorkspaceState? = nil,
    preferences: BYOKchatBackupPreferences
  ) {
    self.schemaVersion = schemaVersion
    self.exportedAt = exportedAt
    self.providerWorkspace = providerWorkspace
    self.conversationWorkspace = conversationWorkspace
    self.mcpWorkspace = mcpWorkspace
    self.projectWorkspace = projectWorkspace
    self.preferences = preferences
  }
}

public actor ProjectAwareDataPortabilityService {
  private let base: DataPortabilityService
  private let projects: ProjectWorkspaceStore
  private let conversations: ConversationStore
  private let projectPortability: ProjectPortabilityService

  public init(
    base: DataPortabilityService,
    projects: ProjectWorkspaceStore,
    conversations: ConversationStore
  ) {
    self.base = base
    self.projects = projects
    self.conversations = conversations
    self.projectPortability = ProjectPortabilityService(workspace: projects)
  }

  public func exportBackup(defaultSystemPrompt: String) async throws -> Data {
    let baseData = try await base.exportBackup(defaultSystemPrompt: defaultSystemPrompt)
    let backup = try JSONDecoder.provider.decode(BYOKchatBackup.self, from: baseData)
    let extended = ProjectAwareBYOKchatBackup(
      schemaVersion: backup.schemaVersion,
      exportedAt: backup.exportedAt,
      providerWorkspace: backup.providerWorkspace,
      conversationWorkspace: backup.conversationWorkspace,
      mcpWorkspace: backup.mcpWorkspace,
      projectWorkspace: await projects.snapshot(),
      preferences: backup.preferences
    )
    return try JSONEncoder.providerEncoder.encode(extended)
  }

  public func importBackup(
    _ data: Data,
    strategy: ProviderImportStrategy
  ) async throws -> BYOKchatImportSummary {
    let extended = try JSONDecoder.provider.decode(ProjectAwareBYOKchatBackup.self, from: data)
    guard extended.schemaVersion == BYOKchatBackup.currentSchemaVersion else {
      throw ProviderError.backupVersionUnsupported(extended.schemaVersion)
    }

    if let projectWorkspace = extended.projectWorkspace {
      _ = try await ProjectPortabilityService.validatedState(projectWorkspace)
      try Self.validateProjectConversationReferences(
        projectWorkspace,
        conversations: extended.conversationWorkspace.conversations
      )
    }

    // The base importer remains the authority for providers, chats, MCP, credentials,
    // validation, and rollback. The project layer consumes its effective restored chats.
    let summary = try await base.importBackup(data, strategy: strategy)
    let mapping = try await conversationMapping(
      sources: extended.conversationWorkspace.conversations
    )

    _ = try await projectPortability.importWorkspace(
      extended.projectWorkspace,
      strategy: strategy,
      conversationIDMapping: mapping
    )
    return summary
  }

  public func importProviderConfiguration(
    _ data: Data,
    strategy: ProviderImportStrategy
  ) async throws -> [ProviderAccountID] {
    try await base.importProviderConfiguration(data, strategy: strategy)
  }

  public func exportConversationMarkdown(
    conversationID: ConversationID,
    accountLabel: String? = nil
  ) async throws -> Data {
    try await base.exportConversationMarkdown(
      conversationID: conversationID,
      accountLabel: accountLabel
    )
  }

  private func conversationMapping(
    sources: [ChatConversation]
  ) async throws -> [ConversationID: ConversationID] {
    let local = await conversations.snapshot().conversations
    var mapping: [ConversationID: ConversationID] = [:]
    var usedLocalIDs: Set<ConversationID> = []

    for source in sources {
      if let sameID = local.first(where: { $0.id == source.id }) {
        mapping[source.id] = sameID.id
        usedLocalIDs.insert(sameID.id)
        continue
      }

      let sourceFingerprint = try Self.portableFingerprint(source)
      let match = try local.first { candidate in
        guard !usedLocalIDs.contains(candidate.id) else { return false }
        return try Self.portableFingerprint(candidate) == sourceFingerprint
      }
      guard let match else {
        throw ProviderError.importConflict(
          "Restored conversation \(source.id.rawValue) could not be mapped back to its project."
        )
      }
      mapping[source.id] = match.id
      usedLocalIDs.insert(match.id)
    }
    return mapping
  }

  private static func validateProjectConversationReferences(
    _ workspace: ProjectWorkspaceState,
    conversations: [ChatConversation]
  ) throws {
    let conversationIDs = Set(conversations.map { $0.id.rawValue })
    for conversationID in workspace.conversationProjectIDs.keys {
      guard conversationIDs.contains(conversationID) else {
        throw ProviderError.importConflict(
          "Project settings reference conversation \(conversationID), which is not present in the backup."
        )
      }
    }
  }

  private static func portableFingerprint(_ conversation: ChatConversation) throws -> Data {
    try JSONEncoder.providerEncoder.encode(
      ProjectPortableConversationFingerprint(
        title: conversation.title,
        providerID: conversation.providerID,
        accountID: conversation.accountID,
        modelID: conversation.modelID,
        systemPrompt: conversation.systemPrompt,
        options: conversation.options,
        messages: conversation.messages.map(ProjectPortableMessageFingerprint.init),
        lastContextOmittedMessageCount: conversation.lastContextOmittedMessageCount,
        draftText: conversation.draftText
      )
    )
  }
}

private struct ProjectPortableConversationFingerprint: Encodable {
  var title: String
  var providerID: ProviderID
  var accountID: ProviderAccountID
  var modelID: ModelID
  var systemPrompt: String
  var options: ProviderRequestOptions
  var messages: [ProjectPortableMessageFingerprint]
  var lastContextOmittedMessageCount: Int
  var draftText: String?
}

private struct ProjectPortableMessageFingerprint: Encodable {
  var role: ChatMessageRole
  var content: String
  var reasoning: String
  var attachments: [ChatAttachment]?
  var toolRounds: [ChatToolRound]?
  var status: ChatMessageStatus
  var providerID: ProviderID?
  var accountID: ProviderAccountID?
  var modelID: ModelID?
  var finishReason: String?
  var usage: ProviderUsage?
  var metadata: [String: String]
  var errorCode: String?
  var errorDescription: String?
  var completionUncertain: Bool?

  init(_ message: ChatMessage) {
    role = message.role
    content = message.content
    reasoning = message.reasoning
    attachments = message.attachments
    toolRounds = message.toolRounds
    status = switch message.status {
    case .complete: .complete
    case .cancelled: .cancelled
    case .failed, .interrupted, .pending, .streaming: .failed
    }
    providerID = message.providerID
    accountID = message.accountID
    modelID = message.modelID
    finishReason = message.finishReason
    usage = message.usage
    metadata = message.metadata
    errorCode = message.errorCode
    errorDescription = message.errorDescription
    completionUncertain = message.completionUncertain
  }
}
