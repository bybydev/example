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
  public var isComplete: Bool = false
  public var isLowerBound: Bool = false
  public var requests: [ChatRequestBilling] = []

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
  public var cacheWriteTokens = 0
  public var reasoningTokens = 0
  public var modelRequestCount = 0
  public var toolCallCount = 0
  public var knownCostMessageCount = 0
  public var incompleteCostMessageCount = 0
  public var estimatedCostMessageCount = 0
  public var scopedProviderCostMessageCount = 0
  public var costUSD = Decimal.zero

  public init() {}

  public mutating func add(_ message: ChatMessage) {
    guard message.role == .assistant else { return }
    let billing = ChatBilling.snapshot(for: message)
    // Ignore pre-flight failed/cancelled placeholders that never attempted a
    // model request and carry no usage or cost, so local validation failures do
    // not mark spend totals as "(partial)" or "Unavailable".
    if message.status != .complete,
      billing.modelRequestCount == 0,
      billing.requests.isEmpty,
      billing.costUSD == nil,
      message.usage == nil
    {
      return
    }

    assistantMessageCount += 1
    if let usage = message.usage {
      inputTokens += usage.inputTokens ?? 0
      outputTokens += usage.outputTokens ?? 0
      cachedInputTokens += usage.cachedInputTokens ?? 0
      cacheWriteTokens += usage.cacheWriteTokens ?? 0
      reasoningTokens += usage.reasoningTokens ?? 0
    }

    modelRequestCount += billing.modelRequestCount
    toolCallCount += billing.toolCallCount
    if !billing.isComplete { incompleteCostMessageCount += 1 }
    if billing.requests.contains(where: { $0.missingDimensions.contains("provider billing scope") }) {
      scopedProviderCostMessageCount += 1
    }
    if billing.accuracy == .calculated { estimatedCostMessageCount += 1 }
    if let cost = billing.costUSD {
      costUSD += cost
      knownCostMessageCount += 1
    }
  }

  public var totalTokens: Int { inputTokens + outputTokens }
  public var cacheHitRate: Double? {
    guard inputTokens > 0, cachedInputTokens > 0 else { return nil }
    return min(max(Double(cachedInputTokens) / Double(inputTokens), 0), 1)
  }
  public var hasEstimatedCost: Bool { estimatedCostMessageCount > 0 }
  public var isLowerBound: Bool { hasKnownCost && hasPartialCost && !hasEstimatedCost }
  public var hasKnownCost: Bool { knownCostMessageCount > 0 }
  public var hasPartialCost: Bool {
    incompleteCostMessageCount > 0
  }
}

public enum ChatBilling {
  public static let completenessKey = "byokchat.billing.complete"
  public static let requestsKey = "byokchat.billing.requests.v1"
  public static let reportedCostCompleteKey = "byokchat.billing.reportedCostComplete"
  public static let unsupportedContextKey = "byokchat.billing.unsupportedContext"
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

  public static func providerReportedCost(from metadata: [String: String]) -> Decimal? {
    providerCostKeys.compactMap { decimal(metadata[$0]) }.first
  }

  public static func replacingProviderReportedCost(
    in metadata: [String: String],
    with cost: Decimal?
  ) -> [String: String] {
    var result = metadata
    for key in providerCostKeys { result.removeValue(forKey: key) }
    if let cost { result["costUSD"] = decimalString(cost) }
    return result
  }

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

    if let providerCost = providerReportedCost(from: existing) {
      result[costKey] = decimalString(providerCost)
      result[accuracyKey] = ChatCostAccuracy.providerReported.rawValue
      result[completenessKey] = String(existing[reportedCostCompleteKey] != "false")
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
      result[completenessKey] = String(modelRequestCount == 1
        && usage.inputTokens != nil && usage.outputTokens != nil
        && (usage.inputTokens == 0 || inputPrice != nil)
        && (usage.outputTokens == 0 || outputPrice != nil)
        && (usage.cachedInputTokens ?? 0) == 0 && (usage.cacheWriteTokens ?? 0) == 0
        && usage.hasUnpricedCharges != true)
    } else {
      result.removeValue(forKey: costKey)
      result[accuracyKey] = ChatCostAccuracy.unavailable.rawValue
      result[completenessKey] = "false"
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
    var snapshot = ChatBillingSnapshot(
      costUSD: cost,
      accuracy: accuracy,
      inputPricePerToken: decimal(metadata[inputPriceKey]),
      outputPricePerToken: decimal(metadata[outputPriceKey]),
      modelRequestCount: requestCount,
      toolCallCount: toolCalls
    )
    snapshot.requests = metadata[requestsKey].flatMap { $0.data(using: .utf8) }
      .flatMap { try? JSONDecoder().decode([ChatRequestBilling].self, from: $0) } ?? []
    // Old calculated totals do not prove every tool request supplied usage.
    // Only a single request with both saved rates and complete plain usage
    // can be classified without consulting today's prices.
    let legacyComplete = accuracy == .providerReported || (
      requestCount == 1 && snapshot.inputPricePerToken != nil && snapshot.outputPricePerToken != nil
        && message.usage?.inputTokens != nil && message.usage?.outputTokens != nil
        && (message.usage?.cachedInputTokens ?? 0) == 0
        && (message.usage?.cacheWriteTokens ?? 0) == 0
        && message.usage?.hasUnpricedCharges != true
    )
    snapshot.isComplete = cost != nil && (metadata[completenessKey].map { $0 == "true" } ?? legacyComplete)
    snapshot.isLowerBound = cost != nil && !snapshot.isComplete && accuracy == .providerReported
    return snapshot
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
    let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    // Decimal(string:) accepts numeric prefixes; reject malformed or
    // nonfinite/negative prices instead of treating them as free.
    guard text.range(of: #"^[+]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#,
      options: .regularExpression) != nil,
      let number = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
      !number.isNaN, number >= 0
    else { return nil }
    return number
  }

  public static func decimalString(_ value: Decimal) -> String {
    NSDecimalNumber(decimal: value).stringValue
  }
}

/// One receipt per attempted inference request, retained in message metadata
/// and therefore also in the lightweight conversation index.
public struct ChatRequestBilling: Codable, Sendable, Equatable {
  public var requestedAt: Date?
  public var completedAt: Date?
  public var costUSD: String?
  public var accuracy: ChatCostAccuracy
  public var isComplete: Bool
  public var pricing: ModelPricingSnapshot?
  public var usage: ProviderUsage?
  public var missingDimensions: [String]
}

extension ChatBilling {
  public static func requestBilling(
    metadata: [String: String], usage: ProviderUsage?, pricing: ModelPricingSnapshot?,
    modelMatches: Bool = true
  ) -> ChatRequestBilling {
    if let reported = providerReportedCost(from: metadata) {
      let complete = metadata[reportedCostCompleteKey] != "false"
      return .init(costUSD: decimalString(reported), accuracy: .providerReported,
        isComplete: complete, pricing: pricing, usage: usage,
        missingDimensions: complete ? [] : ["provider billing scope"])
    }
    var unavailableReasons: [String] = []
    if usage == nil { unavailableReasons.append("request usage") }
    if pricing == nil { unavailableReasons.append("supported model pricing") }
    if !modelMatches { unavailableReasons.append("matching model and account configuration") }
    if metadata[unsupportedContextKey] != nil { unavailableReasons.append("supported billing context") }
    guard let usage, let pricing, unavailableReasons.isEmpty else {
      return .init(costUSD: nil, accuracy: .unavailable, isComplete: false,
        pricing: pricing, usage: usage, missingDimensions: unavailableReasons)
    }
    let rates = pricing.rates(for: usage)
    var missing: [String] = []
    var cost = Decimal.zero
    var hasAmount = false
    func add(_ count: Int?, _ rate: String?, _ dimension: String) {
      guard let count, count >= 0 else { missing.append(dimension + " usage"); return }
      if count == 0 { hasAmount = true; return }
      guard let rate = decimal(rate) else { missing.append(dimension + " price"); return }
      cost += Decimal(count) * rate / 1_000_000
      hasAmount = true
    }
    let cached = usage.cachedInputTokens ?? 0
    let writes = usage.cacheWriteTokens ?? 0
    let longWrites = usage.longCacheWriteTokens ?? 0
    let counts = [usage.inputTokens, usage.outputTokens, usage.cachedInputTokens,
      usage.cacheWriteTokens, usage.longCacheWriteTokens, usage.reasoningTokens].compactMap { $0 }
    guard counts.allSatisfy({ $0 >= 0 }), longWrites <= writes,
      usage.inputTokens.map({ cached <= $0 && writes <= $0 - cached }) ?? true
    else {
      return .init(costUSD: nil, accuracy: .unavailable, isComplete: false,
        pricing: pricing, usage: usage, missingDimensions: ["valid input usage"])
    }
    if rates.cachedInput != nil && usage.cachedInputTokens == nil { missing.append("cache read usage") }
    if rates.cacheWrite != nil && usage.cacheWriteTokens == nil { missing.append("cache write usage") }
    if writes > 0 && pricing.supportsCacheWriteDuration && usage.longCacheWriteTokens == nil {
      missing.append("cache write duration")
    }
    if pricing.longContextThreshold != nil && usage.inputTokens == nil { missing.append("context tier") }
    add(usage.inputTokens.map { $0 - cached - writes }, rates.input, "input")
    if cached > 0 { add(cached, rates.cachedInput, "cache read") }
    if writes - longWrites > 0 { add(writes - longWrites, rates.cacheWrite, "cache write") }
    if longWrites > 0 { add(longWrites, rates.longCacheWrite, "long cache write") }
    add(usage.outputTokens, rates.output, "output")
    if usage.hasUnpricedCharges == true || pricing.hasAdditionalPricingDimensions { missing.append("additional provider charges") }
    if cost.isNaN { hasAmount = false; missing.append("representable cost") }
    return .init(costUSD: hasAmount ? decimalString(cost) : nil,
      accuracy: hasAmount ? .calculated : .unavailable, isComplete: hasAmount && missing.isEmpty,
      pricing: pricing, usage: usage, missingDimensions: missing)
  }

  public static func metadata(
    existing: [String: String], requests: [ChatRequestBilling], toolCallCount: Int
  ) -> [String: String] {
    var result = replacingProviderReportedCost(in: existing, with: nil)
    result[modelRequestCountKey] = String(requests.count)
    result[toolCallCountKey] = String(max(0, toolCallCount))
    result[completenessKey] = String(!requests.isEmpty && requests.allSatisfy(\.isComplete))
    let amounts = requests.compactMap { decimal($0.costUSD) }
    if !amounts.isEmpty {
      result[costKey] = decimalString(amounts.reduce(0, +))
      result[accuracyKey] = requests.contains { $0.costUSD != nil && $0.accuracy == .calculated }
        ? ChatCostAccuracy.calculated.rawValue : ChatCostAccuracy.providerReported.rawValue
    } else {
      result.removeValue(forKey: costKey)
      result[accuracyKey] = ChatCostAccuracy.unavailable.rawValue
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    if let data = try? encoder.encode(requests) { result[requestsKey] = String(data: data, encoding: .utf8) }
    result.removeValue(forKey: inputPriceKey)
    result.removeValue(forKey: outputPriceKey)
    if let first = requests.first, let usage = first.usage, let pricing = first.pricing {
      let rates = pricing.rates(for: usage)
      if let input = decimal(rates.input) { result[inputPriceKey] = decimalString(input / 1_000_000) }
      if let output = decimal(rates.output) { result[outputPriceKey] = decimalString(output / 1_000_000) }
    }
    return result
  }
}
