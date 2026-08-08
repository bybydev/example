import Foundation
import Testing

@testable import BYOKchatProviderCore

@Test func explicitSmallOutputLimitIsRespected() throws {
  let conversation = ChatConversation(
    providerID: "deepseek",
    accountID: "account",
    modelID: "model",
    messages: [
      ChatMessage(role: .user, content: "hello", status: .complete)
    ]
  )

  let result = try ChatContextBuilder.build(
    conversation: conversation,
    contextWindow: 256,
    reservedOutputTokens: 64
  )

  #expect(result.messages.count == 1)
  #expect(result.messages.first?.content == "hello")
  #expect(result.estimatedInputTokens > 0)
}

@Test func unknownOutputLimitDoesNotStarveSmallContextWindow() throws {
  let conversation = ChatConversation(
    providerID: "openrouter",
    accountID: "account",
    modelID: "model",
    messages: [
      ChatMessage(role: .user, content: "small prompt", status: .complete)
    ]
  )

  let result = try ChatContextBuilder.build(
    conversation: conversation,
    contextWindow: 512
  )

  #expect(result.messages.last?.content == "small prompt")
  #expect(result.omittedMessageCount == 0)
}

@Test func safetyMarginCannotConsumeMostOfTinyRemainingInputBudget() throws {
  let conversation = ChatConversation(
    providerID: "deepseek",
    accountID: "account",
    modelID: "model",
    messages: [
      ChatMessage(
        role: .user,
        content: String(repeating: "x", count: 40),
        status: .complete
      )
    ]
  )

  let result = try ChatContextBuilder.build(
    conversation: conversation,
    contextWindow: 128,
    reservedOutputTokens: 64
  )

  #expect(result.messages.count == 1)
  #expect(result.omittedMessageCount == 0)
}

@Test func toolSchemasAreIncludedInEstimatedInputCost() throws {
  let conversation = ChatConversation(
    providerID: "openrouter",
    accountID: "account",
    modelID: "model",
    messages: [
      ChatMessage(role: .user, content: "hello", status: .complete)
    ]
  )

  let withoutTools = try ChatContextBuilder.build(
    conversation: conversation,
    contextWindow: nil
  )
  let tool = ChatToolDefinition(
    name: "large_tool",
    description: String(repeating: "d", count: 1_600),
    inputSchema: .object([
      "type": .string("object"),
      "properties": .object([
        "query": .object(["type": .string("string")])
      ]),
    ])
  )
  let withTools = try ChatContextBuilder.build(
    conversation: conversation,
    contextWindow: nil,
    tools: [tool]
  )

  #expect(withTools.messages == withoutTools.messages)
  #expect(withTools.estimatedInputTokens >= withoutTools.estimatedInputTokens + 400)
}

@Test func nonASCIIFallbackEstimateDoesNotUndercountCJKByUTF8Quartering() {
  let chinese = String(repeating: "你", count: 100)

  #expect(ChatContextBuilder.estimateTokens("") == 0)
  #expect(ChatContextBuilder.estimateTokens("abcd") == 1)
  #expect(ChatContextBuilder.estimateTokens(chinese) >= 100)
}

@Test func toolCallAndResultIDsContributeToContextEstimate() throws {
  let conversation = ChatConversation(
    providerID: "openrouter",
    accountID: "account",
    modelID: "model"
  )
  let shortID = "x"
  let longID = String(repeating: "i", count: 800)

  func tail(id: String) -> [ProviderMessage] {
    let call = ChatToolCall(
      id: id,
      name: "lookup",
      arguments: .object(["query": .string("value")])
    )
    let result = ChatToolResult(
      callID: id,
      name: "lookup",
      content: .string("ok")
    )
    return [
      ProviderMessage(role: .assistant, content: "", toolCalls: [call]),
      ProviderMessage(role: .tool, content: "", toolResults: [result]),
    ]
  }

  let short = try ChatContextBuilder.build(
    conversation: conversation,
    contextWindow: nil,
    requiredTailMessages: tail(id: shortID)
  )
  let long = try ChatContextBuilder.build(
    conversation: conversation,
    contextWindow: nil,
    requiredTailMessages: tail(id: longID)
  )

  #expect(long.estimatedInputTokens >= short.estimatedInputTokens + 350)
}

@Test func persistedToolRoundIsTrimmedAtomicallyWithItsHistoricalTurn() throws {
  let call = contextLookupCall()
  let result = ChatToolResult(
    callID: call.id,
    name: call.name,
    content: .object(["value": .string(String(repeating: "r", count: 2_000))])
  )
  let oldAssistant = ChatMessage(
    role: .assistant,
    content: "old final answer",
    toolRounds: [ChatToolRound(calls: [call], results: [result])],
    status: .complete
  )
  let conversation = ChatConversation(
    providerID: "openrouter",
    accountID: "account",
    modelID: "model",
    messages: [
      ChatMessage(
        role: .user,
        content: String(repeating: "u", count: 1_000),
        status: .complete
      ),
      oldAssistant,
      ChatMessage(role: .user, content: "latest question", status: .complete),
    ]
  )

  let context = try ChatContextBuilder.build(
    conversation: conversation,
    contextWindow: 500,
    reservedOutputTokens: 64,
    policy: noSafetyMarginPolicy()
  )

  #expect(context.omittedMessageCount == 2)
  #expect(context.messages.map(\.role) == [.user])
  #expect(context.messages.first?.content == "latest question")
  #expect(!context.messages.contains { $0.toolCalls != nil || $0.toolResults != nil })
}

@Test func requiredToolContinuationIsPreservedWhileOlderHistoryIsTrimmed() throws {
  let conversation = ChatConversation(
    providerID: "openrouter",
    accountID: "account",
    modelID: "model",
    messages: [
      ChatMessage(
        role: .user,
        content: String(repeating: "u", count: 1_000),
        status: .complete
      ),
      ChatMessage(
        role: .assistant,
        content: String(repeating: "a", count: 1_000),
        status: .complete
      ),
      ChatMessage(role: .user, content: "latest question", status: .complete),
    ]
  )
  let call = contextLookupCall()
  let result = ChatToolResult(
    callID: call.id,
    name: call.name,
    content: .object([
      "value": .string(String(repeating: "r", count: 800))
    ])
  )
  let requiredTail = [
    ProviderMessage(role: .assistant, content: "", toolCalls: [call]),
    ProviderMessage(role: .tool, content: "", toolResults: [result]),
  ]

  let context = try ChatContextBuilder.build(
    conversation: conversation,
    contextWindow: 700,
    reservedOutputTokens: 64,
    requiredTailMessages: requiredTail,
    policy: noSafetyMarginPolicy()
  )

  #expect(context.omittedMessageCount == 2)
  #expect(context.messages.map(\.role) == [.user, .assistant, .tool])
  #expect(context.messages.first?.content == "latest question")
  #expect(context.messages[1].toolCalls == [call])
  #expect(context.messages[2].toolResults == [result])
}

@Test func requiredToolContinuationFailsInsteadOfDroppingCurrentUserTurn() throws {
  let conversation = ChatConversation(
    providerID: "openrouter",
    accountID: "account",
    modelID: "model",
    messages: [
      ChatMessage(role: .user, content: "latest question", status: .complete)
    ]
  )
  let call = contextLookupCall()
  let result = ChatToolResult(
    callID: call.id,
    name: call.name,
    content: .object([
      "value": .string(String(repeating: "r", count: 3_000))
    ])
  )

  #expect(throws: ProviderError.self) {
    _ = try ChatContextBuilder.build(
      conversation: conversation,
      contextWindow: 700,
      reservedOutputTokens: 64,
      requiredTailMessages: [
        ProviderMessage(role: .assistant, content: "", toolCalls: [call]),
        ProviderMessage(role: .tool, content: "", toolResults: [result]),
      ],
      policy: noSafetyMarginPolicy()
    )
  }
}

@Test func runtimeRebudgetsAfterToolRoundAndEvictsOnlyOldHistory() async throws {
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
      contextWindow: 2_048,
      maxOutputTokens: 128
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

  let oldUserText = String(repeating: "u", count: 1_600)
  let oldAssistantText = String(repeating: "a", count: 1_600)
  let oldTurn = try await conversations.beginTurn(
    conversationID: conversation.id,
    userText: oldUserText
  )
  _ = try await conversations.completeMessage(
    conversationID: conversation.id,
    messageID: oldTurn.assistantMessage.id,
    response: ProviderResponse(
      text: oldAssistantText,
      providerID: "openrouter",
      accountID: account.id,
      modelID: "model"
    )
  )

  let tools = ToolRuntime()
  let largeToolResult = String(repeating: "r", count: 5_000)
  try await tools.register(contextLookupTool()) { _ in
    .object(["value": .string(largeToolResult)])
  }

  let provider = ContextRebudgetingProviderRuntime()
  let chat = ChatRuntime(
    providerRuntime: provider,
    providerWorkspace: providerWorkspace,
    conversations: conversations,
    toolRuntime: tools,
    partialPersistenceInterval: .zero
  )
  let currentQuestion = "current-question"

  for try await _ in await chat.send(
    conversationID: conversation.id,
    userText: currentQuestion
  ) {}

  let requests = await provider.requests
  #expect(requests.count == 2)
  #expect(requests[0].messages.contains { $0.content == oldUserText })
  #expect(requests[0].messages.contains { $0.content == oldAssistantText })
  #expect(requests[0].messages.last?.content == currentQuestion)

  #expect(!requests[1].messages.contains { $0.content == oldUserText })
  #expect(!requests[1].messages.contains { $0.content == oldAssistantText })
  #expect(requests[1].messages.map(\.role) == [.user, .assistant, .tool])
  #expect(requests[1].messages.first?.content == currentQuestion)
  #expect(requests[1].messages[1].toolCalls == [contextLookupCall()])
  #expect(
    requests[1].messages[2].toolResults?.first?.content
      == .object(["value": .string(largeToolResult)])
  )

  let stored = try await conversations.conversation(id: conversation.id)
  #expect(stored.lastContextOmittedMessageCount == 2)
  #expect(stored.messages.last?.status == .complete)
  #expect(stored.messages.last?.content == "done")
}

@Test func oversizedToolSchemaFailsBeforeAnyProviderRequest() async throws {
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
      contextWindow: 512,
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
  try await tools.register(
    ChatToolDefinition(
      name: "oversized_tool",
      description: String(repeating: "d", count: 3_000),
      inputSchema: .object(["type": .string("object")])
    )
  ) { _ in
    .string("unused")
  }
  let provider = ContextRecordingSuccessRuntime()
  let chat = ChatRuntime(
    providerRuntime: provider,
    providerWorkspace: providerWorkspace,
    conversations: conversations,
    toolRuntime: tools
  )

  await #expect(throws: ProviderError.self) {
    for try await _ in await chat.send(
      conversationID: conversation.id,
      userText: "hello"
    ) {}
  }

  #expect(await provider.requestCount() == 0)
  let stored = try await conversations.conversation(id: conversation.id)
  #expect(stored.messages.last?.status == .failed)
}

private func noSafetyMarginPolicy() -> ChatContextPolicy {
  ChatContextPolicy(
    safetyMarginRatio: 0,
    minimumSafetyMarginTokens: 0,
    maximumSafetyMarginTokens: 0
  )
}

private func contextLookupTool() -> ChatToolDefinition {
  ChatToolDefinition(
    name: "lookup_context",
    description: "Return context for a query",
    inputSchema: .object([
      "type": .string("object"),
      "properties": .object([
        "query": .object(["type": .string("string")])
      ]),
      "required": .array([.string("query")]),
    ])
  )
}

private func contextLookupCall() -> ChatToolCall {
  ChatToolCall(
    id: "call-1",
    name: "lookup_context",
    arguments: .object(["query": .string("current")])
  )
}

private actor ContextRebudgetingProviderRuntime: ProviderStreamingRuntime {
  private(set) var requests: [ProviderRequest] = []

  func stream(
    request: ProviderRequest,
    accountID: ProviderAccountID
  ) async throws -> AsyncThrowingStream<ProviderStreamEvent, Error> {
    requests.append(request)
    let requestIndex = requests.count
    return AsyncThrowingStream { continuation in
      if requestIndex == 1 {
        continuation.yield(
          .completed(
            ProviderResponse(
              text: "",
              providerID: "openrouter",
              accountID: accountID,
              modelID: request.model,
              finishReason: "tool_calls",
              usage: .init(inputTokens: 100, outputTokens: 10),
              toolCalls: [contextLookupCall()]
            )
          )
        )
      } else {
        continuation.yield(
          .completed(
            ProviderResponse(
              text: "done",
              providerID: "openrouter",
              accountID: accountID,
              modelID: request.model,
              finishReason: "stop",
              usage: .init(inputTokens: 1_300, outputTokens: 2)
            )
          )
        )
      }
      continuation.finish()
    }
  }
}

private actor ContextRecordingSuccessRuntime: ProviderStreamingRuntime {
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
            text: "unexpected",
            providerID: "openrouter",
            accountID: accountID,
            modelID: request.model
          )
        )
      )
      continuation.finish()
    }
  }

  func requestCount() -> Int { requests.count }
}
