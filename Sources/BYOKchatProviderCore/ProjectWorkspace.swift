import Foundation

public struct ProjectID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral,
  CustomStringConvertible
{
  public let rawValue: String

  public init(rawValue: String) { self.rawValue = rawValue }
  public init(stringLiteral value: String) { self.rawValue = value }
  public init() { self.rawValue = UUID().uuidString.lowercased() }
  public var description: String { rawValue }
}

public struct ProjectFile: Codable, Sendable, Equatable, Identifiable {
  public var id: String
  public var filename: String
  public var mimeType: String
  public var data: Data
  /// Blob size, persisted so size surfaces and validation stay correct while
  /// rows are metadata-only. Optional for backward compatibility.
  public var declaredByteCount: Int?
  public var createdAt: Date

  private enum CodingKeys: String, CodingKey {
    case id, filename, mimeType, data, declaredByteCount, createdAt
  }

  /// Decoding tolerates a missing `data` key (the persisted metadata-only
  /// shape); the store hydrates bytes from blob files on demand.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    filename = try container.decode(String.self, forKey: .filename)
    mimeType = try container.decode(String.self, forKey: .mimeType)
    data = try container.decodeIfPresent(Data.self, forKey: .data) ?? Data()
    declaredByteCount = try container.decodeIfPresent(Int.self, forKey: .declaredByteCount)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
  }

  /// Encoding emits `data` unless the encoder opted out via
  /// ``CodingUserInfoKey/byokEmbedsAttachmentData``.
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(filename, forKey: .filename)
    try container.encode(mimeType, forKey: .mimeType)
    let embedsData = encoder.userInfo[.byokEmbedsAttachmentData] as? Bool ?? true
    if embedsData {
      try container.encode(data, forKey: .data)
    }
    try container.encodeIfPresent(declaredByteCount, forKey: .declaredByteCount)
    try container.encode(createdAt, forKey: .createdAt)
  }

  public init(
    id: String = UUID().uuidString.lowercased(),
    filename: String,
    mimeType: String,
    data: Data,
    declaredByteCount: Int? = nil,
    createdAt: Date = .now
  ) {
    self.id = id
    self.filename = filename
    self.mimeType = mimeType
    self.data = data
    self.declaredByteCount = declaredByteCount
    self.createdAt = createdAt
  }

  /// Blob size: the persisted declaration when the row carries no bytes
  /// (metadata-only state), the in-memory count otherwise.
  public var byteCount: Int { data.isEmpty ? (declaredByteCount ?? 0) : data.count }

  public var attachment: ChatAttachment {
    ChatAttachment(
      id: id,
      kind: mimeType.lowercased().hasPrefix("image/") ? .image : .file,
      filename: filename,
      mimeType: mimeType,
      data: data
    )
  }
}

public struct ProjectPromptPreset: Codable, Sendable, Equatable, Identifiable {
  public var id: String
  public var name: String
  public var prompt: String

  public init(
    id: String = UUID().uuidString.lowercased(),
    name: String,
    prompt: String
  ) {
    self.id = id
    self.name = name
    self.prompt = prompt
  }
}

public struct ProjectToolPreset: Codable, Sendable, Equatable, Identifiable {
  public var id: String
  public var name: String
  public var configuration: MCPChatToolConfiguration

  public init(
    id: String = UUID().uuidString.lowercased(),
    name: String,
    configuration: MCPChatToolConfiguration
  ) {
    self.id = id
    self.name = name
    self.configuration = configuration
  }
}

public struct ChatProject: Codable, Sendable, Equatable, Identifiable {
  public var id: ProjectID
  public var name: String
  public var symbolName: String
  public var accentID: String
  public var accountID: ProviderAccountID?
  public var modelID: ModelID?
  public var instructions: String
  public var createdAt: Date
  public var updatedAt: Date

  // Optional fields preserve compatibility with older projects-v1.json files.
  public var files: [ProjectFile]?
  public var mcpConfiguration: MCPChatToolConfiguration?
  public var promptPresets: [ProjectPromptPreset]?
  public var toolPresets: [ProjectToolPreset]?

  public init(
    id: ProjectID = .init(),
    name: String,
    symbolName: String = "folder.fill",
    accentID: String = "blue",
    accountID: ProviderAccountID? = nil,
    modelID: ModelID? = nil,
    instructions: String = "",
    createdAt: Date = .now,
    updatedAt: Date = .now,
    files: [ProjectFile]? = nil,
    mcpConfiguration: MCPChatToolConfiguration? = nil,
    promptPresets: [ProjectPromptPreset]? = nil,
    toolPresets: [ProjectToolPreset]? = nil
  ) {
    self.id = id
    self.name = name
    self.symbolName = symbolName
    self.accentID = accentID
    self.accountID = accountID
    self.modelID = modelID
    self.instructions = instructions
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.files = files
    self.mcpConfiguration = mcpConfiguration
    self.promptPresets = promptPresets
    self.toolPresets = toolPresets
  }

  public var projectFiles: [ProjectFile] { files ?? [] }
  public var projectPromptPresets: [ProjectPromptPreset] { promptPresets ?? [] }
  public var projectToolPresets: [ProjectToolPreset] { toolPresets ?? [] }
}

public struct ProjectWorkspaceState: Codable, Sendable, Equatable {
  /// Single pre-release schema; evolves in place, users fresh-install.
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var projects: [ChatProject]
  public var conversationProjectIDs: [String: String]
  /// projectID → deletedAt. Pruned on load after the retention window.
  public var tombstones: [String: Date]

  public init(
    schemaVersion: Int = Self.currentSchemaVersion,
    projects: [ChatProject] = [],
    conversationProjectIDs: [String: String] = [:],
    tombstones: [String: Date] = [:]
  ) {
    self.schemaVersion = schemaVersion
    self.projects = projects
    self.conversationProjectIDs = conversationProjectIDs
    self.tombstones = tombstones
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, projects, conversationProjectIDs, tombstones
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
      ?? Self.currentSchemaVersion
    projects = try container.decodeIfPresent([ChatProject].self, forKey: .projects) ?? []
    conversationProjectIDs = try container.decodeIfPresent(
      [String: String].self,
      forKey: .conversationProjectIDs
    ) ?? [:]
    tombstones = try container.decodeIfPresent([String: Date].self, forKey: .tombstones) ?? [:]
  }
}

public protocol ProjectWorkspacePersistence: Sendable {
  func loadData() async throws -> Data?
  func saveData(_ data: Data) async throws

  /// Preserves unreadable stored data by moving it aside so future saves cannot overwrite it.
  /// Returns `false` when there is nothing to quarantine.
  func quarantineData() async throws -> Bool
}

public actor InMemoryProjectWorkspacePersistence: ProjectWorkspacePersistence {
  private var data: Data?

  public init(data: Data? = nil) { self.data = data }
  public func loadData() -> Data? { data }
  public func saveData(_ data: Data) { self.data = data }
  public func quarantineData() -> Bool {
    guard data != nil else { return false }
    data = nil
    return true
  }
}

public actor JSONFileProjectWorkspacePersistence: ProjectWorkspacePersistence {
  public let fileURL: URL

  public init(fileURL: URL) { self.fileURL = fileURL }

  public func loadData() throws -> Data? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    return try Data(contentsOf: fileURL)
  }

  public func saveData(_ data: Data) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: fileURL, options: [.atomic])
  }

  public func quarantineData() throws -> Bool {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return false }
    let quarantineURL = fileURL.appendingPathExtension("corrupt")
    if FileManager.default.fileExists(atPath: quarantineURL.path) {
      try FileManager.default.removeItem(at: quarantineURL)
    }
    try FileManager.default.moveItem(at: fileURL, to: quarantineURL)
    return true
  }
}

public enum ProjectWorkspaceError: LocalizedError, Sendable, Equatable {
  case unsupportedVersion(Int)
  case projectNotFound(ProjectID)
  case invalidName
  case nameTooLong
  case duplicateName
  case tooManyFiles
  case emptyFile(String)
  case duplicateFileID
  case fileTooLarge(String)
  case filesTooLarge
  case invalidPresetName
  case presetNameTooLong
  case tooManyPresets
  case duplicatePresetName
  case loadFailurePreserved
  case writesBlockedAfterLoadFailure

  public var errorDescription: String? {
    switch self {
    case .unsupportedVersion(let version):
      "Project workspace version \(version) is not supported."
    case .projectNotFound:
      "The project could not be found."
    case .invalidName:
      "Enter a project name."
    case .nameTooLong:
      "Project names must be \(ProjectWorkspaceStore.maxNameLength) characters or fewer."
    case .duplicateName:
      "A project with this name already exists."
    case .tooManyFiles:
      "A project can contain at most \(ProjectWorkspaceStore.maxFileCount) reference files."
    case .emptyFile(let filename):
      "\(filename) is empty and cannot be added to a project."
    case .duplicateFileID:
      "Duplicate reference files cannot be saved in the same project."
    case .fileTooLarge(let filename):
      "\(filename) is larger than 20 MB."
    case .filesTooLarge:
      "Project reference files cannot exceed 40 MB total."
    case .invalidPresetName:
      "Enter a preset name."
    case .presetNameTooLong:
      "Preset names must be \(ProjectWorkspaceStore.maxPresetNameLength) characters or fewer."
    case .tooManyPresets:
      "A project can contain at most \(ProjectWorkspaceStore.maxPresetCount) presets."
    case .duplicatePresetName:
      "Preset names must be unique within a project."
    case .loadFailurePreserved:
      "Projects could not be loaded because their stored file was unreadable. The file was preserved with a '.corrupt' extension; new projects will start fresh."
    case .writesBlockedAfterLoadFailure:
      "Project changes are blocked because the projects file could not be read. Fix or remove that file, then restart the app."
    }
  }
}

public actor ProjectWorkspaceStore {
  public static let maxNameLength = 80
  public static let maxFileCount = 8
  public static let maxFileBytes = 20 * 1_024 * 1_024
  public static let maxTotalFileBytes = 40 * 1_024 * 1_024
  public static let maxPresetCount = 24
  public static let maxPresetNameLength = 60

  private var state = ProjectWorkspaceState()
  private let persistence: any ProjectWorkspacePersistence
  /// Reference-file bytes rest here; the JSON carries metadata only.
  private let blobs: any AttachmentBlobStoring
  private var hasLoaded = false
  private var blocksWritesAfterFailedLoad = false

  /// Actor methods are reentrant while persistence is awaiting I/O. Keep all
  /// mutations in a FIFO transaction so two overlapping saves cannot commit
  /// candidates derived from the same old state and lose one another.
  private var mutationInProgress = false
  private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

  public init(
    persistence: any ProjectWorkspacePersistence,
    blobs: any AttachmentBlobStoring = InMemoryAttachmentBlobStore()
  ) {
    self.persistence = persistence
    self.blobs = blobs
  }

  public func load() async throws {
    guard !hasLoaded else { return }
    defer { hasLoaded = true }
    guard let data = try await persistence.loadData() else { return }

    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let decoded = try decoder.decode(ProjectWorkspaceState.self, from: data)
      guard decoded.schemaVersion == ProjectWorkspaceState.currentSchemaVersion else {
        // Leave newer-schema files intact on disk and block writes instead of
        // renaming them to .corrupt.
        blocksWritesAfterFailedLoad = true
        throw ProjectWorkspaceError.unsupportedVersion(decoded.schemaVersion)
      }
      var validated = try Self.sanitized(decoded, allowUnbackfilledMetadata: true)
      validated.tombstones = SyncTombstonePolicy.pruned(validated.tombstones)
      state = validated
      await backfillFileByteCounts()
    } catch let error as ProjectWorkspaceError {
      if case .unsupportedVersion = error {
        throw error
      }
      let quarantined = (try? await persistence.quarantineData()) ?? false
      blocksWritesAfterFailedLoad = !quarantined
      throw ProjectWorkspaceError.loadFailurePreserved
    } catch {
      // Preserve the unreadable file so a later save cannot replace it with empty state.
      // When it cannot be moved aside, block all writes outright.
      let quarantined = (try? await persistence.quarantineData()) ?? false
      blocksWritesAfterFailedLoad = !quarantined
      throw ProjectWorkspaceError.loadFailurePreserved
    }
  }

  public func snapshot() -> ProjectWorkspaceState { state }

  public func allProjects() -> [ChatProject] {
    state.projects.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  public func project(id: ProjectID) throws -> ChatProject {
    guard let value = state.projects.first(where: { $0.id == id }) else {
      throw ProjectWorkspaceError.projectNotFound(id)
    }
    return value
  }

  public func projectID(for conversationID: ConversationID) -> ProjectID? {
    guard let value = state.conversationProjectIDs[conversationID.rawValue] else { return nil }
    return ProjectID(rawValue: value)
  }

  public func project(for conversationID: ConversationID) -> ChatProject? {
    guard let projectID = projectID(for: conversationID) else { return nil }
    return state.projects.first { $0.id == projectID }
  }

  public func files(for conversationID: ConversationID) -> [ProjectFile] {
    project(for: conversationID)?.projectFiles ?? []
  }

  public func mcpConfiguration(for conversationID: ConversationID) -> MCPChatToolConfiguration? {
    project(for: conversationID)?.mcpConfiguration
  }

  public func promptPresets(for conversationID: ConversationID) -> [ProjectPromptPreset] {
    project(for: conversationID)?.projectPromptPresets ?? []
  }

  public func toolPresets(for conversationID: ConversationID) -> [ProjectToolPreset] {
    project(for: conversationID)?.projectToolPresets ?? []
  }

  @discardableResult
  public func createProject(
    name: String,
    symbolName: String,
    accentID: String,
    accountID: ProviderAccountID?,
    modelID: ModelID?,
    instructions: String,
    files: [ProjectFile] = [],
    mcpConfiguration: MCPChatToolConfiguration? = nil,
    promptPresets: [ProjectPromptPreset] = [],
    toolPresets: [ProjectToolPreset] = [],
    at date: Date = .now
  ) async throws -> ChatProject {
    await beginMutation()
    defer { endMutation() }

    var candidate = state
    let normalizedName = try Self.validatedName(
      name,
      excluding: nil,
      projects: candidate.projects
    )
    try Self.validateFiles(files)
    let normalizedPrompts = try Self.validatedPromptPresets(promptPresets)
    let normalizedTools = try Self.validatedToolPresets(toolPresets)
    let project = ChatProject(
      name: normalizedName,
      symbolName: symbolName.isEmpty ? "folder.fill" : symbolName,
      accentID: accentID.isEmpty ? "blue" : accentID,
      accountID: accountID,
      modelID: accountID == nil ? nil : modelID,
      instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines),
      createdAt: date,
      updatedAt: date,
      files: files.isEmpty ? nil : files,
      mcpConfiguration: mcpConfiguration,
      promptPresets: normalizedPrompts.isEmpty ? nil : normalizedPrompts,
      toolPresets: normalizedTools.isEmpty ? nil : normalizedTools
    )
    candidate.projects.append(project)

    let committed = try await committedState(candidate, mutatingProject: project.id)
    state = committed
    return committed.projects.last(where: { $0.id == project.id }) ?? project
  }

  @discardableResult
  public func updateProject(
    id: ProjectID,
    name: String,
    symbolName: String,
    accentID: String,
    accountID: ProviderAccountID?,
    modelID: ModelID?,
    instructions: String,
    files: [ProjectFile]? = nil,
    mcpConfiguration: MCPChatToolConfiguration? = nil,
    clearMCPConfiguration: Bool = false,
    promptPresets: [ProjectPromptPreset]? = nil,
    toolPresets: [ProjectToolPreset]? = nil,
    at date: Date = .now
  ) async throws -> ChatProject {
    try await mutateProject(id: id, at: date, offloadFiles: files != nil) { project, projects in
      project.name = try Self.validatedName(name, excluding: id, projects: projects)
      project.symbolName = symbolName.isEmpty ? "folder.fill" : symbolName
      project.accentID = accentID.isEmpty ? "blue" : accentID
      project.accountID = accountID
      project.modelID = accountID == nil ? nil : modelID
      project.instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)

      if let files {
        try Self.validateFiles(files)
        project.files = files.isEmpty ? nil : files
      }
      if clearMCPConfiguration {
        project.mcpConfiguration = nil
      } else if let mcpConfiguration {
        project.mcpConfiguration = mcpConfiguration
      }
      if let promptPresets {
        let normalized = try Self.validatedPromptPresets(promptPresets)
        project.promptPresets = normalized.isEmpty ? nil : normalized
      }
      if let toolPresets {
        let normalized = try Self.validatedToolPresets(toolPresets)
        project.toolPresets = normalized.isEmpty ? nil : normalized
      }
    }
  }

  @discardableResult
  public func updateProjectIdentity(
    id: ProjectID,
    name: String,
    symbolName: String,
    accentID: String,
    at date: Date = .now
  ) async throws -> ChatProject {
    try await mutateProject(id: id, at: date) { project, projects in
      project.name = try Self.validatedName(name, excluding: id, projects: projects)
      project.symbolName = symbolName.isEmpty ? "folder.fill" : symbolName
      project.accentID = accentID.isEmpty ? "blue" : accentID
    }
  }

  @discardableResult
  public func updateProjectDefaults(
    id: ProjectID,
    accountID: ProviderAccountID?,
    modelID: ModelID?,
    at date: Date = .now
  ) async throws -> ChatProject {
    try await mutateProject(id: id, at: date) { project, _ in
      project.accountID = accountID
      project.modelID = accountID == nil ? nil : modelID
    }
  }

  @discardableResult
  public func updateProjectInstructions(
    id: ProjectID,
    instructions: String,
    at date: Date = .now
  ) async throws -> ChatProject {
    try await mutateProject(id: id, at: date) { project, _ in
      project.instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  @discardableResult
  public func addProjectFiles(
    _ additions: [ProjectFile],
    to id: ProjectID,
    at date: Date = .now
  ) async throws -> ChatProject {
    try await mutateProject(id: id, at: date, offloadFiles: true) { project, _ in
      let files = project.projectFiles + additions
      try Self.validateFiles(files)
      project.files = files.isEmpty ? nil : files
    }
  }

  @discardableResult
  public func removeProjectFile(
    _ fileID: String,
    from id: ProjectID,
    at date: Date = .now
  ) async throws -> ChatProject {
    try await mutateProject(id: id, at: date) { project, _ in
      let files = project.projectFiles.filter { $0.id != fileID }
      project.files = files.isEmpty ? nil : files
    }
  }

  @discardableResult
  public func upsertProjectPromptPreset(
    _ preset: ProjectPromptPreset,
    projectID: ProjectID,
    at date: Date = .now
  ) async throws -> ChatProject {
    try await mutateProject(id: projectID, at: date) { project, _ in
      var presets = project.projectPromptPresets
      if let index = presets.firstIndex(where: { $0.id == preset.id }) {
        presets[index] = preset
      } else {
        presets.append(preset)
      }
      let normalized = try Self.validatedPromptPresets(presets)
      project.promptPresets = normalized.isEmpty ? nil : normalized
    }
  }

  @discardableResult
  public func deleteProjectPromptPreset(
    _ presetID: String,
    projectID: ProjectID,
    at date: Date = .now
  ) async throws -> ChatProject {
    try await mutateProject(id: projectID, at: date) { project, _ in
      let presets = project.projectPromptPresets.filter { $0.id != presetID }
      project.promptPresets = presets.isEmpty ? nil : presets
    }
  }

  @discardableResult
  public func replaceProjectToolSettings(
    id: ProjectID,
    mcpConfiguration: MCPChatToolConfiguration?,
    toolPresets: [ProjectToolPreset],
    at date: Date = .now
  ) async throws -> ChatProject {
    try await mutateProject(id: id, at: date) { project, _ in
      let normalized = try Self.validatedToolPresets(toolPresets)
      project.mcpConfiguration = mcpConfiguration
      project.toolPresets = normalized.isEmpty ? nil : normalized
    }
  }

  /// Remove a deleted MCP server from every default/preset in one transaction.
  /// Preserve optional/empty configuration semantics and all unrelated fields.
  public func removeMCPServerReferences(
    _ serverID: MCPServerID,
    knownServerIDs: [MCPServerID]
  ) async throws {
    await beginMutation()
    defer { endMutation() }

    var candidate = state
    let configurations = candidate.projects.flatMap { project in
      [project.mcpConfiguration].compactMap { $0 }
        + project.projectToolPresets.map(\.configuration)
    }
    let knownIDs = Set(knownServerIDs).union(configurations.flatMap(\.enabledServerIDs))
    for index in candidate.projects.indices {
      let original = candidate.projects[index]
      if let configuration = original.mcpConfiguration {
        candidate.projects[index].mcpConfiguration = try MCPToolNamespace.removingServerReferences(
          serverID, from: configuration, knownServerIDs: knownIDs
        )
      }
      if var presets = original.toolPresets {
        for presetIndex in presets.indices {
          presets[presetIndex].configuration = try MCPToolNamespace.removingServerReferences(
            serverID, from: presets[presetIndex].configuration, knownServerIDs: knownIDs
          )
        }
        candidate.projects[index].toolPresets = presets
      }
      if candidate.projects[index] != original { candidate.projects[index].updatedAt = .now }
    }
    guard candidate != state else { return }
    state = try await committedState(candidate)
  }

  public func deleteProject(_ id: ProjectID) async throws {
    await beginMutation()
    defer { endMutation() }

    guard state.projects.contains(where: { $0.id == id }) else { return }
    var candidate = state
    candidate.projects.removeAll { $0.id == id }
    candidate.conversationProjectIDs = candidate.conversationProjectIDs.filter {
      $0.value != id.rawValue
    }
    candidate.tombstones[id.rawValue] = .now

    state = try await committedState(candidate)
    // Orphaned file blobs are swept by the app-level sweepOrphanFiles.
  }

  public func assignConversation(_ conversationID: ConversationID, to projectID: ProjectID?) async throws {
    await beginMutation()
    defer { endMutation() }

    var candidate = state
    if let projectID {
      guard candidate.projects.contains(where: { $0.id == projectID }) else {
        throw ProjectWorkspaceError.projectNotFound(projectID)
      }
      candidate.conversationProjectIDs[conversationID.rawValue] = projectID.rawValue
    } else {
      candidate.conversationProjectIDs.removeValue(forKey: conversationID.rawValue)
    }
    state = try await committedState(candidate)
  }

  public func removeConversation(_ conversationID: ConversationID) async throws {
    await beginMutation()
    defer { endMutation() }

    var candidate = state
    guard candidate.conversationProjectIDs.removeValue(forKey: conversationID.rawValue) != nil else {
      return
    }
    state = try await committedState(candidate)
  }

  public func reconcileConversationIDs(_ validIDs: Set<ConversationID>) async throws {
    await beginMutation()
    defer { endMutation() }

    let validRawIDs = Set(validIDs.map(\.rawValue))
    var candidate = state
    let before = candidate.conversationProjectIDs.count
    candidate.conversationProjectIDs = candidate.conversationProjectIDs.filter {
      validRawIDs.contains($0.key)
    }
    guard candidate.conversationProjectIDs.count != before else { return }
    state = try await committedState(candidate)
  }

  private func mutateProject(
    id: ProjectID,
    at date: Date,
    offloadFiles: Bool = false,
    _ mutation: (inout ChatProject, [ChatProject]) throws -> Void
  ) async throws -> ChatProject {
    await beginMutation()
    defer { endMutation() }

    var candidate = state
    guard let index = candidate.projects.firstIndex(where: { $0.id == id }) else {
      throw ProjectWorkspaceError.projectNotFound(id)
    }

    let projectsBeforeMutation = candidate.projects
    try mutation(&candidate.projects[index], projectsBeforeMutation)
    candidate.projects[index].updatedAt = date

    let committed = try await committedState(
      candidate,
      mutatingProject: offloadFiles ? id : nil
    )
    state = committed
    return committed.projects[index]
  }

  private func beginMutation() async {
    if !mutationInProgress {
      mutationInProgress = true
      return
    }

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      mutationWaiters.append(continuation)
    }
  }

  private func endMutation() {
    guard !mutationWaiters.isEmpty else {
      mutationInProgress = false
      return
    }
    mutationWaiters.removeFirst().resume()
  }

  private static func validatedName(
    _ name: String,
    excluding id: ProjectID?,
    projects: [ChatProject]
  ) throws -> String {
    let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { throw ProjectWorkspaceError.invalidName }
    guard normalized.count <= Self.maxNameLength else { throw ProjectWorkspaceError.nameTooLong }
    guard !projects.contains(where: {
      $0.id != id && $0.name.caseInsensitiveCompare(normalized) == .orderedSame
    }) else {
      throw ProjectWorkspaceError.duplicateName
    }
    return normalized
  }

  // MARK: - File-blob persistence

  /// Reference-file bytes rest in blob files; persisted JSON carries metadata
  /// only. Blobs land before the JSON for the same crash-ordering reason as
  /// ConversationStore.persist.

  /// Rows are metadata-only in memory; sizes shown by the editor and by
  /// validation come from `declaredByteCount`. Projects saved before that
  /// field existed are repaired here from the blob store's index. Best-effort:
  /// an unavailable index leaves rows as-is. Rows stay byte-free — previews
  /// fetch on demand through `fileData`.
  private func backfillFileByteCounts() async {
    var missingIDs: Set<String> = []
    for project in state.projects {
      for file in project.projectFiles where file.declaredByteCount == nil && file.data.isEmpty {
        missingIDs.insert(file.id)
      }
    }
    guard !missingIDs.isEmpty else { return }

    var byteCountByID: [String: Int] = [:]
    for id in missingIDs {
      if let metadata = try? await blobs.metadata(for: id), metadata.byteCount > 0 {
        byteCountByID[id] = metadata.byteCount
      }
    }

    var changed = false
    for projectIndex in state.projects.indices {
      guard let files = state.projects[projectIndex].files, !files.isEmpty else { continue }
      var repaired = files
      for fileIndex in repaired.indices where repaired[fileIndex].declaredByteCount == nil {
        if !repaired[fileIndex].data.isEmpty {
          repaired[fileIndex].declaredByteCount = repaired[fileIndex].data.count
        } else if let byteCount = byteCountByID[repaired[fileIndex].id] {
          repaired[fileIndex].declaredByteCount = byteCount
        } else {
          continue
        }
        changed = true
      }
      state.projects[projectIndex].files = repaired
    }
    if changed {
      // Repairs must reach disk or every launch repeats the backfill.
      try? await persistCurrentJSON()
    }
  }

  /// Pass-through byte access for surfaces that need the original on demand
  /// (previews, attach-to-composer, QuickLook). nil when the blob is missing.
  public func fileData(_ id: String) async -> Data? {
    guard !id.isEmpty else { return nil }
    return (try? await blobs.loadData(id)) ?? nil
  }

  /// Reference-file IDs currently pointed at, for the app-level blob GC.
  public func referencedFileIDs() -> Set<String> {
    Set(state.projects.flatMap { $0.projectFiles.map(\.id) })
  }

  /// Snapshot for backups: fetches each reference file's bytes from disk at
  /// export time so backups stay self-contained. Files whose bytes are gone
  /// are left out.
  public func exportSnapshot() async -> ProjectWorkspaceState {
    var exported = state
    for projectIndex in exported.projects.indices {
      guard let files = exported.projects[projectIndex].files, !files.isEmpty else { continue }
      var kept: [ProjectFile] = []
      kept.reserveCapacity(files.count)
      for var file in files {
        if file.data.isEmpty {
          file.data = (try? await blobs.loadData(file.id)) ?? Data()
        }
        if !file.data.isEmpty { kept.append(file) }
      }
      exported.projects[projectIndex].files = kept.isEmpty ? nil : kept
    }
    return exported
  }

  /// Portability-only atomic state replacement. The caller validates and builds the
  /// complete candidate first; every imported reference-file payload is offloaded before
  /// one JSON commit, and live state changes only after that commit succeeds.
  func replaceStateForImport(_ imported: ProjectWorkspaceState) async throws {
    await beginMutation()
    defer { endMutation() }

    guard imported.schemaVersion == ProjectWorkspaceState.currentSchemaVersion else {
      throw ProjectWorkspaceError.unsupportedVersion(imported.schemaVersion)
    }
    var candidate = try Self.sanitized(imported, allowUnbackfilledMetadata: true)
    candidate.tombstones = SyncTombstonePolicy.pruned(candidate.tombstones)
    for projectID in candidate.projects.map(\.id) {
      candidate = try await stateByOffloadingFileBlobs(projectID: projectID, in: candidate)
    }
    state = try await committedState(candidate)
  }

  private func committedState(
    _ candidate: ProjectWorkspaceState,
    mutatingProject projectID: ProjectID? = nil
  ) async throws -> ProjectWorkspaceState {
    guard !blocksWritesAfterFailedLoad else {
      throw ProjectWorkspaceError.writesBlockedAfterLoadFailure
    }

    var prepared = candidate
    if let projectID {
      prepared = try await stateByOffloadingFileBlobs(projectID: projectID, in: prepared)
    }
    try await persistence.saveData(Self.metadataEncoder().encode(prepared))
    return prepared
  }

  /// Writes any not-yet-stored payloads of one candidate project's files to
  /// blobs and returns a metadata-only candidate. The actor's committed state
  /// is untouched until the JSON save succeeds.
  private func stateByOffloadingFileBlobs(
    projectID: ProjectID,
    in candidate: ProjectWorkspaceState
  ) async throws -> ProjectWorkspaceState {
    var result = candidate
    guard let projectIndex = result.projects.firstIndex(where: { $0.id == projectID }),
      var files = result.projects[projectIndex].files
    else { return result }

    for fileIndex in files.indices {
      let file = files[fileIndex]
      guard !file.data.isEmpty else { continue }
      try await blobs.writeIfAbsent(
        file.id,
        data: file.data,
        metadata: AttachmentBlobMetadata(
          filename: file.filename,
          mimeType: file.mimeType,
          byteCount: file.data.count,
          createdAt: file.createdAt
        )
      )
      files[fileIndex].data = Data()
      if files[fileIndex].declaredByteCount == nil {
        files[fileIndex].declaredByteCount = file.data.count
      }
    }
    result.projects[projectIndex].files = files.isEmpty ? nil : files
    return result
  }

  private func persistCurrentJSON() async throws {
    guard !blocksWritesAfterFailedLoad else {
      throw ProjectWorkspaceError.writesBlockedAfterLoadFailure
    }
    try await persistence.saveData(Self.metadataEncoder().encode(state))
  }

  private static func metadataEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.userInfo[.byokEmbedsAttachmentData] = false
    return encoder
  }

  /// Validates an imported backup workspace without routing through `load()`
  /// (so specific schema/validation errors are preserved rather than masked as
  /// local file corruption).
  static func validatedForImport(_ value: ProjectWorkspaceState) throws -> ProjectWorkspaceState {
    guard value.schemaVersion == ProjectWorkspaceState.currentSchemaVersion else {
      throw ProjectWorkspaceError.unsupportedVersion(value.schemaVersion)
    }
    var result = try sanitized(value, allowUnbackfilledMetadata: false)
    result.tombstones = SyncTombstonePolicy.pruned(result.tombstones)

    var projectIDs: Set<ProjectID> = []
    var validatedProjects: [ChatProject] = []
    validatedProjects.reserveCapacity(result.projects.count)
    for var project in result.projects {
      guard projectIDs.insert(project.id).inserted else {
        throw ProviderError.importConflict(
          "The project workspace contains duplicate project IDs."
        )
      }
      project.name = try validatedName(
        project.name,
        excluding: nil,
        projects: validatedProjects
      )
      validatedProjects.append(project)
    }
    result.projects = validatedProjects
    return result
  }

  private static func sanitized(
    _ value: ProjectWorkspaceState,
    allowUnbackfilledMetadata: Bool = false
  ) throws -> ProjectWorkspaceState {
    var result = value
    let validProjectIDs = Set(result.projects.map { $0.id.rawValue })
    result.conversationProjectIDs = result.conversationProjectIDs.filter {
      validProjectIDs.contains($0.value)
    }
    for index in result.projects.indices {
      let files = result.projects[index].projectFiles
      try validateFiles(files, allowUnbackfilledMetadata: allowUnbackfilledMetadata)
      result.projects[index].files = files.isEmpty ? nil : files
      let prompts = try validatedPromptPresets(result.projects[index].projectPromptPresets)
      result.projects[index].promptPresets = prompts.isEmpty ? nil : prompts
      let tools = try validatedToolPresets(result.projects[index].projectToolPresets)
      result.projects[index].toolPresets = tools.isEmpty ? nil : tools
    }
    return result
  }

  private static func validateFiles(
    _ files: [ProjectFile],
    allowUnbackfilledMetadata: Bool = false
  ) throws {
    guard files.count <= Self.maxFileCount else { throw ProjectWorkspaceError.tooManyFiles }
    var total = 0
    var ids: Set<String> = []
    for file in files {
      guard ids.insert(file.id).inserted else { throw ProjectWorkspaceError.duplicateFileID }
      let isUnbackfilledLegacyRow = allowUnbackfilledMetadata
        && file.data.isEmpty
        && file.declaredByteCount == nil
      if !isUnbackfilledLegacyRow {
        guard file.byteCount > 0 else {
          throw ProjectWorkspaceError.emptyFile(file.filename)
        }
      }
      guard file.byteCount <= Self.maxFileBytes else {
        throw ProjectWorkspaceError.fileTooLarge(file.filename)
      }
      total += file.byteCount
    }
    guard total <= Self.maxTotalFileBytes else { throw ProjectWorkspaceError.filesTooLarge }
  }

  private static func validatedPromptPresets(_ presets: [ProjectPromptPreset]) throws
    -> [ProjectPromptPreset]
  {
    guard presets.count <= Self.maxPresetCount else { throw ProjectWorkspaceError.tooManyPresets }
    var names: Set<String> = []
    return try presets.map { preset in
      var value = preset
      value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
      value.prompt = value.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.name.isEmpty, !value.prompt.isEmpty else {
        throw ProjectWorkspaceError.invalidPresetName
      }
      guard value.name.count <= Self.maxPresetNameLength else {
        throw ProjectWorkspaceError.presetNameTooLong
      }
      let key = value.name.lowercased()
      guard names.insert(key).inserted else { throw ProjectWorkspaceError.duplicatePresetName }
      return value
    }
  }

  private static func validatedToolPresets(_ presets: [ProjectToolPreset]) throws
    -> [ProjectToolPreset]
  {
    guard presets.count <= Self.maxPresetCount else { throw ProjectWorkspaceError.tooManyPresets }
    var names: Set<String> = []
    return try presets.map { preset in
      var value = preset
      value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.name.isEmpty else {
        throw ProjectWorkspaceError.invalidPresetName
      }
      guard value.name.count <= Self.maxPresetNameLength else {
        throw ProjectWorkspaceError.presetNameTooLong
      }
      let key = value.name.lowercased()
      guard names.insert(key).inserted else { throw ProjectWorkspaceError.duplicatePresetName }
      return value
    }
  }
}
