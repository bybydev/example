import Foundation

public struct ChatContextPolicy: Sendable, Equatable {
  public var minimumOutputReserve: Int
  public var defaultOutputReserve: Int
  public var safetyMarginRatio: Double
  public var minimumSafetyMarginTokens: Int
  public var maximumSafetyMarginTokens: Int

  public init(
    minimumOutputReserve: Int = 256,
    defaultOutputReserve: Int = 4096,
    safetyMarginRatio: Double = 0.05,
    minimumSafetyMarginTokens: Int = 64,
    maximumSafetyMarginTokens: Int = 65_536
  ) {
    self.minimumOutputReserve = max(0, minimumOutputReserve)
    self.defaultOutputReserve = max(0, defaultOutputReserve)
    self.safetyMarginRatio = max(0, safetyMarginRatio)
    self.minimumSafetyMarginTokens = max(0, minimumSafetyMarginTokens)
    self.maximumSafetyMarginTokens = max(
      self.minimumSafetyMarginTokens,
      maximumSafetyMarginTokens
    )
  }

  public static var automatic: Self { .init() }

  fileprivate func outputReserve(
    requested: Int?,
    modelMaximum: Int?,
    contextWindow: Int?
  ) -> Int {
    if let requested {
      // A supplied request value is the actual generation ceiling. Respect it exactly instead of
      // inflating a real 64-token request to an arbitrary minimum.
      return max(0, requested)
    }

    var preferred = max(minimumOutputReserve, defaultOutputReserve)
    if let modelMaximum, modelMaximum > 0 {
      // The model maximum is a capability ceiling, not the amount the user asked to generate.
      // It may lower the fallback but must never inflate it (for example 128k or 384k models).
      preferred = min(preferred, modelMaximum)
    }
    guard let contextWindow else { return preferred }

    // Unknown-output models with small combined windows must still have room for input. The cap
    // is harmless for input-only windows because their output reserve is not subtracted below.
    let window = max(0, contextWindow)
    guard window > 0 else { return 0 }
    return min(preferred, max(1, window / 4))
  }

  fileprivate func safetyMargin(contextWindow: Int, reservedWithinWindow: Int) -> Int {
    let window = max(0, contextWindow)
    let remaining = max(0, window - reservedWithinWindow)
    guard remaining > 0 else { return 0 }

    let proportional = Int(ceil(Double(window) * safetyMarginRatio))
    let desired = min(
      maximumSafetyMarginTokens,
      max(minimumSafetyMarginTokens, proportional)
    )

    // Headroom exists to absorb estimation error, not to starve genuinely small contexts.
    return min(desired, remaining / 4)
  }
}

public enum ChatContextBuilder {
  public static func build(
    conversation: ChatConversation,
    contextWindow: Int?,
    contextWindowKind: ProviderContextWindowKind = .combined,
    reservedOutputTokens: Int? = nil,
    modelMaxOutputTokens: Int? = nil,
    tools: [ChatToolDefinition] = [],
    requiredTailMessages: [ProviderMessage] = [],
    policy: ChatContextPolicy = .automatic
  ) throws -> ChatContextResult {
    let outputReserve = policy.outputReserve(
      requested: reservedOutputTokens ?? conversation.options.maxOutputTokens,
      modelMaximum: modelMaxOutputTokens,
      contextWindow: contextWindow
    )
    let reservedWithinWindow = contextWindowKind == .combined ? outputReserve : 0
    let safetyMargin = contextWindow.map {
      policy.safetyMargin(contextWindow: $0, reservedWithinWindow: reservedWithinWindow)
    } ?? 0
    let inputBudget = contextWindow.map {
      max(0, $0 - reservedWithinWindow - safetyMargin)
    }

    var fixedMessages: [ProviderMessage] = []
    let trimmedSystem = conversation.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedSystem.isEmpty {
      fixedMessages.append(.init(role: .system, content: trimmedSystem))
    }

    let latestUserIndex = conversation.messages.lastIndex { $0.role == .user }
    let eligible = conversation.messages.enumerated().compactMap { index, message -> ChatMessage? in
      switch message.role {
      case .user:
        guard message.status == .complete,
          !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(message.attachments ?? []).isEmpty
        else { return nil }

        // beginTurn persists the newest user message together with a pending assistant placeholder.
        // That newest user message is the request being generated and must always enter context.
        if index == latestUserIndex { return message }

        // Historical context is turn-based. If the assistant response failed, was cancelled, or was
        // interrupted, do not leave the preceding user message (and especially its attachments) as
        // an orphaned half-turn that gets resent forever on every later request.
        let responseIndex = index + 1
        guard conversation.messages.indices.contains(responseIndex) else { return nil }
        let response = conversation.messages[responseIndex]
        guard response.role == .assistant, response.status == .complete else { return nil }
        return message

      case .assistant:
        guard message.status == .complete,
          !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !message.reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(message.toolRounds ?? []).isEmpty
        else { return nil }

        // Keep assistant history paired with the user turn that produced it. This also avoids
        // importing a malformed/orphan assistant response into provider context.
        let userIndex = index - 1
        guard conversation.messages.indices.contains(userIndex) else { return nil }
        let user = conversation.messages[userIndex]
        guard user.role == .user, user.status == .complete,
          !user.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(user.attachments ?? []).isEmpty
        else { return nil }
        return message
      }
    }

    let turns = makeTurns(from: eligible)
    let toolCost = estimate(toolDefinitions: tools)
    let fixedCost = estimate(messages: fixedMessages)
      + toolCost
      + estimate(messages: requiredTailMessages)

    guard let inputBudget else {
      let all = fixedMessages + turns.flatMap(\.messages) + requiredTailMessages
      return .init(
        messages: all,
        omittedMessageCount: 0,
        estimatedInputTokens: estimate(messages: all) + toolCost
      )
    }

    guard fixedCost <= inputBudget else {
      throw ProviderError.contextWindowExceeded(
        estimatedInputTokens: fixedCost,
        limit: inputBudget
      )
    }

    var selected: [Turn] = []
    var used = fixedCost
    for turn in turns.reversed() {
      let cost = estimate(messages: turn.messages)
      if used + cost <= inputBudget {
        selected.append(turn)
        used += cost
      } else if selected.isEmpty {
        // The newest turn is mandatory. Failing is safer than sending tool state or a response
        // without the user message that caused it.
        throw ProviderError.contextWindowExceeded(
          estimatedInputTokens: used + cost,
          limit: inputBudget
        )
      } else {
        // Keep history contiguous. Do not skip a large recent turn to fish for older small turns.
        break
      }
    }
    selected.reverse()

    let selectedMessageCount = selected.reduce(0) { $0 + $1.sourceMessageCount }
    let omitted = max(0, eligible.count - selectedMessageCount)
    let result = fixedMessages + selected.flatMap(\.messages) + requiredTailMessages
    return .init(
      messages: result,
      omittedMessageCount: omitted,
      estimatedInputTokens: estimate(messages: result) + toolCost
    )
  }

  /// Provider-independent fallback estimate. ASCII text follows the common ~4 bytes/token
  /// heuristic; non-ASCII text is counted more conservatively so CJK and other multibyte input
  /// cannot be underestimated simply because UTF-8 uses several bytes per scalar.
  public static func estimateTokens(_ text: String) -> Int {
    guard !text.isEmpty else { return 0 }

    var asciiByteCount = 0
    var nonASCIIByteCount = 0
    var nonASCIIScalarCount = 0
    for scalar in text.unicodeScalars {
      if scalar.value < 0x80 {
        asciiByteCount += 1
      } else {
        nonASCIIScalarCount += 1
        nonASCIIByteCount += String(scalar).utf8.count
      }
    }

    let asciiEstimate = Int(ceil(Double(asciiByteCount) / 4.0))
    let nonASCIIByteEstimate = Int(ceil(Double(nonASCIIByteCount) / 3.0))
    let nonASCIIEstimate = max(nonASCIIScalarCount, nonASCIIByteEstimate)
    return max(1, asciiEstimate + nonASCIIEstimate)
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
              toolCalls: round.calls,
              toolContinuation: round.providerContinuation
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
        + estimate(toolContinuation: message.toolContinuation)
    }
  }

  private static func estimate(attachments: [ChatAttachment]) -> Int {
    attachments.reduce(0) { partial, attachment in
      let metadataCost = estimateTokens(attachment.filename) + estimateTokens(attachment.mimeType)
      if let text = attachment.utf8Text {
        return partial + 16 + metadataCost + estimateTokens(text)
      }
      return partial + metadataCost + (attachment.isImage ? 1_024 : 2_048)
    }
  }

  private static func estimate(toolDefinitions: [ChatToolDefinition]) -> Int {
    toolDefinitions.reduce(0) { partial, tool in
      partial + 24
        + estimateTokens(tool.name)
        + estimateTokens(tool.description)
        + estimateTokens(tool.inputSchema.compactJSONString())
    }
  }

  private static func estimate(toolCalls: [ChatToolCall]) -> Int {
    toolCalls.reduce(0) { partial, call in
      partial + 12
        + estimateTokens(call.id)
        + estimateTokens(call.name)
        + estimateTokens(call.arguments.compactJSONString())
    }
  }

  private static func estimate(toolResults: [ChatToolResult]) -> Int {
    toolResults.reduce(0) { partial, result in
      partial + 12
        + estimateTokens(result.callID)
        + estimateTokens(result.name)
        + estimateTokens(result.content.compactJSONString())
        + (result.isError ? 1 : 0)
    }
  }

  private static func estimate(toolContinuation: ProviderToolContinuation?) -> Int {
    guard let toolContinuation else { return 0 }
    return 12 + estimateTokens(toolContinuation.payload.compactJSONString())
  }
}
