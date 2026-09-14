import Foundation
import Testing

@testable import BYOKchatProviderCore

@Test func providerReportedCostAggregatesAcrossToolRounds() async throws {
  let providerWorkspace = ProviderWorkspaceStore(
    persistence: InMemoryProviderWorkspacePersistence()
  )
  try await providerWorkspace.load()
  let account = ProviderAccount(
    kind: .openRouter,
    id: "cost-account",
    providerID: "openrouter",
    label: "Cost Provider",
    defaultModelID: "cost-model"
  )
  try await providerWorkspace.upsertAccount(account)
  try await providerWorkspace.addManualModel(
    ProviderModel(
      providerID: "openrouter",
      id: "cost-model",
      displayName: "Cost Model",
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
    modelID: "cost-model"
  )

  let tools = ToolRuntime()
  try await tools.register(costAggregationTool()) { _ in
    .object(["value": .string("ok")])
  }

  let provider = ProviderReportedCostRuntime()
  let chat = ChatRuntime(
    providerRuntime: provider,
    providerWorkspace: providerWorkspace,
    conversations: conversations,
    toolRuntime: tools,
    partialPersistenceInterval: .zero
  )

  for try await _ in await chat.send(
    conversationID: conversation.id,
    userText: "Use the tool"
  ) {}

  let stored = try await conversations.conversation(id: conversation.id)
  let assistant = try #require(stored.messages.last)
  let billing = ChatBilling.snapshot(for: assistant)

  #expect(assistant.status == .complete)
  #expect(assistant.content == "finished")
  #expect(assistant.usage == .init(inputTokens: 15, outputTokens: 5))
  #expect(billing.costUSD == Decimal(string: "0.003"))
  #expect(billing.accuracy == .providerReported)
  #expect(billing.modelRequestCount == 2)
  #expect(billing.toolCallCount == 1)
}

@Test func partialProviderCostDoesNotMasqueradeAsCompleteExactCost() async throws {
  let providerWorkspace = ProviderWorkspaceStore(
    persistence: InMemoryProviderWorkspacePersistence()
  )
  try await providerWorkspace.load()
  let account = ProviderAccount(
    kind: .openRouter,
    id: "partial-cost-account",
    providerID: "openrouter",
    label: "Partial Cost Provider",
    defaultModelID: "priced-model"
  )
  try await providerWorkspace.upsertAccount(account)
  try await providerWorkspace.addManualModel(
    ProviderModel(
      providerID: "openrouter",
      id: "priced-model",
      displayName: "Priced Model",
      contextWindow: 16_384,
      maxOutputTokens: 1_024,
      promptPricePerToken: "0.001",
      completionPricePerToken: "0.002"
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
    modelID: "priced-model"
  )

  let tools = ToolRuntime()
  try await tools.register(costAggregationTool()) { _ in
    .object(["value": .string("ok")])
  }

  let provider = PartialProviderReportedCostRuntime()
  let chat = ChatRuntime(
    providerRuntime: provider,
    providerWorkspace: providerWorkspace,
    conversations: conversations,
    toolRuntime: tools,
    partialPersistenceInterval: .zero
  )

  for try await _ in await chat.send(
    conversationID: conversation.id,
    userText: "Use the tool"
  ) {}

  let stored = try await conversations.conversation(id: conversation.id)
  let assistant = try #require(stored.messages.last)
  let billing = ChatBilling.snapshot(for: assistant)

  #expect(assistant.usage == .init(inputTokens: 15, outputTokens: 5))
  #expect(billing.costUSD == Decimal(string: "0.025"))
  #expect(billing.accuracy == .calculated)
  #expect(billing.modelRequestCount == 2)
}

private func costAggregationTool() -> ChatToolDefinition {
  ChatToolDefinition(
    name: "lookup",
    description: "Look up a value",
    inputSchema: .object([
      "type": .string("object"),
      "properties": .object([:]),
    ])
  )
}

private func costAggregationCall() -> ChatToolCall {
  ChatToolCall(id: "call-1", name: "lookup", arguments: .object([:]))
}

private actor ProviderReportedCostRuntime: ProviderStreamingRuntime {
  private var requestCount = 0

  func stream(
    request: ProviderRequest,
    accountID: ProviderAccountID
  ) async throws -> AsyncThrowingStream<ProviderStreamEvent, Error> {
    requestCount += 1
    let index = requestCount
    return AsyncThrowingStream { continuation in
      if index == 1 {
        continuation.yield(
          .completed(
            ProviderResponse(
              text: "",
              providerID: "openrouter",
              accountID: accountID,
              modelID: request.model,
              finishReason: "tool_calls",
              usage: .init(inputTokens: 10, outputTokens: 2),
              metadata: ["costUSD": "0.001"],
              toolCalls: [costAggregationCall()]
            )
          )
        )
      } else {
        continuation.yield(
          .completed(
            ProviderResponse(
              text: "finished",
              providerID: "openrouter",
              accountID: accountID,
              modelID: request.model,
              finishReason: "stop",
              usage: .init(inputTokens: 5, outputTokens: 3),
              metadata: ["costUSD": "0.002"]
            )
          )
        )
      }
      continuation.finish()
    }
  }
}

private actor PartialProviderReportedCostRuntime: ProviderStreamingRuntime {
  private var requestCount = 0

  func stream(
    request: ProviderRequest,
    accountID: ProviderAccountID
  ) async throws -> AsyncThrowingStream<ProviderStreamEvent, Error> {
    requestCount += 1
    let index = requestCount
    return AsyncThrowingStream { continuation in
      if index == 1 {
        continuation.yield(
          .completed(
            ProviderResponse(
              text: "",
              providerID: "openrouter",
              accountID: accountID,
              modelID: request.model,
              finishReason: "tool_calls",
              usage: .init(inputTokens: 10, outputTokens: 2),
              metadata: ["costUSD": "0.001"],
              toolCalls: [costAggregationCall()]
            )
          )
        )
      } else {
        continuation.yield(
          .completed(
            ProviderResponse(
              text: "finished",
              providerID: "openrouter",
              accountID: accountID,
              modelID: request.model,
              finishReason: "stop",
              usage: .init(inputTokens: 5, outputTokens: 3)
            )
          )
        )
      }
      continuation.finish()
    }
  }
}
