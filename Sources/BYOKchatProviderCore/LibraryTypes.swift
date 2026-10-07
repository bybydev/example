import Foundation

/// A creation limit, distinct from a storage failure so the app can offer Pro.
public enum LibraryCapacityError: LocalizedError, Sendable {
  case limitReached(Int)

  public var errorDescription: String? {
    switch self {
    case .limitReached(let limit):
      "Free includes \(limit) saved files. Upgrade to BYOK Pro to save more."
    }
  }
}

public struct LibraryEntryID: RawRepresentable, Hashable, Codable, Sendable,
  ExpressibleByStringLiteral, CustomStringConvertible
{
  public let rawValue: String

  public init(rawValue: String) { self.rawValue = rawValue }
  public init(stringLiteral value: String) { self.rawValue = value }
  public init() { self.rawValue = UUID().uuidString.lowercased() }
  public var description: String { rawValue }
}

/// Where a library entry came from. Entries saved from a chat remember their
/// origin so the UI can offer a jump back to the source message.
public enum LibraryEntrySource: Codable, Sendable, Equatable {
  case chat(conversationID: ConversationID, messageID: ChatMessageID)
  case manual
  case project(ProjectID)
}

public struct LibraryEntry: Codable, Sendable, Equatable, Identifiable {
  public var id: LibraryEntryID
  public var filename: String
  public var kind: ChatAttachmentKind
  public var mimeType: String
  /// Stored explicitly; unlike chat attachments there is no inline payload to
  /// derive it from.
  public var byteCount: Int
  public var createdAt: Date
  /// Last metadata edit (rename); LWW ordering input for sync.
  public var updatedAt: Date
  public var source: LibraryEntrySource

  public init(
    id: LibraryEntryID = .init(),
    filename: String,
    kind: ChatAttachmentKind,
    mimeType: String,
    byteCount: Int,
    createdAt: Date = .now,
    updatedAt: Date = .now,
    source: LibraryEntrySource = .manual
  ) {
    self.id = id
    self.filename = filename
    self.kind = kind
    self.mimeType = mimeType
    self.byteCount = byteCount
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.source = source
  }

  public var isImage: Bool {
    kind == .image || mimeType.lowercased().hasPrefix("image/")
  }

  public var byteCountText: String {
    ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
  }
}

public struct LibraryWorkspaceState: Codable, Sendable, Equatable {
  /// Single pre-release schema; evolves in place, users fresh-install.
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var entries: [LibraryEntry]
  /// entryID → deletedAt. Pruned on load after the retention window.
  public var tombstones: [String: Date]

  public init(
    schemaVersion: Int = Self.currentSchemaVersion,
    entries: [LibraryEntry] = [],
    tombstones: [String: Date] = [:]
  ) {
    self.schemaVersion = schemaVersion
    self.entries = entries
    self.tombstones = tombstones
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, entries, tombstones
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
      ?? Self.currentSchemaVersion
    entries = try container.decodeIfPresent([LibraryEntry].self, forKey: .entries) ?? []
    tombstones = try container.decodeIfPresent([String: Date].self, forKey: .tombstones) ?? [:]
  }
}
