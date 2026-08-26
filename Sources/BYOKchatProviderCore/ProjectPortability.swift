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
        for project in await workspace.allProjects() {
          try await workspace.deleteProject(project.id)
        }
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
    for project in await workspace.allProjects() {
      try await workspace.deleteProject(project.id)
    }

    var projectMapping: [ProjectID: ProjectID] = [:]
    for source in imported.projects.sorted(by: Self.projectSort) {
      let created = try await create(source, name: source.name)
      projectMapping[source.id] = created.id
    }

    try await restoreMemberships(
      imported,
      projectIDMapping: projectMapping,
      conversationIDMapping: conversationIDMapping,
      preserveExistingAssignments: false
    )
    return ProjectImportResult(
      projectIDMapping: projectMapping,
      importedProjectCount: imported.projects.count
    )
  }

  private func merge(
    _ imported: ProjectWorkspaceState,
    conversationIDMapping: [ConversationID: ConversationID]
  ) async throws -> ProjectImportResult {
    var localProjects = await workspace.allProjects()
    var projectMapping: [ProjectID: ProjectID] = [:]

    for source in imported.projects.sorted(by: Self.projectSort) {
      if let local = localProjects.first(where: { $0.id == source.id })
        ?? localProjects.first(where: {
          $0.name.caseInsensitiveCompare(source.name) == .orderedSame
        })
      {
        if source.updatedAt > local.updatedAt {
          let updated = try await update(local.id, from: source, name: local.name)
          if let index = localProjects.firstIndex(where: { $0.id == local.id }) {
            localProjects[index] = updated
          }
        }
        projectMapping[source.id] = local.id
        continue
      }

      let name = Self.uniqueName(source.name, existing: localProjects.map(\.name))
      let created = try await create(source, name: name)
      localProjects.append(created)
      projectMapping[source.id] = created.id
    }

    try await restoreMemberships(
      imported,
      projectIDMapping: projectMapping,
      conversationIDMapping: conversationIDMapping,
      preserveExistingAssignments: true
    )
    return ProjectImportResult(
      projectIDMapping: projectMapping,
      importedProjectCount: imported.projects.count
    )
  }

  private func create(_ source: ChatProject, name: String) async throws -> ChatProject {
    try await workspace.createProject(
      name: name,
      symbolName: source.symbolName,
      accentID: source.accentID,
      accountID: source.accountID,
      modelID: source.modelID,
      instructions: source.instructions,
      files: source.projectFiles,
      mcpConfiguration: source.mcpConfiguration,
      promptPresets: source.projectPromptPresets,
      toolPresets: source.projectToolPresets,
      at: source.updatedAt
    )
  }

  private func update(
    _ localID: ProjectID,
    from source: ChatProject,
    name: String
  ) async throws -> ChatProject {
    try await workspace.updateProject(
      id: localID,
      name: name,
      symbolName: source.symbolName,
      accentID: source.accentID,
      accountID: source.accountID,
      modelID: source.modelID,
      instructions: source.instructions,
      files: source.projectFiles,
      mcpConfiguration: source.mcpConfiguration ?? MCPChatToolConfiguration(),
      promptPresets: source.projectPromptPresets,
      toolPresets: source.projectToolPresets,
      at: source.updatedAt
    )
  }

  private func restoreMemberships(
    _ imported: ProjectWorkspaceState,
    projectIDMapping: [ProjectID: ProjectID],
    conversationIDMapping: [ConversationID: ConversationID],
    preserveExistingAssignments: Bool
  ) async throws {
    for (sourceConversationValue, sourceProjectValue) in imported.conversationProjectIDs {
      let sourceConversationID = ConversationID(rawValue: sourceConversationValue)
      let sourceProjectID = ProjectID(rawValue: sourceProjectValue)
      guard let destinationConversationID = conversationIDMapping[sourceConversationID],
        let destinationProjectID = projectIDMapping[sourceProjectID]
      else {
        throw ProviderError.importConflict(
          "A project membership could not be mapped to its restored conversation."
        )
      }

      if preserveExistingAssignments,
        await workspace.projectID(for: destinationConversationID) != nil
      {
        continue
      }
      try await workspace.assignConversation(destinationConversationID, to: destinationProjectID)
    }
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
