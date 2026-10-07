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

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, servers, snapshots, chatConfigurations, tombstones
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
      ?? Self.currentSchemaVersion
    servers = try container.decodeIfPresent([MCPRemoteServer].self, forKey: .servers) ?? []
    snapshots = try container.decodeIfPresent([MCPServerSnapshot].self, forKey: .snapshots) ?? []
    chatConfigurations = try container.decodeIfPresent(
      [String: MCPChatToolConfiguration].self,
      forKey: .chatConfigurations
    )
    tombstones = try container.decodeIfPresent([String: Date].self, forKey: .tombstones) ?? [:]
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

  /// Actor methods are reentrant while persistence awaits I/O. Serialize all
  /// mutations so every candidate starts from the latest committed state.
  private var mutationInProgress = false
  private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

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

  public func explicitChatConfiguration(for conversationID: ConversationID) -> MCPChatToolConfiguration? {
    state.chatConfigurations?[conversationID.rawValue]
  }

  public func upsertServer(
    _ server: MCPRemoteServer,
    invalidateSnapshot: Bool = false
  ) async throws {
    await beginMutation()
    defer { endMutation() }

    var value = server
    try Self.validateServer(value)
    value.updatedAt = .now

    var candidate = state
    let previous = candidate.servers.first(where: { $0.id == value.id })
    if let index = candidate.servers.firstIndex(where: { $0.id == value.id }) {
      candidate.servers[index] = value
    } else {
      candidate.servers.append(value)
    }

    if invalidateSnapshot
      || previous?.endpoint != value.endpoint
      || previous?.authentication != value.authentication
      || previous?.additionalHeaders != value.additionalHeaders
    {
      candidate.snapshots.removeAll { $0.serverID == value.id }
    }

    try await commit(candidate)
  }

  public func setEnabled(_ enabled: Bool, serverID: MCPServerID) async throws {
    await beginMutation()
    defer { endMutation() }

    var candidate = state
    guard let index = candidate.servers.firstIndex(where: { $0.id == serverID }) else {
      throw MCPError.serverNotFound(serverID)
    }
    candidate.servers[index].isEnabled = enabled
    candidate.servers[index].updatedAt = .now
    try await commit(candidate)
  }

  public func setChatServerEnabled(
    _ enabled: Bool,
    serverID: MCPServerID,
    conversationID: ConversationID
  ) async throws {
    await beginMutation()
    defer { endMutation() }

    var candidate = state
    guard candidate.servers.contains(where: { $0.id == serverID }) else {
      throw MCPError.serverNotFound(serverID)
    }
    var configuration = chatConfiguration(in: candidate, conversationID: conversationID)
    configuration.enabledServerIDs.removeAll { $0 == serverID }
    if enabled { configuration.enabledServerIDs.append(serverID) }
    configuration.enabledServerIDs.sort { $0.rawValue < $1.rawValue }
    storeChatConfiguration(configuration, conversationID: conversationID, in: &candidate)
    try await commit(candidate)
  }

  public func setChatToolPolicy(
    _ policy: ChatToolPermissionPolicy,
    exposedToolName: String,
    conversationID: ConversationID
  ) async throws {
    await beginMutation()
    defer { endMutation() }

    let normalized = exposedToolName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, normalized.count <= MCPToolNamespace.maximumExposedNameLength else {
      throw MCPError.invalidToolDefinition("Invalid MCP tool permission name.")
    }

    var candidate = state
    var configuration = chatConfiguration(in: candidate, conversationID: conversationID)
    if policy == .ask {
      configuration.toolPolicies.removeValue(forKey: normalized)
    } else {
      configuration.toolPolicies[normalized] = policy
    }
    storeChatConfiguration(configuration, conversationID: conversationID, in: &candidate)
    try await commit(candidate)
  }

  /// Replaces an explicit chat configuration as one persistence transaction.
  /// Unknown/deleted server IDs are dropped, matching the old materialization
  /// behavior, while Ask policies are normalized away.
  public func replaceChatConfiguration(
    _ configuration: MCPChatToolConfiguration,
    conversationID: ConversationID
  ) async throws {
    await beginMutation()
    defer { endMutation() }

    let knownServerIDs = Set(state.servers.map(\.id))
    var normalized = MCPChatToolConfiguration(
      enabledServerIDs: Array(Set(configuration.enabledServerIDs.filter(knownServerIDs.contains)))
        .sorted { $0.rawValue < $1.rawValue },
      toolPolicies: [:]
    )

    for (rawName, policy) in configuration.toolPolicies {
      let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty, name.count <= MCPToolNamespace.maximumExposedNameLength else {
        throw MCPError.invalidToolDefinition("Invalid MCP tool permission name.")
      }
      if policy != .ask { normalized.toolPolicies[name] = policy }
    }

    var candidate = state
    storeChatConfiguration(normalized, conversationID: conversationID, in: &candidate)
    try await commit(candidate)
  }

  public func removeChatConfiguration(conversationID: ConversationID) async throws {
    await beginMutation()
    defer { endMutation() }

    guard state.chatConfigurations?[conversationID.rawValue] != nil else { return }
    var candidate = state
    candidate.chatConfigurations?[conversationID.rawValue] = nil
    normalizeChatConfigurationStorage(in: &candidate)
    try await commit(candidate)
  }

  public func deleteServer(_ id: MCPServerID) async throws {
    await beginMutation()
    defer { endMutation() }

    var candidate = state
    let knownServerIDs = Set(candidate.servers.map(\.id)).union(
      (candidate.chatConfigurations ?? [:]).values.flatMap(\.enabledServerIDs)
    ).union(candidate.tombstones.keys.map { MCPServerID(rawValue: $0) })
    candidate.servers.removeAll { $0.id == id }
    candidate.snapshots.removeAll { $0.serverID == id }
    candidate.tombstones[id.rawValue] = .now

    if var configurations = candidate.chatConfigurations {
      for key in Array(configurations.keys) {
        guard let existing = configurations[key] else { continue }
        let configuration = try MCPToolNamespace.removingServerReferences(
          id, from: existing, knownServerIDs: knownServerIDs
        )
        if configuration.enabledServerIDs.isEmpty && configuration.toolPolicies.isEmpty {
          configurations.removeValue(forKey: key)
        } else {
          configurations[key] = configuration
        }
      }
      candidate.chatConfigurations = configurations.isEmpty ? nil : configurations
    }
    try await commit(candidate)
  }

  public func storeSnapshot(_ snapshot: MCPServerSnapshot) async throws {
    await beginMutation()
    defer { endMutation() }

    var candidate = state
    guard candidate.servers.contains(where: { $0.id == snapshot.serverID }) else {
      throw MCPError.serverNotFound(snapshot.serverID)
    }
    if let index = candidate.snapshots.firstIndex(where: { $0.serverID == snapshot.serverID }) {
      candidate.snapshots[index] = snapshot
    } else {
      candidate.snapshots.append(snapshot)
    }
    try await commit(candidate)
  }

  public func invalidateSnapshot(serverID: MCPServerID) async throws {
    await beginMutation()
    defer { endMutation() }

    var candidate = state
    candidate.snapshots.removeAll { $0.serverID == serverID }
    guard candidate != state else { return }
    try await commit(candidate)
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

    await beginMutation()
    defer { endMutation() }

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
    try await commit(candidate)
  }

  private func chatConfiguration(
    in candidate: MCPWorkspaceState,
    conversationID: ConversationID
  ) -> MCPChatToolConfiguration {
    candidate.chatConfigurations?[conversationID.rawValue] ?? MCPChatToolConfiguration()
  }

  private func storeChatConfiguration(
    _ configuration: MCPChatToolConfiguration,
    conversationID: ConversationID,
    in candidate: inout MCPWorkspaceState
  ) {
    var values = candidate.chatConfigurations ?? [:]
    if configuration.enabledServerIDs.isEmpty && configuration.toolPolicies.isEmpty {
      values.removeValue(forKey: conversationID.rawValue)
    } else {
      values[conversationID.rawValue] = configuration
    }
    candidate.chatConfigurations = values.isEmpty ? nil : values
  }

  private func normalizeChatConfigurationStorage(in candidate: inout MCPWorkspaceState) {
    if candidate.chatConfigurations?.isEmpty == true { candidate.chatConfigurations = nil }
  }

  private func commit(_ candidate: MCPWorkspaceState) async throws {
    try Self.validate(candidate)
    try await persistence.saveData(JSONEncoder.providerEncoder.encode(candidate))
    state = candidate
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
