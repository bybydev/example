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

  public init(
    id: ProjectID = .init(),
    name: String,
    symbolName: String = "folder.fill",
    accentID: String = "blue",
    accountID: ProviderAccountID? = nil,
    modelID: ModelID? = nil,
    instructions: String = "",
    createdAt: Date = .now,
    updatedAt: Date = .now
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
  }
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
    state = Self.sanitized(decoded)
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

  @discardableResult
  public func createProject(
    name: String,
    symbolName: String,
    accentID: String,
    accountID: ProviderAccountID?,
    modelID: ModelID?,
    instructions: String,
    at date: Date = .now
  ) async throws -> ChatProject {
    let normalizedName = try validatedName(name, excluding: nil)
    let project = ChatProject(
      name: normalizedName,
      symbolName: symbolName.isEmpty ? "folder.fill" : symbolName,
      accentID: accentID.isEmpty ? "blue" : accentID,
      accountID: accountID,
      modelID: accountID == nil ? nil : modelID,
      instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines),
      createdAt: date,
      updatedAt: date
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

  private static func sanitized(_ value: ProjectWorkspaceState) -> ProjectWorkspaceState {
    var result = value
    let validProjectIDs = Set(result.projects.map { $0.id.rawValue })
    result.conversationProjectIDs = result.conversationProjectIDs.filter {
      validProjectIDs.contains($0.value)
    }
    return result
  }
}
