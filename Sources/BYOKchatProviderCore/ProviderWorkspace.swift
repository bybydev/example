import Foundation

public struct AccountModelRecord: Codable, Sendable, Equatable, Identifiable {
  public var accountID: ProviderAccountID
  public var model: ProviderModel
  public var isFavorite: Bool
  public var isHidden: Bool
  public var isManual: Bool
  public var isAvailable: Bool
  public var id: String { "\(accountID.rawValue)::\(model.id.rawValue)" }

  public init(
    accountID: ProviderAccountID,
    model: ProviderModel,
    isFavorite: Bool = false,
    isHidden: Bool = false,
    isManual: Bool = false,
    isAvailable: Bool = true
  ) {
    self.accountID = accountID
    self.model = model
    self.isFavorite = isFavorite
    self.isHidden = isHidden
    self.isManual = isManual
    self.isAvailable = isAvailable
  }
}

public struct ProviderWorkspaceState: Codable, Sendable, Equatable {
  /// Version 2 folds provider kinds into accounts (v1 → v2 via
  /// `BYOKStorageBootstrap`). Evolves in place; users fresh-install.
  public static let currentSchemaVersion = 2
  public var schemaVersion: Int
  public var customProviders: [ProviderDefinition]
  public var accounts: [ProviderAccount]
  public var modelRecords: [AccountModelRecord]
  public var defaultAccountID: ProviderAccountID?
  public var providerDefaultAccountIDs: [String: String]
  /// Optional so schema-v2 workspaces created before catalog timestamps decode unchanged.
  public var lastSuccessfulModelRefreshAt: [String: Date]?

  public init(
    schemaVersion: Int = Self.currentSchemaVersion,
    customProviders: [ProviderDefinition] = [],
    accounts: [ProviderAccount] = [],
    modelRecords: [AccountModelRecord] = [],
    defaultAccountID: ProviderAccountID? = nil,
    providerDefaultAccountIDs: [String: String] = [:],
    lastSuccessfulModelRefreshAt: [String: Date]? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.customProviders = customProviders
    self.accounts = accounts
    self.modelRecords = modelRecords
    self.defaultAccountID = defaultAccountID
    self.providerDefaultAccountIDs = providerDefaultAccountIDs
    self.lastSuccessfulModelRefreshAt = lastSuccessfulModelRefreshAt
  }
}

public protocol ProviderWorkspacePersistence: Sendable {
  func loadData() async throws -> Data?
  func saveData(_ data: Data) async throws
}

public actor InMemoryProviderWorkspacePersistence: ProviderWorkspacePersistence {
  private var data: Data?
  public init(data: Data? = nil) { self.data = data }
  public func loadData() -> Data? { data }
  public func saveData(_ data: Data) { self.data = data }
}

public actor JSONFileProviderWorkspacePersistence: ProviderWorkspacePersistence {
  public let fileURL: URL
  public init(fileURL: URL) { self.fileURL = fileURL }

  public func loadData() throws -> Data? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    return try Data(contentsOf: fileURL)
  }

  public func saveData(_ data: Data) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: fileURL, options: [.atomic])
  }
}

public enum ProviderImportStrategy: Sendable {
  case keepExisting
  case replaceExisting
}

public actor ProviderWorkspaceStore {
  private var state = ProviderWorkspaceState()
  private let persistence: any ProviderWorkspacePersistence
  private var hasLoaded = false

  public init(persistence: any ProviderWorkspacePersistence) { self.persistence = persistence }

  public func load() async throws {
    guard !hasLoaded else { return }
    guard let data = try await persistence.loadData() else {
      hasLoaded = true
      return
    }
    let decoded = try JSONDecoder.provider.decode(ProviderWorkspaceState.self, from: data)
    guard decoded.schemaVersion == ProviderWorkspaceState.currentSchemaVersion else {
      throw ProviderError.workspaceVersionUnsupported(decoded.schemaVersion)
    }
    try WorkspaceImportValidator.validateProviderWorkspace(decoded)
    state = decoded
    hasLoaded = true
  }

  public func snapshot() -> ProviderWorkspaceState { state }

  public func lastModelRefreshAt(for accountID: ProviderAccountID) -> Date? {
    state.lastSuccessfulModelRefreshAt?[accountID.rawValue]
  }

  public func allAccounts() -> [ProviderAccount] {
    state.accounts.sorted { lhs, rhs in
      if lhs.providerID == rhs.providerID {
        return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
      }
      return lhs.providerID.rawValue < rhs.providerID.rawValue
    }
  }

  public func accounts(for providerID: ProviderID) -> [ProviderAccount] {
    state.accounts.filter { $0.providerID == providerID }.sorted {
      $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
    }
  }

  public func account(id: ProviderAccountID) throws -> ProviderAccount {
    guard let account = state.accounts.first(where: { $0.id == id }) else {
      throw ProviderError.accountNotFound(id)
    }
    return account
  }

  public func upsertAccount(_ account: ProviderAccount) async throws {
    var value = account
    value.updatedAt = .now
    if let index = state.accounts.firstIndex(where: { $0.id == value.id }) {
      if !state.accounts[index].hasSamePricingContext(as: value) {
        state.lastSuccessfulModelRefreshAt?[value.id.rawValue] = nil
        for modelIndex in state.modelRecords.indices
        where state.modelRecords[modelIndex].accountID == value.id {
          // Keep model selections and capabilities, but never reuse prices
          // discovered from an endpoint/configuration the account no longer uses.
          state.modelRecords[modelIndex].model.promptPricePerToken = nil
          state.modelRecords[modelIndex].model.completionPricePerToken = nil
          state.modelRecords[modelIndex].model.cachedInputPricePerToken = nil
          state.modelRecords[modelIndex].model.cacheWritePricePerToken = nil
          state.modelRecords[modelIndex].model.hasAdditionalPricingDimensions = nil
        }
      }
      state.accounts[index] = value
    } else {
      state.accounts.append(value)
    }
    if state.defaultAccountID == nil { state.defaultAccountID = value.id }
    if state.providerDefaultAccountIDs[value.providerID.rawValue] == nil {
      state.providerDefaultAccountIDs[value.providerID.rawValue] = value.id.rawValue
    }
    try await persist()
  }

  public func deleteAccount(_ id: ProviderAccountID) async throws {
    guard let account = state.accounts.first(where: { $0.id == id }) else { return }
    var candidate = state
    candidate.accounts.removeAll { $0.id == id }
    candidate.modelRecords.removeAll { $0.accountID == id }
    candidate.lastSuccessfulModelRefreshAt?[id.rawValue] = nil
    if candidate.defaultAccountID == id { candidate.defaultAccountID = candidate.accounts.first?.id }
    if candidate.providerDefaultAccountIDs[account.providerID.rawValue] == id.rawValue {
      candidate.providerDefaultAccountIDs[account.providerID.rawValue] =
        candidate.accounts.first(where: { $0.providerID == account.providerID })?.id.rawValue
    }
    try await commit(candidate)
  }

  public func setDefaultAccount(_ id: ProviderAccountID?) async throws {
    if let id { _ = try account(id: id) }
    state.defaultAccountID = id
    try await persist()
  }

  public func setDefaultAccount(_ id: ProviderAccountID?, for providerID: ProviderID) async throws {
    if let id {
      let account = try account(id: id)
      guard account.providerID == providerID else {
        throw ProviderError.invalidRequest("The account belongs to a different provider.")
      }
      state.providerDefaultAccountIDs[providerID.rawValue] = id.rawValue
    } else {
      state.providerDefaultAccountIDs.removeValue(forKey: providerID.rawValue)
    }
    try await persist()
  }

  public func defaultAccountID(for providerID: ProviderID? = nil) -> ProviderAccountID? {
    if let providerID, let value = state.providerDefaultAccountIDs[providerID.rawValue] {
      return ProviderAccountID(rawValue: value)
    }
    return state.defaultAccountID
  }

  /// Pure default resolution — the single rule every consumer shares.
  /// Never writes: the stored default only changes via explicit
  /// `setDefaultAccount` or `deleteAccount` reassignment.
  ///
  /// Fallback order: stored default if usable → first ready → first enabled
  /// → first account → nil. Inputs are plain Sendable values so this can be
  /// called from any isolation domain.
  public func resolvedDefaultAccountID(
    credentialRequiredByProvider: [ProviderID: Bool],
    credentialAccountIDs: Set<ProviderAccountID>
  ) -> ProviderAccountID? {
    func isReady(_ account: ProviderAccount) -> Bool {
      guard account.isEnabled else { return false }
      let requiresCredential =
        credentialRequiredByProvider[account.providerID]
        ?? true  // Unknown provider: assume a credential is needed.
      if requiresCredential, !credentialAccountIDs.contains(account.id) { return false }
      return state.modelRecords.contains {
        $0.accountID == account.id && $0.isAvailable && !$0.isHidden
      }
    }

    let accounts = state.accounts
    let storedDefault = state.defaultAccountID
    if let storedDefault, let account = accounts.first(where: { $0.id == storedDefault }),
      isReady(account)
    {
      return storedDefault
    }
    return accounts.first(where: isReady)?.id
      ?? accounts.first(where: \.isEnabled)?.id
      ?? accounts.first?.id
  }

  public func customProviderDefinitions() -> [ProviderDefinition] {
    state.customProviders.sorted {
      $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
  }

  public func upsertCustomProvider(_ definition: ProviderDefinition) async throws {
    guard !definition.isBuiltIn else {
      throw ProviderError.invalidDefinition(
        "Built-in providers cannot be stored as custom providers.")
    }
    try ProviderRegistry.validate(definition)
    guard !BuiltInProviders.all.contains(where: { $0.id == definition.id }) else {
      throw ProviderError.invalidDefinition(
        "Custom provider IDs cannot replace built-in providers."
      )
    }
    if let index = state.customProviders.firstIndex(where: { $0.id == definition.id }) {
      state.customProviders[index] = definition
    } else {
      state.customProviders.append(definition)
    }
    try await persist()
  }

  public func deleteCustomProvider(_ id: ProviderID) async throws {
    guard !state.accounts.contains(where: { $0.providerID == id }) else {
      throw ProviderError.invalidRequest(
        "Delete accounts using this provider before deleting the provider.")
    }
    state.customProviders.removeAll { $0.id == id }
    try await persist()
  }

  public func modelRecords(for accountID: ProviderAccountID, includeHidden: Bool = false)
    -> [AccountModelRecord]
  {
    state.modelRecords
      .filter { $0.accountID == accountID && (includeHidden || !$0.isHidden) }
      .sorted {
        if $0.isFavorite != $1.isFavorite { return $0.isFavorite && !$1.isFavorite }
        return $0.model.displayName.localizedCaseInsensitiveCompare($1.model.displayName)
          == .orderedAscending
      }
  }

  /// Merges a catalog without removing older models: provider list endpoints may be partial.
  /// Only a confirmed remote discovery advances freshness; seeded/manual models do not.
  @discardableResult
  public func mergeModels(
    _ models: [ProviderModel], for accountID: ProviderAccountID, at date: Date = .now,
    expectedAccount: ProviderAccount? = nil, markRefreshed: Bool = false
  ) async throws -> Bool {
    if let expectedAccount {
      let current = try account(id: accountID)
      // Discovery may finish after the user edits the endpoint. Discard that
      // old result rather than restoring the invalidated prices.
      guard current.hasSamePricingContext(as: expectedAccount) else { return false }
    }
    var records = Dictionary(
      uniqueKeysWithValues: state.modelRecords.filter { $0.accountID == accountID }.map {
        ($0.model.id, $0)
      })
    for model in models {
      if var existing = records[model.id] {
        existing.model = mergeModel(existing.model, model)
        existing.isAvailable = true
        records[model.id] = existing
      } else {
        records[model.id] = .init(
          accountID: accountID, model: model, isManual: false, isAvailable: true)
      }
    }
    // Absence from discovery is not proof a model is retired or inaccessible.
    state.modelRecords.removeAll { $0.accountID == accountID }
    state.modelRecords.append(contentsOf: records.values)
    if markRefreshed {
      if state.lastSuccessfulModelRefreshAt == nil { state.lastSuccessfulModelRefreshAt = [:] }
      state.lastSuccessfulModelRefreshAt?[accountID.rawValue] = date
    }
    try await persist()
    return true
  }

  public func addManualModel(_ model: ProviderModel, for accountID: ProviderAccountID) async throws
  {
    _ = try account(id: accountID)
    if let index = state.modelRecords.firstIndex(where: {
      $0.accountID == accountID && $0.model.id == model.id
    }) {
      state.modelRecords[index].model = mergeModel(state.modelRecords[index].model, model)
      state.modelRecords[index].isManual = true
      state.modelRecords[index].isAvailable = true
    } else {
      state.modelRecords.append(.init(accountID: accountID, model: model, isManual: true))
    }
    try await persist()
  }

  /// Remove user-added IDs only; chat history stores its target IDs separately.
  public func removeManualModels(_ ids: Set<ModelID>, for accountID: ProviderAccountID)
    async throws
  {
    guard !ids.isEmpty else { return }
    var candidate = state
    guard let accountIndex = candidate.accounts.firstIndex(where: { $0.id == accountID }) else {
      throw ProviderError.accountNotFound(accountID)
    }
    let stored = candidate.modelRecords.filter { $0.accountID == accountID }
    for id in ids {
      guard let record = stored.first(where: { $0.model.id == id }) else {
        throw ProviderError.modelUnavailable
      }
      guard record.isManual else {
        throw ProviderError.invalidRequest("Only manually added models can be removed.")
      }
    }
    candidate.modelRecords.removeAll {
      $0.accountID == accountID && ids.contains($0.model.id)
    }
    if let currentDefault = candidate.accounts[accountIndex].defaultModelID,
       ids.contains(currentDefault) {
      // Removing the connection's default selects a remaining model, if any.
      candidate.accounts[accountIndex].defaultModelID = candidate.modelRecords
        .filter { $0.accountID == accountID && $0.isAvailable && !$0.isHidden }
        .sorted {
          $0.model.displayName.localizedCaseInsensitiveCompare($1.model.displayName)
            == .orderedAscending
        }
        .first?.model.id
      candidate.accounts[accountIndex].updatedAt = .now
    }
    try await commit(candidate)
  }

  public func setFavorite(_ favorite: Bool, modelID: ModelID, accountID: ProviderAccountID)
    async throws
  {
    guard
      let index = state.modelRecords.firstIndex(where: {
        $0.accountID == accountID && $0.model.id == modelID
      })
    else { throw ProviderError.modelUnavailable }
    state.modelRecords[index].isFavorite = favorite
    try await persist()
  }

  public func setHidden(_ hidden: Bool, modelID: ModelID, accountID: ProviderAccountID) async throws
  {
    guard
      let index = state.modelRecords.firstIndex(where: {
        $0.accountID == accountID && $0.model.id == modelID
      })
    else { throw ProviderError.modelUnavailable }
    state.modelRecords[index].isHidden = hidden
    try await persist()
  }

  public func exportConfiguration() throws -> Data {
    try JSONEncoder.providerEncoder.encode(state)
  }

  public func importConfiguration(_ data: Data, strategy: ProviderImportStrategy) async throws {
    let imported = try JSONDecoder.provider.decode(ProviderWorkspaceState.self, from: data)
    guard imported.schemaVersion == ProviderWorkspaceState.currentSchemaVersion else {
      throw ProviderError.workspaceVersionUnsupported(imported.schemaVersion)
    }
    try WorkspaceImportValidator.validateProviderWorkspace(imported)

    var candidate = state
    switch strategy {
    case .replaceExisting:
      candidate = imported
    case .keepExisting:
      candidate.customProviders = mergeByID(
        current: candidate.customProviders, incoming: imported.customProviders,
        id: \ProviderDefinition.id)
      candidate.accounts = mergeByID(
        current: candidate.accounts, incoming: imported.accounts, id: \ProviderAccount.id)
      let existingModelIDs = Set(candidate.modelRecords.map(\.id))
      candidate.modelRecords.append(
        contentsOf: imported.modelRecords.filter { !existingModelIDs.contains($0.id) })
      if candidate.defaultAccountID == nil { candidate.defaultAccountID = imported.defaultAccountID }
      for (key, value) in imported.providerDefaultAccountIDs
      where candidate.providerDefaultAccountIDs[key] == nil {
        candidate.providerDefaultAccountIDs[key] = value
      }
    }
    try WorkspaceImportValidator.validateProviderWorkspace(candidate)
    try await commit(candidate)
  }

  private func persist() async throws {
    try await persistence.saveData(JSONEncoder.providerEncoder.encode(state))
  }

  private func commit(_ candidate: ProviderWorkspaceState) async throws {
    try await persistence.saveData(JSONEncoder.providerEncoder.encode(candidate))
    state = candidate
  }

  private func mergeModel(_ current: ProviderModel, _ incoming: ProviderModel) -> ProviderModel {
    incoming.mergingCapabilities(from: current)
  }

  private func mergeByID<Value, ID: Hashable>(
    current: [Value], incoming: [Value], id: KeyPath<Value, ID>
  ) -> [Value] {
    let existing = Set(current.map { $0[keyPath: id] })
    return current + incoming.filter { !existing.contains($0[keyPath: id]) }
  }
}

