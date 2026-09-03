import Foundation
import Testing

@testable import BYOKchatProviderCore

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

@Test func contextBuilderExcludesIncompleteMessagesAndDropsWholeOldTurns() throws {
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
  let result = try ChatContextBuilder.build(
    conversation: conversation,
    contextWindow: 400,
    reservedOutputTokens: 64
  )

  #expect(result.messages.first?.role == .system)
  #expect(result.messages.last?.content == "latest question")
  #expect(!result.messages.contains(where: { $0.content == "not ready" }))
  #expect(result.omittedMessageCount == 2)
  #expect(result.estimatedInputTokens <= 144)
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
    kind: ProviderKind(providerID: "deepseek"),
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

actor PartialThenSuspendRuntime: ProviderStreamingRuntime {
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
