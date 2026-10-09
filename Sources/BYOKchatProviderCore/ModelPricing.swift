import Foundation

/// The complete rule is captured before inference; usage selects a context tier
/// later without consulting refreshed model metadata or the current catalog.
public struct ModelPricingSnapshot: Codable, Sendable, Equatable {
  public var source: String
  public var version: String?
  public var sourceURL: String?
  public var verifiedAt: String?
  public var modelID: String
  public var rates: ModelPricingRates
  public var longContextThreshold: Int?
  public var longContextInputMultiplier: String?
  public var longContextOutputMultiplier: String?
  public var validUntil: String?
  public var timeRule: String?
  public var contextNote: String?
  public var supportsCacheWriteDuration: Bool = false
  public var hasAdditionalPricingDimensions: Bool = false

  /// Conservatively reject intervals that cross a scheduled rate boundary,
  /// even when their start and end happen to have the same rate bucket.
  public func coversRequest(startedAt: Date, endedAt: Date) -> Bool {
    guard endedAt >= startedAt else { return false }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    if let validUntil,
      let expiry = ISO8601DateFormatter().date(from: validUntil + "T00:00:00Z"), endedAt >= expiry
    { return false }
    guard timeRule != nil else { return true }
    guard calendar.isDate(startedAt, inSameDayAs: endedAt) else { return false }
    guard (2...6).contains(calendar.component(.weekday, from: startedAt)) else { return true }
    for hour in [1, 4, 6, 10] {
      if let boundary = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: startedAt),
        startedAt < boundary && endedAt >= boundary
      { return false }
    }
    return true
  }

  public func rates(for usage: ProviderUsage) -> ModelPricingRates {
    guard let threshold = longContextThreshold,
      let input = usage.inputTokens, input >= threshold
    else { return rates }
    return rates.multiplied(
      input: ChatBilling.decimal(longContextInputMultiplier) ?? 1,
      output: ChatBilling.decimal(longContextOutputMultiplier) ?? 1
    )
  }
}

public struct ModelPricingRates: Codable, Sendable, Equatable {
  /// All catalog/snapshot rates use USD per one million tokens.
  public var input: String?
  public var output: String?
  public var cachedInput: String?
  public var cacheWrite: String?
  public var longCacheWrite: String?

  func multiplied(input inputMultiplier: Decimal, output outputMultiplier: Decimal) -> Self {
    func scale(_ value: String?, _ factor: Decimal) -> String? {
      ChatBilling.decimal(value).map { ChatBilling.decimalString($0 * factor) }
    }
    return Self(
      input: scale(input, inputMultiplier), output: scale(output, outputMultiplier),
      cachedInput: scale(cachedInput, inputMultiplier),
      cacheWrite: scale(cacheWrite, inputMultiplier),
      longCacheWrite: scale(longCacheWrite, inputMultiplier)
    )
  }

  var isValid: Bool {
    let values = [input, output, cachedInput, cacheWrite, longCacheWrite].compactMap { $0 }
    return !values.isEmpty && values.allSatisfy { ChatBilling.decimal($0) != nil }
  }
}

struct ModelPricingCatalog: Decodable, Sendable {
  var schemaVersion: Int
  var version: String
  var currency: String
  var units: String
  var entries: [Entry]

  struct Entry: Decodable, Sendable {
    var provider: String
    var modelIDs: [String]
    var sourceURL: String
    var verifiedAt: String
    var rates: ModelPricingRates
    var longContextThreshold: Int?
    var longContextInputMultiplier: String?
    var longContextOutputMultiplier: String?
    var peakMultiplier: String?
    var validUntil: String?
    var contextNote: String?
  }

  static let bundled: Self? = {
    guard let url = Bundle.module.url(forResource: "ModelPricingCatalog", withExtension: "json"),
      let data = try? Data(contentsOf: url)
    else { return nil }
    return decode(data)
  }()

  static func decode(_ data: Data) -> Self? {
    guard let catalog = try? JSONDecoder().decode(Self.self, from: data),
      catalog.schemaVersion == 1, !catalog.version.isEmpty,
      catalog.currency == "USD", catalog.units == "USD per 1000000 tokens",
      catalog.entries.allSatisfy({ entry in
        !entry.provider.isEmpty && !entry.modelIDs.isEmpty && entry.rates.isValid
          && entry.modelIDs.allSatisfy { !$0.isEmpty }
          && URL(string: entry.sourceURL)?.scheme == "https"
          && validDay(entry.verifiedAt)
          && (entry.validUntil.map(validDay) ?? true)
          && [entry.longContextInputMultiplier, entry.longContextOutputMultiplier, entry.peakMultiplier]
            .compactMap { $0 }.allSatisfy { (ChatBilling.decimal($0) ?? 0) > 0 }
          && (entry.longContextThreshold == nil || entry.longContextThreshold! > 0)
      })
    else { return nil }
    let keys = catalog.entries.flatMap { entry in entry.modelIDs.map { entry.provider + ":" + $0 } }
    guard Set(keys).count == keys.count else { return nil }
    return catalog
  }
  private static func validDay(_ text: String) -> Bool {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    return formatter.date(from: text).map { formatter.string(from: $0) == text } ?? false
  }
}

public enum ModelPriceResolver {
  public static func resolve(
    account: ProviderAccount, modelID: ModelID, model: ProviderModel?, at date: Date = .now
  ) -> ModelPricingSnapshot? {
    // Optional prices returned by this account's discovery endpoint take
    // precedence, including a partial rule or a valid zero rate.
    if let model, model.id == modelID, model.providerID == account.providerID {
      let rates = ModelPricingRates(
        input: perMillion(model.promptPricePerToken), output: perMillion(model.completionPricePerToken),
        cachedInput: perMillion(model.cachedInputPricePerToken),
        cacheWrite: perMillion(model.cacheWritePricePerToken)
      )
      if rates.isValid {
        return ModelPricingSnapshot(
          source: "providerModelAPI",
          modelID: modelID.rawValue, rates: rates,
          contextNote: "Model API token rates; unsupported charge dimensions are excluded.",
          hasAdditionalPricingDimensions: model.hasAdditionalPricingDimensions == true
        )
      }
    }

    // Direct-provider catalog rates must never leak into proxies, regional
    // endpoints, or arbitrary compatible accounts with a matching model name.
    guard let catalog = ModelPricingCatalog.bundled,
      let entry = catalogEntry(account: account, modelID: modelID, catalog: catalog)
    else { return nil }
    let day = utcDay(date)
    if let expiry = entry.validUntil, day >= expiry { return nil }
    var rates = entry.rates
    var version = catalog.version
    if let peak = entry.peakMultiplier, isDeepSeekPeak(date) {
      let multiplier = ChatBilling.decimal(peak) ?? 1
      rates = rates.multiplied(input: multiplier, output: multiplier)
      version += ":peak"
    } else if entry.peakMultiplier != nil {
      version += ":offPeak"
    }
    return ModelPricingSnapshot(
      source: "bundledCatalog", version: version,
      sourceURL: entry.sourceURL, verifiedAt: entry.verifiedAt,
      modelID: modelID.rawValue, rates: rates,
      longContextThreshold: entry.longContextThreshold,
      longContextInputMultiplier: entry.longContextInputMultiplier,
      longContextOutputMultiplier: entry.longContextOutputMultiplier,
      validUntil: entry.validUntil,
      timeRule: entry.peakMultiplier == nil ? nil : "UTC weekdays 01:00–04:00 and 06:00–10:00; peak multiplier " + (entry.peakMultiplier ?? ""),
      contextNote: entry.contextNote,
      supportsCacheWriteDuration: entry.provider == "anthropic"
    )
  }

  /// A provider may return the canonical ID for a requested legacy alias.
  /// Accept only explicitly verified aliases in the same direct-provider
  /// catalog entry; a real model change must still invalidate calculation.
  public static func responseModelMatches(
    account: ProviderAccount, requestedModelID: ModelID, responseModelID: ModelID
  ) -> Bool {
    if requestedModelID == responseModelID { return true }
    guard let catalog = ModelPricingCatalog.bundled,
      let entry = catalogEntry(account: account, modelID: requestedModelID, catalog: catalog)
    else { return false }
    return entry.modelIDs.contains(responseModelID.rawValue)
  }

  private static func catalogEntry(
    account: ProviderAccount, modelID: ModelID, catalog: ModelPricingCatalog
  ) -> ModelPricingCatalog.Entry? {
    guard account.kind != .openAICompatible,
      account.providerID == account.kind.defaultProviderID,
      let endpoint = account.kind.defaultEndpoint
    else { return nil }
    let configured = account.baseURLOverride ?? endpoint
    // DeepSeek also accepts the OpenAI-compatible /v1 base URL spelling.
    // Normalize that exact path only, keeping host/auth/query checks strict.
    var normalized = configured
    if account.kind == .deepSeek, configured.path == "/v1" || configured.path == "/v1/" {
      guard var components = URLComponents(url: configured, resolvingAgainstBaseURL: false) else {
        return nil
      }
      components.path = ""
      guard let url = components.url else { return nil }
      normalized = url
    }
    guard sameEndpoint(normalized, endpoint) else { return nil }
    return catalog.entries.first {
      $0.provider == account.providerID.rawValue && $0.modelIDs.contains(modelID.rawValue)
    }
  }

  private static func perMillion(_ value: String?) -> String? {
    ChatBilling.decimal(value).map { ChatBilling.decimalString($0 * 1_000_000) }
  }

  private static func sameEndpoint(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
      && lhs.host?.lowercased() == rhs.host?.lowercased()
      && (lhs.port ?? 443) == (rhs.port ?? 443) && lhs.user == nil && lhs.password == nil
      && lhs.query == nil && lhs.fragment == nil
      && lhs.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        == rhs.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }

  static func isDeepSeekPeak(_ date: Date) -> Bool {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let parts = calendar.dateComponents([.weekday, .hour], from: date)
    guard let weekday = parts.weekday, (2...6).contains(weekday), let hour = parts.hour else { return false }
    return (1..<4).contains(hour) || (6..<10).contains(hour)
  }

  private static func utcDay(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }
}
