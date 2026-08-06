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

  public init(
    id: ChatMessageID = .init(),
    role: ChatMessageRole,
    content: String = "",
    reasoning: String = "",
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
    errorDescription: String? = nil
  ) {
    self.id = id
    self.role = role
    self.content = content
    self.reasoning = reasoning
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
  }
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
    lastContextOmittedMessageCount: Int = 0
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
