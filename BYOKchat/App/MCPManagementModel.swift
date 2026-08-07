import BYOKchatProviderCore
import Foundation
import Observation

@MainActor
@Observable
final class MCPManagementModel {
  private(set) var servers: [MCPRemoteServer] = []
  private(set) var snapshotsByServer: [MCPServerID: MCPServerSnapshot] = [:]
  private(set) var credentialServerIDs: Set<MCPServerID> = []
  var isBusy = false
  var errorMessage: String?
  var statusMessage: String?

  private let runtime: MCPRemoteRuntime

  init(runtime: MCPRemoteRuntime) {
    self.runtime = runtime
  }

  func load() async {
    await perform(nil) {
      try await runtime.load()
      try await reloadSnapshot()
    }
  }

  func snapshot(for serverID: MCPServerID) -> MCPServerSnapshot? {
    snapshotsByServer[serverID]
  }

  func hasCredential(_ serverID: MCPServerID) -> Bool {
    credentialServerIDs.contains(serverID)
  }

  func saveServer(
    existing: MCPRemoteServer?,
    name: String,
    endpoint: String,
    authenticationKind: MCPAuthenticationKind,
    authenticationHeader: String,
    credential: String?,
    additionalHeaders: [String: String],
    isEnabled: Bool
  ) async -> Bool {
    await performResult("MCP server saved") {
      let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
      let normalizedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let url = URL(string: normalizedEndpoint) else {
        throw MCPError.invalidServer("Enter a valid MCP endpoint URL.")
      }
      let authentication = MCPAuthentication(
        kind: authenticationKind,
        headerName: authenticationKind == .customHeader
          ? authenticationHeader.trimmingCharacters(in: .whitespacesAndNewlines)
          : nil
      )
      var server = existing ?? MCPRemoteServer(name: normalizedName, endpoint: url)
      server.name = normalizedName
      server.endpoint = url
      server.authentication = authentication
      server.additionalHeaders = additionalHeaders
      server.isEnabled = isEnabled

      if existing == nil,
        authenticationKind != .none,
        credential?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
      {
        throw MCPError.missingCredential
      }

      try await runtime.saveServer(server, credential: credential)
      try await reloadSnapshot()
    }
  }

  func deleteServer(_ serverID: MCPServerID) async {
    await perform("MCP server deleted") {
      try await runtime.deleteServer(serverID)
      try await reloadSnapshot()
    }
  }

  func setEnabled(_ enabled: Bool, serverID: MCPServerID) async {
    await perform(nil) {
      try await runtime.setEnabled(enabled, serverID: serverID)
      try await reloadSnapshot()
    }
  }

  func refresh(_ serverID: MCPServerID) async {
    await perform("MCP tools refreshed") {
      _ = try await runtime.refreshServer(serverID, force: true)
      try await reloadSnapshot()
    }
  }

  private func reloadSnapshot() async throws {
    servers = await runtime.servers()
    let snapshots = await runtime.snapshots()
    snapshotsByServer = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.serverID, $0) })
    var credentials: Set<MCPServerID> = []
    for server in servers {
      if try await runtime.hasCredential(serverID: server.id) {
        credentials.insert(server.id)
      }
    }
    credentialServerIDs = credentials
  }

  private func perform(_ success: String?, operation: () async throws -> Void) async {
    isBusy = true
    defer { isBusy = false }
    do {
      try await operation()
      statusMessage = success
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func performResult(_ success: String?, operation: () async throws -> Void) async -> Bool {
    isBusy = true
    defer { isBusy = false }
    do {
      try await operation()
      statusMessage = success
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }
}
