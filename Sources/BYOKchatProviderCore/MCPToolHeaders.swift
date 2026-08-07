import Foundation

public enum MCPToolHeaderMapper {
  public static func bindings(from inputSchema: JSONValue) throws -> [MCPHeaderBinding] {
    guard case .object = inputSchema else {
      throw MCPError.invalidToolDefinition("MCP tool inputSchema must be a JSON object.")
    }

    var bindings: [MCPHeaderBinding] = []
    var names: Set<String> = []
    try walk(
      inputSchema,
      propertyPath: [],
      isReachableProperty: false,
      bindings: &bindings,
      headerNames: &names
    )
    return bindings
  }

  public static func headers(
    bindings: [MCPHeaderBinding],
    arguments: JSONValue
  ) throws -> [String: String] {
    var result: [String: String] = [:]
    for binding in bindings {
      guard let value = value(at: binding.propertyPath, in: arguments), value != .null else {
        continue
      }
      let string: String
      switch (binding.valueType, value) {
      case ("string", .string(let value)):
        string = value
      case ("boolean", .bool(let value)):
        string = value ? "true" : "false"
      case ("integer", .number(let value)):
        guard value.isFinite,
          value.rounded(.towardZero) == value,
          abs(value) <= 9_007_199_254_740_991
        else {
          throw MCPError.invalidToolDefinition(
            "MCP header parameter \(binding.propertyPath.joined(separator: ".")) must be a safe integer."
          )
        }
        string = String(format: "%.0f", value)
      case ("number", .number(let value)):
        guard value.isFinite else {
          throw MCPError.invalidToolDefinition(
            "MCP header parameter \(binding.propertyPath.joined(separator: ".")) must be a finite number."
          )
        }
        string = JSONValue.number(value).compactJSONString()
      default:
        throw MCPError.invalidToolDefinition(
          "MCP header parameter \(binding.propertyPath.joined(separator: ".")) has the wrong value type."
        )
      }
      result["Mcp-Param-\(binding.headerName)"] = encodeHeaderValue(string)
    }
    return result
  }

  public static func encodeHeaderValue(_ value: String) -> String {
    let isSentinel = value.hasPrefix("=?base64?") && value.hasSuffix("?=")
    let hasOuterWhitespace = value != value.trimmingCharacters(in: .whitespaces)
    let isPlainASCII = value.unicodeScalars.allSatisfy { scalar in
      scalar.value >= 0x20 && scalar.value <= 0x7E
    }
    if isPlainASCII && !hasOuterWhitespace && !isSentinel {
      return value
    }
    return "=?base64?\(Data(value.utf8).base64EncodedString())?="
  }

  private static func walk(
    _ node: JSONValue,
    propertyPath: [String],
    isReachableProperty: Bool,
    bindings: inout [MCPHeaderBinding],
    headerNames: inout Set<String>
  ) throws {
    guard case .object(let object) = node else { return }

    if let annotation = object["x-mcp-header"] {
      guard isReachableProperty,
        case .string(let headerName) = annotation,
        isValidHeaderName(headerName)
      else {
        throw MCPError.invalidToolDefinition("Invalid x-mcp-header annotation in MCP tool schema.")
      }
      let normalized = headerName.lowercased()
      guard headerNames.insert(normalized).inserted else {
        throw MCPError.invalidToolDefinition(
          "MCP tool schema contains duplicate x-mcp-header name \(headerName)."
        )
      }
      guard case .string(let type)? = object["type"],
        ["string", "integer", "number", "boolean"].contains(type)
      else {
        throw MCPError.invalidToolDefinition(
          "x-mcp-header can only annotate string, integer, number, or boolean properties."
        )
      }
      bindings.append(
        MCPHeaderBinding(propertyPath: propertyPath, headerName: headerName, valueType: type)
      )
    }

    for (key, value) in object {
      switch key {
      case "x-mcp-header":
        continue
      case "properties":
        guard case .object(let properties) = value else { continue }
        for (propertyName, propertySchema) in properties {
          try walk(
            propertySchema,
            propertyPath: propertyPath + [propertyName],
            isReachableProperty: true,
            bindings: &bindings,
            headerNames: &headerNames
          )
        }
      default:
        if containsHeaderAnnotation(value) {
          throw MCPError.invalidToolDefinition(
            "x-mcp-header must be reachable only through JSON Schema properties."
          )
        }
      }
    }
  }

  private static func containsHeaderAnnotation(_ value: JSONValue) -> Bool {
    switch value {
    case .object(let object):
      if object["x-mcp-header"] != nil { return true }
      return object.values.contains { containsHeaderAnnotation($0) }
    case .array(let values):
      return values.contains { containsHeaderAnnotation($0) }
    case .string, .number, .bool, .null:
      return false
    }
  }

  private static func value(at path: [String], in root: JSONValue) -> JSONValue? {
    var current = root
    for component in path {
      guard case .object(let object) = current, let next = object[component] else { return nil }
      current = next
    }
    return current
  }

  private static func isValidHeaderName(_ value: String) -> Bool {
    guard !value.isEmpty else { return false }
    return value.unicodeScalars.allSatisfy { scalar in
      scalar.value >= 0x21 && scalar.value <= 0x7E && scalar.value != 0x3A
    }
  }
}
