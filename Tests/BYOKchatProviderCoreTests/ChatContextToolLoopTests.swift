import Foundation
import Testing

@testable import BYOKchatProviderCore

@Test func multiRoundToolLoopPreservesEveryRequiredContinuationInOrder() async throws {
  let providerWorkspace = ProviderWorkspaceStore(
    persistence: InMemoryProviderWorkspacePersistence()
  )
  try await providerWorkspace.load()
  let account = ProviderAccount(
    id: "account",
    providerID: "openrouter",
    label: "OpenRouter",
    defaultModelID: "model"
  )
  try await providerWorkspace.upsertAccount(account)
  try await providerWorkspace.addManualModel(
    ProviderModel(
      providerID: "openrouter",
      id: "model",
      displayName: "Model",
      contextWindow: 16_384,
      maxOutputTokens: 1_024
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

  let tools = ToolRuntime()
  try await tools.register(multiRoundTool()) { arguments in
    guard case .object(let object) = arguments,
      case .string(let query)? = object["query"]
    else {
      return .string("invalid")
    }
    return .object(["value": .string("result-\(query)")])
  }

  let provider = MultiRoundContextProviderRuntime()
  let chat = ChatRuntime(
    providerRuntime: provider,
    providerWorkspace: providerWorkspace,
    conversations: conversations,
    toolRuntime: tools,
    partialPersistenceInterval: .zero
  )

  for try await _ in await chat.send(
    conversationID: conversation.id,
    userText: "do two lookups"
  ) {}

  let requests = await provider.requests
  #expect(requests.count == 3)
  #expect(requests[0].messages.map(\.role) == [.user])
  #expect(requests[1].messages.map(\.role) == [.user, .assistant, .tool])
  #expect(
    requests[2].messages.map(\.role)
      == [.user, .assistant, .tool, .assistant, .tool]
  )

  #expect(requests[1].messages[1].toolCalls == [multiRoundCall(id: "call-1", query: "first")])
  #expect(requests[1].messages[2].toolResults?.first?.callID == "call-1")
  #expect(requests[1].messages[1].toolContinuation == multiRoundContinuation(id: "call-1", value: "sig-1"))

  #expect(requests[2].messages[1].toolCalls == [multiRoundCall(id: "call-1", query: "first")])
  #expect(requests[2].messages[2].toolResults?.first?.callID == "call-1")
  #expect(requests[2].messages[1].toolContinuation == multiRoundContinuation(id: "call-1", value: "sig-1"))
  #expect(requests[2].messages[3].toolCalls == [multiRoundCall(id: "call-2", query: "second")])
  #expect(requests[2].messages[4].toolResults?.first?.callID == "call-2")
  #expect(requests[2].messages[3].toolContinuation == multiRoundContinuation(id: "call-2", value: "sig-2"))

  let stored = try await conversations.conversation(id: conversation.id)
  let assistant = try #require(stored.messages.last)
  #expect(assistant.status == .complete)
  #expect(assistant.content == "finished")
  #expect(assistant.toolRounds?.count == 2)
  #expect(assistant.toolRounds?[0].calls == [multiRoundCall(id: "call-1", query: "first")])
  #expect(assistant.toolRounds?[1].calls == [multiRoundCall(id: "call-2", query: "second")])
}

@Test func opaqueProviderContinuationPayloadContributesToEstimatedInputCost() throws {
  let conversation = ChatConversation(
    providerID: "gemini",
    accountID: "account",
    modelID: "model"
  )
  let call = multiRoundCall(id: "call-1", query: "first")
  let baseMessage = ProviderMessage(
    role: .assistant,
    content: "",
    toolCalls: [call]
  )
  let continuationMessage = ProviderMessage(
    role: .assistant,
    content: "",
    toolCalls: [call],
    toolContinuation: ProviderToolContinuation(
      apiFamily: .geminiGenerateContent,
      payload: .object([
        "call-1": .string(String(repeating: "s", count: 2_000))
      ])
    )
  )

  let withoutContinuation = try ChatContextBuilder.build(
    conversation: conversation,
    contextWindow: nil,
    requiredTailMessages: [baseMessage]
  )
  let withContinuation = try ChatContextBuilder.build(
    conversation: conversation,
    contextWindow: nil,
    requiredTailMessages: [continuationMessage]
  )

  #expect(
    withContinuation.estimatedInputTokens
      >= withoutContinuation.estimatedInputTokens + 500
  )
}

@Test func oversizedToolResultStopsBeforeSecondProviderRequestAndPersistsFailure() async throws {
  let providerWorkspace = ProviderWorkspaceStore(
    persistence: InMemoryProviderWorkspacePersistence()
  )
  try await providerWorkspace.load()
  let account = ProviderAccount(
    id: "account",
    providerID: "openrouter",
    label: "OpenRouter",
    defaultModelID: "model"
  )
  try await providerWorkspace.upsertAccount(account)
  try await providerWorkspace.addManualModel(
    ProviderModel(
      providerID: "openrouter",
      id: "model",
      displayName: "Model",
      contextWindow: 768,
      maxOutputTokens: 64
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

  let tools = ToolRuntime()
  try await tools.register(multiRoundTool()) { _ in
    .object(["value": .string(String(repeating: "r", count: 5_000))])
  }

  let provider = SingleToolCallProviderRuntime()
  let chat = ChatRuntime(
    providerRuntime: provider,
    providerWorkspace: providerWorkspace,
    conversations: conversations,
    toolRuntime: tools,
    partialPersistenceInterval: .zero
  )

  await #expect(throws: ProviderError.self) {
    for try await _ in await chat.send(
      conversationID: conversation.id,
      userText: "lookup"
    ) {}
  }

  #expect(await provider.requestCount() == 1)
  let stored = try await conversations.conversation(id: conversation.id)
  let assistant = try #require(stored.messages.last)
  #expect(assistant.status == .failed)
  #expect(assistant.toolRounds?.count == 1)
  #expect(assistant.toolRounds?.first?.calls == [multiRoundCall(id: "call-1", query: "first")])
}

private func multiRoundTool() -> ChatToolDefinition {
  ChatToolDefinition(
    name: "multi_round_lookup",
    description: "Look up a value",
    inputSchema: .object([
      "type": .string("object"),
      "properties": .object([
        "query": .object(["type": .string("string")])
      ]),
      "required": .array([.string("query")]),
    ])
  )
}

private func multiRoundCall(id: String, query: String) -> ChatToolCall {
  ChatToolCall(
    id: id,
    name: "multi_round_lookup",
    arguments: .object(["query": .string(query)])
  )
}

private func multiRoundContinuation(id: String, value: String) -> ProviderToolContinuation {
  ProviderToolContinuation(
    apiFamily: .geminiGenerateContent,
    payload: .object([id: .string(value)])
  )
}

private actor MultiRoundContextProviderRuntime: ProviderStreamingRuntime {
  private(set) var requests: [ProviderRequest] = []

  func stream(
    request: ProviderRequest,
    accountID: ProviderAccountID
  ) async throws -> AsyncThrowingStream<ProviderStreamEvent, Error> {
    requests.append(request)
    let index = requests.count
    return AsyncThrowingStream { continuation in
      switch index {
      case 1:
        continuation.yield(
          .completed(
            ProviderResponse(
              text: "",
              providerID: "openrouter",
              accountID: accountID,
              modelID: request.model,
              finishReason: "tool_calls",
              toolCalls: [multiRoundCall(id: "call-1", query: "first")],
              toolContinuation: multiRoundContinuation(id: "call-1", value: "sig-1")
            )
          )
        )
      case 2:
        continuation.yield(
          .completed(
            ProviderResponse(
              text: "",
              providerID: "openrouter",
              accountID: accountID,
              modelID: request.model,
              finishReason: "tool_calls",
              toolCalls: [multiRoundCall(id: "call-2", query: "second")],
              toolContinuation: multiRoundContinuation(id: "call-2", value: "sig-2")
            )
          )
        )
      default:
        continuation.yield(
          .completed(
            ProviderResponse(
              text: "finished",
              providerID: "openrouter",
              accountID: accountID,
              modelID: request.model,
              finishReason: "stop"
            )
          )
        )
      }
      continuation.finish()
    }
  }
}

private actor SingleToolCallProviderRuntime: ProviderStreamingRuntime {
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
            text: "",
            providerID: "openrouter",
            accountID: accountID,
            modelID: request.model,
            finishReason: "tool_calls",
            toolCalls: [multiRoundCall(id: "call-1", query: "first")]
          )
        )
      )
      continuation.finish()
    }
  }

  func requestCount() -> Int { requests.count }
}
