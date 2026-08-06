import Foundation

public actor ProviderRegistry {
  private var definitions: [ProviderID: ProviderDefinition]

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
    definitions.values.sorted { $0.displayName < $1.displayName }
  }

  public func definition(for id: ProviderID) throws -> ProviderDefinition {
    guard let definition = definitions[id] else {
      throw ProviderError.providerNotFound(id)
    }
    return definition
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

  private static func validate(_ definition: ProviderDefinition) throws {
    let id = definition.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !id.isEmpty else {
      throw ProviderError.invalidDefinition("Provider ID cannot be empty.")
    }
    guard definition.defaultBaseURL.scheme?.lowercased() == "https" else {
      throw ProviderError.invalidDefinition("Provider base URL must use HTTPS.")
    }
    guard !definition.chatCompletionsPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw ProviderError.invalidDefinition("Chat completions path cannot be empty.")
    }
  }
}

extension ProviderRegistry {
  public static func builtIn() throws -> ProviderRegistry {
    try ProviderRegistry(definitions: BuiltInProviders.all)
  }
}
