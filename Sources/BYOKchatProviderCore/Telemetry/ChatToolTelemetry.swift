import Foundation

struct ToolTelemetryFailureDescriptor: Sendable, Equatable {
  var errorCode: String
  var classification: String
  var metadata: [String: String]

  init(
    errorCode: String,
    classification: String,
    metadata: [String: String] = [:]
  ) {
    self.errorCode = errorCode
    self.classification = classification
    self.metadata = metadata
  }
}

struct ChatToolTelemetry: Sendable {
  let recorder: TelemetryRecorder?

  init(recorder: TelemetryRecorder?) {
    self.recorder = recorder ?? TelemetryRecorder.shared
  }

  func started(
    call: ChatToolCall,
    conversationID: ConversationID,
    source: String,
    serverID: MCPServerID? = nil,
    remoteToolName: String? = nil,
    policy: ChatToolPermissionPolicy? = nil
  ) {
    emit(
      TelemetryEvent(
        dataClass: .analytics,
        category: .tool,
        name: .toolCallStarted,
        conversationID: conversationID,
        toolCallCount: 1,
        metadata: metadata(
          call: call,
          source: source,
          serverID: serverID,
          remoteToolName: remoteToolName,
          policy: policy
        )
      )
    )
  }

  func completed(
    call: ChatToolCall,
    conversationID: ConversationID,
    source: String,
    serverID: MCPServerID? = nil,
    remoteToolName: String? = nil,
    policy: ChatToolPermissionPolicy? = nil,
    durationMilliseconds: Double,
    resultIsError: Bool,
    interactiveRoundCount: Int = 0,
    elicitationCount: Int = 0,
    approvalDecision: String? = nil
  ) {
    var metadata = metadata(
      call: call,
      source: source,
      serverID: serverID,
      remoteToolName: remoteToolName,
      policy: policy
    )
    metadata["interactiveRoundCount"] = String(max(0, interactiveRoundCount))
    metadata["elicitationCount"] = String(max(0, elicitationCount))
    if resultIsError { metadata["classification"] = "tool_result" }
    if let approvalDecision { metadata["approvalDecision"] = approvalDecision }

    emit(
      TelemetryEvent(
        dataClass: .analytics,
        category: .tool,
        name: resultIsError ? .toolCallFailed : .toolCallCompleted,
        severity: resultIsError ? .warning : .info,
        outcome: resultIsError ? .failure : .success,
        conversationID: conversationID,
        durationMilliseconds: durationMilliseconds,
        toolCallCount: 1,
        errorCode: resultIsError ? "tool_result_error" : nil,
        metadata: metadata
      )
    )
  }

  func failed(
    call: ChatToolCall,
    conversationID: ConversationID,
    source: String,
    serverID: MCPServerID? = nil,
    remoteToolName: String? = nil,
    policy: ChatToolPermissionPolicy? = nil,
    durationMilliseconds: Double,
    errorCode: String,
    classification: String,
    interactiveRoundCount: Int = 0,
    elicitationCount: Int = 0,
    approvalDecision: String? = nil
  ) {
    var metadata = metadata(
      call: call,
      source: source,
      serverID: serverID,
      remoteToolName: remoteToolName,
      policy: policy
    )
    metadata["classification"] = classification
    metadata["interactiveRoundCount"] = String(max(0, interactiveRoundCount))
    metadata["elicitationCount"] = String(max(0, elicitationCount))
    if let approvalDecision { metadata["approvalDecision"] = approvalDecision }

    emit(
      TelemetryEvent(
        dataClass: .analytics,
        category: .tool,
        name: .toolCallFailed,
        severity: .warning,
        outcome: .failure,
        conversationID: conversationID,
        durationMilliseconds: durationMilliseconds,
        toolCallCount: 1,
        errorCode: errorCode,
        metadata: metadata
      )
    )
  }

  func cancelled(
    call: ChatToolCall,
    conversationID: ConversationID,
    source: String,
    serverID: MCPServerID? = nil,
    remoteToolName: String? = nil,
    policy: ChatToolPermissionPolicy? = nil,
    durationMilliseconds: Double,
    interactiveRoundCount: Int = 0,
    elicitationCount: Int = 0
  ) {
    var metadata = metadata(
      call: call,
      source: source,
      serverID: serverID,
      remoteToolName: remoteToolName,
      policy: policy
    )
    metadata["classification"] = "cancelled"
    metadata["interactiveRoundCount"] = String(max(0, interactiveRoundCount))
    metadata["elicitationCount"] = String(max(0, elicitationCount))

    emit(
      TelemetryEvent(
        dataClass: .analytics,
        category: .tool,
        name: .toolCallCancelled,
        severity: .notice,
        outcome: .cancelled,
        conversationID: conversationID,
        durationMilliseconds: durationMilliseconds,
        toolCallCount: 1,
        errorCode: "cancelled",
        metadata: metadata
      )
    )
  }

  static func failureDescriptor(for error: Error) -> ToolTelemetryFailureDescriptor {
    if error is CancellationError {
      return .init(errorCode: "cancelled", classification: "cancelled")
    }
    guard let error = error as? MCPError else {
      return .init(errorCode: "unknown", classification: "unknown")
    }

    switch error {
    case .serverNotFound:
      return .init(errorCode: "server_not_found", classification: "configuration")
    case .invalidServer:
      return .init(errorCode: "invalid_server", classification: "configuration")
    case .missingCredential:
      return .init(errorCode: "missing_credential", classification: "authentication")
    case .authenticationFailed:
      return .init(errorCode: "authentication_failed", classification: "authentication")
    case .permissionDenied:
      return .init(errorCode: "permission_denied", classification: "permission")
    case .rateLimited:
      return .init(errorCode: "rate_limited", classification: "rate_limit")
    case .invalidResponse:
      return .init(errorCode: "invalid_response", classification: "protocol")
    case .protocolError(let code, _):
      return .init(
        errorCode: "protocol_error",
        classification: "protocol",
        metadata: ["protocolCode": String(code)]
      )
    case .unsupportedProtocol(let versions):
      return .init(
        errorCode: "unsupported_protocol",
        classification: "protocol",
        metadata: ["supportedVersionCount": String(versions.count)]
      )
    case .unsupportedLegacyTransport:
      return .init(errorCode: "unsupported_legacy_transport", classification: "protocol")
    case .toolNotFound:
      return .init(errorCode: "tool_not_found", classification: "configuration")
    case .invalidToolDefinition:
      return .init(errorCode: "invalid_tool_definition", classification: "protocol")
    case .inputRequired:
      return .init(errorCode: "input_required", classification: "interaction")
    case .transport:
      return .init(errorCode: "transport", classification: "transport")
    }
  }

  static func milliseconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1_000
      + Double(components.attoseconds) / 1_000_000_000_000_000
  }

  private func metadata(
    call: ChatToolCall,
    source: String,
    serverID: MCPServerID?,
    remoteToolName: String?,
    policy: ChatToolPermissionPolicy?
  ) -> [String: String] {
    var metadata: [String: String] = [
      "source": source,
      "toolName": call.name,
    ]
    if let serverID { metadata["serverID"] = serverID.rawValue }
    if let remoteToolName { metadata["remoteToolName"] = remoteToolName }
    if let policy { metadata["policy"] = policy.rawValue }
    return metadata
  }

  private func emit(_ event: TelemetryEvent) {
    guard let recorder else { return }
    _ = Task.detached(priority: .utility) {
      await recorder.record(event)
    }
  }
}
