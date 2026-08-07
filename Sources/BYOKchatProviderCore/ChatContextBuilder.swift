import Foundation

public enum ChatContextBuilder {
  public static func build(
    conversation: ChatConversation,
    contextWindow: Int?,
    reservedOutputTokens: Int? = nil
  ) throws -> ChatContextResult {
    let outputReserve = max(
      256,
      reservedOutputTokens ?? conversation.options.maxOutputTokens ?? 4096
    )
    let inputBudget = contextWindow.map { max(0, $0 - outputReserve) }

    var systemMessages: [ProviderMessage] = []
    let trimmedSystem = conversation.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedSystem.isEmpty {
      systemMessages.append(.init(role: .system, content: trimmedSystem))
    }

    let eligible = conversation.messages.filter { message in
      switch message.role {
      case .user:
        return message.status == .complete
          && (!message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(message.attachments ?? []).isEmpty)
      case .assistant:
        return message.status == .complete
          && (!message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !message.reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(message.toolRounds ?? []).isEmpty)
      }
    }

    let turns = makeTurns(from: eligible)
    let systemCost = estimate(messages: systemMessages)
    guard let inputBudget else {
      let all = systemMessages + turns.flatMap(\.messages)
      return .init(
        messages: all,
        omittedMessageCount: 0,
        estimatedInputTokens: estimate(messages: all)
      )
    }

    guard systemCost <= inputBudget else {
      throw ProviderError.contextWindowExceeded(
        estimatedInputTokens: systemCost,
        limit: inputBudget
      )
    }

    var selected: [Turn] = []
    var used = systemCost
    for turn in turns.reversed() {
      let cost = estimate(messages: turn.messages)
      if used + cost <= inputBudget {
        selected.append(turn)
        used += cost
      } else if selected.isEmpty {
        throw ProviderError.contextWindowExceeded(
          estimatedInputTokens: used + cost,
          limit: inputBudget
        )
      } else {
        break
      }
    }
    selected.reverse()

    let selectedMessageCount = selected.reduce(0) { $0 + $1.sourceMessageCount }
    let omitted = max(0, eligible.count - selectedMessageCount)
    let result = systemMessages + selected.flatMap(\.messages)
    return .init(
      messages: result,
      omittedMessageCount: omitted,
      estimatedInputTokens: estimate(messages: result)
    )
  }

  public static func estimateTokens(_ text: String) -> Int {
    max(1, Int(ceil(Double(text.utf8.count) / 4.0)))
  }

  private struct Turn {
    var messages: [ProviderMessage]
    var sourceMessageCount: Int
  }

  private static func makeTurns(from messages: [ChatMessage]) -> [Turn] {
    var turns: [Turn] = []
    var current: Turn?

    for message in messages {
      switch message.role {
      case .user:
        if let current { turns.append(current) }
        current = Turn(
          messages: [
            .init(
              role: .user,
              content: message.content,
              attachments: message.attachments
            )
          ],
          sourceMessageCount: 1
        )
      case .assistant:
        var providerMessages: [ProviderMessage] = []
        for round in message.toolRounds ?? [] {
          providerMessages.append(
            ProviderMessage(
              role: .assistant,
              content: round.assistantText,
              reasoning: round.assistantReasoning.isEmpty ? nil : round.assistantReasoning,
              toolCalls: round.calls
            )
          )
          providerMessages.append(
            ProviderMessage(
              role: .tool,
              content: "",
              toolResults: round.results
            )
          )
        }

        if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          || !message.reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
          providerMessages.append(
            ProviderMessage(
              role: .assistant,
              content: message.content,
              reasoning: message.reasoning.isEmpty ? nil : message.reasoning
            )
          )
        }

        if current == nil {
          current = Turn(messages: providerMessages, sourceMessageCount: 1)
        } else {
          current?.messages.append(contentsOf: providerMessages)
          current?.sourceMessageCount += 1
        }
      }
    }
    if let current { turns.append(current) }
    return turns
  }

  private static func estimate(messages: [ProviderMessage]) -> Int {
    messages.reduce(0) { partial, message in
      partial + 6 + estimateTokens(message.content) + estimateTokens(message.reasoning ?? "")
        + estimate(attachments: message.attachments ?? [])
        + estimate(toolCalls: message.toolCalls ?? [])
        + estimate(toolResults: message.toolResults ?? [])
    }
  }

  private static func estimate(attachments: [ChatAttachment]) -> Int {
    attachments.reduce(0) { partial, attachment in
      if let text = attachment.utf8Text {
        return partial + 16 + estimateTokens(text)
      }
      return partial + (attachment.isImage ? 1_024 : 2_048)
    }
  }

  private static func estimate(toolCalls: [ChatToolCall]) -> Int {
    toolCalls.reduce(0) { partial, call in
      partial + 12 + estimateTokens(call.name) + estimateTokens(call.arguments.compactJSONString())
    }
  }

  private static func estimate(toolResults: [ChatToolResult]) -> Int {
    toolResults.reduce(0) { partial, result in
      partial + 12 + estimateTokens(result.name) + estimateTokens(result.content.compactJSONString())
    }
  }
}
