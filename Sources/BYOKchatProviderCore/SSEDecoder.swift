import Foundation

public struct ServerSentEvent: Sendable, Equatable {
  public var event: String?
  public var data: String

  public init(event: String?, data: String) {
    self.event = event
    self.data = data
  }
}

public struct SSEDecoder: Sendable {
  private var buffer = Data()
  private var currentEvent: String?
  private var currentDataLines: [String] = []

  public init() {}

  public mutating func append(_ chunk: Data) throws -> [ServerSentEvent] {
    buffer.append(chunk)
    return try parseCompleteLines()
  }

  public mutating func finish() throws -> [ServerSentEvent] {
    var events = try parseCompleteLines()
    if !buffer.isEmpty {
      guard let line = String(data: buffer, encoding: .utf8) else {
        throw ProviderError.invalidResponse
      }
      buffer.removeAll(keepingCapacity: false)
      try consume(
        line: line.trimmingCharacters(in: CharacterSet(charactersIn: "\r")), events: &events)
    }
    if let event = flushEvent() {
      events.append(event)
    }
    return events
  }

  private mutating func parseCompleteLines() throws -> [ServerSentEvent] {
    var events: [ServerSentEvent] = []
    while let newline = buffer.firstIndex(of: 0x0A) {
      let lineData = buffer[..<newline]
      buffer.removeSubrange(...newline)
      guard var line = String(data: lineData, encoding: .utf8) else {
        throw ProviderError.invalidResponse
      }
      if line.last == "\r" { line.removeLast() }
      try consume(line: line, events: &events)
    }
    return events
  }

  private mutating func consume(
    line: String,
    events: inout [ServerSentEvent]
  ) throws {
    if line.isEmpty {
      if let event = flushEvent() {
        events.append(event)
      }
      return
    }

    if line.hasPrefix(":") {
      return
    }

    let field: String
    let value: String
    if let colon = line.firstIndex(of: ":") {
      field = String(line[..<colon])
      var remainder = String(line[line.index(after: colon)...])
      if remainder.first == " " { remainder.removeFirst() }
      value = remainder
    } else {
      field = line
      value = ""
    }

    switch field {
    case "event":
      currentEvent = value
    case "data":
      currentDataLines.append(value)
    default:
      break
    }
  }

  private mutating func flushEvent() -> ServerSentEvent? {
    guard currentEvent != nil || !currentDataLines.isEmpty else {
      return nil
    }
    defer {
      currentEvent = nil
      currentDataLines.removeAll(keepingCapacity: true)
    }
    return ServerSentEvent(
      event: currentEvent,
      data: currentDataLines.joined(separator: "\n")
    )
  }
}
