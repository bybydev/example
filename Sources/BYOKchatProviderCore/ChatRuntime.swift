import Foundation

public protocol ProviderStreamingRuntime: Sendable {
  func stream(
    request: ProviderRequest,
    accountID: ProviderAccountID
  ) async throws -> AsyncThrowingStream<ProviderStreamEvent, Error>
}

extension ProviderRuntime: ProviderStreamingRuntime {}

func hydrateChatRuntimeAttachments(
  into messages: inout [ProviderMessage],
  loader: @Sendable (String) async -> Data?
) async throws {
  guard messages.contains(where: { !($0.attachments ?? []).isEmpty }) else { return }
  let latestUserIndex = messages.lastIndex(where: { $0.role == .user })

  for messageIndex in messages.indices {
    guard let attachments = messages[messageIndex].attachments, !attachments.isEmpty else {
      continue
    }

    var hydrated: [ChatAttachment] = []
    hydrated.reserveCapacity(attachments.count)
    var missingCurrent: [String] = []

    for var attachment in attachments {
      if !attachment.data.isEmpty {
        hydrated.append(attachment)
        continue
      }

      if let data = await loader(attachment.id), !data.isEmpty {
        attachment.data = data
        hydrated.append(attachment)
      } else if messageIndex == latestUserIndex {
        missingCurrent.append(attachment.filename)
      }
      // Missing historical blobs are omitted from the wire request. Their
      // persisted metadata remains untouched so UI can still show unavailable.
    }

    if !missingCurrent.isEmpty {
      let names = missingCurrent.joined(separator: ", ")
      throw ProviderError.invalidRequest(
        "One or more attachments for the current message are no longer available: \(names)."
      )
    }

    messages[messageIndex].attachments = hydrated.isEmpty ? nil : hydrated
  }
}

public actor ChatRuntime {
  private enum GenerationOperation: Sendable {
    case send(text: String, attachments: [ChatAttachment])
    case edit(messageID: ChatMessageID, text: String)
    case regenerate(confirmingUncertainCompletion: Bool)

    var telemetryName: String {
      switch self {
      case .send: "send"
      case .edit: "edit"
      case .regenerate: "regenerate"
      }
    }
  }

  private let providerRuntime: any ProviderStreamingRuntime
  private let providerWorkspace: ProviderWorkspaceStore
  private let conversations: ConversationStore
  private let toolRuntime: (any ChatConversationToolExecuting)?
  private let maxToolRounds: Int
  private let telemetry: ChatRuntimeTelemetry
  /// Attachment rows are metadata-only; bytes are fetched into the built
  /// request messages right before the provider call. nil (tests) skips the
  /// fetch, matching legacy in-memory fixtures.
  private let attachmentByteLoader: (@Sendable (String) async -> Data?)?

  private struct ActiveGenerationState: Sendable {
    var assistantID: ChatMessageID
    var content: String
    var reasoning: String
    var usage: ProviderUsage?
  }

  private let partialPersistenceInterval: Duration
  private var generationTasks: [ConversationID: Task<Void, Never>] = [:]
  private var activeStates: [ConversationID: ActiveGenerationState] = [:]

  public init(
    providerRuntime: any ProviderStreamingRuntime,
    providerWorkspace: ProviderWorkspaceStore,
    conversations: ConversationStore,
    toolRuntime: (any ChatConversationToolExecuting)? = nil,
    telemetryRecorder: TelemetryRecorder? = nil,
    maxToolRounds: Int = 8,
    partialPersistenceInterval: Duration = .milliseconds(300),
    attachmentByteLoader: (@Sendable (String) async -> Data?)? = nil
  ) {
    self.providerRuntime = providerRuntime
    self.providerWorkspace = providerWorkspace
    self.conversations = conversations
    self.toolRuntime = toolRuntime
    self.telemetry = ChatRuntimeTelemetry(recorder: telemetryRecorder)
    self.maxToolRounds = max(1, maxToolRounds)
    self.partialPersistenceInterval = partialPersistenceInterval
    self.attachmentByteLoader = attachmentByteLoader
      ?? { [conversations] id in await conversations.attachmentData(id) }
  }

  public func send(
    conversationID: ConversationID,
    userText: String,
    attachments: [ChatAttachment] = []
  ) -> AsyncThrowingStream<ChatRuntimeEvent, Error> {
    start(
      conversationID: conversationID,
      operation: .send(text: userText, attachments: attachments)
    )
  }

  public func editAndResend(
    conversationID: ConversationID,
    messageID: ChatMessageID,
    newText: String
  ) -> AsyncThrowingStream<ChatRuntimeEvent, Error> {
    start(
      conversationID: conversationID,
      operation: .edit(messageID: messageID, text: newText)
    )
  }

  public func regenerate(
    conversationID: ConversationID,
    confirmingUncertainCompletion: Bool = false
  ) -> AsyncThrowingStream<ChatRuntimeEvent, Error> {
    start(
      conversationID: conversationID,
      operation: .regenerate(
        confirmingUncertainCompletion: confirmingUncertainCompletion
      )
    )
  }

  public func cancel(conversationID: ConversationID) async {
    guard let task = generationTasks[conversationID] else { return }
    task.cancel()
    await task.value
  }

  public func flushActiveGenerations() async {
    for (conversationID, state) in activeStates {
      try? await conversations.updateStreamingMessage(
        conversationID: conversationID,
        messageID: state.assistantID,
        content: state.content,
        reasoning: state.reasoning,
        usage: state.usage
      )
    }
  }

  private func start(
    conversationID: ConversationID,
    operation: GenerationOperation
  ) -> AsyncThrowingStream<ChatRuntimeEvent, Error> {
    guard generationTasks[conversationID] == nil else {
      let error = ProviderError.conversationBusy(conversationID)
      telemetry.turnFailed(
        conversationID: conversationID,
        messageID: nil,
        providerID: nil,
        accountID: nil,
        modelID: nil,
        operation: operation.telemetryName,
        error: error,
        durationMilliseconds: 0
      )
      return AsyncThrowingStream { continuation in
        continuation.finish(throwing: error)
      }
    }

    let (stream, continuation) = AsyncThrowingStream<ChatRuntimeEvent, Error>.makeStream()
    let task = Task {
      await self.runGeneration(
        conversationID: conversationID,
        operation: operation,
        continuation: continuation
      )
    }
    generationTasks[conversationID] = task
    continuation.onTermination = { @Sendable _ in task.cancel() }
    return stream
  }

  private func runGeneration(
    conversationID: ConversationID,
    operation: GenerationOperation,
    continuation: AsyncThrowingStream<ChatRuntimeEvent, Error>.Continuation
  ) async {
    defer {
      generationTasks.removeValue(forKey: conversationID)
      activeStates.removeValue(forKey: conversationID)
    }

    let turnClock = ContinuousClock()
    let turnStartedAt = turnClock.now
    let operationName = operation.telemetryName

    var assistantID: ChatMessageID?
    var telemetryProviderID: ProviderID?
    var telemetryAccountID: ProviderAccountID?
    var telemetryModelID: ModelID?
    var visibleText = ""
    var reasoningText = ""
    var visibleUsage: ProviderUsage?

    do {
      let turn = try await prepareTurn(
        conversationID: conversationID,
        operation: operation
      )
      assistantID = turn.assistantMessage.id
      telemetryProviderID = turn.assistantMessage.providerID
      telemetryAccountID = turn.assistantMessage.accountID
      telemetryModelID = turn.assistantMessage.modelID
      activeStates[conversationID] = ActiveGenerationState(
        assistantID: turn.assistantMessage.id,
        content: "",
        reasoning: "",
        usage: nil
      )
      continuation.yield(.turnStarted(turn))
      telemetry.turnStarted(turn, operation: operationName)

      let conversation = try await conversations.conversation(id: conversationID)
      let modelRecord = await providerWorkspace.modelRecords(for: conversation.accountID)
        .first { $0.model.id == conversation.modelID }
      let model = modelRecord?.model
      let contextWindowKind = model?.effectiveContextWindowKind ?? .combined
      let tools: [ChatToolDefinition]
      if let toolRuntime {
        tools = await toolRuntime.availableTools(conversationID: conversationID)
      } else {
        tools = []
      }

      let context = try ChatContextBuilder.build(
        conversation: conversation,
        contextWindow: model?.contextWindow,
        contextWindowKind: contextWindowKind,
        reservedOutputTokens: conversation.options.maxOutputTokens,
        modelMaxOutputTokens: model?.maxOutputTokens,
        tools: tools
      )
      try await conversations.setContextOmissionCount(
        context.omittedMessageCount,
        conversationID: conversationID
      )
      telemetry.contextBuilt(
        context,
        conversation: conversation,
        model: model,
        contextWindowKind: contextWindowKind,
        requestIndex: 1,
        toolCount: tools.count,
        isContinuation: false,
        messageID: turn.assistantMessage.id
      )

      var requestMessages = context.messages
      // Attachment rows carry metadata only; fetch bytes for exactly the
      // messages in the built context before the first provider call.
      try await hydrateAttachments(into: &requestMessages)
      var continuationMessages: [ProviderMessage] = []
      var accumulatedUsage: ProviderUsage?
      var accumulatedProviderCostUSD = Decimal.zero
      var providerCostReportCount = 0
      var toolRoundCount = 0
      var totalToolCallCount = 0

      while true {
        try Task.checkCancellation()
        visibleText = ""
        reasoningText = ""
        visibleUsage = accumulatedUsage
        var stepUsage: ProviderUsage?
        var response: ProviderResponse
        let requestClock = ContinuousClock()
        let requestStartedAt = requestClock.now
        var lastPersist = requestStartedAt
        var firstTokenMilliseconds: Double?
        let requestIndex = toolRoundCount + 1

        let request = ProviderRequest(
          model: conversation.modelID,
          messages: requestMessages,
          options: conversation.options,
          tools: tools
        )
        telemetry.providerRequestStarted(
          conversation: conversation,
          messageID: turn.assistantMessage.id,
          requestIndex: requestIndex,
          requestMessageCount: request.messages.count,
          toolCount: request.tools.count
        )

        do {
          let stream = try await providerRuntime.stream(
            request: request,
            accountID: conversation.accountID
          )
          var finalResponse: ProviderResponse?

          for try await event in stream {
            try Task.checkCancellation()
            switch event {
            case .textDelta(let value):
              visibleText += value
              continuation.yield(.textDelta(messageID: turn.assistantMessage.id, value: value))
              if firstTokenMilliseconds == nil, !value.isEmpty {
                let milliseconds = ChatRuntimeTelemetry.milliseconds(
                  requestStartedAt.duration(to: requestClock.now)
                )
                firstTokenMilliseconds = milliseconds
                telemetry.providerFirstToken(
                  conversation: conversation,
                  messageID: turn.assistantMessage.id,
                  requestIndex: requestIndex,
                  milliseconds: milliseconds
                )
              }
            case .reasoningDelta(let value):
              reasoningText += value
              continuation.yield(.reasoningDelta(messageID: turn.assistantMessage.id, value: value))
              if firstTokenMilliseconds == nil, !value.isEmpty {
                let milliseconds = ChatRuntimeTelemetry.milliseconds(
                  requestStartedAt.duration(to: requestClock.now)
                )
                firstTokenMilliseconds = milliseconds
                telemetry.providerFirstToken(
                  conversation: conversation,
                  messageID: turn.assistantMessage.id,
                  requestIndex: requestIndex,
                  milliseconds: milliseconds
                )
              }
            case .usage(let value):
              stepUsage = value
              visibleUsage = addingUsage(accumulatedUsage, value)
              if let visibleUsage {
                continuation.yield(.usage(messageID: turn.assistantMessage.id, value: visibleUsage))
              }
            case .completed(let value):
              finalResponse = value
            }

            activeStates[conversationID] = ActiveGenerationState(
              assistantID: turn.assistantMessage.id,
              content: visibleText,
              reasoning: reasoningText,
              usage: visibleUsage
            )

            if lastPersist.duration(to: requestClock.now) >= partialPersistenceInterval {
              try await conversations.updateStreamingMessage(
                conversationID: conversationID,
                messageID: turn.assistantMessage.id,
                content: visibleText,
                reasoning: reasoningText,
                usage: visibleUsage
              )
              lastPersist = requestClock.now
            }
          }

          guard let finalResponse else {
            throw ProviderError.prematureStreamEnd
          }
          response = finalResponse
        } catch {
          telemetry.providerRequestFailed(
            conversation: conversation,
            messageID: turn.assistantMessage.id,
            requestIndex: requestIndex,
            error: error,
            durationMilliseconds: ChatRuntimeTelemetry.milliseconds(
              requestStartedAt.duration(to: requestClock.now)
            ),
            timeToFirstTokenMilliseconds: firstTokenMilliseconds
          )
          throw error
        }

        if response.text.isEmpty { response.text = visibleText }
        if response.reasoning.isEmpty { response.reasoning = reasoningText }
        let completedStepUsage = response.usage ?? stepUsage
        if let providerCost = ChatBilling.providerReportedCost(from: response.metadata) {
          accumulatedProviderCostUSD += providerCost
          providerCostReportCount += 1
        }
        telemetry.providerRequestCompleted(
          conversation: conversation,
          messageID: turn.assistantMessage.id,
          requestIndex: requestIndex,
          response: response,
          usage: completedStepUsage,
          durationMilliseconds: ChatRuntimeTelemetry.milliseconds(
            requestStartedAt.duration(to: requestClock.now)
          ),
          timeToFirstTokenMilliseconds: firstTokenMilliseconds
        )

        if !response.toolCalls.isEmpty {
          guard toolRoundCount < maxToolRounds else {
            throw ProviderError.invalidRequest(
              "The model exceeded the maximum of \(maxToolRounds) consecutive tool-call rounds."
            )
          }
          guard let toolRuntime else {
            throw ProviderError.invalidRequest(
              "The model requested a tool, but no tool runtime is configured."
            )
          }

          totalToolCallCount += response.toolCalls.count
          continuation.yield(
            .toolCallsStarted(
              messageID: turn.assistantMessage.id,
              value: response.toolCalls
            )
          )

          var results: [ChatToolResult] = []
          results.reserveCapacity(response.toolCalls.count)
          for call in response.toolCalls {
            try Task.checkCancellation()
            results.append(
              await toolRuntime.execute(call, conversationID: conversationID)
            )
          }

          let round = ChatToolRound(
            calls: response.toolCalls,
            results: results,
            assistantText: response.text,
            assistantReasoning: response.reasoning,
            usage: completedStepUsage,
            providerContinuation: response.toolContinuation
          )
          _ = try await conversations.appendToolRound(
            conversationID: conversationID,
            messageID: turn.assistantMessage.id,
            round: round
          )
          continuation.yield(.toolRound(messageID: turn.assistantMessage.id, value: round))

          accumulatedUsage = addingUsage(accumulatedUsage, completedStepUsage)
          continuationMessages.append(
            ProviderMessage(
              role: .assistant,
              content: response.text,
              reasoning: response.reasoning.isEmpty ? nil : response.reasoning,
              toolCalls: response.toolCalls,
              toolContinuation: response.toolContinuation
            )
          )
          continuationMessages.append(
            ProviderMessage(role: .tool, content: "", toolResults: results)
          )
          toolRoundCount += 1

          let continuedContext = try ChatContextBuilder.build(
            conversation: conversation,
            contextWindow: model?.contextWindow,
            contextWindowKind: contextWindowKind,
            reservedOutputTokens: conversation.options.maxOutputTokens,
            modelMaxOutputTokens: model?.maxOutputTokens,
            tools: tools,
            requiredTailMessages: continuationMessages
          )
          requestMessages = continuedContext.messages
          // Tool-round continuations rebuild context; the newest fetched bytes
          // ride along in continuationMessages, so hydrate the rebuilt tail.
          try await hydrateAttachments(into: &requestMessages)
          try await conversations.setContextOmissionCount(
            continuedContext.omittedMessageCount,
            conversationID: conversationID
          )
          telemetry.contextBuilt(
            continuedContext,
            conversation: conversation,
            model: model,
            contextWindowKind: contextWindowKind,
            requestIndex: toolRoundCount + 1,
            toolCount: tools.count,
            isContinuation: true,
            messageID: turn.assistantMessage.id
          )

          activeStates[conversationID] = ActiveGenerationState(
            assistantID: turn.assistantMessage.id,
            content: "",
            reasoning: "",
            usage: accumulatedUsage
          )
          continue
        }

        response.usage = addingUsage(accumulatedUsage, completedStepUsage)
        let modelRequestCount = toolRoundCount + 1
        response.metadata = ChatBilling.replacingProviderReportedCost(
          in: response.metadata,
          with: providerCostReportCount == modelRequestCount ? accumulatedProviderCostUSD : nil
        )
        response.metadata = ChatBilling.metadata(
          existing: response.metadata,
          usage: response.usage,
          model: model,
          modelRequestCount: modelRequestCount,
          toolCallCount: totalToolCallCount
        )
        let completed = try await conversations.completeMessage(
          conversationID: conversationID,
          messageID: turn.assistantMessage.id,
          response: response
        )
        continuation.yield(.completed(completed))
        telemetry.turnCompleted(
          completed,
          conversationID: conversationID,
          operation: operationName,
          durationMilliseconds: ChatRuntimeTelemetry.milliseconds(
            turnStartedAt.duration(to: turnClock.now)
          )
        )
        continuation.finish()
        return
      }
    } catch {
      let durationMilliseconds = ChatRuntimeTelemetry.milliseconds(
        turnStartedAt.duration(to: turnClock.now)
      )
      if Task.isCancelled || error is CancellationError {
        if let assistantID,
          let cancelled = try? await conversations.cancelMessage(
            conversationID: conversationID,
            messageID: assistantID,
            content: visibleText,
            reasoning: reasoningText
          )
        {
          continuation.yield(.cancelled(cancelled))
        }
        telemetry.turnCancelled(
          conversationID: conversationID,
          messageID: assistantID,
          providerID: telemetryProviderID,
          accountID: telemetryAccountID,
          modelID: telemetryModelID,
          operation: operationName,
          durationMilliseconds: durationMilliseconds
        )
        continuation.finish(throwing: CancellationError())
      } else {
        if let assistantID,
          let failed = try? await conversations.failMessage(
            conversationID: conversationID,
            messageID: assistantID,
            content: visibleText,
            reasoning: reasoningText,
            error: error
          )
        {
          continuation.yield(.failed(failed))
        }
        telemetry.turnFailed(
          conversationID: conversationID,
          messageID: assistantID,
          providerID: telemetryProviderID,
          accountID: telemetryAccountID,
          modelID: telemetryModelID,
          operation: operationName,
          error: error,
          durationMilliseconds: durationMilliseconds
        )
        continuation.finish(throwing: error)
      }
    }
  }

  /// Fills attachment bytes for the request messages through the blob store
  /// (just-in-time, scoped to this request). Missing historical blobs are
  /// omitted from the request; a missing attachment on the latest user turn
  /// fails that turn clearly instead of silently changing its meaning.
  private func hydrateAttachments(into messages: inout [ProviderMessage]) async throws {
    guard let attachmentByteLoader else { return }
    try await hydrateChatRuntimeAttachments(into: &messages, loader: attachmentByteLoader)
  }

  private func prepareTurn(
    conversationID: ConversationID,
    operation: GenerationOperation
  ) async throws -> ChatTurnStart {
    switch operation {
    case .send(let text, let attachments):
      return try await conversations.beginTurn(
        conversationID: conversationID,
        userText: text,
        attachments: attachments
      )
    case .edit(let messageID, let text):
      return try await conversations.editUserMessageAndBeginTurn(
        conversationID: conversationID,
        messageID: messageID,
        newText: text
      ).turn
    case .regenerate(let confirmingUncertainCompletion):
      return try await conversations.beginRegeneration(
        conversationID: conversationID,
        confirmingUncertainCompletion: confirmingUncertainCompletion
      ).turn
    }
  }

  private func addingUsage(_ lhs: ProviderUsage?, _ rhs: ProviderUsage?) -> ProviderUsage? {
    guard lhs != nil || rhs != nil else { return nil }
    return ProviderUsage(
      inputTokens: adding(lhs?.inputTokens, rhs?.inputTokens),
      outputTokens: adding(lhs?.outputTokens, rhs?.outputTokens),
      cachedInputTokens: adding(lhs?.cachedInputTokens, rhs?.cachedInputTokens),
      reasoningTokens: adding(lhs?.reasoningTokens, rhs?.reasoningTokens)
    )
  }

  private func adding(_ lhs: Int?, _ rhs: Int?) -> Int? {
    guard lhs != nil || rhs != nil else { return nil }
    return (lhs ?? 0) + (rhs ?? 0)
  }
}
