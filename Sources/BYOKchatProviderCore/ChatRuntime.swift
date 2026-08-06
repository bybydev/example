import Foundation

public protocol ProviderStreamingRuntime: Sendable {
  func stream(
    request: ProviderRequest,
    accountID: ProviderAccountID
  ) async throws -> AsyncThrowingStream<ProviderStreamEvent, Error>
}

extension ProviderRuntime: ProviderStreamingRuntime {}

public actor ChatRuntime {
  private let providerRuntime: any ProviderStreamingRuntime
  private let providerWorkspace: ProviderWorkspaceStore
  private let conversations: ConversationStore
  private let partialPersistenceInterval: Duration
  private var generationTasks: [ConversationID: Task<Void, Never>] = [:]

  public init(
    providerRuntime: any ProviderStreamingRuntime,
    providerWorkspace: ProviderWorkspaceStore,
    conversations: ConversationStore,
    partialPersistenceInterval: Duration = .milliseconds(300)
  ) {
    self.providerRuntime = providerRuntime
    self.providerWorkspace = providerWorkspace
    self.conversations = conversations
    self.partialPersistenceInterval = partialPersistenceInterval
  }

  public func send(
    conversationID: ConversationID,
    userText: String
  ) -> AsyncThrowingStream<ChatRuntimeEvent, Error> {
    guard generationTasks[conversationID] == nil else {
      return AsyncThrowingStream { continuation in
        continuation.finish(throwing: ProviderError.conversationBusy(conversationID))
      }
    }

    var capturedContinuation:
      AsyncThrowingStream<ChatRuntimeEvent, Error>.Continuation!
    let stream = AsyncThrowingStream<ChatRuntimeEvent, Error> { continuation in
      capturedContinuation = continuation
    }
    let task = Task {
      await self.runSend(
        conversationID: conversationID,
        userText: userText,
        continuation: capturedContinuation
      )
    }
    generationTasks[conversationID] = task
    capturedContinuation.onTermination = { _ in task.cancel() }
    return stream
  }

  public func cancel(conversationID: ConversationID) async {
    guard let task = generationTasks[conversationID] else { return }
    task.cancel()
    await task.value
  }

  private func runSend(
    conversationID: ConversationID,
    userText: String,
    continuation: AsyncThrowingStream<ChatRuntimeEvent, Error>.Continuation
  ) async {
    defer { generationTasks.removeValue(forKey: conversationID) }

    var assistantID: ChatMessageID?
    var visibleText = ""
    var reasoningText = ""
    var usage: ProviderUsage?

    do {
      let turn = try await conversations.beginTurn(
        conversationID: conversationID,
        userText: userText
      )
      assistantID = turn.assistantMessage.id
      continuation.yield(.turnStarted(turn))

      let conversation = try await conversations.conversation(id: conversationID)
      let modelRecord = await providerWorkspace.modelRecords(for: conversation.accountID)
        .first { $0.model.id == conversation.modelID }
      let context = ChatContextBuilder.build(
        conversation: conversation,
        contextWindow: modelRecord?.model.contextWindow,
        reservedOutputTokens: modelRecord?.model.maxOutputTokens
      )
      try await conversations.setContextOmissionCount(
        context.omittedMessageCount,
        conversationID: conversationID
      )

      let request = ProviderRequest(
        model: conversation.modelID,
        messages: context.messages,
        options: conversation.options
      )
      let stream = try await providerRuntime.stream(
        request: request,
        accountID: conversation.accountID
      )

      let clock = ContinuousClock()
      var lastPersist = clock.now
      var finalResponse: ProviderResponse?

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
          usage = value
          continuation.yield(.usage(messageID: turn.assistantMessage.id, value: value))
        case .completed(let response):
          finalResponse = response
        }

        if lastPersist.duration(to: clock.now) >= partialPersistenceInterval {
          try await conversations.updateStreamingMessage(
            conversationID: conversationID,
            messageID: turn.assistantMessage.id,
            content: visibleText,
            reasoning: reasoningText,
            usage: usage
          )
          lastPersist = clock.now
        }
      }

      guard var response = finalResponse else {
        throw ProviderError.prematureStreamEnd
      }
      if response.text.isEmpty { response.text = visibleText }
      if response.reasoning.isEmpty { response.reasoning = reasoningText }
      if response.usage == nil { response.usage = usage }
      let completed = try await conversations.completeMessage(
        conversationID: conversationID,
        messageID: turn.assistantMessage.id,
        response: response
      )
      continuation.yield(.completed(completed))
      continuation.finish()
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
}
