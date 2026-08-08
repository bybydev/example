import Foundation
import Testing

@testable import BYOKchatProviderCore

@Test func toolSchemasConsumeContextBudgetAndDropOnlyWholeOldTurns() throws {
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
      ChatMessage(role: .user, content: String(repeating: "q", count: 100), status: .complete),
    ]
  )
  let noSafetyMargin = ChatContextPolicy(
    safetyMarginRatio: 0,
    minimumSafetyMarginTokens: 0,
    maximumSafetyMarginTokens: 0
  )

  let withoutTools = try ChatContextBuilder.build(
    conversation: conversation,
    contextWindow: 1_200,
    reservedOutputTokens: 256,
    policy: noSafetyMargin
  )
  #expect(withoutTools.omittedMessageCount == 0)

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
    contextWindow: 1_200,
    reservedOutputTokens: 256,
    tools: [tool],
    policy: noSafetyMargin
  )

  #expect(withTools.omittedMessageCount == 2)
  #expect(withTools.messages.count == 1)
  #expect(withTools.messages.last?.role == .user)
  #expect(withTools.messages.last?.content == String(repeating: "q", count: 100))
  #expect(withTools.estimatedInputTokens > withoutTools.messages.last.map { _ in 0 } ?? 0)
}

@Test func defaultContextPolicyKeepsSafetyHeadroomForApproximateTokenCounting() throws {
  let conversation = ChatConversation(
    providerID: "deepseek",
    accountID: "account",
    modelID: "model",
    messages: [
      ChatMessage(
        role: .user,
        content: String(repeating: "x", count: 2_800),
        status: .complete
      )
    ]
  )
  let noSafetyMargin = ChatContextPolicy(
    safetyMarginRatio: 0,
    minimumSafetyMarginTokens: 0,
    maximumSafetyMarginTokens: 0
  )

  _ = try ChatContextBuilder.build(
    conversation: conversation,
    contextWindow: 1_000,
    reservedOutputTokens: 256,
    policy: noSafetyMargin
  )

  do {
    _ = try ChatContextBuilder.build(
      conversation: conversation,
      contextWindow: 1_000,
      reservedOutputTokens: 256
    )
    Issue.record("Expected the default safety margin to reject a near-limit prompt")
  } catch let error as ProviderError {
    guard case .contextWindowExceeded(let estimated, let limit) = error else {
      Issue.record("Expected contextWindowExceeded, got \(error)")
      return
    }
    #expect(estimated > limit)
    #expect(limit < 744)
  }
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
  let call = ChatToolCall(
    id: "call-1",
    name: "lookup",
    arguments: .object(["query": .string("latest")])
  )
  let result = ChatToolResult(
    callID: call.id,
    name: call.name,
    content: .object([
      "value": .string(String(repeating: "r", count: 2_000))
    ])
  )
  let requiredTail = [
    ProviderMessage(role: .assistant, content: "", toolCalls: [call]),
    ProviderMessage(role: .tool, content: "", toolResults: [result]),
  ]
  let noSafetyMargin = ChatContextPolicy(
    safetyMarginRatio: 0,
    minimumSafetyMarginTokens: 0,
    maximumSafetyMarginTokens: 0
  )

  let context = try ChatContextBuilder.build(
    conversation: conversation,
    contextWindow: 1_200,
    reservedOutputTokens: 256,
    requiredTailMessages: requiredTail,
    policy: noSafetyMargin
  )

  #expect(context.omittedMessageCount == 2)
  #expect(context.messages.first?.role == .user)
  #expect(context.messages.first?.content == "latest question")
  #expect(Array(context.messages.suffix(2)).map(\.role) == [.assistant, .tool])
  #expect(context.messages.last?.toolResults == [result])
}

@Test func requiredToolContinuationFailsInsteadOfBeingSilentlyDropped() throws {
  let conversation = ChatConversation(
    providerID: "openrouter",
    accountID: "account",
    modelID: "model",
    messages: [
      ChatMessage(role: .user, content: "latest question", status: .complete)
    ]
  )
  let result = ChatToolResult(
    callID: "call-1",
    name: "lookup",
    content: .object([
      "value": .string(String(repeating: "r", count: 4_000))
    ])
  )
  let noSafetyMargin = ChatContextPolicy(
    safetyMarginRatio: 0,
    minimumSafetyMarginTokens: 0,
    maximumSafetyMarginTokens: 0
  )

  #expect(throws: ProviderError.self) {
    _ = try ChatContextBuilder.build(
      conversation: conversation,
      contextWindow: 1_000,
      reservedOutputTokens: 256,
      requiredTailMessages: [
        ProviderMessage(role: .tool, content: "", toolResults: [result])
      ],
      policy: noSafetyMargin
    )
  }
}
