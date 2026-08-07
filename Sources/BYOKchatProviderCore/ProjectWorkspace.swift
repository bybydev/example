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
  public var createdAt: Date

  public init(
    id: String = UUID().uuidString.lowercased(),
    filename: String,
    mimeType: String,
    data: Data,
    createdAt: Date = .now
  ) {
    self.id = id
    self.filename = filename
    self.mimeType = mimeType
    self.data = data
    self.createdAt = createdAt
  }

  public var byteCount: Int { data.count }

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

  // Optional fields preserve compatibility with Phase 1 projects-v1.json files.
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
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var projects: [ChatProject]
  public var conversationProjectIDs: [String: String]

  public init(
    schemaVersion: Int = Self.currentSchemaVersion,
    projects: [ChatProject] = [],
    conversationProjectIDs: [String: String] = [:]
  ) {
    self.schemaVersion = schemaVersion
    self.projects = projects
    self.conversationProjectIDs = conversationProjectIDs
  }
}

public protocol ProjectWorkspacePersistence: Sendable {
  func loadData() async throws -> Data?
  func saveData(_ data: Data) async throws
}

public actor InMemoryProjectWorkspacePersistence: ProjectWorkspacePersistence {
  private var data: Data?

  public init(data: Data? = nil) { self.data = data }
  public func loadData() -> Data? { data }
  public func saveData(_ data: Data) { self.data = data }
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
}

public enum ProjectWorkspaceError: LocalizedError, Sendable, Equatable {
  case unsupportedVersion(Int)
  case projectNotFound(ProjectID)
  case invalidName
  case duplicateName
  case tooManyFiles
  case fileTooLarge(String)
  case filesTooLarge
  case invalidPresetName
  case duplicatePresetName

  public var errorDescription: String? {
    switch self {
    case .unsupportedVersion(let version):
      "Project workspace version \(version) is not supported."
    case .projectNotFound:
      "The project could not be found."
    case .invalidName:
      "Enter a project name."
    case .duplicateName:
      "A project with this name already exists."
    case .tooManyFiles:
      "A project can contain at most 8 reference files."
    case .fileTooLarge(let filename):
      "\(filename) is larger than 20 MB."
    case .filesTooLarge:
      "Project reference files cannot exceed 40 MB total."
    case .invalidPresetName:
      "Enter a preset name."
    case .duplicatePresetName:
      "Preset names must be unique within a project."
    }
  }
}

public actor ProjectWorkspaceStore {
  private var state = ProjectWorkspaceState()
  private let persistence: any ProjectWorkspacePersistence
  private var hasLoaded = false

  public init(persistence: any ProjectWorkspacePersistence) {
    self.persistence = persistence
  }

  public func load() async throws {
    guard !hasLoaded else { return }
    defer { hasLoaded = true }
    guard let data = try await persistence.loadData() else { return }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(ProjectWorkspaceState.self, from: data)
    guard decoded.schemaVersion == ProjectWorkspaceState.currentSchemaVersion else {
      throw ProjectWorkspaceError.unsupportedVersion(decoded.schemaVersion)
    }
    state = try Self.sanitized(decoded)
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
    let normalizedName = try validatedName(name, excluding: nil)
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
    state.projects.append(project)
    try await persist()
    return project
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
    promptPresets: [ProjectPromptPreset]? = nil,
    toolPresets: [ProjectToolPreset]? = nil,
    at date: Date = .now
  ) async throws -> ChatProject {
    guard let index = state.projects.firstIndex(where: { $0.id == id }) else {
      throw ProjectWorkspaceError.projectNotFound(id)
    }
    state.projects[index].name = try validatedName(name, excluding: id)
    state.projects[index].symbolName = symbolName.isEmpty ? "folder.fill" : symbolName
    state.projects[index].accentID = accentID.isEmpty ? "blue" : accentID
    state.projects[index].accountID = accountID
    state.projects[index].modelID = accountID == nil ? nil : modelID
    state.projects[index].instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)

    if let files {
      try Self.validateFiles(files)
      state.projects[index].files = files.isEmpty ? nil : files
    }
    if let mcpConfiguration {
      state.projects[index].mcpConfiguration = mcpConfiguration
    }
    if let promptPresets {
      let normalized = try Self.validatedPromptPresets(promptPresets)
      state.projects[index].promptPresets = normalized.isEmpty ? nil : normalized
    }
    if let toolPresets {
      let normalized = try Self.validatedToolPresets(toolPresets)
      state.projects[index].toolPresets = normalized.isEmpty ? nil : normalized
    }

    state.projects[index].updatedAt = date
    let result = state.projects[index]
    try await persist()
    return result
  }

  public func deleteProject(_ id: ProjectID) async throws {
    guard state.projects.contains(where: { $0.id == id }) else { return }
    state.projects.removeAll { $0.id == id }
    state.conversationProjectIDs = state.conversationProjectIDs.filter { $0.value != id.rawValue }
    try await persist()
  }

  public func assignConversation(_ conversationID: ConversationID, to projectID: ProjectID?) async throws {
    if let projectID {
      _ = try project(id: projectID)
      state.conversationProjectIDs[conversationID.rawValue] = projectID.rawValue
    } else {
      state.conversationProjectIDs.removeValue(forKey: conversationID.rawValue)
    }
    try await persist()
  }

  public func removeConversation(_ conversationID: ConversationID) async throws {
    guard state.conversationProjectIDs.removeValue(forKey: conversationID.rawValue) != nil else { return }
    try await persist()
  }

  public func reconcileConversationIDs(_ validIDs: Set<ConversationID>) async throws {
    let validRawIDs = Set(validIDs.map(\.rawValue))
    let before = state.conversationProjectIDs.count
    state.conversationProjectIDs = state.conversationProjectIDs.filter { validRawIDs.contains($0.key) }
    if state.conversationProjectIDs.count != before {
      try await persist()
    }
  }

  private func validatedName(_ name: String, excluding id: ProjectID?) throws -> String {
    let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { throw ProjectWorkspaceError.invalidName }
    guard normalized.count <= 80 else { throw ProjectWorkspaceError.invalidName }
    guard !state.projects.contains(where: {
      $0.id != id && $0.name.caseInsensitiveCompare(normalized) == .orderedSame
    }) else {
      throw ProjectWorkspaceError.duplicateName
    }
    return normalized
  }

  private func persist() async throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try await persistence.saveData(encoder.encode(state))
  }

  private static func sanitized(_ value: ProjectWorkspaceState) throws -> ProjectWorkspaceState {
    var result = value
    let validProjectIDs = Set(result.projects.map { $0.id.rawValue })
    result.conversationProjectIDs = result.conversationProjectIDs.filter {
      validProjectIDs.contains($0.value)
    }
    for index in result.projects.indices {
      let files = result.projects[index].projectFiles
      try validateFiles(files)
      result.projects[index].files = files.isEmpty ? nil : files
      let prompts = try validatedPromptPresets(result.projects[index].projectPromptPresets)
      result.projects[index].promptPresets = prompts.isEmpty ? nil : prompts
      let tools = try validatedToolPresets(result.projects[index].projectToolPresets)
      result.projects[index].toolPresets = tools.isEmpty ? nil : tools
    }
    return result
  }

  private static func validateFiles(_ files: [ProjectFile]) throws {
    guard files.count <= 8 else { throw ProjectWorkspaceError.tooManyFiles }
    var total = 0
    var ids: Set<String> = []
    for file in files {
      guard ids.insert(file.id).inserted else { throw ProjectWorkspaceError.tooManyFiles }
      guard file.byteCount <= 20 * 1_024 * 1_024 else {
        throw ProjectWorkspaceError.fileTooLarge(file.filename)
      }
      total += file.byteCount
    }
    guard total <= 40 * 1_024 * 1_024 else { throw ProjectWorkspaceError.filesTooLarge }
  }

  private static func validatedPromptPresets(_ presets: [ProjectPromptPreset]) throws
    -> [ProjectPromptPreset]
  {
    guard presets.count <= 24 else { throw ProjectWorkspaceError.invalidPresetName }
    var names: Set<String> = []
    return try presets.map { preset in
      var value = preset
      value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
      value.prompt = value.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.name.isEmpty, value.name.count <= 60, !value.prompt.isEmpty else {
        throw ProjectWorkspaceError.invalidPresetName
      }
      let key = value.name.lowercased()
      guard names.insert(key).inserted else { throw ProjectWorkspaceError.duplicatePresetName }
      return value
    }
  }

  private static func validatedToolPresets(_ presets: [ProjectToolPreset]) throws
    -> [ProjectToolPreset]
  {
    guard presets.count <= 24 else { throw ProjectWorkspaceError.invalidPresetName }
    var names: Set<String> = []
    return try presets.map { preset in
      var value = preset
      value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.name.isEmpty, value.name.count <= 60 else {
        throw ProjectWorkspaceError.invalidPresetName
      }
      let key = value.name.lowercased()
      guard names.insert(key).inserted else { throw ProjectWorkspaceError.duplicatePresetName }
      return value
    }
  }
}
