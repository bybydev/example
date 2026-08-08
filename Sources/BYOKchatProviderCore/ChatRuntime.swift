import Foundation

public protocol ProviderStreamingRuntime: Sendable {
  func stream(
    request: ProviderRequest,
    accountID: ProviderAccountID
  ) async throws -> AsyncThrowingStream<ProviderStreamEvent, Error>
}

extension ProviderRuntime: ProviderStreamingRuntime {}

public actor ChatRuntime {
  private enum GenerationOperation: Sendable {
    case send(text: String, attachments: [ChatAttachment])
    case edit(messageID: ChatMessageID, text: String)
    case regenerate(confirmingUncertainCompletion: Bool)
  }

  private let providerRuntime: any ProviderStreamingRuntime
  private let providerWorkspace: ProviderWorkspaceStore
  private let conversations: ConversationStore
  private let projectWorkspace: ProjectWorkspaceStore?
  private let toolRuntime: (any ChatConversationToolExecuting)?
  private let maxToolRounds: Int

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
    projectWorkspace: ProjectWorkspaceStore? = nil,
    toolRuntime: (any ChatConversationToolExecuting)? = nil,
    maxToolRounds: Int = 8,
    partialPersistenceInterval: Duration = .milliseconds(300)
  ) {
    self.providerRuntime = providerRuntime
    self.providerWorkspace = providerWorkspace
    self.conversations = conversations
    self.projectWorkspace = projectWorkspace
    self.toolRuntime = toolRuntime
    self.maxToolRounds = max(1, maxToolRounds)
    self.partialPersistenceInterval = partialPersistenceInterval
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
      return AsyncThrowingStream { continuation in
        continuation.finish(throwing: ProviderError.conversationBusy(conversationID))
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

    var assistantID: ChatMessageID?
    var visibleText = ""
    var reasoningText = ""
    var visibleUsage: ProviderUsage?

    do {
      let turn = try await prepareTurn(
        conversationID: conversationID,
        operation: operation
      )
      assistantID = turn.assistantMessage.id
      activeStates[conversationID] = ActiveGenerationState(
        assistantID: turn.assistantMessage.id,
        content: "",
        reasoning: "",
        usage: nil
      )
      continuation.yield(.turnStarted(turn))

      let conversation = try await conversations.conversation(id: conversationID)
      let modelRecord = await providerWorkspace.modelRecords(for: conversation.accountID)
        .first { $0.model.id == conversation.modelID }
      let projectAttachments = await projectWorkspace?.files(for: conversationID).map(\.attachment) ?? []
      let tools: [ChatToolDefinition]
      if let toolRuntime {
        tools = await toolRuntime.availableTools(conversationID: conversationID)
      } else {
        tools = []
      }

      let context = try ChatContextBuilder.build(
        conversation: conversation,
        contextWindow: modelRecord?.model.contextWindow,
        reservedOutputTokens: conversation.options.maxOutputTokens,
        modelMaxOutputTokens: modelRecord?.model.maxOutputTokens,
        supplementalAttachments: projectAttachments,
        tools: tools
      )
      try await conversations.setContextOmissionCount(
        context.omittedMessageCount,
        conversationID: conversationID
      )

      var requestMessages = context.messages
      var continuationMessages: [ProviderMessage] = []
      var accumulatedUsage: ProviderUsage?
      var toolRoundCount = 0
      var totalToolCallCount = 0

      while true {
        try Task.checkCancellation()
        visibleText = ""
        reasoningText = ""
        visibleUsage = accumulatedUsage
        var stepUsage: ProviderUsage?
        var finalResponse: ProviderResponse?
        let clock = ContinuousClock()
        var lastPersist = clock.now

        let request = ProviderRequest(
          model: conversation.modelID,
          messages: requestMessages,
          options: conversation.options,
          tools: tools
        )
        let stream = try await providerRuntime.stream(
          request: request,
          accountID: conversation.accountID
        )

        for try await event in stream {
          try Task.checkCancellation()
          switch event {
          case .textDelta(let value):
            visibleText += value
            continuation.yield(.textDelta(messageID: turn.assistantMessage.id, value: value))
          case .reasoningDelta(let value):
            reasoningText += value
            continuation.yield(.reasoningDelta(messageID: turn.assistantMessage.id, value: value))
          case .usage(let value):
            stepUsage = value
            visibleUsage = addingUsage(accumulatedUsage, value)
            if let visibleUsage {
              continuation.yield(.usage(messageID: turn.assistantMessage.id, value: visibleUsage))
            }
          case .completed(let response):
            finalResponse = response
          }

          activeStates[conversationID] = ActiveGenerationState(
            assistantID: turn.assistantMessage.id,
            content: visibleText,
            reasoning: reasoningText,
            usage: visibleUsage
          )

          if lastPersist.duration(to: clock.now) >= partialPersistenceInterval {
            try await conversations.updateStreamingMessage(
              conversationID: conversationID,
              messageID: turn.assistantMessage.id,
              content: visibleText,
              reasoning: reasoningText,
              usage: visibleUsage
            )
            lastPersist = clock.now
          }
        }

        guard var response = finalResponse else {
          throw ProviderError.prematureStreamEnd
        }
        if response.text.isEmpty { response.text = visibleText }
        if response.reasoning.isEmpty { response.reasoning = reasoningText }
        let completedStepUsage = response.usage ?? stepUsage

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
            contextWindow: modelRecord?.model.contextWindow,
            reservedOutputTokens: conversation.options.maxOutputTokens,
            modelMaxOutputTokens: modelRecord?.model.maxOutputTokens,
            supplementalAttachments: projectAttachments,
            tools: tools,
            requiredTailMessages: continuationMessages
          )
          requestMessages = continuedContext.messages
          try await conversations.setContextOmissionCount(
            continuedContext.omittedMessageCount,
            conversationID: conversationID
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
        response.metadata = ChatBilling.metadata(
          existing: response.metadata,
          usage: response.usage,
          model: modelRecord?.model,
          modelRequestCount: toolRoundCount + 1,
          toolCallCount: totalToolCallCount
        )
        let completed = try await conversations.completeMessage(
          conversationID: conversationID,
          messageID: turn.assistantMessage.id,
          response: response
        )
        continuation.yield(.completed(completed))
        continuation.finish()
        return
      }
    } catch {
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
        continuation.finish(throwing: error)
      }
    }
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
