import Foundation

enum TelemetryPrivacy {
  private static let maximumIdentifierLength = 256
  private static let maximumEventNameLength = 120
  private static let maximumErrorCodeLength = 160
  private static let maximumMetadataEntries = 24
  private static let maximumMetadataKeyLength = 64
  private static let maximumMetadataValueLength = 256

  private static let sensitiveKeyFragments = [
    "authorization",
    "proxyauthorization",
    "apikey",
    "secret",
    "password",
    "credential",
    "cookie",
    "accesstoken",
    "refreshtoken",
    "bearertoken",
    "authtoken",
    "prompt",
    "assistanttext",
    "responsetext",
    "requestbody",
    "responsebody",
    "payload",
    "toolargument",
    "toolresult",
    "attachment",
    "filedata",
    "imagedata",
    "reasoningtext",
    "content",
    "headers",
  ]

  private static let sensitiveValueFragments = [
    "bearer ",
    "authorization:",
    "api_key=",
    "apikey=",
    "access_token=",
    "refresh_token=",
    "token=",
    "secret=",
    "password=",
  ]

  static func sanitize(_ event: TelemetryEvent) -> TelemetryEvent {
    var value = event
    value.id = bounded(event.id, maximum: maximumIdentifierLength)
    value.name = TelemetryEventName(
      rawValue: bounded(event.name.rawValue, maximum: maximumEventNameLength)
    )
    value.deviceID = boundedOptional(event.deviceID, maximum: maximumIdentifierLength)
    value.sessionID = boundedOptional(event.sessionID, maximum: maximumIdentifierLength)
    value.errorCode = sanitizeErrorCode(event.errorCode)
    value.durationMilliseconds = nonNegative(event.durationMilliseconds)
    value.timeToFirstTokenMilliseconds = nonNegative(event.timeToFirstTokenMilliseconds)
    value.inputTokens = nonNegative(event.inputTokens)
    value.outputTokens = nonNegative(event.outputTokens)
    value.cachedInputTokens = nonNegative(event.cachedInputTokens)
    value.reasoningTokens = nonNegative(event.reasoningTokens)
    value.modelRequestCount = nonNegative(event.modelRequestCount)
    value.toolCallCount = nonNegative(event.toolCallCount)
    if let status = event.httpStatus, (100...999).contains(status) {
      value.httpStatus = status
    } else {
      value.httpStatus = nil
    }
    value.metadata = sanitizeMetadata(event.metadata)
    return value
  }

  static func sanitizeMetadata(_ metadata: [String: String]) -> [String: String] {
    var result: [String: String] = [:]
    result.reserveCapacity(min(metadata.count, maximumMetadataEntries))

    for (rawKey, rawValue) in metadata.sorted(by: { $0.key < $1.key }) {
      guard result.count < maximumMetadataEntries else { break }

      let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
      let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !key.isEmpty, !value.isEmpty else { continue }
      guard !isSensitiveKey(key), !isSensitiveValue(value) else { continue }

      result[bounded(key, maximum: maximumMetadataKeyLength)] = bounded(
        value,
        maximum: maximumMetadataValueLength
      )
    }

    return result
  }

  private static func sanitizeErrorCode(_ errorCode: String?) -> String? {
    guard let errorCode else { return nil }
    let firstLine = errorCode
      .split(whereSeparator: { $0.isNewline })
      .first
      .map(String.init)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let firstLine, !firstLine.isEmpty else { return nil }
    return bounded(firstLine, maximum: maximumErrorCodeLength)
  }

  private static func isSensitiveKey(_ key: String) -> Bool {
    let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
    return sensitiveKeyFragments.contains { normalized.contains($0) }
  }

  private static func isSensitiveValue(_ value: String) -> Bool {
    let normalized = value.lowercased()
    return sensitiveValueFragments.contains { normalized.contains($0) }
  }

  private static func nonNegative(_ value: Double?) -> Double? {
    guard let value, value.isFinite, value >= 0 else { return nil }
    return value
  }

  private static func nonNegative(_ value: Int?) -> Int? {
    guard let value, value >= 0 else { return nil }
    return value
  }

  private static func boundedOptional(_ value: String?, maximum: Int) -> String? {
    guard let value else { return nil }
    let boundedValue = bounded(value, maximum: maximum)
    return boundedValue.isEmpty ? nil : boundedValue
  }

  private static func bounded(_ value: String, maximum: Int) -> String {
    String(value.prefix(maximum))
  }
}
