import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case object([String: JSONValue])
  case array([JSONValue])
  case null

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Unsupported JSON value")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }
}

public extension CodingUserInfoKey {
  /// When `false`, `ChatAttachment` omits its inline `data` payload while
  /// encoding. Persistence uses this so attachment bytes live in blob files
  /// instead of the workspace JSON; exports and fingerprints keep the default
  /// (`true`), which embeds data for self-contained payloads.
  static let byokEmbedsAttachmentData = CodingUserInfoKey(
    rawValue: "byokchat.embedsAttachmentData"
  )!
}

extension JSONEncoder {
  static var providerEncoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  /// Like `providerEncoder`, but strips attachment byte payloads so persisted
  /// workspace JSON carries metadata only.
  static var providerEncoderWithoutAttachmentData: JSONEncoder {
    let encoder = providerEncoder
    encoder.userInfo[.byokEmbedsAttachmentData] = false
    return encoder
  }
}

extension JSONDecoder {
  static var provider: JSONDecoder { JSONDecoder() }
}
