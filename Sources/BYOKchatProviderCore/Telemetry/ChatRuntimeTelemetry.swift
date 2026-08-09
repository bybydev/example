import Foundation

struct TelemetryFailureDescriptor: Sendable, Equatable {
  var errorCode: String
  var classification: String
  var httpStatus: Int?
  var metadata: [String: String]

  init(
    errorCode: String,
    classification: String,
    httpStatus: Int? = nil,
    metadata: [String: String] = [:]
  ) {
    self.errorCode = errorCode
    self.classification = classification
    self.httpStatus = httpStatus
    self.metadata = metadata
  }
}

struct ChatRuntimeTelemetry: Sendable {
  let recorder: TelemetryRecorder?

  init(recorder: TelemetryRecorder?) {
    self.recorder = recorder ?? TelemetryRecorder.shared
  }

  func turnStarted(_ turn: ChatTurnStart, operation: String) {
    let assistant = turn.assistantMessage
    emit(
      TelemetryEvent(
        dataClass: .analytics,
        category: .chat,
        name: .chatTurnStarted,
        conversationID: turn.conversationID,
        messageID: assistant.id,
        providerID: assistant.providerID,
        accountID: assistant.accountID,
        modelID: assistant.modelID,
        metadata: ["operation": operation]
      )
    )
  }

  func contextBuilt(
    _ context: ChatContextResult,
    conversation: ChatConversation,
    model: ProviderModel?,
    contextWindowKind: ProviderContextWindowKind,
    requestIndex: Int,
    toolCount: Int,
    projectFileCount: Int,
    isContinuation: Bool,
    messageID: ChatMessageID
  ) {
    var metadata: [String: String] = [
      "estimatedInputTokens": String(context.estimatedInputTokens),
      "includedMessageCount": String(context.messages.count),
      "omittedMessageCount": String(context.omittedMessageCount),
      "contextWindowKind": contextWindowKind.rawValue,
      "requestIndex": String(requestIndex),
      "toolCount": String(toolCount),
      "projectFileCount": String(projectFileCount),
      "isContinuation": String(isContinuation),
    ]
    if let contextWindow = model?.contextWindow {
      metadata["contextWindow"] = String(contextWindow)
    }
    if let maxOutputTokens = conversation.options.maxOutputTokens {
      metadata["requestedMaxOutputTokens"] = String(maxOutputTokens)
    }
    if let modelMaxOutputTokens = model?.maxOutputTokens {
      metadata["modelMaxOutputTokens"] = String(modelMaxOutputTokens)
    }

    emit(
      TelemetryEvent(
        dataClass: .analytics,
        category: .context,
        name: .contextBuilt,
        conversationID: conversation.id,
        messageID: messageID,
        providerID: conversation.providerID,
        accountID: conversation.accountID,
        modelID: conversation.modelID,
        metadata: metadata
      )
    )
  }

  func providerRequestStarted(
    conversation: ChatConversation,
    messageID: ChatMessageID,
    requestIndex: Int,
    requestMessageCount: Int,
    toolCount: Int
  ) {
    emit(
      TelemetryEvent(
        dataClass: .analytics,
        category: .provider,
        name: .providerRequestStarted,
        conversationID: conversation.id,
        messageID: messageID,
        providerID: conversation.providerID,
        accountID: conversation.accountID,
        modelID: conversation.modelID,
        modelRequestCount: 1,
        metadata: [
          "requestIndex": String(requestIndex),
          "requestMessageCount": String(requestMessageCount),
          "toolCount": String(toolCount),
          "retryCount": "0",
        ]
      )
    )
  }

  func providerFirstToken(
    conversation: ChatConversation,
    messageID: ChatMessageID,
    requestIndex: Int,
    milliseconds: Double
  ) {
    emit(
      TelemetryEvent(
        dataClass: .analytics,
        category: .provider,
        name: .providerFirstToken,
        conversationID: conversation.id,
        messageID: messageID,
        providerID: conversation.providerID,
        accountID: conversation.accountID,
        modelID: conversation.modelID,
        timeToFirstTokenMilliseconds: milliseconds,
        metadata: ["requestIndex": String(requestIndex)]
      )
    )
  }

  func providerRequestCompleted(
    conversation: ChatConversation,
    messageID: ChatMessageID,
    requestIndex: Int,
    response: ProviderResponse,
    usage: ProviderUsage?,
    durationMilliseconds: Double,
    timeToFirstTokenMilliseconds: Double?
  ) {
    var metadata: [String: String] = [
      "requestIndex": String(requestIndex),
      "retryCount": "0",
    ]
    if let finishReason = response.finishReason, !finishReason.isEmpty {
      metadata["finishReason"] = finishReason
    }
    if let routedProvider = response.metadata["provider"], !routedProvider.isEmpty {
      metadata["routedProvider"] = routedProvider
    }
    if let outputTokens = usage?.outputTokens, outputTokens > 0 {
      let generationMilliseconds = max(
        durationMilliseconds - (timeToFirstTokenMilliseconds ?? 0),
        1
      )
      let tokensPerSecond = Double(outputTokens) * 1_000 / generationMilliseconds
      metadata["outputTokensPerSecond"] = String(
        format: "%.2f",
        locale: Locale(identifier: "en_US_POSIX"),
        tokensPerSecond
      )
    }

    emit(
      TelemetryEvent(
        dataClass: .analytics,
        category: .provider,
        name: .providerRequestCompleted,
        outcome: .success,
        conversationID: conversation.id,
        messageID: messageID,
        providerID: conversation.providerID,
        accountID: conversation.accountID,
        modelID: conversation.modelID,
        durationMilliseconds: durationMilliseconds,
        timeToFirstTokenMilliseconds: timeToFirstTokenMilliseconds,
        inputTokens: usage?.inputTokens,
        outputTokens: usage?.outputTokens,
        cachedInputTokens: usage?.cachedInputTokens,
        reasoningTokens: usage?.reasoningTokens,
        modelRequestCount: 1,
        toolCallCount: response.toolCalls.count,
        metadata: metadata
      )
    )
  }

  func providerRequestFailed(
    conversation: ChatConversation,
    messageID: ChatMessageID,
    requestIndex: Int,
    error: Error,
    durationMilliseconds: Double,
    timeToFirstTokenMilliseconds: Double?
  ) {
    let cancelled = error is CancellationError
    let failure = Self.failureDescriptor(for: error)
    var metadata = failure.metadata
    metadata["classification"] = failure.classification
    metadata["requestIndex"] = String(requestIndex)
    metadata["retryCount"] = "0"

    emit(
      TelemetryEvent(
        dataClass: .analytics,
        category: .provider,
        name: cancelled ? .providerRequestCancelled : .providerRequestFailed,
        severity: cancelled ? .notice : .error,
        outcome: cancelled ? .cancelled : .failure,
        conversationID: conversation.id,
        messageID: messageID,
        providerID: conversation.providerID,
        accountID: conversation.accountID,
        modelID: conversation.modelID,
        durationMilliseconds: durationMilliseconds,
        timeToFirstTokenMilliseconds: timeToFirstTokenMilliseconds,
        modelRequestCount: 1,
        httpStatus: failure.httpStatus,
        errorCode: failure.errorCode,
        metadata: metadata
      )
    )
  }

  func turnCompleted(
    _ message: ChatMessage,
    conversationID: ConversationID,
    operation: String,
    durationMilliseconds: Double
  ) {
    let billing = ChatBilling.snapshot(for: message)
    emit(
      TelemetryEvent(
        dataClass: .analytics,
        category: .chat,
        name: .chatTurnCompleted,
        outcome: .success,
        conversationID: conversationID,
        messageID: message.id,
        providerID: message.providerID,
        accountID: message.accountID,
        modelID: message.modelID,
        durationMilliseconds: durationMilliseconds,
        inputTokens: message.usage?.inputTokens,
        outputTokens: message.usage?.outputTokens,
        cachedInputTokens: message.usage?.cachedInputTokens,
        reasoningTokens: message.usage?.reasoningTokens,
        modelRequestCount: billing.modelRequestCount,
        toolCallCount: billing.toolCallCount,
        metadata: ["operation": operation]
      )
    )
  }

  func turnFailed(
    conversationID: ConversationID,
    messageID: ChatMessageID?,
    providerID: ProviderID?,
    accountID: ProviderAccountID?,
    modelID: ModelID?,
    operation: String,
    error: Error,
    durationMilliseconds: Double
  ) {
    let failure = Self.failureDescriptor(for: error)
    var metadata = failure.metadata
    metadata["classification"] = failure.classification
    metadata["operation"] = operation

    emit(
      TelemetryEvent(
        dataClass: .analytics,
        category: .chat,
        name: .chatTurnFailed,
        severity: .error,
        outcome: .failure,
        conversationID: conversationID,
        messageID: messageID,
        providerID: providerID,
        accountID: accountID,
        modelID: modelID,
        durationMilliseconds: durationMilliseconds,
        httpStatus: failure.httpStatus,
        errorCode: failure.errorCode,
        metadata: metadata
      )
    )
  }

  func turnCancelled(
    conversationID: ConversationID,
    messageID: ChatMessageID?,
    providerID: ProviderID?,
    accountID: ProviderAccountID?,
    modelID: ModelID?,
    operation: String,
    durationMilliseconds: Double
  ) {
    emit(
      TelemetryEvent(
        dataClass: .analytics,
        category: .chat,
        name: .chatTurnCancelled,
        severity: .notice,
        outcome: .cancelled,
        conversationID: conversationID,
        messageID: messageID,
        providerID: providerID,
        accountID: accountID,
        modelID: modelID,
        durationMilliseconds: durationMilliseconds,
        errorCode: "cancelled",
        metadata: ["operation": operation]
      )
    )
  }

  func emit(_ event: TelemetryEvent) {
    guard let recorder else { return }
    _ = Task.detached(priority: .utility) {
      await recorder.record(event)
    }
  }

  static func milliseconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1_000
      + Double(components.attoseconds) / 1_000_000_000_000_000
  }

  static func failureDescriptor(for error: Error) -> TelemetryFailureDescriptor {
    if error is CancellationError {
      return .init(errorCode: "cancelled", classification: "cancelled")
    }
    guard let error = error as? ProviderError else {
      return .init(errorCode: "unknown", classification: "unknown")
    }

    switch error {
    case .authenticationFailed:
      return .init(errorCode: "authentication_failed", classification: "authentication", httpStatus: 401)
    case .permissionDenied:
      return .init(errorCode: "permission_denied", classification: "permission", httpStatus: 403)
    case .insufficientCredits:
      return .init(errorCode: "insufficient_credits", classification: "quota")
    case .rateLimited(let retryAfter):
      return .init(
        errorCode: "rate_limited",
        classification: "rate_limit",
        httpStatus: 429,
        metadata: ["retryAfterProvided": String(retryAfter != nil)]
      )
    case .modelUnavailable:
      return .init(errorCode: "model_unavailable", classification: "model")
    case .invalidEndpoint:
      return .init(errorCode: "invalid_endpoint", classification: "endpoint", httpStatus: 404)
    case .provider(let status, _):
      return .init(errorCode: "provider_http", classification: "http", httpStatus: status)
    case .midStreamProvider:
      return .init(errorCode: "mid_stream_provider", classification: "provider_stream")
    case .transport(_, let completionUnknown):
      return .init(
        errorCode: "transport",
        classification: "transport",
        metadata: ["completionUnknown": String(completionUnknown)]
      )
    case .invalidResponse:
      return .init(errorCode: "invalid_response", classification: "provider_response")
    case .emptyOutput:
      return .init(errorCode: "empty_output", classification: "provider_response")
    case .prematureStreamEnd:
      return .init(errorCode: "premature_stream_end", classification: "provider_stream")
    case .contextWindowExceeded(let estimatedInputTokens, let limit):
      return .init(
        errorCode: "context_window_exceeded",
        classification: "context",
        metadata: [
          "estimatedInputTokens": String(estimatedInputTokens),
          "contextLimit": String(limit),
        ]
      )
    case .missingCredential:
      return .init(errorCode: "missing_credential", classification: "configuration")
    case .invalidBaseURL:
      return .init(errorCode: "invalid_base_url", classification: "configuration")
    case .invalidModel:
      return .init(errorCode: "invalid_model", classification: "configuration")
    case .invalidMessages:
      return .init(errorCode: "invalid_messages", classification: "request")
    case .invalidRequest:
      return .init(errorCode: "invalid_request", classification: "request")
    case .unsafeHeader:
      return .init(errorCode: "unsafe_header", classification: "configuration")
    case .invalidDefinition:
      return .init(errorCode: "invalid_definition", classification: "configuration")
    case .duplicateProvider:
      return .init(errorCode: "duplicate_provider", classification: "configuration")
    case .providerNotFound:
      return .init(errorCode: "provider_not_found", classification: "configuration")
    case .accountNotFound:
      return .init(errorCode: "account_not_found", classification: "configuration")
    case .duplicateAccount:
      return .init(errorCode: "duplicate_account", classification: "configuration")
    case .unsupportedAPIFamily:
      return .init(errorCode: "unsupported_api_family", classification: "configuration")
    case .workspaceVersionUnsupported:
      return .init(errorCode: "workspace_version_unsupported", classification: "storage")
    case .conversationVersionUnsupported:
      return .init(errorCode: "conversation_version_unsupported", classification: "storage")
    case .backupVersionUnsupported:
      return .init(errorCode: "backup_version_unsupported", classification: "storage")
    case .conversationNotFound:
      return .init(errorCode: "conversation_not_found", classification: "local")
    case .conversationBusy:
      return .init(errorCode: "conversation_busy", classification: "local")
    case .chatMessageNotFound:
      return .init(errorCode: "chat_message_not_found", classification: "local")
    case .uncertainCompletionConfirmationRequired:
      return .init(errorCode: "uncertain_completion_confirmation_required", classification: "local")
    case .importConflict:
      return .init(errorCode: "import_conflict", classification: "storage")
    case .credentialCleanupFailed:
      return .init(errorCode: "credential_cleanup_failed", classification: "storage")
    }
  }
}
