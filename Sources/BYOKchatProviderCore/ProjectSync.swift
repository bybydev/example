import Foundation

public struct SyncedProjectRecord: Codable, Sendable, Equatable, Identifiable {
  public var syncID: String
  public var project: ChatProject

  public var id: String { syncID }

  public init(syncID: String, project: ChatProject) {
    self.syncID = syncID
    self.project = project
  }
}

public struct ProjectSyncEnvelope: Codable, Sendable, Equatable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var updatedAt: Date
  public var projects: [SyncedProjectRecord]
  public var tombstones: [String: Date]

  public init(
    schemaVersion: Int = Self.currentSchemaVersion,
    updatedAt: Date = .now,
    projects: [SyncedProjectRecord] = [],
    tombstones: [String: Date] = [:]
  ) {
    self.schemaVersion = schemaVersion
    self.updatedAt = updatedAt
    self.projects = projects
    self.tombstones = tombstones
  }
}

public struct ProjectSyncLocalState: Codable, Sendable, Equatable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var syncIDsByLocalProjectID: [String: String]
  public var tombstones: [String: Date]
  public var lastSyncedAt: Date?

  public init(
    schemaVersion: Int = Self.currentSchemaVersion,
    syncIDsByLocalProjectID: [String: String] = [:],
    tombstones: [String: Date] = [:],
    lastSyncedAt: Date? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.syncIDsByLocalProjectID = syncIDsByLocalProjectID
    self.tombstones = tombstones
    self.lastSyncedAt = lastSyncedAt
  }
}

public struct ProjectSyncResult: Sendable, Equatable {
  public var projectCount: Int
  public var uploadedProjectCount: Int
  public var downloadedProjectCount: Int
  public var deletedProjectCount: Int
  public var syncedAt: Date

  public init(
    projectCount: Int,
    uploadedProjectCount: Int,
    downloadedProjectCount: Int,
    deletedProjectCount: Int,
    syncedAt: Date
  ) {
    self.projectCount = projectCount
    self.uploadedProjectCount = uploadedProjectCount
    self.downloadedProjectCount = downloadedProjectCount
    self.deletedProjectCount = deletedProjectCount
    self.syncedAt = syncedAt
  }
}

public enum ProjectSyncError: LocalizedError, Sendable, Equatable {
  case unavailable
  case unsupportedVersion(Int)
  case corruptState

  public var errorDescription: String? {
    switch self {
    case .unavailable:
      "iCloud Drive is unavailable. Sign in to iCloud and enable iCloud Drive for BYOKchat."
    case .unsupportedVersion(let version):
      "Project sync data version \(version) is not supported."
    case .corruptState:
      "Project sync data is invalid or corrupted."
    }
  }
}

public protocol ProjectSyncRemoteStorage: Sendable {
  func loadData() async throws -> Data?
  func saveData(_ data: Data) async throws
}

public protocol ProjectSyncLocalPersistence: Sendable {
  func loadData() async throws -> Data?
  func saveData(_ data: Data) async throws
}

public actor InMemoryProjectSyncRemoteStorage: ProjectSyncRemoteStorage {
  public var data: Data?
  public init(data: Data? = nil) { self.data = data }
  public func loadData() -> Data? { data }
  public func saveData(_ data: Data) { self.data = data }
}

public actor InMemoryProjectSyncLocalPersistence: ProjectSyncLocalPersistence {
  public var data: Data?
  public init(data: Data? = nil) { self.data = data }
  public func loadData() -> Data? { data }
  public func saveData(_ data: Data) { self.data = data }
}

public actor JSONFileProjectSyncLocalPersistence: ProjectSyncLocalPersistence {
  public let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public func loadData() throws -> Data? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    return try Data(contentsOf: fileURL)
  }

  public func saveData(_ data: Data) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: fileURL, options: .atomic)
  }
}

public actor ProjectSyncService {
  private let workspace: ProjectWorkspaceStore
  private let remote: any ProjectSyncRemoteStorage
  private let localPersistence: any ProjectSyncLocalPersistence

  private var localState = ProjectSyncLocalState()
  private var hasLoadedLocalState = false

  public init(
    workspace: ProjectWorkspaceStore,
    remote: any ProjectSyncRemoteStorage,
    localPersistence: any ProjectSyncLocalPersistence
  ) {
    self.workspace = workspace
    self.remote = remote
    self.localPersistence = localPersistence
  }

  public func synchronize(at date: Date = .now) async throws -> ProjectSyncResult {
    try await loadLocalStateIfNeeded()
    let beforeProjects = await workspace.allProjects()
    reconcileLocalIdentity(with: beforeProjects, at: date)

    let localEnvelope = makeLocalEnvelope(projects: beforeProjects, at: date)
    let remoteEnvelope = try await loadRemoteEnvelope()
    let merged = try Self.merge(local: localEnvelope, remote: remoteEnvelope, at: date)

    let beforeIDs = Set(beforeProjects.map(\.id))
    let localSyncIDsBefore = Set(localState.syncIDsByLocalProjectID.values)
    let remoteSyncIDs = Set(remoteEnvelope?.projects.map(\.syncID) ?? [])

    try await apply(merged, at: date)
    let afterProjects = await workspace.allProjects()
    let afterIDs = Set(afterProjects.map(\.id))

    localState.lastSyncedAt = date
    localState.tombstones = merged.tombstones
    pruneLocalMappings(validProjectIDs: afterIDs)
    try await persistLocalState()
    try await remote.saveData(try Self.encode(merged))

    let mergedSyncIDs = Set(merged.projects.map(\.syncID))
    let downloaded = mergedSyncIDs.subtracting(localSyncIDsBefore).count
    let uploaded = mergedSyncIDs.subtracting(remoteSyncIDs).count
    let deleted = beforeIDs.subtracting(afterIDs).count

    return ProjectSyncResult(
      projectCount: afterProjects.count,
      uploadedProjectCount: uploaded,
      downloadedProjectCount: downloaded,
      deletedProjectCount: deleted,
      syncedAt: date
    )
  }

  public func lastSyncedAt() async throws -> Date? {
    try await loadLocalStateIfNeeded()
    return localState.lastSyncedAt
  }

  private func loadLocalStateIfNeeded() async throws {
    guard !hasLoadedLocalState else { return }
    defer { hasLoadedLocalState = true }
    guard let data = try await localPersistence.loadData() else { return }
    let decoded = try Self.decoder.decode(ProjectSyncLocalState.self, from: data)
    guard decoded.schemaVersion == ProjectSyncLocalState.currentSchemaVersion else {
      throw ProjectSyncError.unsupportedVersion(decoded.schemaVersion)
    }
    localState = decoded
  }

  private func reconcileLocalIdentity(with projects: [ChatProject], at date: Date) {
    let currentProjectIDs = Set(projects.map { $0.id.rawValue })

    for (localProjectID, syncID) in localState.syncIDsByLocalProjectID
      where !currentProjectIDs.contains(localProjectID)
    {
      if localState.tombstones[syncID] == nil {
        localState.tombstones[syncID] = date
      }
      localState.syncIDsByLocalProjectID.removeValue(forKey: localProjectID)
    }

    let usedSyncIDs = Set(localState.syncIDsByLocalProjectID.values)
    for project in projects where localState.syncIDsByLocalProjectID[project.id.rawValue] == nil {
      var syncID = project.id.rawValue
      if usedSyncIDs.contains(syncID) {
        syncID = UUID().uuidString.lowercased()
      }
      localState.syncIDsByLocalProjectID[project.id.rawValue] = syncID
      if let tombstone = localState.tombstones[syncID], tombstone < project.updatedAt {
        localState.tombstones.removeValue(forKey: syncID)
      }
    }
  }

  private func makeLocalEnvelope(projects: [ChatProject], at date: Date) -> ProjectSyncEnvelope {
    let records = projects.compactMap { project -> SyncedProjectRecord? in
      guard let syncID = localState.syncIDsByLocalProjectID[project.id.rawValue] else { return nil }
      return SyncedProjectRecord(syncID: syncID, project: project)
    }
    return ProjectSyncEnvelope(
      updatedAt: date,
      projects: records,
      tombstones: localState.tombstones
    )
  }

  private func loadRemoteEnvelope() async throws -> ProjectSyncEnvelope? {
    guard let data = try await remote.loadData() else { return nil }
    let envelope = try Self.decoder.decode(ProjectSyncEnvelope.self, from: data)
    guard envelope.schemaVersion == ProjectSyncEnvelope.currentSchemaVersion else {
      throw ProjectSyncError.unsupportedVersion(envelope.schemaVersion)
    }
    return envelope
  }

  private func apply(_ envelope: ProjectSyncEnvelope, at date: Date) async throws {
    var localProjects = await workspace.allProjects()
    let activeSyncIDs = Set(envelope.projects.map(\.syncID))

    for (localProjectValue, syncID) in Array(localState.syncIDsByLocalProjectID) {
      guard !activeSyncIDs.contains(syncID), envelope.tombstones[syncID] != nil else { continue }
      let localID = ProjectID(rawValue: localProjectValue)
      if localProjects.contains(where: { $0.id == localID }) {
        try await workspace.deleteProject(localID)
        localProjects.removeAll { $0.id == localID }
      }
      localState.syncIDsByLocalProjectID.removeValue(forKey: localProjectValue)
    }

    for record in envelope.projects.sorted(by: { $0.syncID < $1.syncID }) {
      let desired = record.project
      if let localProjectValue = localState.syncIDsByLocalProjectID.first(where: {
        $0.value == record.syncID
      })?.key,
        let local = localProjects.first(where: { $0.id.rawValue == localProjectValue })
      {
        if !Self.samePortableProject(local, desired) {
          let updated = try await workspace.updateProject(
            id: local.id,
            name: desired.name,
            symbolName: desired.symbolName,
            accentID: desired.accentID,
            accountID: desired.accountID,
            modelID: desired.modelID,
            instructions: desired.instructions,
            files: desired.projectFiles,
            mcpConfiguration: desired.mcpConfiguration ?? MCPChatToolConfiguration(),
            promptPresets: desired.projectPromptPresets,
            toolPresets: desired.projectToolPresets,
            at: desired.updatedAt
          )
          if let index = localProjects.firstIndex(where: { $0.id == local.id }) {
            localProjects[index] = updated
          }
        }
      } else {
        let created = try await workspace.createProject(
          name: desired.name,
          symbolName: desired.symbolName,
          accentID: desired.accentID,
          accountID: desired.accountID,
          modelID: desired.modelID,
          instructions: desired.instructions,
          files: desired.projectFiles,
          mcpConfiguration: desired.mcpConfiguration,
          promptPresets: desired.projectPromptPresets,
          toolPresets: desired.projectToolPresets,
          at: desired.updatedAt
        )
        localProjects.append(created)
        localState.syncIDsByLocalProjectID[created.id.rawValue] = record.syncID
      }
    }
  }

  private func pruneLocalMappings(validProjectIDs: Set<ProjectID>) {
    let valid = Set(validProjectIDs.map(\.rawValue))
    localState.syncIDsByLocalProjectID = localState.syncIDsByLocalProjectID.filter {
      valid.contains($0.key)
    }
  }

  private func persistLocalState() async throws {
    try await localPersistence.saveData(try Self.encode(localState))
  }

  private static func merge(
    local: ProjectSyncEnvelope,
    remote: ProjectSyncEnvelope?,
    at date: Date
  ) throws -> ProjectSyncEnvelope {
    guard let remote else { return normalized(local, at: date) }

    var tombstones = local.tombstones
    for (syncID, remoteDate) in remote.tombstones {
      if let localDate = tombstones[syncID] {
        tombstones[syncID] = max(localDate, remoteDate)
      } else {
        tombstones[syncID] = remoteDate
      }
    }

    var candidates: [String: [SyncedProjectRecord]] = [:]
    for record in local.projects { candidates[record.syncID, default: []].append(record) }
    for record in remote.projects { candidates[record.syncID, default: []].append(record) }

    var merged: [SyncedProjectRecord] = []
    for syncID in candidates.keys.sorted() {
      guard let values = candidates[syncID], !values.isEmpty else { continue }
      let selected = try values.sorted { lhs, rhs in
        if lhs.project.updatedAt != rhs.project.updatedAt {
          return lhs.project.updatedAt > rhs.project.updatedAt
        }
        return try encodedProjectKey(lhs.project) < encodedProjectKey(rhs.project)
      }.first!

      if let deletedAt = tombstones[syncID], deletedAt >= selected.project.updatedAt {
        continue
      }
      merged.append(selected)
    }

    var result = ProjectSyncEnvelope(
      updatedAt: date,
      projects: merged,
      tombstones: tombstones
    )
    result = normalized(result, at: date)
    return result
  }

  private static func normalized(_ envelope: ProjectSyncEnvelope, at date: Date)
    -> ProjectSyncEnvelope
  {
    var result = envelope
    var usedNames: Set<String> = []
    var records: [SyncedProjectRecord] = []

    for var record in result.projects.sorted(by: { lhs, rhs in
      let lhsName = lhs.project.name.localizedLowercase
      let rhsName = rhs.project.name.localizedLowercase
      if lhsName == rhsName { return lhs.syncID < rhs.syncID }
      return lhsName < rhsName
    }) {
      let original = record.project.name
      var candidate = original
      var index = 2
      while usedNames.contains(candidate.localizedLowercase) {
        candidate = "\(original) (Synced \(index))"
        index += 1
      }
      record.project.name = candidate
      usedNames.insert(candidate.localizedLowercase)
      records.append(record)
    }

    result.projects = records.sorted { $0.syncID < $1.syncID }
    result.updatedAt = date
    return result
  }

  private static func samePortableProject(_ lhs: ChatProject, _ rhs: ChatProject) -> Bool {
    lhs.name == rhs.name
      && lhs.symbolName == rhs.symbolName
      && lhs.accentID == rhs.accentID
      && lhs.accountID == rhs.accountID
      && lhs.modelID == rhs.modelID
      && lhs.instructions == rhs.instructions
      && lhs.updatedAt == rhs.updatedAt
      && lhs.projectFiles == rhs.projectFiles
      && lhs.mcpConfiguration == rhs.mcpConfiguration
      && lhs.projectPromptPresets == rhs.projectPromptPresets
      && lhs.projectToolPresets == rhs.projectToolPresets
  }

  private static func encodedProjectKey(_ project: ChatProject) throws -> String {
    try encode(project).base64EncodedString()
  }

  private static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(value)
  }

  private static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
