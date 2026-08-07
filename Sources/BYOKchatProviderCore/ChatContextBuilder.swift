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
            || !message.reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        let providerMessage = ProviderMessage(
          role: .assistant,
          content: message.content,
          reasoning: message.reasoning.isEmpty ? nil : message.reasoning
        )
        if current == nil {
          current = Turn(messages: [providerMessage], sourceMessageCount: 1)
        } else {
          current?.messages.append(providerMessage)
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
    }
  }

  private static func estimate(attachments: [ChatAttachment]) -> Int {
    attachments.reduce(0) { partial, attachment in
      if let text = attachment.utf8Text {
        return partial + 16 + estimateTokens(text)
      }
      // Binary multimodal tokenization differs by provider/model. Reserve a conservative
      // fixed budget instead of treating base64 bytes as prompt text.
      return partial + (attachment.isImage ? 1_024 : 2_048)
    }
  }
}
