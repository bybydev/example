import Foundation

public struct ConversationID: RawRepresentable, Hashable, Codable, Sendable,
  ExpressibleByStringLiteral, CustomStringConvertible
{
  public let rawValue: String

  public init(rawValue: String) { self.rawValue = rawValue }
  public init(stringLiteral value: String) { self.rawValue = value }
  public init() { self.rawValue = UUID().uuidString.lowercased() }
  public var description: String { rawValue }
}

public struct ChatMessageID: RawRepresentable, Hashable, Codable, Sendable,
  ExpressibleByStringLiteral, CustomStringConvertible
{
  public let rawValue: String

  public init(rawValue: String) { self.rawValue = rawValue }
  public init(stringLiteral value: String) { self.rawValue = value }
  public init() { self.rawValue = UUID().uuidString.lowercased() }
  public var description: String { rawValue }
}

public enum ChatAttachmentKind: String, Codable, Sendable {
  case image
  case file
}

public struct ChatAttachment: Codable, Sendable, Equatable, Identifiable {
  public var id: String
  public var kind: ChatAttachmentKind
  public var filename: String
  public var mimeType: String
  public var data: Data
  public var declaredByteCount: Int?

  private enum CodingKeys: String, CodingKey {
    case id, kind, filename, mimeType, data, declaredByteCount
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    kind = try container.decode(ChatAttachmentKind.self, forKey: .kind)
    filename = try container.decode(String.self, forKey: .filename)
    mimeType = try container.decode(String.self, forKey: .mimeType)
    data = try container.decodeIfPresent(Data.self, forKey: .data) ?? Data()
    declaredByteCount = try container.decodeIfPresent(Int.self, forKey: .declaredByteCount)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(kind, forKey: .kind)
    try container.encode(filename, forKey: .filename)
    try container.encode(mimeType, forKey: .mimeType)
    let embedsData = encoder.userInfo[.byokEmbedsAttachmentData] as? Bool ?? true
    if embedsData {
      try container.encode(data, forKey: .data)
    }
    try container.encodeIfPresent(declaredByteCount, forKey: .declaredByteCount)
  }

  public init(
    id: String = UUID().uuidString.lowercased(),
    kind: ChatAttachmentKind,
    filename: String,
    mimeType: String,
    data: Data,
    declaredByteCount: Int? = nil
  ) {
    self.id = id
    self.kind = kind
    self.filename = filename
    self.mimeType = mimeType
    self.data = data
    self.declaredByteCount = declaredByteCount
  }

  public var byteCount: Int { data.isEmpty ? (declaredByteCount ?? 0) : data.count }

  public var isImage: Bool {
    kind == .image || mimeType.lowercased().hasPrefix("image/")
  }

  public var isTextLike: Bool {
    let value = mimeType.lowercased()
    return value.hasPrefix("text/")
      || value == "application/json"
      || value == "application/xml"
      || value == "application/javascript"
      || value == "application/x-javascript"
      || value == "application/yaml"
      || value == "application/x-yaml"
  }

  public var utf8Text: String? {
    guard isTextLike else { return nil }
    return String(data: data, encoding: .utf8)
  }

  public var dataURL: String {
    "data:\(mimeType);base64,\(data.base64EncodedString())"
  }
}

public enum ChatMessageRole: String, Codable, Sendable {
  case user
  case assistant
}

public enum ChatMessageStatus: String, Codable, Sendable {
  case pending
  case streaming
  case complete
  case failed
  case cancelled
  case interrupted
}

public struct ChatMessage: Codable, Sendable, Equatable, Identifiable {
  public var id: ChatMessageID
  public var role: ChatMessageRole
  public var content: String
  public var reasoning: String
  public var attachments: [ChatAttachment]?
  public var toolRounds: [ChatToolRound]?
  public var createdAt: Date
  public var updatedAt: Date
  public var status: ChatMessageStatus
  public var providerID: ProviderID?
  public var accountID: ProviderAccountID?
  public var modelID: ModelID?
  public var finishReason: String?
  public var usage: ProviderUsage?
  public var providerContinuation: ProviderToolContinuation?
  public var metadata: [String: String]
  public var errorCode: String?
  public var errorDescription: String?
  public var completionUncertain: Bool?

  public init(
    id: ChatMessageID = .init(),
    role: ChatMessageRole,
    content: String = "",
    reasoning: String = "",
    attachments: [ChatAttachment]? = nil,
    toolRounds: [ChatToolRound]? = nil,
    createdAt: Date = .now,
    updatedAt: Date = .now,
    status: ChatMessageStatus,
    providerID: ProviderID? = nil,
    accountID: ProviderAccountID? = nil,
    modelID: ModelID? = nil,
    finishReason: String? = nil,
    usage: ProviderUsage? = nil,
    providerContinuation: ProviderToolContinuation? = nil,
    metadata: [String: String] = [:],
    errorCode: String? = nil,
    errorDescription: String? = nil,
    completionUncertain: Bool? = nil
  ) {
    self.id = id
    self.role = role
    self.content = content
    self.reasoning = reasoning
    self.attachments = attachments
    self.toolRounds = toolRounds
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.status = status
    self.providerID = providerID
    self.accountID = accountID
    self.modelID = modelID
    self.finishReason = finishReason
    self.usage = usage
    self.providerContinuation = providerContinuation
    self.metadata = metadata
    self.errorCode = errorCode
    self.errorDescription = errorDescription
    self.completionUncertain = completionUncertain
  }

  public var requiresRegenerationConfirmation: Bool { completionUncertain == true }
}

public struct ChatConversation: Codable, Sendable, Equatable, Identifiable {
  public var id: ConversationID
  public var title: String
  public var createdAt: Date
  public var updatedAt: Date
  public var providerID: ProviderID
  public var accountID: ProviderAccountID
  public var modelID: ModelID
  public var systemPrompt: String
  public var options: ProviderRequestOptions
  public var messages: [ChatMessage]
  public var lastContextOmittedMessageCount: Int
  public var draftText: String?

  /// Opt-in ownership for iOS new-chat cleanup. Older/imported/macOS records
  /// leave this nil. A persisted user message always takes precedence.
  public var isIOSNewChat: Bool?

  /// Present only on the lightweight conversation objects synthesized from
  /// `index.json`. Full conversation shards leave these nil.
  public var indexedMessageCount: Int?
  public var indexedLastMessagePreview: String?

  public init(
    id: ConversationID = .init(),
    title: String = "New Chat",
    createdAt: Date = .now,
    updatedAt: Date = .now,
    providerID: ProviderID,
    accountID: ProviderAccountID,
    modelID: ModelID,
    systemPrompt: String = "",
    options: ProviderRequestOptions = .init(),
    messages: [ChatMessage] = [],
    lastContextOmittedMessageCount: Int = 0,
    draftText: String? = nil,
    isIOSNewChat: Bool? = nil,
    indexedMessageCount: Int? = nil,
    indexedLastMessagePreview: String? = nil
  ) {
    self.id = id
    self.title = title
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.providerID = providerID
    self.accountID = accountID
    self.modelID = modelID
    self.systemPrompt = systemPrompt
    self.options = options
    self.messages = messages
    self.lastContextOmittedMessageCount = lastContextOmittedMessageCount
    self.draftText = draftText
    self.isIOSNewChat = isIOSNewChat
    self.indexedMessageCount = indexedMessageCount
    self.indexedLastMessagePreview = indexedLastMessagePreview
  }

  public var messageCount: Int { indexedMessageCount ?? messages.count }

  public var lastMessagePreview: String? {
    if let indexedLastMessagePreview { return indexedLastMessagePreview }
    return messages.last(where: { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
      .content
  }
}

/// Versioned envelope for one authoritative conversation shard. Version fields
/// are intentionally outside `ChatConversation` so readers can reject newer
/// formats before attempting to decode the conversation payload.
public struct ConversationShardRecord: Codable, Sendable, Equatable {
  public static let currentSchemaVersion = 1
  public static let currentReaderVersion = 1

  public var schemaVersion: Int
  public var minimumReaderVersion: Int
  public var conversation: ChatConversation

  public init(
    schemaVersion: Int = Self.currentSchemaVersion,
    minimumReaderVersion: Int = Self.currentReaderVersion,
    conversation: ChatConversation
  ) {
    self.schemaVersion = schemaVersion
    self.minimumReaderVersion = minimumReaderVersion
    self.conversation = conversation
  }
}

public struct ConversationWorkspaceState: Codable, Sendable, Equatable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var conversations: [ChatConversation]
  public var tombstones: [String: Date]

  public init(
    schemaVersion: Int = Self.currentSchemaVersion,
    conversations: [ChatConversation] = [],
    tombstones: [String: Date] = [:]
  ) {
    self.schemaVersion = schemaVersion
    self.conversations = conversations
    self.tombstones = tombstones
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, conversations, tombstones
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
      ?? Self.currentSchemaVersion
    conversations = try container.decodeIfPresent([ChatConversation].self, forKey: .conversations) ?? []
    tombstones = try container.decodeIfPresent([String: Date].self, forKey: .tombstones) ?? [:]
  }
}

/// Compact message metadata kept in index.json for analytics and attachment
/// history without storing message content/reasoning/tool payloads there.
public struct ConversationIndexMessage: Codable, Sendable, Equatable {
  public var id: ChatMessageID
  public var role: ChatMessageRole
  public var createdAt: Date
  public var updatedAt: Date
  public var status: ChatMessageStatus
  public var providerID: ProviderID?
  public var accountID: ProviderAccountID?
  public var modelID: ModelID?
  public var usage: ProviderUsage?
  public var metadata: [String: String]
  public var attachments: [ChatAttachment]?

  public init(message: ChatMessage) {
    id = message.id
    role = message.role
    createdAt = message.createdAt
    updatedAt = message.updatedAt
    status = message.status
    providerID = message.providerID
    accountID = message.accountID
    modelID = message.modelID
    usage = message.usage

    var compactMetadata = message.metadata
    if compactMetadata[ChatBilling.modelRequestCountKey] == nil,
      message.role == .assistant,
      message.status == .complete
    {
      compactMetadata[ChatBilling.modelRequestCountKey] = String(
        max(1, (message.toolRounds?.count ?? 0) + 1)
      )
    }
    if compactMetadata[ChatBilling.toolCallCountKey] == nil {
      let count = (message.toolRounds ?? []).reduce(0) { $0 + $1.calls.count }
      compactMetadata[ChatBilling.toolCallCountKey] = String(count)
    }
    metadata = compactMetadata

    attachments = message.attachments?.map { attachment in
      var value = attachment
      if value.declaredByteCount == nil, !value.data.isEmpty {
        value.declaredByteCount = value.data.count
      }
      value.data = Data()
      return value
    }
  }

  public var summaryMessage: ChatMessage {
    ChatMessage(
      id: id,
      role: role,
      attachments: attachments,
      createdAt: createdAt,
      updatedAt: updatedAt,
      status: status,
      providerID: providerID,
      accountID: accountID,
      modelID: modelID,
      usage: usage,
      metadata: metadata
    )
  }
}

/// Lightweight list metadata for one sharded conversation. It deliberately
/// omits message content/reasoning while retaining compact per-message usage
/// and attachment metadata needed by existing analytics/library surfaces.
public struct ConversationIndexEntry: Codable, Sendable, Equatable, Identifiable {
  public var id: ConversationID
  public var title: String
  public var createdAt: Date
  public var updatedAt: Date
  public var providerID: ProviderID
  public var accountID: ProviderAccountID
  public var modelID: ModelID
  public var draftText: String?
  public var isIOSNewChat: Bool?
  public var messageCount: Int
  public var lastMessagePreview: String?
  public var messages: [ConversationIndexMessage]
  public var referencedAttachmentIDs: [String]
  public var shardSchemaVersion: Int
  public var minimumReaderVersion: Int

  public init(conversation: ChatConversation) {
    id = conversation.id
    title = conversation.title
    createdAt = conversation.createdAt
    updatedAt = conversation.updatedAt
    providerID = conversation.providerID
    accountID = conversation.accountID
    modelID = conversation.modelID
    draftText = conversation.draftText
    isIOSNewChat = conversation.isIOSNewChat
    messageCount = conversation.messages.count
    lastMessagePreview = conversation.messages.last(where: {
      !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    })?.content
    messages = conversation.messages.map(ConversationIndexMessage.init)
    referencedAttachmentIDs = Array(
      Set(
        conversation.messages.flatMap { message in
          (message.attachments ?? []).map(\.id)
        }
      )
    ).sorted()
    shardSchemaVersion = ConversationShardRecord.currentSchemaVersion
    minimumReaderVersion = ConversationShardRecord.currentReaderVersion
  }

  public var summaryConversation: ChatConversation {
    ChatConversation(
      id: id,
      title: title,
      createdAt: createdAt,
      updatedAt: updatedAt,
      providerID: providerID,
      accountID: accountID,
      modelID: modelID,
      messages: messages.map(\.summaryMessage),
      draftText: draftText,
      isIOSNewChat: isIOSNewChat,
      indexedMessageCount: messageCount,
      indexedLastMessagePreview: lastMessagePreview
    )
  }
}

/// Startup catalog for the sharded layout. Version 2 is intentionally rich
/// enough that normal launch never needs to decode conversation shards.
public struct ConversationIndexState: Codable, Sendable, Equatable {
  public static let currentSchemaVersion = 2

  public var schemaVersion: Int
  public var entries: [ConversationIndexEntry]
  public var tombstones: [String: Date]

  public init(
    schemaVersion: Int = Self.currentSchemaVersion,
    entries: [ConversationIndexEntry] = [],
    tombstones: [String: Date] = [:]
  ) {
    self.schemaVersion = schemaVersion
    self.entries = entries
    self.tombstones = tombstones
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // Missing schemaVersion is an old index, never silently treated as v2.
    schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    entries = try container.decodeIfPresent([ConversationIndexEntry].self, forKey: .entries) ?? []
    tombstones = try container.decodeIfPresent([String: Date].self, forKey: .tombstones) ?? [:]
  }
}

public enum ConversationSearchMatchRole: String, Codable, Sendable {
  case title
  case user
  case assistant
}

public struct ConversationSearchResult: Sendable, Equatable, Identifiable {
  public var conversationID: ConversationID
  public var messageID: ChatMessageID?
  public var role: ConversationSearchMatchRole
  public var title: String
  public var snippet: String
  public var updatedAt: Date

  public var id: String {
    "\(conversationID.rawValue)::\(messageID?.rawValue ?? "title")"
  }

  public init(
    conversationID: ConversationID,
    messageID: ChatMessageID?,
    role: ConversationSearchMatchRole,
    title: String,
    snippet: String,
    updatedAt: Date
  ) {
    self.conversationID = conversationID
    self.messageID = messageID
    self.role = role
    self.title = title
    self.snippet = snippet
    self.updatedAt = updatedAt
  }
}

public struct ChatHistoryMutation: Sendable, Equatable {
  public var turn: ChatTurnStart
  public var removedMessageCount: Int

  public init(turn: ChatTurnStart, removedMessageCount: Int) {
    self.turn = turn
    self.removedMessageCount = removedMessageCount
  }
}

public struct ChatContextResult: Sendable, Equatable {
  public var messages: [ProviderMessage]
  public var omittedMessageCount: Int
  public var estimatedInputTokens: Int

  public init(
    messages: [ProviderMessage],
    omittedMessageCount: Int,
    estimatedInputTokens: Int
  ) {
    self.messages = messages
    self.omittedMessageCount = omittedMessageCount
    self.estimatedInputTokens = estimatedInputTokens
  }
}

public struct ChatTurnStart: Sendable, Equatable {
  public var conversationID: ConversationID
  public var userMessage: ChatMessage
  public var assistantMessage: ChatMessage

  public init(
    conversationID: ConversationID,
    userMessage: ChatMessage,
    assistantMessage: ChatMessage
  ) {
    self.conversationID = conversationID
    self.userMessage = userMessage
    self.assistantMessage = assistantMessage
  }
}

public enum ChatRuntimeEvent: Sendable, Equatable {
  case turnStarted(ChatTurnStart)
  case textDelta(messageID: ChatMessageID, value: String)
  case reasoningDelta(messageID: ChatMessageID, value: String)
  case usage(messageID: ChatMessageID, value: ProviderUsage)
  case toolCallsStarted(messageID: ChatMessageID, value: [ChatToolCall])
  case toolRound(messageID: ChatMessageID, value: ChatToolRound)
  case completed(ChatMessage)
  case cancelled(ChatMessage)
  case failed(ChatMessage)
}
