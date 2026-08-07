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

  public init(
    id: String = UUID().uuidString.lowercased(),
    kind: ChatAttachmentKind,
    filename: String,
    mimeType: String,
    data: Data
  ) {
    self.id = id
    self.kind = kind
    self.filename = filename
    self.mimeType = mimeType
    self.data = data
  }

  public var byteCount: Int { data.count }

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
  public var createdAt: Date
  public var updatedAt: Date
  public var status: ChatMessageStatus
  public var providerID: ProviderID?
  public var accountID: ProviderAccountID?
  public var modelID: ModelID?
  public var finishReason: String?
  public var usage: ProviderUsage?
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
    createdAt: Date = .now,
    updatedAt: Date = .now,
    status: ChatMessageStatus,
    providerID: ProviderID? = nil,
    accountID: ProviderAccountID? = nil,
    modelID: ModelID? = nil,
    finishReason: String? = nil,
    usage: ProviderUsage? = nil,
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
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.status = status
    self.providerID = providerID
    self.accountID = accountID
    self.modelID = modelID
    self.finishReason = finishReason
    self.usage = usage
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
    draftText: String? = nil
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
  }

  public var lastMessagePreview: String? {
    messages.last(where: { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
      .content
  }
}

public struct ConversationWorkspaceState: Codable, Sendable, Equatable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var conversations: [ChatConversation]

  public init(
    schemaVersion: Int = Self.currentSchemaVersion,
    conversations: [ChatConversation] = []
  ) {
    self.schemaVersion = schemaVersion
    self.conversations = conversations
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
  case completed(ChatMessage)
  case cancelled(ChatMessage)
  case failed(ChatMessage)
}