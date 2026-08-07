import Foundation

public struct ChatToolDefinition: Codable, Sendable, Equatable, Identifiable {
  public var name: String
  public var description: String
  public var inputSchema: JSONValue

  public var id: String { name }

  public init(
    name: String,
    description: String,
    inputSchema: JSONValue = .object(["type": .string("object")])
  ) {
    self.name = name
    self.description = description
    self.inputSchema = inputSchema
  }
}

public struct ChatToolCall: Codable, Sendable, Equatable, Identifiable {
  public var id: String
  public var name: String
  public var arguments: JSONValue

  public init(id: String, name: String, arguments: JSONValue) {
    self.id = id
    self.name = name
    self.arguments = arguments
  }
}

public struct ChatToolResult: Codable, Sendable, Equatable, Identifiable {
  public var callID: String
  public var name: String
  public var content: JSONValue
  public var isError: Bool

  public var id: String { callID }

  public init(
    callID: String,
    name: String,
    content: JSONValue,
    isError: Bool = false
  ) {
    self.callID = callID
    self.name = name
    self.content = content
    self.isError = isError
  }
}

public struct ChatToolRound: Codable, Sendable, Equatable, Identifiable {
  public var id: String
  public var calls: [ChatToolCall]
  public var results: [ChatToolResult]
  public var assistantText: String
  public var assistantReasoning: String
  public var usage: ProviderUsage?
  public var createdAt: Date

  public init(
    id: String = UUID().uuidString.lowercased(),
    calls: [ChatToolCall],
    results: [ChatToolResult],
    assistantText: String = "",
    assistantReasoning: String = "",
    usage: ProviderUsage? = nil,
    createdAt: Date = .now
  ) {
    self.id = id
    self.calls = calls
    self.results = results
    self.assistantText = assistantText
    self.assistantReasoning = assistantReasoning
    self.usage = usage
    self.createdAt = createdAt
  }
}

extension JSONValue {
  static func parseJSONString(_ value: String) throws -> JSONValue {
    guard let data = value.data(using: .utf8) else {
      throw ProviderError.invalidResponse
    }
    do {
      return try JSONDecoder.provider.decode(JSONValue.self, from: data)
    } catch {
      throw ProviderError.invalidResponse
    }
  }

  func compactJSONString() -> String {
    guard let data = try? JSONEncoder.providerEncoder.encode(self),
      let value = String(data: data, encoding: .utf8)
    else {
      return "null"
    }
    return value
  }

  var objectValue: [String: JSONValue]? {
    guard case .object(let value) = self else { return nil }
    return value
  }
}
