import Foundation

public enum ChatCostAccuracy: String, Codable, Sendable {
  case providerReported
  case calculated
  case unavailable
}

public struct ChatBillingSnapshot: Sendable, Equatable {
  public var costUSD: Decimal?
  public var accuracy: ChatCostAccuracy
  public var inputPricePerToken: Decimal?
  public var outputPricePerToken: Decimal?
  public var modelRequestCount: Int
  public var toolCallCount: Int

  public init(
    costUSD: Decimal?,
    accuracy: ChatCostAccuracy,
    inputPricePerToken: Decimal?,
    outputPricePerToken: Decimal?,
    modelRequestCount: Int,
    toolCallCount: Int
  ) {
    self.costUSD = costUSD
    self.accuracy = accuracy
    self.inputPricePerToken = inputPricePerToken
    self.outputPricePerToken = outputPricePerToken
    self.modelRequestCount = modelRequestCount
    self.toolCallCount = toolCallCount
  }
}

public struct ChatUsageAggregate: Sendable, Equatable {
  public var assistantMessageCount = 0
  public var inputTokens = 0
  public var outputTokens = 0
  public var cachedInputTokens = 0
  public var reasoningTokens = 0
  public var modelRequestCount = 0
  public var toolCallCount = 0
  public var knownCostMessageCount = 0
  public var costUSD = Decimal.zero

  public init() {}

  public mutating func add(_ message: ChatMessage) {
    guard message.role == .assistant else { return }
    assistantMessageCount += 1
    if let usage = message.usage {
      inputTokens += usage.inputTokens ?? 0
      outputTokens += usage.outputTokens ?? 0
      cachedInputTokens += usage.cachedInputTokens ?? 0
      reasoningTokens += usage.reasoningTokens ?? 0
    }

    let billing = ChatBilling.snapshot(for: message)
    modelRequestCount += billing.modelRequestCount
    toolCallCount += billing.toolCallCount
    if let cost = billing.costUSD {
      costUSD += cost
      knownCostMessageCount += 1
    }
  }

  public var hasKnownCost: Bool { knownCostMessageCount > 0 }
  public var hasPartialCost: Bool {
    knownCostMessageCount > 0 && knownCostMessageCount < assistantMessageCount
  }
}

public enum ChatBilling {
  public static let costKey = "byokchat.billing.costUSD"
  public static let accuracyKey = "byokchat.billing.accuracy"
  public static let inputPriceKey = "byokchat.billing.inputPricePerToken"
  public static let outputPriceKey = "byokchat.billing.outputPricePerToken"
  public static let modelRequestCountKey = "byokchat.billing.modelRequestCount"
  public static let toolCallCountKey = "byokchat.billing.toolCallCount"

  private static let providerCostKeys = [
    "costUSD",
    "cost_usd",
    "openrouter.costUSD",
    "openrouter.cost",
  ]

  public static func metadata(
    existing: [String: String],
    usage: ProviderUsage?,
    model: ProviderModel?,
    modelRequestCount: Int,
    toolCallCount: Int
  ) -> [String: String] {
    var result = existing
    result[modelRequestCountKey] = String(max(1, modelRequestCount))
    result[toolCallCountKey] = String(max(0, toolCallCount))

    if let providerCost = providerCostKeys.compactMap({ decimal(existing[$0]) }).first {
      result[costKey] = decimalString(providerCost)
      result[accuracyKey] = ChatCostAccuracy.providerReported.rawValue
      return result
    }

    let inputPrice = decimal(model?.promptPricePerToken)
    let outputPrice = decimal(model?.completionPricePerToken)
    if let inputPrice { result[inputPriceKey] = decimalString(inputPrice) }
    if let outputPrice { result[outputPriceKey] = decimalString(outputPrice) }

    if let usage,
      let cost = calculatedCost(
        usage: usage,
        inputPricePerToken: inputPrice,
        outputPricePerToken: outputPrice
      )
    {
      result[costKey] = decimalString(cost)
      result[accuracyKey] = ChatCostAccuracy.calculated.rawValue
    } else {
      result.removeValue(forKey: costKey)
      result[accuracyKey] = ChatCostAccuracy.unavailable.rawValue
    }
    return result
  }

  public static func snapshot(for message: ChatMessage) -> ChatBillingSnapshot {
    let metadata = message.metadata
    let cost = decimal(metadata[costKey])
    let accuracy = metadata[accuracyKey].flatMap(ChatCostAccuracy.init(rawValue:))
      ?? (cost == nil ? .unavailable : .calculated)
    let fallbackToolCalls = (message.toolRounds ?? []).reduce(0) { $0 + $1.calls.count }
    let requestCount = Int(metadata[modelRequestCountKey] ?? "")
      ?? (message.role == .assistant && message.status == .complete ? max(1, (message.toolRounds?.count ?? 0) + 1) : 0)
    let toolCalls = Int(metadata[toolCallCountKey] ?? "") ?? fallbackToolCalls
    return ChatBillingSnapshot(
      costUSD: cost,
      accuracy: accuracy,
      inputPricePerToken: decimal(metadata[inputPriceKey]),
      outputPricePerToken: decimal(metadata[outputPriceKey]),
      modelRequestCount: requestCount,
      toolCallCount: toolCalls
    )
  }

  public static func aggregate(messages: [ChatMessage]) -> ChatUsageAggregate {
    var result = ChatUsageAggregate()
    for message in messages { result.add(message) }
    return result
  }

  public static func aggregate(conversations: [ChatConversation]) -> ChatUsageAggregate {
    aggregate(messages: conversations.flatMap(\.messages))
  }

  public static func calculatedCost(
    usage: ProviderUsage,
    inputPricePerToken: Decimal?,
    outputPricePerToken: Decimal?
  ) -> Decimal? {
    var total = Decimal.zero
    var hasPrice = false

    if let inputPricePerToken, let inputTokens = usage.inputTokens {
      total += Decimal(inputTokens) * inputPricePerToken
      hasPrice = true
    }
    if let outputPricePerToken, let outputTokens = usage.outputTokens {
      total += Decimal(outputTokens) * outputPricePerToken
      hasPrice = true
    }

    return hasPrice ? total : nil
  }

  public static func decimal(_ value: String?) -> Decimal? {
    guard let value else { return nil }
    return Decimal(
      string: value.trimmingCharacters(in: .whitespacesAndNewlines),
      locale: Locale(identifier: "en_US_POSIX")
    )
  }

  public static func decimalString(_ value: Decimal) -> String {
    NSDecimalNumber(decimal: value).stringValue
  }
}
