import Foundation

public struct MCPWorkspaceState: Codable, Sendable, Equatable {
  /// Single pre-release schema; evolves in place, users fresh-install.
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var servers: [MCPRemoteServer]
  public var snapshots: [MCPServerSnapshot]
  /// Optional so older schema-v1 MCP workspaces and full backups still decode.
  public var chatConfigurations: [String: MCPChatToolConfiguration]?
  /// serverID → deletedAt. Pruned on load after the retention window.
  public var tombstones: [String: Date]

  public init(
    schemaVersion: Int = Self.currentSchemaVersion,
    servers: [MCPRemoteServer] = [],
    snapshots: [MCPServerSnapshot] = [],
    chatConfigurations: [String: MCPChatToolConfiguration]? = nil,
    tombstones: [String: Date] = [:]
  ) {
    self.schemaVersion = schemaVersion
    self.servers = servers
    self.snapshots = snapshots
    self.chatConfigurations = chatConfigurations
    self.tombstones = tombstones
  }
}

public protocol MCPWorkspacePersistence: Sendable {
  func loadData() async throws -> Data?
  func saveData(_ data: Data) async throws
}

public actor InMemoryMCPWorkspacePersistence: MCPWorkspacePersistence {
  private var data: Data?
  public init(data: Data? = nil) { self.data = data }
  public func loadData() -> Data? { data }
  public func saveData(_ data: Data) { self.data = data }
}

public actor JSONFileMCPWorkspacePersistence: MCPWorkspacePersistence {
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

public actor MCPWorkspaceStore {
  private var state = MCPWorkspaceState()
  private let persistence: any MCPWorkspacePersistence
  private var hasLoaded = false

  public init(persistence: any MCPWorkspacePersistence) {
    self.persistence = persistence
  }

  public func load() async throws {
    guard !hasLoaded else { return }
    guard let data = try await persistence.loadData() else {
      hasLoaded = true
      return
    }
    let decoded = try JSONDecoder.provider.decode(MCPWorkspaceState.self, from: data)
    guard decoded.schemaVersion == MCPWorkspaceState.currentSchemaVersion else {
      throw ProviderError.workspaceVersionUnsupported(decoded.schemaVersion)
    }
    try Self.validate(decoded)
    state = decoded
    state.tombstones = SyncTombstonePolicy.pruned(state.tombstones)
    hasLoaded = true
  }

  public func snapshot() -> MCPWorkspaceState { state }

  public func allServers() -> [MCPRemoteServer] {
    state.servers.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  public func server(id: MCPServerID) throws -> MCPRemoteServer {
    guard let value = state.servers.first(where: { $0.id == id }) else {
      throw MCPError.serverNotFound(id)
    }
    return value
  }

  public func snapshot(for serverID: MCPServerID) -> MCPServerSnapshot? {
    state.snapshots.first { $0.serverID == serverID }
  }

  public func chatConfiguration(for conversationID: ConversationID) -> MCPChatToolConfiguration {
    state.chatConfigurations?[conversationID.rawValue] ?? MCPChatToolConfiguration()
  }

  public func upsertServer(_ server: MCPRemoteServer) async throws {
    var value = server
    try Self.validateServer(value)
    value.updatedAt = .now
    if let index = state.servers.firstIndex(where: { $0.id == value.id }) {
      state.servers[index] = value
    } else {
      state.servers.append(value)
    }
    try await persist()
  }

  public func setEnabled(_ enabled: Bool, serverID: MCPServerID) async throws {
    guard let index = state.servers.firstIndex(where: { $0.id == serverID }) else {
      throw MCPError.serverNotFound(serverID)
    }
    state.servers[index].isEnabled = enabled
    state.servers[index].updatedAt = .now
    try await persist()
  }

  public func setChatServerEnabled(
    _ enabled: Bool,
    serverID: MCPServerID,
    conversationID: ConversationID
  ) async throws {
    guard state.servers.contains(where: { $0.id == serverID }) else {
      throw MCPError.serverNotFound(serverID)
    }
    var configuration = chatConfiguration(for: conversationID)
    configuration.enabledServerIDs.removeAll { $0 == serverID }
    if enabled { configuration.enabledServerIDs.append(serverID) }
    configuration.enabledServerIDs.sort { $0.rawValue < $1.rawValue }
    storeChatConfiguration(configuration, conversationID: conversationID)
    try await persist()
  }

  public func setChatToolPolicy(
    _ policy: ChatToolPermissionPolicy,
    exposedToolName: String,
    conversationID: ConversationID
  ) async throws {
    let normalized = exposedToolName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, normalized.count <= MCPToolNamespace.maximumExposedNameLength else {
      throw MCPError.invalidToolDefinition("Invalid MCP tool permission name.")
    }
    var configuration = chatConfiguration(for: conversationID)
    if policy == .ask {
      configuration.toolPolicies.removeValue(forKey: normalized)
    } else {
      configuration.toolPolicies[normalized] = policy
    }
    storeChatConfiguration(configuration, conversationID: conversationID)
    try await persist()
  }

  public func removeChatConfiguration(conversationID: ConversationID) async throws {
    guard state.chatConfigurations?[conversationID.rawValue] != nil else { return }
    state.chatConfigurations?[conversationID.rawValue] = nil
    normalizeChatConfigurationStorage()
    try await persist()
  }

  public func deleteServer(_ id: MCPServerID) async throws {
    let exposedNames = Set(
      state.snapshots.first(where: { $0.serverID == id })?.tools.map {
        MCPToolNamespace.exposedName(serverID: id, remoteName: $0.remoteName)
      } ?? []
    )
    state.servers.removeAll { $0.id == id }
    state.snapshots.removeAll { $0.serverID == id }
    state.tombstones[id.rawValue] = .now

    if var configurations = state.chatConfigurations {
      for key in Array(configurations.keys) {
        guard var configuration = configurations[key] else { continue }
        configuration.enabledServerIDs.removeAll { $0 == id }
        for name in exposedNames { configuration.toolPolicies.removeValue(forKey: name) }
        if configuration.enabledServerIDs.isEmpty && configuration.toolPolicies.isEmpty {
          configurations.removeValue(forKey: key)
        } else {
          configurations[key] = configuration
        }
      }
      state.chatConfigurations = configurations.isEmpty ? nil : configurations
    }
    try await persist()
  }

  public func storeSnapshot(_ snapshot: MCPServerSnapshot) async throws {
    guard state.servers.contains(where: { $0.id == snapshot.serverID }) else {
      throw MCPError.serverNotFound(snapshot.serverID)
    }
    if let index = state.snapshots.firstIndex(where: { $0.serverID == snapshot.serverID }) {
      state.snapshots[index] = snapshot
    } else {
      state.snapshots.append(snapshot)
    }
    try await persist()
  }

  public func invalidateSnapshot(serverID: MCPServerID) async throws {
    state.snapshots.removeAll { $0.serverID == serverID }
    try await persist()
  }

  public func exportConfiguration() throws -> Data {
    try JSONEncoder.providerEncoder.encode(state)
  }

  public func importConfiguration(
    _ data: Data,
    strategy: ProviderImportStrategy
  ) async throws {
    let imported = try JSONDecoder.provider.decode(MCPWorkspaceState.self, from: data)
    guard imported.schemaVersion == MCPWorkspaceState.currentSchemaVersion else {
      throw ProviderError.workspaceVersionUnsupported(imported.schemaVersion)
    }
    try Self.validate(imported)

    var candidate = state
    switch strategy {
    case .replaceExisting:
      candidate = imported
    case .keepExisting:
      let existingServerIDs = Set(candidate.servers.map(\.id))
      candidate.servers.append(
        contentsOf: imported.servers.filter { !existingServerIDs.contains($0.id) }
      )
      let availableIDs = Set(candidate.servers.map(\.id))
      let existingSnapshotIDs = Set(candidate.snapshots.map(\.serverID))
      candidate.snapshots.append(
        contentsOf: imported.snapshots.filter {
          availableIDs.contains($0.serverID) && !existingSnapshotIDs.contains($0.serverID)
        }
      )

      var chatConfigurations = candidate.chatConfigurations ?? [:]
      for (conversationID, configuration) in imported.chatConfigurations ?? [:]
        where chatConfigurations[conversationID] == nil
      {
        chatConfigurations[conversationID] = configuration
      }
      candidate.chatConfigurations = chatConfigurations.isEmpty ? nil : chatConfigurations
    }
    try Self.validate(candidate)
    try await persistence.saveData(JSONEncoder.providerEncoder.encode(candidate))
    state = candidate
  }

  private func storeChatConfiguration(
    _ configuration: MCPChatToolConfiguration,
    conversationID: ConversationID
  ) {
    var values = state.chatConfigurations ?? [:]
    if configuration.enabledServerIDs.isEmpty && configuration.toolPolicies.isEmpty {
      values.removeValue(forKey: conversationID.rawValue)
    } else {
      values[conversationID.rawValue] = configuration
    }
    state.chatConfigurations = values.isEmpty ? nil : values
  }

  private func normalizeChatConfigurationStorage() {
    if state.chatConfigurations?.isEmpty == true { state.chatConfigurations = nil }
  }

  private func persist() async throws {
    try await persistence.saveData(JSONEncoder.providerEncoder.encode(state))
  }

  public static func validate(_ workspace: MCPWorkspaceState) throws {
    var ids: Set<MCPServerID> = []
    for server in workspace.servers {
      guard ids.insert(server.id).inserted else {
        throw MCPError.invalidServer("Duplicate MCP server ID: \(server.id.rawValue)")
      }
      try validateServer(server)
    }

    var snapshotIDs: Set<MCPServerID> = []
    for snapshot in workspace.snapshots {
      guard ids.contains(snapshot.serverID) else {
        throw MCPError.invalidServer(
          "Cached MCP discovery references unknown server \(snapshot.serverID.rawValue)."
        )
      }
      guard snapshotIDs.insert(snapshot.serverID).inserted else {
        throw MCPError.invalidServer(
          "Duplicate MCP discovery cache for \(snapshot.serverID.rawValue)."
        )
      }
    }

    for (conversationID, configuration) in workspace.chatConfigurations ?? [:] {
      guard !conversationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw MCPError.invalidServer("MCP chat configuration contains an empty conversation ID.")
      }
      let enabledIDs = configuration.enabledServerIDs
      guard Set(enabledIDs).count == enabledIDs.count else {
        throw MCPError.invalidServer(
          "MCP chat configuration \(conversationID) contains duplicate server IDs."
        )
      }
      guard enabledIDs.allSatisfy(ids.contains) else {
        throw MCPError.invalidServer(
          "MCP chat configuration \(conversationID) references an unknown server."
        )
      }
      for name in configuration.toolPolicies.keys {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          name.count <= MCPToolNamespace.maximumExposedNameLength
        else {
          throw MCPError.invalidServer(
            "MCP chat configuration \(conversationID) contains an invalid tool permission."
          )
        }
      }
    }
  }

  public static func validateServer(_ server: MCPRemoteServer) throws {
    let name = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { throw MCPError.invalidServer("MCP server name is required.") }
    guard server.endpoint.scheme?.lowercased() == "https",
      server.endpoint.host?.isEmpty == false,
      server.endpoint.user == nil,
      server.endpoint.password == nil
    else {
      throw MCPError.invalidServer(
        "Remote MCP endpoints must use HTTPS and cannot include embedded credentials."
      )
    }
    guard server.endpoint.fragment == nil else {
      throw MCPError.invalidServer("MCP endpoint URLs cannot contain a fragment.")
    }

    if server.authentication.kind == .customHeader {
      guard let header = server.authentication.headerName,
        isValidHeaderName(header),
        !isReservedHeader(header)
      else {
        throw MCPError.invalidServer("Enter a valid custom authentication header name.")
      }
    }

    for (header, value) in server.additionalHeaders {
      guard isValidHeaderName(header), !isReservedHeader(header) else {
        throw MCPError.invalidServer("The additional header \(header) is reserved or invalid.")
      }
      guard !value.contains("\r"), !value.contains("\n") else {
        throw MCPError.invalidServer("Header values cannot contain line breaks.")
      }
    }
  }

  private static func isValidHeaderName(_ value: String) -> Bool {
    guard !value.isEmpty else { return false }
    let allowed = Set("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
    return value.allSatisfy { allowed.contains($0) }
  }

  private static func isReservedHeader(_ value: String) -> Bool {
    let normalized = value.lowercased()
    return [
      "authorization",
      "content-type",
      "accept",
      "mcp-protocol-version",
      "mcp-method",
      "mcp-name",
      "mcp-session-id",
    ].contains(normalized) || normalized.hasPrefix("mcp-param-")
  }
}
