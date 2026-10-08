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
  #expect(billing.isComplete)
  #expect(billing.requests.count == 2)
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
  #expect(billing.costUSD == Decimal(string: "0.012"))
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


@Test(arguments: [0, 1, 2])
func toolRoundReceiptsRetainMissingUsageAndPaidRequests(mode: Int) async throws {
  let workspace = ProviderWorkspaceStore(persistence: InMemoryProviderWorkspacePersistence())
  try await workspace.load()
  let account = ProviderAccount(kind: .openRouter, id: "receipt-account", providerID: "openrouter", label: "Receipts")
  try await workspace.upsertAccount(account)
  try await workspace.addManualModel(ProviderModel(
    providerID: "openrouter", id: "receipt-model", displayName: "Receipts",
    contextWindow: 16_384, maxOutputTokens: 1_024,
    promptPricePerToken: "0.000001", completionPricePerToken: "0.000002"), for: account.id)
  let conversations = ConversationStore(persistence: InMemoryConversationWorkspacePersistence())
  try await conversations.load()
  let conversation = try await conversations.createConversation(
    providerID: account.providerID, accountID: account.id, modelID: "receipt-model")
  let tools = ToolRuntime()
  try await tools.register(costAggregationTool()) { _ in .object(["value": .string("ok")]) }
  let chat = ChatRuntime(providerRuntime: ReceiptRegressionRuntime(mode: mode), providerWorkspace: workspace,
    conversations: conversations, toolRuntime: tools, partialPersistenceInterval: .zero)
  do {
    for try await _ in await chat.send(conversationID: conversation.id, userText: "Use tool") {}
    #expect(mode != 2)
  } catch {
    #expect(mode == 2)
  }
  let stored = try await conversations.conversation(id: conversation.id)
  let assistant = try #require(stored.messages.last)
  let billing = ChatBilling.snapshot(for: assistant)
  #expect(assistant.status == (mode == 2 ? .failed : .complete))
  #expect(billing.modelRequestCount == 2 && billing.requests.count == 2)
  #expect(!billing.isComplete)
  #expect(billing.costUSD == Decimal(string: mode == 0 ? "0.000021" : "0.001"))
  #expect(billing.accuracy == (mode == 0 ? .calculated : .providerReported))
  #expect(billing.isLowerBound == (mode != 0))
  #expect(ChatBilling.aggregate(messages: [assistant]).hasPartialCost)
}

private actor ReceiptRegressionRuntime: ProviderStreamingRuntime {
  let mode: Int
  var count = 0
  init(mode: Int) { self.mode = mode }
  func stream(request: ProviderRequest, accountID: ProviderAccountID) async throws
    -> AsyncThrowingStream<ProviderStreamEvent, Error>
  {
    count += 1
    let index = count
    if index == 2 && mode == 2 { throw ProviderError.invalidResponse }
    let usage: ProviderUsage? = index == 1
      ? .init(inputTokens: 10, outputTokens: mode == 0 ? nil : 2)
      : (mode == 1 ? nil : .init(inputTokens: 5, outputTokens: 3))
    let response = ProviderResponse(text: index == 1 ? "" : "finished", providerID: "openrouter",
      accountID: accountID, modelID: request.model, usage: usage,
      metadata: index == 1 && mode != 0 ? ["costUSD": "0.001"] : [:],
      toolCalls: index == 1 ? [costAggregationCall()] : [])
    return AsyncThrowingStream { continuation in
      continuation.yield(.completed(response))
      continuation.finish()
    }
  }
}

@Test(arguments: [true, false])
func completedReceiptSurvivesCancellationOrTransportFailure(cancel: Bool) async throws {
  let workspace = ProviderWorkspaceStore(persistence: InMemoryProviderWorkspacePersistence())
  try await workspace.load()
  let account = ProviderAccount(kind: .openRouter, id: "completed-cost-account", label: "Completed receipt")
  try await workspace.upsertAccount(account)
  let persistence = InMemoryConversationWorkspacePersistence()
  let conversations = ConversationStore(persistence: persistence)
  try await conversations.load()
  let conversation = try await conversations.createConversation(
    providerID: account.providerID, accountID: account.id, modelID: "cost-model")
  let chat = ChatRuntime(providerRuntime: CompletedThenFailedRuntime(cancel: cancel),
    providerWorkspace: workspace, conversations: conversations)
  do {
    for try await _ in await chat.send(conversationID: conversation.id, userText: "Hello") {}
    Issue.record("The late stream error should still end the turn")
  } catch {
    #expect((error is CancellationError) == cancel)
  }

  let restored = ConversationStore(persistence: persistence)
  try await restored.load()
  let stored = try await restored.conversation(id: conversation.id)
  let assistant = try #require(stored.messages.last)
  let billing = ChatBilling.snapshot(for: assistant)
  #expect(assistant.status == (cancel ? .cancelled : .failed))
  #expect(assistant.content == "paid response")
  #expect(assistant.usage == .init(inputTokens: 10, outputTokens: 2))
  #expect(billing.costUSD == Decimal(string: "0.002"))
  #expect(billing.accuracy == .providerReported && billing.isComplete)
  #expect(billing.requests.count == 1)
  #expect(billing.requests.first?.completedAt != nil)
  let summaries = await restored.conversationSummaries()
  let indexedAssistant = try #require(summaries.first?.messages.last)
  #expect(ChatBilling.snapshot(for: indexedAssistant).costUSD == billing.costUSD)
}

@Test func endpointEditBetweenToolRoundsDoesNotReuseTurnStartPrices() async throws {
  let workspace = ProviderWorkspaceStore(persistence: InMemoryProviderWorkspacePersistence())
  try await workspace.load()
  let account = ProviderAccount(kind: .openAICompatible, id: "edited-cost-account", providerID: "openrouter",
    label: "Edited endpoint", baseURLOverride: URL(string: "https://old.example/v1"))
  try await workspace.upsertAccount(account)
  try await workspace.addManualModel(ProviderModel(providerID: account.providerID, id: "receipt-model",
    displayName: "Priced model", contextWindow: 16_384, maxOutputTokens: 1_024,
    promptPricePerToken: "0.000001", completionPricePerToken: "0.000002"), for: account.id)
  let conversations = ConversationStore(persistence: InMemoryConversationWorkspacePersistence())
  try await conversations.load()
  let conversation = try await conversations.createConversation(
    providerID: account.providerID, accountID: account.id, modelID: "receipt-model")
  let tools = ToolRuntime()
  try await tools.register(costAggregationTool()) { _ in
    var changed = account
    changed.baseURLOverride = URL(string: "https://new.example/v1")
    try await workspace.upsertAccount(changed)
    return .object(["value": .string("ok")])
  }
  let chat = ChatRuntime(providerRuntime: ReceiptRegressionRuntime(mode: 0), providerWorkspace: workspace,
    conversations: conversations, toolRuntime: tools)
  for try await _ in await chat.send(conversationID: conversation.id, userText: "Use tool") {}
  let stored = try await conversations.conversation(id: conversation.id)
  let assistant = try #require(stored.messages.last)
  let billing = ChatBilling.snapshot(for: assistant)
  #expect(assistant.status == .complete)
  #expect(billing.requests.count == 2)
  #expect(billing.requests.first?.costUSD == "0.00001")
  #expect(billing.requests.last?.pricing == nil)
  #expect(billing.requests.last?.costUSD == nil)
  #expect(billing.costUSD == Decimal(string: "0.00001") && !billing.isComplete)
}

private actor CompletedThenFailedRuntime: ProviderStreamingRuntime {
  let cancel: Bool
  init(cancel: Bool) { self.cancel = cancel }
  func stream(request: ProviderRequest, accountID: ProviderAccountID) async throws
    -> AsyncThrowingStream<ProviderStreamEvent, Error>
  {
    AsyncThrowingStream { continuation in
      continuation.yield(.completed(ProviderResponse(text: "paid response", providerID: "openrouter",
        accountID: accountID, modelID: request.model, usage: .init(inputTokens: 10, outputTokens: 2),
        metadata: ["costUSD": "0.002"])))
      if cancel { continuation.finish(throwing: CancellationError()) }
      else { continuation.finish(throwing: ProviderError.invalidResponse) }
    }
  }
}
