import Foundation
import Testing

@testable import BYOKchatProviderCore

@Test func responsesContinuationOnlyReplaysForTheExactChatTargetThatProducedIt() throws {
  let rawOutput: JSONValue = .array([
    .object([
      "id": .string("rs_provider_specific"),
      "type": .string("reasoning"),
      "encrypted_content": .string("opaque-provider-specific-state"),
      "summary": .array([]),
    ]),
    .object([
      "id": .string("msg_provider_specific"),
      "type": .string("message"),
      "role": .string("assistant"),
      "content": .array([
        .object(["type": .string("output_text"), "text": .string("First answer")])
      ]),
    ]),
  ])
  let continuation = ProviderToolContinuation(apiFamily: .openAIResponses, payload: rawOutput)
  let response = ProviderResponse(
    text: "First answer",
    providerID: "openai",
    accountID: "openai-account",
    modelID: "gpt-5.6-sol",
    toolContinuation: continuation
  )

  let historicalAssistant = ChatMessage(
    role: .assistant,
    content: response.text,
    status: .complete,
    providerID: "openai",
    accountID: "openai-account",
    modelID: "gpt-5.6-sol",
    providerContinuation: response.toolContinuation,
    metadata: response.metadata
  )
  let history = [
    ChatMessage(role: .user, content: "First question", status: .complete),
    historicalAssistant,
    ChatMessage(role: .user, content: "Follow up", status: .complete),
  ]

  let matchingConversation = ChatConversation(
    providerID: "openai",
    accountID: "openai-account",
    modelID: "gpt-5.6-sol",
    messages: history
  )
  let matchingContext = try ChatContextBuilder.build(
    conversation: matchingConversation,
    contextWindow: nil
  )
  let replayed = try #require(matchingContext.messages.first { $0.role == .assistant })
  #expect(replayed.toolContinuation == continuation)

  let switchedAccount = ChatConversation(
    providerID: "openai",
    accountID: "other-openai-account",
    modelID: "gpt-5.6-sol",
    messages: history
  )
  let switchedAccountContext = try ChatContextBuilder.build(
    conversation: switchedAccount,
    contextWindow: nil
  )
  #expect(switchedAccountContext.messages.first { $0.role == .assistant }?.toolContinuation == nil)

  let switchedModel = ChatConversation(
    providerID: "openai",
    accountID: "openai-account",
    modelID: "gpt-6-astra",
    messages: history
  )
  let switchedModelContext = try ChatContextBuilder.build(
    conversation: switchedModel,
    contextWindow: nil
  )
  #expect(switchedModelContext.messages.first { $0.role == .assistant }?.toolContinuation == nil)

  let switchedProvider = ChatConversation(
    providerID: "xai",
    accountID: "xai-account",
    modelID: "grok-4.6",
    messages: history
  )
  let switchedProviderContext = try ChatContextBuilder.build(
    conversation: switchedProvider,
    contextWindow: nil
  )
  let stripped = try #require(switchedProviderContext.messages.first { $0.role == .assistant })
  #expect(stripped.content == "First answer")
  #expect(stripped.toolContinuation == nil)
}

@Test func toolRoundContinuationIsAlsoStrippedAfterTargetSwitch() throws {
  let continuation = ProviderToolContinuation(
    apiFamily: .openAIResponses,
    payload: .array([
      .object([
        "id": .string("rs_tool"),
        "type": .string("reasoning"),
        "encrypted_content": .string("opaque-tool-state"),
      ]),
      .object([
        "id": .string("fc_1"),
        "type": .string("function_call"),
        "call_id": .string("call_1"),
        "name": .string("lookup_weather"),
        "arguments": .string("{\"city\":\"Hanoi\"}"),
      ]),
    ])
  )
  let call = ChatToolCall(
    id: "call_1",
    name: "lookup_weather",
    arguments: .object(["city": .string("Hanoi")])
  )
  let result = ChatToolResult(
    callID: "call_1",
    name: "lookup_weather",
    content: .object(["condition": .string("sunny")])
  )
  let round = ChatToolRound(
    calls: [call],
    results: [result],
    providerContinuation: continuation
  )
  let assistant = ChatMessage(
    role: .assistant,
    content: "Sunny",
    toolRounds: [round],
    status: .complete,
    providerID: "xai",
    accountID: "xai-account",
    modelID: "grok-4.6"
  )
  let conversation = ChatConversation(
    providerID: "openai",
    accountID: "openai-account",
    modelID: "gpt-5.6-sol",
    messages: [
      ChatMessage(role: .user, content: "Weather?", status: .complete),
      assistant,
      ChatMessage(role: .user, content: "And tomorrow?", status: .complete),
    ]
  )

  let context = try ChatContextBuilder.build(conversation: conversation, contextWindow: nil)
  let historicalToolAssistant = try #require(
    context.messages.first { $0.role == .assistant && $0.toolCalls?.isEmpty == false }
  )
  #expect(historicalToolAssistant.toolContinuation == nil)
  #expect(historicalToolAssistant.toolCalls == [call])
  #expect(context.messages.contains { message in
    message.role == .tool && message.toolResults == [result]
  })
}
