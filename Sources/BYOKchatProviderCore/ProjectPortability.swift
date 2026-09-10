import Foundation

public struct ProjectImportResult: Sendable, Equatable {
  public var projectIDMapping: [ProjectID: ProjectID]
  public var importedProjectCount: Int

  public init(
    projectIDMapping: [ProjectID: ProjectID] = [:],
    importedProjectCount: Int = 0
  ) {
    self.projectIDMapping = projectIDMapping
    self.importedProjectCount = importedProjectCount
  }
}

public actor ProjectPortabilityService {
  private let workspace: ProjectWorkspaceStore

  public init(workspace: ProjectWorkspaceStore) {
    self.workspace = workspace
  }

  public func exportWorkspace() async -> ProjectWorkspaceState {
    await workspace.exportSnapshot()
  }

  @discardableResult
  public func importWorkspace(
    _ imported: ProjectWorkspaceState?,
    strategy: ProviderImportStrategy,
    conversationIDMapping: [ConversationID: ConversationID]
  ) async throws -> ProjectImportResult {
    guard let imported else {
      if case .replaceExisting = strategy {
        try await workspace.replaceStateForImport(ProjectWorkspaceState())
      }
      return ProjectImportResult()
    }

    let sanitized = try await Self.validatedState(imported)
    try Self.validateConversationReferences(
      sanitized,
      conversationIDMapping: conversationIDMapping
    )

    switch strategy {
    case .replaceExisting:
      return try await replace(
        with: sanitized,
        conversationIDMapping: conversationIDMapping
      )
    case .keepExisting:
      return try await merge(
        sanitized,
        conversationIDMapping: conversationIDMapping
      )
    }
  }

  public static func validatedState(_ state: ProjectWorkspaceState) async throws
    -> ProjectWorkspaceState
  {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(state)
    let temporary = ProjectWorkspaceStore(
      persistence: InMemoryProjectWorkspacePersistence(data: data)
    )
    try await temporary.load()
    let result = await temporary.snapshot()

    var projectIDs: Set<ProjectID> = []
    var names: Set<String> = []
    for project in result.projects {
      guard projectIDs.insert(project.id).inserted else {
        throw ProviderError.importConflict(
          "The project workspace contains duplicate project IDs."
        )
      }
      let normalizedName = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !normalizedName.isEmpty else { throw ProjectWorkspaceError.invalidName }
      let folded = normalizedName.folding(
        options: [.caseInsensitive, .diacriticInsensitive],
        locale: .current
      )
      guard names.insert(folded).inserted else {
        throw ProjectWorkspaceError.duplicateName
      }
    }
    return result
  }

  private func replace(
    with imported: ProjectWorkspaceState,
    conversationIDMapping: [ConversationID: ConversationID]
  ) async throws -> ProjectImportResult {
    var candidate = imported
    candidate.conversationProjectIDs = try Self.remappedMemberships(
      imported.conversationProjectIDs,
      projectIDMapping: Dictionary(uniqueKeysWithValues: imported.projects.map { ($0.id, $0.id) }),
      conversationIDMapping: conversationIDMapping,
      preservingExisting: nil
    )

    // Preserve imported Project IDs and file payloads exactly. One store commit publishes
    // Projects plus memberships together; a persistence failure leaves live state untouched.
    try await workspace.replaceStateForImport(candidate)
    return ProjectImportResult(
      projectIDMapping: Dictionary(uniqueKeysWithValues: imported.projects.map { ($0.id, $0.id) }),
      importedProjectCount: imported.projects.count
    )
  }

  private func merge(
    _ imported: ProjectWorkspaceState,
    conversationIDMapping: [ConversationID: ConversationID]
  ) async throws -> ProjectImportResult {
    var candidate = await workspace.snapshot()
    var projectMapping: [ProjectID: ProjectID] = [:]

    for source in imported.projects.sorted(by: Self.projectSort) {
      if let localIndex = candidate.projects.firstIndex(where: { $0.id == source.id })
        ?? candidate.projects.firstIndex(where: {
          $0.name.caseInsensitiveCompare(source.name) == .orderedSame
        })
      {
        let local = candidate.projects[localIndex]
        if source.updatedAt > local.updatedAt {
          var updated = source
          // ID/name identity belong to the existing local Project when merging by name.
          updated.id = local.id
          updated.name = local.name
          candidate.projects[localIndex] = updated
        }
        projectMapping[source.id] = local.id
        continue
      }

      var created = source
      created.name = Self.uniqueName(source.name, existing: candidate.projects.map(\.name))
      candidate.projects.append(created)
      projectMapping[source.id] = created.id
    }

    candidate.conversationProjectIDs = try Self.remappedMemberships(
      imported.conversationProjectIDs,
      projectIDMapping: projectMapping,
      conversationIDMapping: conversationIDMapping,
      preservingExisting: candidate.conversationProjectIDs
    )

    // Imported Project payloads and memberships publish in one candidate-state commit.
    try await workspace.replaceStateForImport(candidate)
    return ProjectImportResult(
      projectIDMapping: projectMapping,
      importedProjectCount: imported.projects.count
    )
  }

  private static func remappedMemberships(
    _ sourceMemberships: [String: String],
    projectIDMapping: [ProjectID: ProjectID],
    conversationIDMapping: [ConversationID: ConversationID],
    preservingExisting existingMemberships: [String: String]?
  ) throws -> [String: String] {
    var result = existingMemberships ?? [:]
    for (sourceConversationValue, sourceProjectValue) in sourceMemberships {
      let sourceConversationID = ConversationID(rawValue: sourceConversationValue)
      let sourceProjectID = ProjectID(rawValue: sourceProjectValue)
      guard let destinationConversationID = conversationIDMapping[sourceConversationID],
        let destinationProjectID = projectIDMapping[sourceProjectID]
      else {
        throw ProviderError.importConflict(
          "A project membership could not be mapped to its restored conversation."
        )
      }

      if existingMemberships != nil, result[destinationConversationID.rawValue] != nil {
        continue
      }
      result[destinationConversationID.rawValue] = destinationProjectID.rawValue
    }
    return result
  }

  private static func validateConversationReferences(
    _ state: ProjectWorkspaceState,
    conversationIDMapping: [ConversationID: ConversationID]
  ) throws {
    let knownProjectIDs = Set(state.projects.map { $0.id.rawValue })
    for (conversationValue, projectValue) in state.conversationProjectIDs {
      guard knownProjectIDs.contains(projectValue) else {
        throw ProviderError.importConflict(
          "A project membership references a project that is not present in the backup."
        )
      }
      guard conversationIDMapping[ConversationID(rawValue: conversationValue)] != nil else {
        throw ProviderError.importConflict(
          "A project membership references conversation \(conversationValue), which is not present in the backup."
        )
      }
    }
  }

  private static func uniqueName(_ proposed: String, existing: [String]) -> String {
    guard !existing.contains(where: { $0.caseInsensitiveCompare(proposed) == .orderedSame }) else {
      var index = 2
      while true {
        let candidate = "\(proposed) (Imported \(index))"
        if !existing.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
          return candidate
        }
        index += 1
      }
    }
    return proposed
  }

  private static func projectSort(_ lhs: ChatProject, _ rhs: ChatProject) -> Bool {
    if lhs.createdAt == rhs.createdAt { return lhs.id.rawValue < rhs.id.rawValue }
    return lhs.createdAt < rhs.createdAt
  }
}
