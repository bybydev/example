import Foundation

public actor ProviderRegistry {
  private var definitions: [ProviderID: ProviderDefinition]

  /// Empty registry used only for recovery/bootstrap fallback paths. Normal
  /// production composition uses ``builtIn()`` so built-in definitions are
  /// still validated before the app becomes ready.
  public init() {
    definitions = [:]
  }

  public init(definitions: [ProviderDefinition]) throws {
    var values: [ProviderID: ProviderDefinition] = [:]
    for definition in definitions {
      try Self.validate(definition)
      guard values[definition.id] == nil else {
        throw ProviderError.duplicateProvider(definition.id)
      }
      values[definition.id] = definition
    }
    self.definitions = values
  }

  public func allDefinitions() -> [ProviderDefinition] {
    definitions.values.sorted {
      $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
  }

  public func definition(for id: ProviderID) throws -> ProviderDefinition {
    guard let value = definitions[id] else { throw ProviderError.providerNotFound(id) }
    return value
  }

  public func register(_ definition: ProviderDefinition) throws {
    try Self.validate(definition)
    guard definitions[definition.id] == nil else {
      throw ProviderError.duplicateProvider(definition.id)
    }
    definitions[definition.id] = definition
  }

  public func replace(_ definition: ProviderDefinition) throws {
    try Self.validate(definition)
    definitions[definition.id] = definition
  }

  public func remove(_ id: ProviderID) throws {
    guard definitions[id]?.isBuiltIn != true else {
      throw ProviderError.invalidDefinition("Built-in providers cannot be removed.")
    }
    definitions.removeValue(forKey: id)
  }

  public static func validate(_ definition: ProviderDefinition) throws {
    let id = definition.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !id.isEmpty else { throw ProviderError.invalidDefinition("Provider ID cannot be empty.") }
    guard id.range(of: #"^[a-z0-9][a-z0-9._-]*$"#, options: .regularExpression) != nil else {
      throw ProviderError.invalidDefinition(
        "Provider ID may contain lowercase letters, numbers, dots, dashes, and underscores.")
    }
    guard !definition.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ProviderError.invalidDefinition("Provider name cannot be empty.")
    }
    do {
      try ProviderHTTP.validateBaseURL(
        definition.defaultBaseURL, allowsLocalHTTP: definition.allowsLocalHTTP)
    } catch {
      throw ProviderError.invalidDefinition(
        definition.allowsLocalHTTP
          ? "Provider base URL must be HTTPS or an explicit private-network HTTP URL."
          : "Provider base URL must be a credential-free HTTPS URL.")
    }
    guard !definition.chatCompletionsPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw ProviderError.invalidDefinition("Chat completions path cannot be empty.")
    }
    if case .header(let name) = definition.authentication,
      ProviderHTTP.isForbiddenCustomHeader(name)
    {
      throw ProviderError.invalidDefinition("Authentication header is not allowed: \(name)")
    }
  }

  public static func builtIn() throws -> ProviderRegistry {
    try .init(definitions: BuiltInProviders.all)
  }
}

public enum CustomProviderFactory {
  public static func makeOpenAICompatible(
    id: String,
    displayName: String,
    baseURL: URL,
    chatCompletionsPath: String = "/chat/completions",
    modelsPath: String? = "/models",
    authentication: ProviderAuthentication = .bearer,
    seedModelIDs: [String] = [],
    allowsLocalHTTP: Bool = false
  ) throws -> ProviderDefinition {
    let providerID = ProviderID(
      rawValue: id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    let definition = ProviderDefinition(
      id: providerID,
      displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
      behavior: .genericOpenAICompatible,
      defaultBaseURL: baseURL,
      chatCompletionsPath: chatCompletionsPath,
      modelsPath: modelsPath?.isEmpty == true ? nil : modelsPath,
      authentication: authentication,
      seedModels: seedModelIDs.map {
        .init(providerID: providerID, id: ModelID(rawValue: $0), displayName: $0, isSeed: true)
      },
      allowsLocalHTTP: allowsLocalHTTP,
      isBuiltIn: false
    )
    try ProviderRegistry.validate(definition)
    return definition
  }
}
