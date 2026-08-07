import Foundation

public enum ChatToolPermissionPolicy: String, Codable, Sendable, CaseIterable {
  case ask
  case alwaysAllow
  case disabled

  public var displayName: String {
    switch self {
    case .ask: "Ask"
    case .alwaysAllow: "Always Allow"
    case .disabled: "Disabled"
    }
  }
}

public struct MCPChatToolConfiguration: Codable, Sendable, Equatable {
  public var enabledServerIDs: [MCPServerID]
  public var toolPolicies: [String: ChatToolPermissionPolicy]

  public init(
    enabledServerIDs: [MCPServerID] = [],
    toolPolicies: [String: ChatToolPermissionPolicy] = [:]
  ) {
    self.enabledServerIDs = enabledServerIDs
    self.toolPolicies = toolPolicies
  }

  public func isServerEnabled(_ serverID: MCPServerID) -> Bool {
    enabledServerIDs.contains(serverID)
  }

  public func policy(for exposedToolName: String) -> ChatToolPermissionPolicy {
    toolPolicies[exposedToolName] ?? .ask
  }
}

public enum MCPToolApprovalDecision: String, Sendable, Equatable {
  case allowOnce
  case alwaysAllow
  case deny
}

public struct MCPToolApprovalRequest: Sendable, Equatable, Identifiable {
  public var id: String
  public var conversationID: ConversationID
  public var callID: String
  public var serverID: MCPServerID
  public var serverName: String
  public var exposedToolName: String
  public var remoteToolName: String
  public var toolTitle: String?
  public var toolDescription: String
  public var arguments: JSONValue
  public var readOnlyHint: Bool?
  public var destructiveHint: Bool?
  public var createdAt: Date

  public init(
    id: String = UUID().uuidString.lowercased(),
    conversationID: ConversationID,
    callID: String,
    serverID: MCPServerID,
    serverName: String,
    exposedToolName: String,
    remoteToolName: String,
    toolTitle: String? = nil,
    toolDescription: String,
    arguments: JSONValue,
    readOnlyHint: Bool? = nil,
    destructiveHint: Bool? = nil,
    createdAt: Date = .now
  ) {
    self.id = id
    self.conversationID = conversationID
    self.callID = callID
    self.serverID = serverID
    self.serverName = serverName
    self.exposedToolName = exposedToolName
    self.remoteToolName = remoteToolName
    self.toolTitle = toolTitle
    self.toolDescription = toolDescription
    self.arguments = arguments
    self.readOnlyHint = readOnlyHint
    self.destructiveHint = destructiveHint
    self.createdAt = createdAt
  }

  public var displayName: String {
    let name = toolTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
    return name?.isEmpty == false ? name! : remoteToolName
  }
}

public enum MCPElicitationMode: String, Sendable, Equatable {
  case form
  case url
}

public enum MCPElicitationFieldKind: String, Sendable, Equatable {
  case string
  case integer
  case number
  case boolean
  case stringArray
}

public struct MCPElicitationField: Sendable, Equatable, Identifiable {
  public var name: String
  public var title: String?
  public var description: String?
  public var kind: MCPElicitationFieldKind
  public var isRequired: Bool
  public var allowedValues: [String]
  public var defaultValue: JSONValue?

  public var id: String { name }

  public init(
    name: String,
    title: String? = nil,
    description: String? = nil,
    kind: MCPElicitationFieldKind,
    isRequired: Bool,
    allowedValues: [String] = [],
    defaultValue: JSONValue? = nil
  ) {
    self.name = name
    self.title = title
    self.description = description
    self.kind = kind
    self.isRequired = isRequired
    self.allowedValues = allowedValues
    self.defaultValue = defaultValue
  }

  public var displayName: String {
    let value = title?.trimmingCharacters(in: .whitespacesAndNewlines)
    return value?.isEmpty == false ? value! : name
  }
}

public enum MCPElicitationDecision: Sendable, Equatable {
  case accept([String: JSONValue])
  case decline
  case cancel
}

public struct MCPElicitationRequest: Sendable, Equatable, Identifiable {
  public var id: String
  public var interactionKey: String
  public var conversationID: ConversationID
  public var serverID: MCPServerID
  public var serverName: String
  public var exposedToolName: String
  public var remoteToolName: String
  public var message: String
  public var mode: MCPElicitationMode
  public var fields: [MCPElicitationField]
  public var url: URL?
  public var createdAt: Date

  public init(
    id: String = UUID().uuidString.lowercased(),
    interactionKey: String,
    conversationID: ConversationID,
    serverID: MCPServerID,
    serverName: String,
    exposedToolName: String,
    remoteToolName: String,
    message: String,
    mode: MCPElicitationMode,
    fields: [MCPElicitationField] = [],
    url: URL? = nil,
    createdAt: Date = .now
  ) {
    self.id = id
    self.interactionKey = interactionKey
    self.conversationID = conversationID
    self.serverID = serverID
    self.serverName = serverName
    self.exposedToolName = exposedToolName
    self.remoteToolName = remoteToolName
    self.message = message
    self.mode = mode
    self.fields = fields
    self.url = url
    self.createdAt = createdAt
  }
}

public struct MCPInputRequiredRound: Sendable, Equatable {
  public var inputRequests: [String: JSONValue]
  public var requestState: String?

  public init(inputRequests: [String: JSONValue], requestState: String?) {
    self.inputRequests = inputRequests
    self.requestState = requestState
  }
}

public actor MCPToolApprovalCenter {
  private struct Pending: Sendable {
    var request: MCPToolApprovalRequest
    var continuation: CheckedContinuation<MCPToolApprovalDecision, Never>
  }

  private var pending: [String: Pending] = [:]
  private var observers: [UUID: AsyncStream<[MCPToolApprovalRequest]>.Continuation] = [:]

  public init() {}

  public func updates() -> AsyncStream<[MCPToolApprovalRequest]> {
    let observerID = UUID()
    let (stream, continuation) = AsyncStream<[MCPToolApprovalRequest]>.makeStream()
    observers[observerID] = continuation
    continuation.yield(currentRequests())
    continuation.onTermination = { @Sendable _ in
      Task { await self.removeObserver(observerID) }
    }
    return stream
  }

  public func currentRequests() -> [MCPToolApprovalRequest] {
    pending.values.map(\.request).sorted { $0.createdAt < $1.createdAt }
  }

  public func requestApproval(_ request: MCPToolApprovalRequest) async -> MCPToolApprovalDecision {
    if Task.isCancelled { return .deny }
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        pending[request.id] = Pending(request: request, continuation: continuation)
        publish()
      }
    } onCancel: {
      Task { await self.resolve(request.id, decision: .deny) }
    }
  }

  public func resolve(_ requestID: String, decision: MCPToolApprovalDecision) {
    guard let value = pending.removeValue(forKey: requestID) else { return }
    value.continuation.resume(returning: decision)
    publish()
  }

  public func cancelConversation(_ conversationID: ConversationID) {
    let matches = pending.values.filter { $0.request.conversationID == conversationID }
    for value in matches {
      pending.removeValue(forKey: value.request.id)
      value.continuation.resume(returning: .deny)
    }
    if !matches.isEmpty { publish() }
  }

  private func publish() {
    let values = currentRequests()
    for observer in observers.values { observer.yield(values) }
  }

  private func removeObserver(_ id: UUID) {
    observers.removeValue(forKey: id)
  }
}

public actor MCPElicitationCenter {
  private struct Pending: Sendable {
    var request: MCPElicitationRequest
    var continuation: CheckedContinuation<MCPElicitationDecision, Never>
  }

  private var pending: [String: Pending] = [:]
  private var observers: [UUID: AsyncStream<[MCPElicitationRequest]>.Continuation] = [:]

  public init() {}

  public func updates() -> AsyncStream<[MCPElicitationRequest]> {
    let observerID = UUID()
    let (stream, continuation) = AsyncStream<[MCPElicitationRequest]>.makeStream()
    observers[observerID] = continuation
    continuation.yield(currentRequests())
    continuation.onTermination = { @Sendable _ in
      Task { await self.removeObserver(observerID) }
    }
    return stream
  }

  public func currentRequests() -> [MCPElicitationRequest] {
    pending.values.map(\.request).sorted { $0.createdAt < $1.createdAt }
  }

  public func requestInput(_ request: MCPElicitationRequest) async -> MCPElicitationDecision {
    if Task.isCancelled { return .cancel }
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        pending[request.id] = Pending(request: request, continuation: continuation)
        publish()
      }
    } onCancel: {
      Task { await self.resolve(request.id, decision: .cancel) }
    }
  }

  public func resolve(_ requestID: String, decision: MCPElicitationDecision) {
    guard let value = pending.removeValue(forKey: requestID) else { return }
    value.continuation.resume(returning: decision)
    publish()
  }

  public func cancelConversation(_ conversationID: ConversationID) {
    let matches = pending.values.filter { $0.request.conversationID == conversationID }
    for value in matches {
      pending.removeValue(forKey: value.request.id)
      value.continuation.resume(returning: .cancel)
    }
    if !matches.isEmpty { publish() }
  }

  private func publish() {
    let values = currentRequests()
    for observer in observers.values { observer.yield(values) }
  }

  private func removeObserver(_ id: UUID) {
    observers.removeValue(forKey: id)
  }
}
