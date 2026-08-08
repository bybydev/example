import Foundation
import Testing

@testable import BYOKchatProviderCore

@Test func modelMaximumDoesNotInflateDefaultOutputReserve() throws {
  let prompt = String(repeating: "x", count: 40_000)
  let conversation = ChatConversation(
    providerID: "deepseek",
    accountID: "account",
    modelID: "model",
    messages: [
      ChatMessage(role: .user, content: prompt, status: .complete)
    ]
  )

  let result = try ChatContextBuilder.build(
    conversation: conversation,
    contextWindow: 16_384,
    modelMaxOutputTokens: 100_000
  )

  #expect(result.messages.count == 1)
  #expect(result.messages.first?.content == prompt)
  #expect(result.omittedMessageCount == 0)
}

@Test func smallModelMaximumCanLowerFallbackOutputReserve() throws {
  let prompt = String(repeating: "x", count: 24_000)
  let conversation = ChatConversation(
    providerID: "openrouter",
    accountID: "account",
    modelID: "model",
    messages: [
      ChatMessage(role: .user, content: prompt, status: .complete)
    ]
  )

  let result = try ChatContextBuilder.build(
    conversation: conversation,
    contextWindow: 8_192,
    modelMaxOutputTokens: 64
  )

  #expect(result.messages.first?.content == prompt)
  #expect(result.omittedMessageCount == 0)
}

@Test func explicitOutputRequestTakesPriorityOverModelMaximumForBudgeting() throws {
  let prompt = String(repeating: "x", count: 16_000)
  let conversation = ChatConversation(
    providerID: "openrouter",
    accountID: "account",
    modelID: "model",
    messages: [
      ChatMessage(role: .user, content: prompt, status: .complete)
    ]
  )

  #expect(throws: ProviderError.self) {
    _ = try ChatContextBuilder.build(
      conversation: conversation,
      contextWindow: 8_192,
      reservedOutputTokens: 4_096,
      modelMaxOutputTokens: 64,
      policy: outputReserveNoSafetyMarginPolicy()
    )
  }
}

@Test func runtimeDoesNotReserveAdvertisedModelMaximumWhenOutputOptionIsBlank() async throws {
  let providerWorkspace = ProviderWorkspaceStore(
    persistence: InMemoryProviderWorkspacePersistence()
  )
  try await providerWorkspace.load()
  let account = ProviderAccount(
    id: "account",
    providerID: "deepseek",
    label: "DeepSeek",
    defaultModelID: "model"
  )
  try await providerWorkspace.upsertAccount(account)
  try await providerWorkspace.addManualModel(
    ProviderModel(
      providerID: "deepseek",
      id: "model",
      displayName: "Large-output model",
      contextWindow: 16_384,
      maxOutputTokens: 100_000
    ),
    for: account.id
  )

  let conversations = ConversationStore(
    persistence: InMemoryConversationWorkspacePersistence()
  )
  try await conversations.load()
  let conversation = try await conversations.createConversation(
    providerID: account.providerID,
    accountID: account.id,
    modelID: "model"
  )

  let provider = OutputReserveRecordingRuntime()
  let chat = ChatRuntime(
    providerRuntime: provider,
    providerWorkspace: providerWorkspace,
    conversations: conversations,
    partialPersistenceInterval: .zero
  )
  let prompt = String(repeating: "x", count: 40_000)

  for try await _ in await chat.send(
    conversationID: conversation.id,
    userText: prompt
  ) {}

  #expect(await provider.requestCount() == 1)
  let request = try #require(await provider.lastRequest())
  #expect(request.options.maxOutputTokens == nil)
  #expect(request.messages.last?.content == prompt)

  let stored = try await conversations.conversation(id: conversation.id)
  #expect(stored.messages.last?.status == .complete)
  #expect(stored.messages.last?.content == "ok")
}

private func outputReserveNoSafetyMarginPolicy() -> ChatContextPolicy {
  ChatContextPolicy(
    safetyMarginRatio: 0,
    minimumSafetyMarginTokens: 0,
    maximumSafetyMarginTokens: 0
  )
}

private actor OutputReserveRecordingRuntime: ProviderStreamingRuntime {
  private var requests: [ProviderRequest] = []

  func stream(
    request: ProviderRequest,
    accountID: ProviderAccountID
  ) async throws -> AsyncThrowingStream<ProviderStreamEvent, Error> {
    requests.append(request)
    return AsyncThrowingStream { continuation in
      continuation.yield(
        .completed(
          ProviderResponse(
            text: "ok",
            providerID: "deepseek",
            accountID: accountID,
            modelID: request.model,
            finishReason: "stop"
          )
        )
      )
      continuation.finish()
    }
  }

  func requestCount() -> Int { requests.count }
  func lastRequest() -> ProviderRequest? { requests.last }
}
