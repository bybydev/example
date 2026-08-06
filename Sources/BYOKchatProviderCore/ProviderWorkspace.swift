import Foundation

public struct AccountModelRecord: Codable, Sendable, Equatable, Identifiable {
  public var accountID: ProviderAccountID
  public var model: ProviderModel
  public var isFavorite: Bool
  public var isHidden: Bool
  public var isManual: Bool
  public var isAvailable: Bool
  public var lastSeenAt: Date?
  public var id: String { "\(accountID.rawValue)::\(model.id.rawValue)" }

  public init(
    accountID: ProviderAccountID,
    model: ProviderModel,
    isFavorite: Bool = false,
    isHidden: Bool = false,
    isManual: Bool = false,
    isAvailable: Bool = true,
    lastSeenAt: Date? = .now
  ) {
    self.accountID = accountID
    self.model = model
    self.isFavorite = isFavorite
    self.isHidden = isHidden
    self.isManual = isManual
    self.isAvailable = isAvailable
    self.lastSeenAt = lastSeenAt
  }
}

public struct ProviderWorkspaceState: Codable, Sendable, Equatable {
  public static let currentSchemaVersion = 1
  public var schemaVersion: Int
  public var customProviders: [ProviderDefinition]
  public var accounts: [ProviderAccount]
  public var modelRecords: [AccountModelRecord]
  public var defaultAccountID: ProviderAccountID?
  public var providerDefaultAccountIDs: [String: String]

  public init(
    schemaVersion: Int = Self.currentSchemaVersion,
    customProviders: [ProviderDefinition] = [],
    accounts: [ProviderAccount] = [],
    modelRecords: [AccountModelRecord] = [],
    defaultAccountID: ProviderAccountID? = nil,
    providerDefaultAccountIDs: [String: String] = [:]
  ) {
    self.schemaVersion = schemaVersion
    self.customProviders = customProviders
    self.accounts = accounts
    self.modelRecords = modelRecords
    self.defaultAccountID = defaultAccountID
    self.providerDefaultAccountIDs = providerDefaultAccountIDs
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
    defer { hasLoaded = true }
    guard let data = try await persistence.loadData() else { return }
    let decoded = try JSONDecoder.provider.decode(ProviderWorkspaceState.self, from: data)
    guard decoded.schemaVersion == ProviderWorkspaceState.currentSchemaVersion else {
      throw ProviderError.workspaceVersionUnsupported(decoded.schemaVersion)
    }
    state = decoded
  }

  public func snapshot() -> ProviderWorkspaceState { state }

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
    state.accounts.removeAll { $0.id == id }
    state.modelRecords.removeAll { $0.accountID == id }
    if state.defaultAccountID == id { state.defaultAccountID = state.accounts.first?.id }
    if state.providerDefaultAccountIDs[account.providerID.rawValue] == id.rawValue {
      state.providerDefaultAccountIDs[account.providerID.rawValue] =
        state.accounts.first(where: { $0.providerID == account.providerID })?.id.rawValue
    }
    try await persist()
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

  public func mergeModels(
    _ models: [ProviderModel], for accountID: ProviderAccountID, at date: Date = .now
  ) async throws {
    var records = Dictionary(
      uniqueKeysWithValues: state.modelRecords.filter { $0.accountID == accountID }.map {
        ($0.model.id, $0)
      })
    let discoveredIDs = Set(models.map(\.id))
    for model in models {
      if var existing = records[model.id] {
        existing.model = mergeModel(existing.model, model)
        existing.isAvailable = true
        existing.lastSeenAt = date
        records[model.id] = existing
      } else {
        records[model.id] = .init(
          accountID: accountID, model: model, isManual: false, isAvailable: true, lastSeenAt: date)
      }
    }
    for (id, var record) in records where !record.isManual && !discoveredIDs.contains(id) {
      record.isAvailable = false
      records[id] = record
    }
    state.modelRecords.removeAll { $0.accountID == accountID }
    state.modelRecords.append(contentsOf: records.values)
    try await persist()
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
    switch strategy {
    case .replaceExisting:
      state = imported
    case .keepExisting:
      state.customProviders = mergeByID(
        current: state.customProviders, incoming: imported.customProviders,
        id: \ProviderDefinition.id)
      state.accounts = mergeByID(
        current: state.accounts, incoming: imported.accounts, id: \ProviderAccount.id)
      let existingModelIDs = Set(state.modelRecords.map(\.id))
      state.modelRecords.append(
        contentsOf: imported.modelRecords.filter { !existingModelIDs.contains($0.id) })
      if state.defaultAccountID == nil { state.defaultAccountID = imported.defaultAccountID }
      for (key, value) in imported.providerDefaultAccountIDs
      where state.providerDefaultAccountIDs[key] == nil {
        state.providerDefaultAccountIDs[key] = value
      }
    }
    try await persist()
  }

  private func persist() async throws {
    try await persistence.saveData(JSONEncoder.providerEncoder.encode(state))
  }

  private func mergeModel(_ current: ProviderModel, _ incoming: ProviderModel) -> ProviderModel {
    var result = incoming
    if result.displayName.isEmpty { result.displayName = current.displayName }
    if result.contextWindow == nil { result.contextWindow = current.contextWindow }
    if result.maxOutputTokens == nil { result.maxOutputTokens = current.maxOutputTokens }
    if result.promptPricePerToken == nil {
      result.promptPricePerToken = current.promptPricePerToken
    }
    if result.completionPricePerToken == nil {
      result.completionPricePerToken = current.completionPricePerToken
    }
    result.supportedParameters.formUnion(current.supportedParameters)
    result.inputModalities.formUnion(current.inputModalities)
    result.outputModalities.formUnion(current.outputModalities)
    return result
  }

  private func mergeByID<Value, ID: Hashable>(
    current: [Value], incoming: [Value], id: KeyPath<Value, ID>
  ) -> [Value] {
    let existing = Set(current.map { $0[keyPath: id] })
    return current + incoming.filter { !existing.contains($0[keyPath: id]) }
  }
}
