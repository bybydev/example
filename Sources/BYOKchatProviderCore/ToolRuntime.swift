import Foundation

public protocol ChatToolExecuting: Sendable {
  func availableTools() async -> [ChatToolDefinition]
  func execute(_ call: ChatToolCall) async -> ChatToolResult
}

public actor ToolRuntime: ChatToolExecuting {
  public typealias Handler = @Sendable (JSONValue) async throws -> JSONValue

  private struct Entry: Sendable {
    var definition: ChatToolDefinition
    var handler: Handler
  }

  private var entries: [String: Entry] = [:]

  public init() {}

  public func register(
    _ definition: ChatToolDefinition,
    handler: @escaping Handler
  ) throws {
    let name = definition.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      throw ProviderError.invalidRequest("Tool name cannot be empty.")
    }
    guard entries[name] == nil else {
      throw ProviderError.invalidRequest(
        "Tool name \(name) is already registered. Tool sources must use unique names."
      )
    }
    var normalized = definition
    normalized.name = name
    entries[name] = Entry(definition: normalized, handler: handler)
  }

  public func unregister(name: String) {
    entries.removeValue(forKey: name)
  }

  public func removeAll() {
    entries.removeAll()
  }

  public func availableTools() async -> [ChatToolDefinition] {
    entries.values.map(\.definition).sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  public func execute(_ call: ChatToolCall) async -> ChatToolResult {
    guard let entry = entries[call.name] else {
      return ChatToolResult(
        callID: call.id,
        name: call.name,
        content: .string("Tool not found: \(call.name)"),
        isError: true
      )
    }

    do {
      let content = try await entry.handler(call.arguments)
      return ChatToolResult(
        callID: call.id,
        name: call.name,
        content: content
      )
    } catch {
      return ChatToolResult(
        callID: call.id,
        name: call.name,
        content: .string(error.localizedDescription),
        isError: true
      )
    }
  }
}
