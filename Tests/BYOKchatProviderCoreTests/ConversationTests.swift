import Foundation
import Testing

@testable import BYOKchatProviderCore

private actor MockStreamingRuntime: ProviderStreamingRuntime {
  enum Mode: Sendable {
    case success
    case partialFailure
    case suspended
  }

  let mode: Mode
  private(set) var requests: [ProviderRequest] = []

  init(mode: Mode) { self.mode = mode }

  func stream(
    request: ProviderRequest,
    accountID: ProviderAccountID
  ) async throws -> AsyncThrowingStream<ProviderStreamEvent, Error> {
    requests.append(request)
    return AsyncThrowingStream { continuation in
      let task = Task {
        switch mode {
        case .success:
          continuation.yield(.reasoningDelta("Think "))
          continuation.yield(.textDelta("Hello"))
          let usage = ProviderUsage(inputTokens: 12, outputTokens: 4)
          continuation.yield(.usage(usage))
          continuation.yield(
            .completed(
              ProviderResponse(
                text: "Hello",
                reasoning: "Think ",
                providerID: "deepseek",
                accountID: accountID,
                modelID: request.model,
                finishReason: "stop",
                usage: usage
              )
            )
          )
          continuation.finish()
        case .partialFailure:
          continuation.yield(.textDelta("Partial"))
          continuation.finish(
            throwing: ProviderError.transport(
              message: "Connection lost.",
              completionUnknown: true
            )
          )
        case .suspended:
          do {
            try await Task.sleep(for: .seconds(30))
            continuation.finish()
          } catch {
            continuation.finish(throwing: CancellationError())
          }
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  func requestCount() -> Int { requests.count }
}

private func makeConversationEnvironment(
  runtimeMode: MockStreamingRuntime.Mode = .success,
  partialPersistenceInterval: Duration = .zero
) async throws -> (
  conversations: ConversationStore,
  providerWorkspace: ProviderWorkspaceStore,
  runtime: MockStreamingRuntime,
  chat: ChatRuntime,
  conversation: ChatConversation
) {
  let providerPersistence = InMemoryProviderWorkspacePersistence()
  let providerWorkspace = ProviderWorkspaceStore(persistence: providerPersistence)
  try await providerWorkspace.load()
  let account = ProviderAccount(
    id: "account",
    providerID: "deepseek",
    label: "DeepSeek",
    defaultModelID: "deepseek-v4-flash"
  )
  try await providerWorkspace.upsertAccount(account)
  try await providerWorkspace.addManualModel(
    ProviderModel(
      providerID: "deepseek",
      id: "deepseek-v4-flash",
      displayName: "DeepSeek V4 Flash",
      contextWindow: 256,
      maxOutputTokens: 64
    ),
    for: account.id
  )

  let conversationPersistence = InMemoryConversationWorkspacePersistence()
  let conversations = ConversationStore(persistence: conversationPersistence)
  try await conversations.load()
  let conversation = try await conversations.createConversation(
    providerID: account.providerID,
    accountID: account.id,
    modelID: "deepseek-v4-flash",
    systemPrompt: "Be concise."
  )
  let runtime = MockStreamingRuntime(mode: runtimeMode)
  let chat = ChatRuntime(
    providerRuntime: runtime,
    providerWorkspace: providerWorkspace,
    conversations: conversations,
    partialPersistenceInterval: partialPersistenceInterval
  )
  return (conversations, providerWorkspace, runtime, chat, conversation)
}

@Test func conversationStoreCreatesTitleAndRepairsInterruptedMessages() async throws {
  let persistence = InMemoryConversationWorkspacePersistence()
  let store = ConversationStore(persistence: persistence)
  try await store.load()
  let conversation = try await store.createConversation(
    providerID: "deepseek",
    accountID: "account",
    modelID: "deepseek-v4-flash"
  )
  let turn = try await store.beginTurn(
    conversationID: conversation.id,
    userText: "Explain provider routing in a clear and practical way for my app"
  )
  let afterTurn = try await store.conversation(id: conversation.id)
  #expect(afterTurn.title.hasSuffix("…"))
  #expect(afterTurn.messages.count == 2)
  #expect(afterTurn.messages.last?.status == .pending)

  let reloaded = ConversationStore(persistence: persistence)
  try await reloaded.load()
  let repaired = try await reloaded.conversation(id: conversation.id)
  #expect(
    repaired.messages.first(where: { $0.id == turn.assistantMessage.id })?.status == .interrupted)
}

@Test func contextBuilderExcludesIncompleteMessagesAndDropsWholeOldTurns() {
  let messages = [
    ChatMessage(role: .user, content: String(repeating: "old ", count: 100), status: .complete),
    ChatMessage(
      role: .assistant, content: String(repeating: "answer ", count: 100), status: .complete),
    ChatMessage(role: .user, content: "latest question", status: .complete),
    ChatMessage(role: .assistant, content: "not ready", status: .streaming),
  ]
  let conversation = ChatConversation(
    providerID: "deepseek",
    accountID: "account",
    modelID: "model",
    systemPrompt: "System",
    messages: messages
  )
  let result = ChatContextBuilder.build(
    conversation: conversation,
    contextWindow: 80,
    reservedOutputTokens: 32
  )

  #expect(result.messages.first?.role == .system)
  #expect(result.messages.last?.content == "latest question")
  #expect(!result.messages.contains(where: { $0.content == "not ready" }))
  #expect(result.omittedMessageCount == 2)
}

@Test func successfulChatRuntimePersistsNormalizedCompletion() async throws {
  let environment = try await makeConversationEnvironment()
  var events: [ChatRuntimeEvent] = []
  for try await event in await environment.chat.send(
    conversationID: environment.conversation.id,
    userText: "Hello"
  ) {
    events.append(event)
  }

  let saved = try await environment.conversations.conversation(id: environment.conversation.id)
  let assistant = try #require(saved.messages.last)
  #expect(assistant.status == .complete)
  #expect(assistant.content == "Hello")
  #expect(assistant.reasoning == "Think ")
  #expect(assistant.usage?.inputTokens == 12)
  #expect(events.contains(.textDelta(messageID: assistant.id, value: "Hello")))
  #expect(await environment.runtime.requestCount() == 1)
}

@Test func partialFailureIsRetainedAndNeverRetried() async throws {
  let environment = try await makeConversationEnvironment(runtimeMode: .partialFailure)
  await #expect(throws: ProviderError.self) {
    for try await _ in await environment.chat.send(
      conversationID: environment.conversation.id,
      userText: "Hello"
    ) {}
  }

  let saved = try await environment.conversations.conversation(id: environment.conversation.id)
  let assistant = try #require(saved.messages.last)
  #expect(assistant.status == .failed)
  #expect(assistant.content == "Partial")
  #expect(assistant.errorDescription == "Connection lost.")
  #expect(await environment.runtime.requestCount() == 1)
}

@Test func duplicateSendToSameConversationIsRejected() async throws {
  let environment = try await makeConversationEnvironment(runtimeMode: .suspended)
  let first = await environment.chat.send(
    conversationID: environment.conversation.id,
    userText: "First"
  )
  let firstTask = Task {
    do {
      for try await _ in first {}
    } catch {}
  }

  try await Task.sleep(for: .milliseconds(20))
  await #expect(throws: ProviderError.self) {
    for try await _ in await environment.chat.send(
      conversationID: environment.conversation.id,
      userText: "Second"
    ) {}
  }
  firstTask.cancel()
  _ = await firstTask.result
  #expect(await environment.runtime.requestCount() == 1)
}

@Test func cancellingChatRetainsPartialOutputAndMarksMessageCancelled() async throws {
  let providerPersistence = InMemoryProviderWorkspacePersistence()
  let providerWorkspace = ProviderWorkspaceStore(persistence: providerPersistence)
  try await providerWorkspace.load()
  let account = ProviderAccount(
    id: "account",
    providerID: "deepseek",
    label: "DeepSeek",
    defaultModelID: "model"
  )
  try await providerWorkspace.upsertAccount(account)
  try await providerWorkspace.addManualModel(
    ProviderModel(providerID: "deepseek", id: "model", displayName: "Model"),
    for: account.id
  )

  let store = ConversationStore(persistence: InMemoryConversationWorkspacePersistence())
  try await store.load()
  let conversation = try await store.createConversation(
    providerID: "deepseek",
    accountID: account.id,
    modelID: "model"
  )

  let provider = PartialThenSuspendRuntime()
  let chat = ChatRuntime(
    providerRuntime: provider,
    providerWorkspace: providerWorkspace,
    conversations: store,
    partialPersistenceInterval: .zero
  )
  let stream = await chat.send(conversationID: conversation.id, userText: "Hello")
  let task = Task {
    do {
      for try await _ in stream {}
    } catch {}
  }
  try await Task.sleep(for: .milliseconds(30))
  await chat.cancel(conversationID: conversation.id)
  task.cancel()
  _ = await task.result

  let saved = try await store.conversation(id: conversation.id)
  let assistant = try #require(saved.messages.last)
  #expect(assistant.status == .cancelled)
  #expect(assistant.content == "Partial")
}

private actor PartialThenSuspendRuntime: ProviderStreamingRuntime {
  func stream(
    request: ProviderRequest,
    accountID: ProviderAccountID
  ) async throws -> AsyncThrowingStream<ProviderStreamEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        continuation.yield(.textDelta("Partial"))
        do {
          try await Task.sleep(for: .seconds(30))
          continuation.finish()
        } catch {
          continuation.finish(throwing: CancellationError())
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

@Test func changingConversationTargetDoesNotRewriteExistingMessageMetadata() async throws {
  let store = ConversationStore(persistence: InMemoryConversationWorkspacePersistence())
  try await store.load()
  let conversation = try await store.createConversation(
    providerID: "deepseek",
    accountID: "old-account",
    modelID: "old-model"
  )
  _ = try await store.beginTurn(conversationID: conversation.id, userText: "Hello")

  try await store.updateTarget(
    conversation.id,
    providerID: "openrouter",
    accountID: "new-account",
    modelID: "new-model",
    systemPrompt: "New prompt",
    options: .init(temperature: 0.4)
  )

  let updated = try await store.conversation(id: conversation.id)
  #expect(updated.accountID == "new-account")
  #expect(updated.modelID == "new-model")
  #expect(updated.messages.first?.accountID == "old-account")
  #expect(updated.messages.first?.modelID == "old-model")
}
