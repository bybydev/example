import Foundation
import MarkdownUI
import os

/// MarkdownUI's parsed tree consists of immutable value types, but its public
/// MarkdownContent type predates Sendable. This wrapper publishes only immutable
/// parsed values; all construction happens on the parse actor before publication.
final class MacPreparedAnswer: @unchecked Sendable {
  let source: String
  let blocks: [MacAnswerContentBlock]
  let markdown: [String: MarkdownContent]
  let inlineMathSources: Set<String>

  init(source: String) {
    self.source = source
    let blocks = MacAnswerContentParser.parse(source)
    self.blocks = blocks
    var markdown: [String: MarkdownContent] = [:]
    var inlineMathSources: Set<String> = []
    for case .markdown(let text) in blocks {
      if Self.shouldUseInlineMathRenderer(text) {
        inlineMathSources.insert(text)
      } else {
        markdown[text] = MarkdownContent(text)
      }
    }
    self.markdown = markdown
    self.inlineMathSources = inlineMathSources
  }

  static func shouldUseInlineMathRenderer(_ markdown: String) -> Bool {
    guard MacAnswerContentParser.containsInlineMath(markdown),
      MacAnswerContentParser.isLikelyBalancedInlineMath(markdown)
    else { return false }

    for line in markdown.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("#")
        || trimmed.hasPrefix(">")
        || trimmed.hasPrefix("- ")
        || trimmed.hasPrefix("* ")
        || trimmed.hasPrefix("+ ")
        || trimmed.hasPrefix("|")
        || trimmed.range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil
      {
        return false
      }
    }
    return true
  }
}

/// Synchronous cache hits let newly materialized rows render prepared content on
/// their first frame. The lock protects bookkeeping only, never parsing or UI work.
private final class MacPreparedAnswerStorage: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: MacPreparedAnswer] = [:]
  private var order: [String] = []
  private var sourceBytes = 0
  private let limit: Int
  private let byteLimit: Int

  init(limit: Int, byteLimit: Int) {
    self.limit = max(limit, 1)
    self.byteLimit = max(byteLimit, 1)
  }

  func value(for source: String) -> MacPreparedAnswer? {
    lock.lock()
    defer { lock.unlock() }
    guard let value = values[source] else { return nil }
    order.removeAll { $0 == source }
    order.append(source)
    return value
  }

  func insert(_ value: MacPreparedAnswer) {
    lock.lock()
    defer { lock.unlock() }
    let cost = value.source.utf8.count
    guard cost <= byteLimit else { return }
    if values[value.source] == nil { sourceBytes += cost }
    values[value.source] = value
    order.removeAll { $0 == value.source }
    order.append(value.source)
    while order.count > limit || sourceBytes > byteLimit {
      let source = order.removeFirst()
      sourceBytes -= source.utf8.count
      values.removeValue(forKey: source)
    }
  }
}

/// Bounded by entry count and total source bytes (not an estimate of AST memory).
/// Parsing runs off the main actor and results are reused across row lifetimes.
actor MacAnswerContentParseCache {
  static let shared = MacAnswerContentParseCache()
  private static let log = OSLog(subsystem: "pro.byok.BYOKchat", category: "ChatSwitch")
  private nonisolated let storage: MacPreparedAnswerStorage

  init(limit: Int = 64, byteLimit: Int = 8 * 1_024 * 1_024) {
    storage = MacPreparedAnswerStorage(limit: limit, byteLimit: byteLimit)
  }

  nonisolated func cachedAnswer(for source: String) -> MacPreparedAnswer? {
    storage.value(for: source)
  }

  func answer(for source: String) throws -> MacPreparedAnswer {
    try Task.checkCancellation()
    if let cached = storage.value(for: source) { return cached }
    let signpostID = OSSignpostID(log: Self.log)
    os_signpost(.begin, log: Self.log, name: "Prepare Markdown", signpostID: signpostID)
    defer { os_signpost(.end, log: Self.log, name: "Prepare Markdown", signpostID: signpostID) }
    let answer = MacPreparedAnswer(source: source)
    try Task.checkCancellation()
    storage.insert(answer)
    return answer
  }

  func blocks(for source: String) throws -> [MacAnswerContentBlock] {
    try answer(for: source).blocks
  }
}
