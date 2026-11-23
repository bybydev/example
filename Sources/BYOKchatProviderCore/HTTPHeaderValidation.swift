import Foundation

/// Validation rules for user-supplied HTTP headers in a given surface.
public struct HTTPHeaderValidationPolicy: Sendable, Equatable {
  /// Lowercased header names reserved by the app or protocol adapter.
  public var reservedNames: Set<String>
  /// Lowercased header name prefixes reserved by the protocol (e.g. `mcp-param-`).
  public var reservedPrefixes: [String]
  /// Active authentication header name (if using a named header scheme), trimmed and lowercased.
  public var authenticationHeaderName: String?

  public init(
    reservedNames: Set<String> = [],
    reservedPrefixes: [String] = [],
    authenticationHeaderName: String? = nil
  ) {
    self.reservedNames = Set(
      reservedNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    )
    self.reservedPrefixes = reservedPrefixes.map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    let trimmedAuth = authenticationHeaderName?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    self.authenticationHeaderName = (trimmedAuth?.isEmpty == false) ? trimmedAuth : nil
  }

  /// Policy for provider connection accounts.
  public static func provider(
    kind: ProviderKind,
    authentication: ProviderAuthentication
  ) -> HTTPHeaderValidationPolicy {
    var reserved: Set<String> = [
      "content-type",
      "accept",
    ]
    switch kind {
    case .anthropic:
      reserved.insert("anthropic-version")
    case .openRouter:
      reserved.formUnion([
        "x-openrouter-metadata",
        "http-referer",
        "x-openrouter-title",
        "x-title",
      ])
    default:
      break
    }

    let authHeader: String?
    switch authentication {
    case .header(let name):
      authHeader = name
    case .bearer, .none:
      authHeader = nil
    }

    return HTTPHeaderValidationPolicy(
      reservedNames: reserved,
      authenticationHeaderName: authHeader
    )
  }

  /// Policy for remote Streamable HTTP MCP servers.
  public static func mcp(
    authenticationHeader: String? = nil
  ) -> HTTPHeaderValidationPolicy {
    HTTPHeaderValidationPolicy(
      reservedNames: [
        "authorization",
        "content-type",
        "accept",
        "mcp-protocol-version",
        "mcp-method",
        "mcp-name",
        "mcp-session-id",
      ],
      reservedPrefixes: ["mcp-param-"],
      authenticationHeaderName: authenticationHeader
    )
  }

  public func isReserved(_ name: String) -> Bool {
    let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if reservedNames.contains(normalized) {
      return true
    }
    return reservedPrefixes.contains { normalized.hasPrefix($0) }
  }

  public func conflictsWithAuthentication(_ name: String) -> Bool {
    guard let authenticationHeaderName else { return false }
    let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized == authenticationHeaderName
  }
}

/// Typed validation errors for custom HTTP header names and values.
public enum HTTPHeaderValidationError: Error, LocalizedError, Sendable, Equatable {
  case emptyName
  case invalidName(String)
  case emptyValue
  case invalidValue
  case forbiddenHeader(String)
  case reservedHeader(String)
  case authenticationConflict(String)
  case duplicateHeader(String)

  public var errorDescription: String? {
    switch self {
    case .emptyName:
      return "Header name is required."
    case .invalidName(let name):
      return "Header name \"\(name)\" can only contain letters, numbers, and HTTP token symbols (no spaces or colons)."
    case .emptyValue:
      return "Header value is required."
    case .invalidValue:
      return "Header value cannot contain line breaks or control characters."
    case .forbiddenHeader(let name):
      return "The header \"\(name)\" is managed by the transport layer and cannot be customized."
    case .reservedHeader(let name):
      return "The header \"\(name)\" is reserved and managed automatically by BYOKchat."
    case .authenticationConflict(let name):
      return "The header \"\(name)\" conflicts with the authentication header."
    case .duplicateHeader(let name):
      return "A header named \"\(name)\" already exists."
    }
  }
}

/// Shared RFC 9110 & policy validator for custom HTTP headers across Provider and MCP surfaces.
public enum HTTPHeaderValidator: Sendable {
  /// RFC 9110 §5.6.2 HTTP token characters (`tchar`).
  private static let validNameScalars: Set<UnicodeScalar> = Set(
    "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".unicodeScalars
  )

  public static func isValidName(_ value: String) -> Bool {
    guard !value.isEmpty else { return false }
    return value.unicodeScalars.allSatisfy { validNameScalars.contains($0) }
  }

  public static func hasDisallowedValueCharacters(_ value: String) -> Bool {
    value.unicodeScalars.contains { scalar in
      let code = scalar.value
      // Disallow CR, LF, NUL, DEL, and all ASCII control characters other than horizontal tab (0x09).
      return (code < 0x20 && code != 0x09) || code == 0x7F
    }
  }

  /// Validates a single header entry and returns its normalized `(name, value)` pair.
  @discardableResult
  public static func validateEntry(
    name rawName: String,
    value rawValue: String,
    existingNames: [String] = [],
    policy: HTTPHeaderValidationPolicy
  ) throws -> (name: String, value: String) {
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      throw HTTPHeaderValidationError.emptyName
    }
    guard isValidName(name) else {
      throw HTTPHeaderValidationError.invalidName(name)
    }

    guard !hasDisallowedValueCharacters(rawValue) else {
      throw HTTPHeaderValidationError.invalidValue
    }
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else {
      throw HTTPHeaderValidationError.emptyValue
    }

    guard !ProviderHTTP.isForbiddenCustomHeader(name) else {
      throw HTTPHeaderValidationError.forbiddenHeader(name)
    }
    guard !policy.conflictsWithAuthentication(name) else {
      throw HTTPHeaderValidationError.authenticationConflict(name)
    }
    guard !policy.isReserved(name) else {
      throw HTTPHeaderValidationError.reservedHeader(name)
    }

    let normalized = name.lowercased()
    let hasDuplicate = existingNames.contains {
      $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
    }
    guard !hasDuplicate else {
      throw HTTPHeaderValidationError.duplicateHeader(name)
    }

    return (name: name, value: value)
  }

  /// Returns the first validation error for a single entry, or `nil` when valid.
  public static func firstError(
    name: String,
    value: String,
    existingNames: [String] = [],
    policy: HTTPHeaderValidationPolicy
  ) -> HTTPHeaderValidationError? {
    do {
      _ = try validateEntry(
        name: name,
        value: value,
        existingNames: existingNames,
        policy: policy
      )
      return nil
    } catch let error as HTTPHeaderValidationError {
      return error
    } catch {
      return .invalidValue
    }
  }

  /// Validates a complete header dictionary, including case-insensitive uniqueness.
  public static func validateHeaders(
    _ headers: [String: String],
    policy: HTTPHeaderValidationPolicy
  ) throws {
    var seenNames: [String] = []
    seenNames.reserveCapacity(headers.count)
    for (name, value) in headers {
      let validated = try validateEntry(
        name: name,
        value: value,
        existingNames: seenNames,
        policy: policy
      )
      seenNames.append(validated.name)
    }
  }
}
