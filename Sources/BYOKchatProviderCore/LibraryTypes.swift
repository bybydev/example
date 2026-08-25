import Foundation

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
  public var source: LibraryEntrySource

  public init(
    id: LibraryEntryID = .init(),
    filename: String,
    kind: ChatAttachmentKind,
    mimeType: String,
    byteCount: Int,
    createdAt: Date = .now,
    source: LibraryEntrySource = .manual
  ) {
    self.id = id
    self.filename = filename
    self.kind = kind
    self.mimeType = mimeType
    self.byteCount = byteCount
    self.createdAt = createdAt
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
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var entries: [LibraryEntry]

  public init(
    schemaVersion: Int = Self.currentSchemaVersion,
    entries: [LibraryEntry] = []
  ) {
    self.schemaVersion = schemaVersion
    self.entries = entries
  }
}
