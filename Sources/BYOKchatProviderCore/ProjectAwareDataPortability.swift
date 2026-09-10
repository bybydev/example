import Foundation

/// Self-contained library entry for backups: metadata plus the byte payload,
/// so a single document restores on any device.
public struct PortableLibraryEntry: Codable, Sendable, Equatable {
  public var id: LibraryEntryID
  public var filename: String
  public var kind: ChatAttachmentKind
  public var mimeType: String
  public var createdAt: Date
  public var source: LibraryEntrySource
  public var data: Data

  public init(entry: LibraryEntry, data: Data) {
    id = entry.id
    filename = entry.filename
    kind = entry.kind
    mimeType = entry.mimeType
    createdAt = entry.createdAt
    source = entry.source
    self.data = data
  }
}

/// Backward-compatible full-backup envelope. `projectWorkspace` is optional so older
/// schema-v1 backups written before project data was added continue to decode.
/// `libraryEntries` is likewise optional for backups predating the library store.
public struct ProjectAwareBYOKchatBackup: Codable, Sendable, Equatable {
  public var schemaVersion: Int
  public var exportedAt: Date
  public var providerWorkspace: ProviderWorkspaceState
  public var conversationWorkspace: ConversationWorkspaceState
  public var mcpWorkspace: MCPWorkspaceState?
  public var projectWorkspace: ProjectWorkspaceState?
  public var libraryEntries: [PortableLibraryEntry]?
  public var preferences: BYOKchatBackupPreferences

  public init(
    schemaVersion: Int = BYOKchatBackup.currentSchemaVersion,
    exportedAt: Date = .now,
    providerWorkspace: ProviderWorkspaceState,
    conversationWorkspace: ConversationWorkspaceState,
    mcpWorkspace: MCPWorkspaceState? = nil,
    projectWorkspace: ProjectWorkspaceState? = nil,
    libraryEntries: [PortableLibraryEntry]? = nil,
    preferences: BYOKchatBackupPreferences
  ) {
    self.schemaVersion = schemaVersion
    self.exportedAt = exportedAt
    self.providerWorkspace = providerWorkspace
    self.conversationWorkspace = conversationWorkspace
    self.mcpWorkspace = mcpWorkspace
    self.projectWorkspace = projectWorkspace
    self.libraryEntries = libraryEntries
    self.preferences = preferences
  }
}

public actor ProjectAwareDataPortabilityService {
  private let base: DataPortabilityService
  private let projects: ProjectWorkspaceStore
  private let conversations: ConversationStore
  private let library: LibraryStore?
  private let projectPortability: ProjectPortabilityService

  public init(
    base: DataPortabilityService,
    projects: ProjectWorkspaceStore,
    conversations: ConversationStore,
    library: LibraryStore? = nil
  ) {
    self.base = base
    self.projects = projects
    self.conversations = conversations
    self.library = library
    self.projectPortability = ProjectPortabilityService(workspace: projects)
  }

  public func exportBackup(defaultSystemPrompt: String) async throws -> Data {
    let baseData = try await base.exportBackup(defaultSystemPrompt: defaultSystemPrompt)
    let backup = try JSONDecoder.provider.decode(BYOKchatBackup.self, from: baseData)

    var portableEntries: [PortableLibraryEntry]?
    if let library {
      portableEntries = await Self.portableLibraryEntries(from: library)
    }

    let extended = ProjectAwareBYOKchatBackup(
      schemaVersion: backup.schemaVersion,
      exportedAt: backup.exportedAt,
      providerWorkspace: backup.providerWorkspace,
      conversationWorkspace: backup.conversationWorkspace,
      mcpWorkspace: backup.mcpWorkspace,
      // Project runtime state is metadata-only. Use its dedicated export boundary so
      // reference-file bytes are hydrated into the portable document.
      projectWorkspace: await projectPortability.exportWorkspace(),
      libraryEntries: portableEntries,
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

    // Keep a self-contained Project snapshot for exact rollback. Project IDs matter and
    // Project reference files live in blobs, so a normal metadata snapshot is insufficient.
    let previousProjects = await projectPortability.exportWorkspace()

    // The core importer commits provider/chat/MCP workspace data but deliberately leaves
    // Keychain credentials untouched until Projects and Library have also committed.
    let transaction: DataPortabilityImportTransaction
    do {
      transaction = try await base.beginImportBackup(data, strategy: strategy)
    } catch let rolledBack as DataPortabilityRolledBackImportError {
      // Core rollback can recreate conversations with fresh local IDs. Even though Projects
      // were not part of the failed core import, their old conversation keys must therefore
      // be remapped through the exact rollback mapping before returning the failure.
      do {
        _ = try await projectPortability.importWorkspace(
          previousProjects,
          strategy: .replaceExisting,
          conversationIDMapping: rolledBack.conversationIDMapping
        )
      } catch let projectRollbackError {
        throw ProviderError.importConflict(
          "Full backup import failed: \(rolledBack.localizedDescription) Project rollback also failed: \(projectRollbackError.localizedDescription)"
        )
      }
      throw rolledBack
    }

    do {
      // Reuse the exact source -> effective local chat mapping produced by ConversationStore.
      // MCP and Projects must never independently guess which equivalent local chat won a merge.
      _ = try await projectPortability.importWorkspace(
        extended.projectWorkspace,
        strategy: strategy,
        conversationIDMapping: transaction.conversationIDMapping
      )

      if let library {
        // LibraryStore.restorePortableEntries is already a candidate-state transaction:
        // blobs land first and live metadata changes only after its one persistence commit.
        try await library.restorePortableEntries(
          extended.libraryEntries ?? [],
          strategy: strategy
        )
      }
    } catch let importError {
      do {
        let rollbackMapping = try await base.rollbackImport(transaction)
        _ = try await projectPortability.importWorkspace(
          previousProjects,
          strategy: .replaceExisting,
          conversationIDMapping: rollbackMapping
        )
      } catch let rollbackError {
        throw ProviderError.importConflict(
          "Full backup import failed: \(importError.localizedDescription) Rollback also failed: \(rollbackError.localizedDescription)"
        )
      }
      throw importError
    }

    // Only after every persistent workspace has committed do replace imports remove old/new
    // provider and MCP credentials. Cleanup failures are warnings, never data rollback triggers.
    return await base.commitImport(transaction)
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

  private static func portableLibraryEntries(from library: LibraryStore) async
    -> [PortableLibraryEntry]
  {
    var collected: [PortableLibraryEntry] = []
    for entry in await library.entries() {
      if let data = await library.data(for: entry), !data.isEmpty {
        collected.append(PortableLibraryEntry(entry: entry, data: data))
      }
    }
    return collected
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
}
