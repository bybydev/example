import Foundation
import Testing

@testable import BYOKchatProviderCore

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

@Test func editAndResendTruncatesLinearHistory() async throws {
  let store = ConversationStore(persistence: InMemoryConversationWorkspacePersistence())
  try await store.load()
  let conversation = try await store.createConversation(
    providerID: "deepseek",
    accountID: "account",
    modelID: "model"
  )
  let first = try await store.beginTurn(conversationID: conversation.id, userText: "First question")
  _ = try await store.completeMessage(
    conversationID: conversation.id,
    messageID: first.assistantMessage.id,
    response: ProviderResponse(
      text: "First answer",
      providerID: "deepseek",
      accountID: "account",
      modelID: "model"
    )
  )
  let second = try await store.beginTurn(
    conversationID: conversation.id, userText: "Second question")
  _ = try await store.completeMessage(
    conversationID: conversation.id,
    messageID: second.assistantMessage.id,
    response: ProviderResponse(
      text: "Second answer",
      providerID: "deepseek",
      accountID: "account",
      modelID: "model"
    )
  )

  let mutation = try await store.editUserMessageAndBeginTurn(
    conversationID: conversation.id,
    messageID: first.userMessage.id,
    newText: "Edited first question"
  )
  let updated = try await store.conversation(id: conversation.id)

  #expect(mutation.removedMessageCount == 3)
  #expect(updated.messages.count == 2)
  #expect(updated.messages.first?.content == "Edited first question")
  #expect(updated.messages.last?.status == .pending)
  #expect(updated.title == "Edited first question")
}

@Test func regenerateReplacesLatestAssistantAndKeepsUserMessage() async throws {
  let store = ConversationStore(persistence: InMemoryConversationWorkspacePersistence())
  try await store.load()
  let conversation = try await store.createConversation(
    providerID: "deepseek",
    accountID: "account",
    modelID: "model"
  )
  let turn = try await store.beginTurn(conversationID: conversation.id, userText: "Question")
  _ = try await store.completeMessage(
    conversationID: conversation.id,
    messageID: turn.assistantMessage.id,
    response: ProviderResponse(
      text: "Old answer",
      providerID: "deepseek",
      accountID: "account",
      modelID: "model"
    )
  )

  let mutation = try await store.beginRegeneration(
    conversationID: conversation.id,
    confirmingUncertainCompletion: false
  )
  let updated = try await store.conversation(id: conversation.id)

  #expect(mutation.removedMessageCount == 1)
  #expect(updated.messages.count == 2)
  #expect(updated.messages.first?.id == turn.userMessage.id)
  #expect(updated.messages.last?.id != turn.assistantMessage.id)
  #expect(updated.messages.last?.status == .pending)
}

@Test func uncertainCompletionRequiresConfirmationBeforeRegeneration() async throws {
  let environment = try await makeConversationEnvironment(runtimeMode: .partialFailure)
  await #expect(throws: ProviderError.self) {
    for try await _ in await environment.chat.send(
      conversationID: environment.conversation.id,
      userText: "Hello"
    ) {}
  }

  let failed = try await environment.conversations.conversation(id: environment.conversation.id)
  #expect(failed.messages.last?.completionUncertain == true)

  await #expect(throws: ProviderError.self) {
    for try await _ in await environment.chat.regenerate(
      conversationID: environment.conversation.id
    ) {}
  }

  await #expect(throws: ProviderError.self) {
    for try await _ in await environment.chat.regenerate(
      conversationID: environment.conversation.id,
      confirmingUncertainCompletion: true
    ) {}
  }
  let regenerated = try await environment.conversations.conversation(
    id: environment.conversation.id)
  #expect(regenerated.messages.last?.status == .failed)
  #expect(await environment.runtime.requestCount() == 2)
}

@Test func draftsAndSearchPersistLocally() async throws {
  let persistence = InMemoryConversationWorkspacePersistence()
  let store = ConversationStore(persistence: persistence)
  try await store.load()
  let conversation = try await store.createConversation(
    providerID: "deepseek",
    accountID: "account",
    modelID: "model"
  )
  let turn = try await store.beginTurn(
    conversationID: conversation.id,
    userText: "Explain model routing"
  )
  _ = try await store.completeMessage(
    conversationID: conversation.id,
    messageID: turn.assistantMessage.id,
    response: ProviderResponse(
      text: "Routing chooses a provider endpoint.",
      providerID: "deepseek",
      accountID: "account",
      modelID: "model"
    )
  )
  try await store.setDraft("unfinished follow-up", conversationID: conversation.id)

  let results = await store.search("provider endpoint")
  #expect(results.count == 1)
  #expect(results.first?.messageID == turn.assistantMessage.id)

  let reloaded = ConversationStore(persistence: persistence)
  try await reloaded.load()
  let saved = try await reloaded.conversation(id: conversation.id)
  #expect(saved.draftText == "unfinished follow-up")
}
