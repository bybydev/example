import Foundation

public struct MCPServerID: RawRepresentable, Hashable, Codable, Sendable, Identifiable,
  ExpressibleByStringLiteral, CustomStringConvertible
{
  public var rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(stringLiteral value: String) { rawValue = value }
  public var id: String { rawValue }
  public var description: String { rawValue }
}

public enum MCPAuthenticationKind: String, Codable, Sendable, CaseIterable {
  case none
  case bearer
  case customHeader
}

public struct MCPAuthentication: Codable, Sendable, Equatable {
  public var kind: MCPAuthenticationKind
  public var headerName: String?

  public init(kind: MCPAuthenticationKind = .none, headerName: String? = nil) {
    self.kind = kind
    self.headerName = headerName
  }
}

public struct MCPRemoteServer: Codable, Sendable, Equatable, Identifiable {
  public var id: MCPServerID
  public var name: String
  public var endpoint: URL
  public var authentication: MCPAuthentication
  public var additionalHeaders: [String: String]
  public var isEnabled: Bool
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: MCPServerID = MCPServerID(rawValue: UUID().uuidString.lowercased()),
    name: String,
    endpoint: URL,
    authentication: MCPAuthentication = .init(),
    additionalHeaders: [String: String] = [:],
    isEnabled: Bool = true,
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) {
    self.id = id
    self.name = name
    self.endpoint = endpoint
    self.authentication = authentication
    self.additionalHeaders = additionalHeaders
    self.isEnabled = isEnabled
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public enum MCPProtocolEra: String, Codable, Sendable {
  case modern
  case legacy
}

public struct MCPImplementationInfo: Codable, Sendable, Equatable {
  public var name: String
  public var version: String
  public var title: String?

  public init(name: String, version: String, title: String? = nil) {
    self.name = name
    self.version = version
    self.title = title
  }
}

public struct MCPHeaderBinding: Codable, Sendable, Equatable {
  public var propertyPath: [String]
  public var headerName: String
  public var valueType: String

  public init(propertyPath: [String], headerName: String, valueType: String) {
    self.propertyPath = propertyPath
    self.headerName = headerName
    self.valueType = valueType
  }
}

public struct MCPRemoteTool: Codable, Sendable, Equatable, Identifiable {
  public var remoteName: String
  public var title: String?
  public var description: String
  public var inputSchema: JSONValue
  public var outputSchema: JSONValue?
  public var annotations: JSONValue?
  public var headerBindings: [MCPHeaderBinding]

  public var id: String { remoteName }

  public init(
    remoteName: String,
    title: String? = nil,
    description: String,
    inputSchema: JSONValue,
    outputSchema: JSONValue? = nil,
    annotations: JSONValue? = nil,
    headerBindings: [MCPHeaderBinding] = []
  ) {
    self.remoteName = remoteName
    self.title = title
    self.description = description
    self.inputSchema = inputSchema
    self.outputSchema = outputSchema
    self.annotations = annotations
    self.headerBindings = headerBindings
  }
}

public struct MCPServerSnapshot: Codable, Sendable, Equatable, Identifiable {
  public var serverID: MCPServerID
  public var protocolVersion: String
  public var era: MCPProtocolEra
  public var serverInfo: MCPImplementationInfo?
  public var capabilities: JSONValue
  public var instructions: String?
  public var tools: [MCPRemoteTool]
  public var refreshedAt: Date
  public var expiresAt: Date?
  public var cacheScope: String?
  public var warnings: [String]

  public var id: MCPServerID { serverID }

  public init(
    serverID: MCPServerID,
    protocolVersion: String,
    era: MCPProtocolEra,
    serverInfo: MCPImplementationInfo? = nil,
    capabilities: JSONValue = .object([:]),
    instructions: String? = nil,
    tools: [MCPRemoteTool] = [],
    refreshedAt: Date = .now,
    expiresAt: Date? = nil,
    cacheScope: String? = nil,
    warnings: [String] = []
  ) {
    self.serverID = serverID
    self.protocolVersion = protocolVersion
    self.era = era
    self.serverInfo = serverInfo
    self.capabilities = capabilities
    self.instructions = instructions
    self.tools = tools
    self.refreshedAt = refreshedAt
    self.expiresAt = expiresAt
    self.cacheScope = cacheScope
    self.warnings = warnings
  }

  public var isFresh: Bool {
    guard let expiresAt else { return false }
    return expiresAt > .now
  }
}

public struct MCPToolBinding: Sendable, Equatable, Identifiable {
  public var serverID: MCPServerID
  public var remoteTool: MCPRemoteTool
  public var exposedName: String

  public var id: String { exposedName }

  public init(serverID: MCPServerID, remoteTool: MCPRemoteTool, exposedName: String) {
    self.serverID = serverID
    self.remoteTool = remoteTool
    self.exposedName = exposedName
  }

  public var chatDefinition: ChatToolDefinition {
    ChatToolDefinition(
      name: exposedName,
      description: remoteTool.description,
      inputSchema: remoteTool.inputSchema
    )
  }
}

public struct MCPToolCallOutput: Sendable, Equatable {
  public var content: JSONValue
  public var isError: Bool

  public init(content: JSONValue, isError: Bool) {
    self.content = content
    self.isError = isError
  }
}

public enum MCPError: Error, LocalizedError, Sendable, Equatable {
  case serverNotFound(MCPServerID)
  case invalidServer(String)
  case missingCredential
  case authenticationFailed
  case permissionDenied
  case rateLimited
  case invalidResponse
  case protocolError(code: Int, message: String)
  case unsupportedProtocol([String])
  case unsupportedLegacyTransport
  case toolNotFound(String)
  case invalidToolDefinition(String)
  case inputRequired
  case transport(String)

  public var errorDescription: String? {
    switch self {
    case .serverNotFound(let id): "MCP server not found: \(id.rawValue)"
    case .invalidServer(let message): message
    case .missingCredential: "This MCP server requires a credential."
    case .authenticationFailed: "The MCP server rejected the credential."
    case .permissionDenied: "The MCP server denied this request."
    case .rateLimited: "The MCP server rate limited this request."
    case .invalidResponse: "The MCP server returned an invalid response."
    case .protocolError(_, let message): message
    case .unsupportedProtocol(let versions):
      versions.isEmpty
        ? "The MCP server uses an unsupported protocol version."
        : "The MCP server only supports: \(versions.joined(separator: ", "))."
    case .unsupportedLegacyTransport:
      "This endpoint uses the deprecated HTTP+SSE MCP transport, which BYOKchat does not support."
    case .toolNotFound(let name): "MCP tool not found: \(name)"
    case .invalidToolDefinition(let message): message
    case .inputRequired:
      "This MCP tool requires additional interactive input. BYOKchat will support that in a later phase."
    case .transport(let message): message
    }
  }
}

public enum MCPToolNamespace {
  public static func exposedName(serverID: MCPServerID, remoteName: String) -> String {
    let prefixSource = serverID.rawValue.lowercased().filter { $0.isLetter || $0.isNumber }
    let serverPrefix = String(prefixSource.prefix(8)).isEmpty ? "server" : String(prefixSource.prefix(8))
    let sanitized = remoteName.map { character -> Character in
      if character.isASCII && (character.isLetter || character.isNumber || character == "_" || character == "-") {
        return character
      }
      return "_"
    }
    let body = String(sanitized)
    let suffix = String(format: "%08x", stableHash(remoteName))
    let fixed = "mcp_\(serverPrefix)_"
    let reserved = fixed.count + 1 + suffix.count
    let available = max(1, 128 - reserved)
    return fixed + String(body.prefix(available)) + "_" + suffix
  }

  private static func stableHash(_ value: String) -> UInt32 {
    var hash: UInt32 = 2_166_136_261
    for byte in value.utf8 {
      hash ^= UInt32(byte)
      hash = hash &* 16_777_619
    }
    return hash
  }
}
