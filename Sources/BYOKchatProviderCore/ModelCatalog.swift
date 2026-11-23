import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public enum ModelCatalogSource: String, Codable, Sendable, Equatable {
  case bundled
  case remote

  public var pricingSnapshotSource: String {
    switch self {
    case .bundled: "bundledCatalog"
    case .remote: "remoteCatalog"
    }
  }
}

public enum ModelCatalogError: Error, LocalizedError, Sendable, Equatable {
  case invalidURL
  case httpStatus(Int)
  case payloadTooLarge
  case invalidCatalog

  public var errorDescription: String? {
    switch self {
    case .invalidURL:
      "The model catalog URL must be a valid credential-free HTTPS URL."
    case .httpStatus(let code):
      "Model catalog request failed with HTTP \(code)."
    case .payloadTooLarge:
      "The downloaded model catalog exceeded the maximum allowed size."
    case .invalidCatalog:
      "The downloaded model catalog failed validation."
    }
  }
}

public struct ModelCatalog: Codable, Sendable, Equatable {
  public static let supportedSchemaVersion = 1

  public var schemaVersion: Int
  public var revision: Int
  public var version: String
  public var generatedAt: String
  public var providers: [String: ProviderSection]
  public var pricing: PricingSection

  public struct ProviderSection: Codable, Sendable, Equatable {
    public var models: [ModelEntry]
    public var reasoningRules: [ReasoningRule]

    public init(models: [ModelEntry] = [], reasoningRules: [ReasoningRule] = []) {
      self.models = models
      self.reasoningRules = reasoningRules
    }
  }

  public struct ModelEntry: Codable, Sendable, Equatable {
    public var id: String
    public var displayName: String
    public var contextWindow: Int?
    public var contextWindowKind: ProviderContextWindowKind?
    public var maxOutputTokens: Int?
    public var inputModalities: [String]
    public var outputModalities: [String]
    public var supportedParameters: [String]

    public init(
      id: String,
      displayName: String,
      contextWindow: Int? = nil,
      contextWindowKind: ProviderContextWindowKind? = nil,
      maxOutputTokens: Int? = nil,
      inputModalities: [String] = ["text"],
      outputModalities: [String] = ["text"],
      supportedParameters: [String] = []
    ) {
      self.id = id
      self.displayName = displayName
      self.contextWindow = contextWindow
      self.contextWindowKind = contextWindowKind
      self.maxOutputTokens = maxOutputTokens
      self.inputModalities = inputModalities
      self.outputModalities = outputModalities
      self.supportedParameters = supportedParameters
    }
  }

  public struct ReasoningRule: Codable, Sendable, Equatable {
    public struct Match: Codable, Sendable, Equatable {
      public var exactAny: [String]?
      public var prefixAny: [String]?
      public var containsAny: [String]?

      public init(
        exactAny: [String]? = nil,
        prefixAny: [String]? = nil,
        containsAny: [String]? = nil
      ) {
        self.exactAny = exactAny
        self.prefixAny = prefixAny
        self.containsAny = containsAny
      }

      var isValid: Bool {
        let lists = [exactAny, prefixAny, containsAny].compactMap { $0 }
        guard !lists.isEmpty else { return false }
        return lists.allSatisfy { list in
          !list.isEmpty && list.allSatisfy { !$0.isEmpty }
        }
      }

      func matches(normalizedID: String) -> Bool {
        if let exactAny, !exactAny.contains(normalizedID) { return false }
        if let prefixAny, !prefixAny.contains(where: { normalizedID.hasPrefix($0) }) { return false }
        if let containsAny, !containsAny.contains(where: { normalizedID.contains($0) }) { return false }
        return true
      }
    }

    public struct Control: Codable, Sendable, Equatable {
      public var kind: ModelReasoningControl.Kind
      public var efforts: [ReasoningEffort]?
      public var defaultEffort: ReasoningEffort?
      public var allowsOff: Bool?
      public var offWireValue: String?
      public var budget: ReasoningBudgetControl?
      public var combinesEffortAndBudget: Bool?

      public init(
        kind: ModelReasoningControl.Kind,
        efforts: [ReasoningEffort]? = nil,
        defaultEffort: ReasoningEffort? = nil,
        allowsOff: Bool? = nil,
        offWireValue: String? = nil,
        budget: ReasoningBudgetControl? = nil,
        combinesEffortAndBudget: Bool? = nil
      ) {
        self.kind = kind
        self.efforts = efforts
        self.defaultEffort = defaultEffort
        self.allowsOff = allowsOff
        self.offWireValue = offWireValue
        self.budget = budget
        self.combinesEffortAndBudget = combinesEffortAndBudget
      }

      var isValid: Bool {
        if let budget {
          guard budget.minimum > 0 else { return false }
          if let maximum = budget.maximum, maximum < budget.minimum { return false }
          if budget.defaultTokens != -1 {
            guard budget.defaultTokens >= budget.minimum else { return false }
            if let maximum = budget.maximum, budget.defaultTokens > maximum { return false }
          } else if !budget.allowsAutomatic {
            return false
          }
        }
        return true
      }

      public func toReasoningControl() -> ModelReasoningControl {
        if kind == .unknown {
          return ModelReasoningControl()
        }
        return ModelReasoningControl(
          kind: kind,
          efforts: efforts ?? [],
          defaultEffort: defaultEffort,
          allowsOff: allowsOff ?? false,
          offWireValue: offWireValue,
          budget: budget,
          combinesEffortAndBudget: combinesEffortAndBudget,
          source: .adapter
        )
      }
    }

    public var match: Match
    public var control: Control

    public init(match: Match, control: Control) {
      self.match = match
      self.control = control
    }
  }

  public struct PricingSection: Codable, Sendable, Equatable {
    public var currency: String
    public var units: String
    public var entries: [ModelPricingCatalog.Entry]

    public init(currency: String, units: String, entries: [ModelPricingCatalog.Entry]) {
      self.currency = currency
      self.units = units
      self.entries = entries
    }
  }

  public static let bundled: ModelCatalog? = {
    guard let url = Bundle.module.url(forResource: "ModelCatalog", withExtension: "json"),
      let data = try? Data(contentsOf: url)
    else { return nil }
    return decode(data)
  }()

  public static func decode(_ data: Data) -> ModelCatalog? {
    guard data.count <= ModelCatalogStore.maxPayloadBytes,
      let catalog = try? JSONDecoder().decode(Self.self, from: data),
      catalog.schemaVersion == supportedSchemaVersion,
      catalog.revision > 0,
      !catalog.version.isEmpty,
      !catalog.generatedAt.isEmpty,
      !catalog.providers.isEmpty
    else { return nil }

    for (providerKey, section) in catalog.providers {
      guard !providerKey.isEmpty else { return nil }
      var seenModelIDs: Set<String> = []
      for model in section.models {
        guard !model.id.isEmpty,
          !model.displayName.isEmpty,
          seenModelIDs.insert(model.id).inserted,
          model.contextWindow.map({ $0 > 0 }) ?? true,
          model.maxOutputTokens.map({ $0 > 0 }) ?? true
        else { return nil }
      }
      for rule in section.reasoningRules {
        guard rule.match.isValid, rule.control.isValid else { return nil }
      }
    }

    guard ModelPricingCatalog.isValid(
      currency: catalog.pricing.currency,
      units: catalog.pricing.units,
      entries: catalog.pricing.entries
    ) else { return nil }

    return catalog
  }

  public var pricingCatalog: ModelPricingCatalog {
    ModelPricingCatalog(
      schemaVersion: schemaVersion,
      version: version,
      currency: pricing.currency,
      units: pricing.units,
      entries: pricing.entries
    )
  }

  public func seedModels(for kind: ProviderKind) -> [ProviderModel] {
    guard let providerID = kind.defaultProviderID,
      let section = providers[providerID.rawValue]
    else { return [] }
    return section.models.map { entry in
      ProviderModel(
        providerID: providerID,
        id: ModelID(rawValue: entry.id),
        displayName: entry.displayName,
        contextWindow: entry.contextWindow,
        contextWindowKind: entry.contextWindowKind,
        maxOutputTokens: entry.maxOutputTokens,
        supportedParameters: Set(entry.supportedParameters),
        inputModalities: Set(entry.inputModalities),
        outputModalities: Set(entry.outputModalities)
      )
      .withCatalogEvidence()
    }
  }

  public func reasoningControl(kind: ProviderKind, modelID: ModelID) -> ModelReasoningControl? {
    guard let providerID = kind.defaultProviderID,
      let section = providers[providerID.rawValue]
    else { return nil }
    let normalized = modelID.rawValue.lowercased().replacingOccurrences(of: "_", with: "-")
    for rule in section.reasoningRules where rule.match.matches(normalizedID: normalized) {
      return rule.control.toReasoningControl()
    }
    return nil
  }
}

public struct ModelCatalogSnapshot: Sendable, Equatable {
  public let source: ModelCatalogSource
  public let catalog: ModelCatalog
  public var revision: Int { catalog.revision }
  public var version: String { catalog.version }

  private let seedModelsByKind: [ProviderKind: [ProviderModel]]
  private let reasoningRulesByKind: [ProviderKind: [ModelCatalog.ReasoningRule]]
  let pricingCatalog: ModelPricingCatalog
  private let pricingEntryByKey: [String: ModelPricingCatalog.Entry]

  public init(source: ModelCatalogSource, catalog: ModelCatalog) {
    self.source = source
    self.catalog = catalog
    var models: [ProviderKind: [ProviderModel]] = [:]
    var rules: [ProviderKind: [ModelCatalog.ReasoningRule]] = [:]
    for kind in ProviderKind.allCases {
      guard let providerID = kind.defaultProviderID,
        let section = catalog.providers[providerID.rawValue]
      else { continue }
      models[kind] = catalog.seedModels(for: kind)
      rules[kind] = section.reasoningRules
    }
    self.seedModelsByKind = models
    self.reasoningRulesByKind = rules
    self.pricingCatalog = catalog.pricingCatalog
    var pricingLookup: [String: ModelPricingCatalog.Entry] = [:]
    for entry in catalog.pricing.entries {
      for modelID in entry.modelIDs {
        pricingLookup[entry.provider + ":" + modelID] = entry
      }
    }
    self.pricingEntryByKey = pricingLookup
  }

  public func seedModels(for kind: ProviderKind) -> [ProviderModel] {
    seedModelsByKind[kind] ?? []
  }

  public func reasoningControl(kind: ProviderKind, modelID: ModelID) -> ModelReasoningControl? {
    guard let rules = reasoningRulesByKind[kind], !rules.isEmpty else { return nil }
    let normalized = modelID.rawValue.lowercased().replacingOccurrences(of: "_", with: "-")
    for rule in rules where rule.match.matches(normalizedID: normalized) {
      return rule.control.toReasoningControl()
    }
    return nil
  }

  func pricingEntry(provider: String, modelID: String) -> ModelPricingCatalog.Entry? {
    pricingEntryByKey[provider + ":" + modelID]
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.source == rhs.source && lhs.catalog == rhs.catalog
  }
}

/// Thread-safe synchronous access to the active 2-layer model catalog snapshot.
/// Layer 1 (bundled JSON) is always the baseline; Layer 2 (remote static JSON)
/// activates only when its `revision` is strictly newer than Layer 1.
public enum ModelCatalogRegistry {
  private final class Storage: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: ModelCatalogSnapshot?

    init(initial: ModelCatalogSnapshot?) {
      self.snapshot = initial
    }

    func get() -> ModelCatalogSnapshot? {
      lock.lock()
      defer { lock.unlock() }
      return snapshot
    }

    func set(_ newValue: ModelCatalogSnapshot?) {
      lock.lock()
      snapshot = newValue
      lock.unlock()
    }
  }

  public static let bundled: ModelCatalogSnapshot? = {
    ModelCatalog.bundled.map { ModelCatalogSnapshot(source: .bundled, catalog: $0) }
  }()

  private static let storage = Storage(initial: bundled)

  public static var current: ModelCatalogSnapshot? {
    storage.get()
  }

  @discardableResult
  public static func activate(_ snapshot: ModelCatalogSnapshot) -> Bool {
    if snapshot.source == .remote, let bundled, snapshot.revision <= bundled.revision {
      return false
    }
    storage.set(snapshot)
    return true
  }

  public static func resetToBundled() {
    storage.set(bundled)
  }
}

public struct ModelCatalogMetadata: Codable, Sendable, Equatable {
  public var etag: String?
  public var lastCheckedAt: Date?
  public var lastUpdatedAt: Date?
  public var cachedRevision: Int?
  public var cachedVersion: String?

  public init(
    etag: String? = nil,
    lastCheckedAt: Date? = nil,
    lastUpdatedAt: Date? = nil,
    cachedRevision: Int? = nil,
    cachedVersion: String? = nil
  ) {
    self.etag = etag
    self.lastCheckedAt = lastCheckedAt
    self.lastUpdatedAt = lastUpdatedAt
    self.cachedRevision = cachedRevision
    self.cachedVersion = cachedVersion
  }
}

public struct ModelCatalogStatus: Sendable, Equatable {
  public var source: ModelCatalogSource
  public var schemaVersion: Int
  public var revision: Int
  public var version: String
  public var generatedAt: String?
  public var bundledRevision: Int
  public var bundledVersion: String
  public var remoteURL: URL
  public var etag: String?
  public var cachedRevision: Int?
  public var cachedVersion: String?
  public var lastCheckedAt: Date?
  public var lastUpdatedAt: Date?
  public var lastFailureAt: Date?
  public var lastFailureMessage: String?
  public var providerCount: Int
  public var modelCount: Int
  public var reasoningRuleCount: Int
  public var pricingEntryCount: Int

  public init(
    source: ModelCatalogSource,
    schemaVersion: Int = ModelCatalog.supportedSchemaVersion,
    revision: Int,
    version: String,
    generatedAt: String? = nil,
    bundledRevision: Int,
    bundledVersion: String,
    remoteURL: URL = ModelCatalogStore.defaultRemoteURL,
    etag: String? = nil,
    cachedRevision: Int? = nil,
    cachedVersion: String? = nil,
    lastCheckedAt: Date? = nil,
    lastUpdatedAt: Date? = nil,
    lastFailureAt: Date? = nil,
    lastFailureMessage: String? = nil,
    providerCount: Int = 0,
    modelCount: Int = 0,
    reasoningRuleCount: Int = 0,
    pricingEntryCount: Int = 0
  ) {
    self.source = source
    self.schemaVersion = schemaVersion
    self.revision = revision
    self.version = version
    self.generatedAt = generatedAt
    self.bundledRevision = bundledRevision
    self.bundledVersion = bundledVersion
    self.remoteURL = remoteURL
    self.etag = etag
    self.cachedRevision = cachedRevision
    self.cachedVersion = cachedVersion
    self.lastCheckedAt = lastCheckedAt
    self.lastUpdatedAt = lastUpdatedAt
    self.lastFailureAt = lastFailureAt
    self.lastFailureMessage = lastFailureMessage
    self.providerCount = providerCount
    self.modelCount = modelCount
    self.reasoningRuleCount = reasoningRuleCount
    self.pricingEntryCount = pricingEntryCount
  }
}

public enum ModelCatalogRefreshResult: Sendable, Equatable {
  case updated(revision: Int, version: String)
  case notModified
  case upToDate
  case throttled
  case ignoredOlderThanBundled(remoteRevision: Int, bundledRevision: Int)
}

public protocol ModelCatalogPersistence: Sendable {
  func loadCatalogData() async throws -> Data?
  func saveCatalogData(_ data: Data) async throws
  func removeCatalogData() async throws
  func loadMetadata() async throws -> ModelCatalogMetadata?
  func saveMetadata(_ metadata: ModelCatalogMetadata) async throws
  func removeMetadata() async throws
}

public actor InMemoryModelCatalogPersistence: ModelCatalogPersistence {
  private var catalogData: Data?
  private var metadata: ModelCatalogMetadata?

  public init(catalogData: Data? = nil, metadata: ModelCatalogMetadata? = nil) {
    self.catalogData = catalogData
    self.metadata = metadata
  }

  public func loadCatalogData() -> Data? { catalogData }
  public func saveCatalogData(_ data: Data) { catalogData = data }
  public func removeCatalogData() { catalogData = nil }
  public func loadMetadata() -> ModelCatalogMetadata? { metadata }
  public func saveMetadata(_ metadata: ModelCatalogMetadata) { self.metadata = metadata }
  public func removeMetadata() { metadata = nil }
}

public actor JSONFileModelCatalogPersistence: ModelCatalogPersistence {
  public let catalogFileURL: URL
  public let metadataFileURL: URL

  public init(catalogFileURL: URL, metadataFileURL: URL) {
    self.catalogFileURL = catalogFileURL
    self.metadataFileURL = metadataFileURL
  }

  public func loadCatalogData() throws -> Data? {
    guard FileManager.default.fileExists(atPath: catalogFileURL.path) else { return nil }
    return try Data(contentsOf: catalogFileURL)
  }

  public func saveCatalogData(_ data: Data) throws {
    try FileManager.default.createDirectory(
      at: catalogFileURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try data.write(to: catalogFileURL, options: [.atomic])
  }

  public func removeCatalogData() throws {
    guard FileManager.default.fileExists(atPath: catalogFileURL.path) else { return }
    try FileManager.default.removeItem(at: catalogFileURL)
  }

  public func loadMetadata() throws -> ModelCatalogMetadata? {
    guard FileManager.default.fileExists(atPath: metadataFileURL.path) else { return nil }
    let data = try Data(contentsOf: metadataFileURL)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(ModelCatalogMetadata.self, from: data)
  }

  public func saveMetadata(_ metadata: ModelCatalogMetadata) throws {
    try FileManager.default.createDirectory(
      at: metadataFileURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(metadata)
    try data.write(to: metadataFileURL, options: [.atomic])
  }

  public func removeMetadata() throws {
    guard FileManager.default.fileExists(atPath: metadataFileURL.path) else { return }
    try FileManager.default.removeItem(at: metadataFileURL)
  }
}

/// Manages Layer 1 (bundled) + Layer 2 (remote static JSON) catalog loading,
/// validation, conditional ETag refresh, and atomic on-disk caching.
public actor ModelCatalogStore {
  public static let defaultRemoteURL = URL(string: "https://spokiostudio.com/byokchat/catalog/v1/models.json")!
  public static let maxPayloadBytes = 2 * 1_024 * 1_024
  public static let defaultRefreshInterval: TimeInterval = 12 * 60 * 60
  public static let defaultRetryInterval: TimeInterval = 15 * 60

  public let remoteURL: URL
  private let persistence: any ModelCatalogPersistence
  private let transport: any ProviderHTTPTransport
  private let refreshInterval: TimeInterval
  private let retryInterval: TimeInterval
  private let activatesGlobally: Bool
  private let bundledSnapshot: ModelCatalogSnapshot?

  private var metadata = ModelCatalogMetadata()
  private var activeSnapshot: ModelCatalogSnapshot?
  private var lastFailureAt: Date?
  private var lastFailureMessage: String?
  private var hasLoaded = false

  public init(
    remoteURL: URL = Self.defaultRemoteURL,
    persistence: any ModelCatalogPersistence,
    transport: (any ProviderHTTPTransport)? = nil,
    refreshInterval: TimeInterval = Self.defaultRefreshInterval,
    retryInterval: TimeInterval = Self.defaultRetryInterval,
    activatesGlobally: Bool = true,
    bundledSnapshot: ModelCatalogSnapshot? = ModelCatalogRegistry.bundled
  ) {
    self.remoteURL = remoteURL
    self.persistence = persistence
    self.transport = transport ?? Self.makeDefaultTransport()
    self.refreshInterval = refreshInterval
    self.retryInterval = retryInterval
    self.activatesGlobally = activatesGlobally
    self.bundledSnapshot = bundledSnapshot
    self.activeSnapshot = bundledSnapshot
  }

  /// Loads any previously cached Layer 2 catalog from disk. Never throws:
  /// corrupted or obsolete cache files safely fall back to Layer 1 bundled.
  public func load() async {
    guard !hasLoaded else { return }
    hasLoaded = true

    if let loadedMetadata = try? await persistence.loadMetadata() {
      metadata = loadedMetadata
    }

    let bundledRevision = bundledSnapshot?.revision ?? 0
    if let data = try? await persistence.loadCatalogData(),
      let decoded = ModelCatalog.decode(data),
      decoded.revision > bundledRevision
    {
      let remoteSnapshot = ModelCatalogSnapshot(source: .remote, catalog: decoded)
      activeSnapshot = remoteSnapshot
      if activatesGlobally {
        ModelCatalogRegistry.activate(remoteSnapshot)
      }
      return
    }

    // Stale or invalid cache (for example after an App Store update bundled a
    // newer catalog): fall back to Layer 1 and clear the obsolete cache file.
    try? await persistence.removeCatalogData()
    if metadata.cachedRevision != nil || metadata.cachedVersion != nil {
      metadata.cachedRevision = nil
      metadata.cachedVersion = nil
      metadata.etag = nil
      try? await persistence.saveMetadata(metadata)
    }
    activeSnapshot = bundledSnapshot
    if activatesGlobally {
      ModelCatalogRegistry.resetToBundled()
    }
  }

  public func activeCatalog() -> ModelCatalogSnapshot? {
    activeSnapshot ?? bundledSnapshot
  }

  public func status() -> ModelCatalogStatus {
    let active = activeSnapshot ?? bundledSnapshot
    let catalog = active?.catalog
    let providers = catalog?.providers ?? [:]
    let modelCount = providers.values.reduce(0) { $0 + $1.models.count }
    let ruleCount = providers.values.reduce(0) { $0 + $1.reasoningRules.count }
    return ModelCatalogStatus(
      source: active?.source ?? .bundled,
      schemaVersion: catalog?.schemaVersion ?? ModelCatalog.supportedSchemaVersion,
      revision: active?.revision ?? 0,
      version: active?.version ?? "Unknown",
      generatedAt: catalog?.generatedAt,
      bundledRevision: bundledSnapshot?.revision ?? 0,
      bundledVersion: bundledSnapshot?.version ?? "Unknown",
      remoteURL: remoteURL,
      etag: metadata.etag,
      cachedRevision: metadata.cachedRevision,
      cachedVersion: metadata.cachedVersion,
      lastCheckedAt: metadata.lastCheckedAt,
      lastUpdatedAt: metadata.lastUpdatedAt,
      lastFailureAt: lastFailureAt,
      lastFailureMessage: lastFailureMessage,
      providerCount: providers.count,
      modelCount: modelCount,
      reasoningRuleCount: ruleCount,
      pricingEntryCount: catalog?.pricing.entries.count ?? 0
    )
  }

  public func refresh(
    force: Bool = false,
    now: Date = .now
  ) async throws -> ModelCatalogRefreshResult {
    if !hasLoaded {
      await load()
    }

    if !force {
      if let lastChecked = metadata.lastCheckedAt,
        now.timeIntervalSince(lastChecked) < refreshInterval
      {
        return .upToDate
      }
      if let lastFailure = lastFailureAt,
        now.timeIntervalSince(lastFailure) < retryInterval
      {
        return .throttled
      }
    }

    do {
      try ProviderHTTP.validateBaseURL(remoteURL, allowsLocalHTTP: false)
    } catch {
      throw ModelCatalogError.invalidURL
    }

    var request = URLRequest(url: remoteURL)
    request.httpMethod = "GET"
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let etag = metadata.etag, !etag.isEmpty {
      request.setValue(etag, forHTTPHeaderField: "If-None-Match")
    }

    let response: ProviderHTTPResponse
    do {
      response = try await transport.data(for: request)
    } catch {
      lastFailureAt = now
      lastFailureMessage = error.localizedDescription
      throw error
    }

    if response.statusCode == 304 {
      lastFailureAt = nil
      lastFailureMessage = nil
      metadata.lastCheckedAt = now
      try? await persistence.saveMetadata(metadata)
      return .notModified
    }

    guard response.statusCode == 200 else {
      let error = ModelCatalogError.httpStatus(response.statusCode)
      lastFailureAt = now
      lastFailureMessage = error.localizedDescription
      throw error
    }

    guard response.data.count <= Self.maxPayloadBytes else {
      let error = ModelCatalogError.payloadTooLarge
      lastFailureAt = now
      lastFailureMessage = error.localizedDescription
      throw error
    }

    guard let decoded = ModelCatalog.decode(response.data) else {
      let error = ModelCatalogError.invalidCatalog
      lastFailureAt = now
      lastFailureMessage = error.localizedDescription
      throw error
    }

    lastFailureAt = nil
    lastFailureMessage = nil
    let etag = Self.headerValue("etag", in: response.headers)
    metadata.lastCheckedAt = now
    if let etag { metadata.etag = etag }

    let bundledRevision = bundledSnapshot?.revision ?? 0
    guard decoded.revision > bundledRevision else {
      try? await persistence.removeCatalogData()
      metadata.cachedRevision = nil
      metadata.cachedVersion = nil
      try? await persistence.saveMetadata(metadata)
      activeSnapshot = bundledSnapshot
      if activatesGlobally {
        ModelCatalogRegistry.resetToBundled()
      }
      return .ignoredOlderThanBundled(
        remoteRevision: decoded.revision,
        bundledRevision: bundledRevision
      )
    }

    try await persistence.saveCatalogData(response.data)
    metadata.lastUpdatedAt = now
    metadata.cachedRevision = decoded.revision
    metadata.cachedVersion = decoded.version
    try await persistence.saveMetadata(metadata)

    let remoteSnapshot = ModelCatalogSnapshot(source: .remote, catalog: decoded)
    activeSnapshot = remoteSnapshot
    if activatesGlobally {
      ModelCatalogRegistry.activate(remoteSnapshot)
    }
    return .updated(revision: decoded.revision, version: decoded.version)
  }

  public func clearCache() async throws {
    try await persistence.removeCatalogData()
    try await persistence.removeMetadata()
    metadata = ModelCatalogMetadata()
    lastFailureAt = nil
    lastFailureMessage = nil
    activeSnapshot = bundledSnapshot
    if activatesGlobally {
      ModelCatalogRegistry.resetToBundled()
    }
  }

  private static func headerValue(_ target: String, in headers: [String: String]) -> String? {
    for (key, value) in headers where key.lowercased() == target {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { return trimmed }
    }
    return nil
  }

  private static func makeDefaultTransport() -> URLSessionProviderHTTPTransport {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 10
    configuration.timeoutIntervalForResource = 15
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.httpShouldSetCookies = false
    #if canImport(Darwin)
      configuration.httpCookieAcceptPolicy = .never
    #endif
    return URLSessionProviderHTTPTransport(session: URLSession(configuration: configuration))
  }
}
