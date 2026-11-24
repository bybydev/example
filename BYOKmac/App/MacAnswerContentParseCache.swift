import Foundation
import MarkdownUI
import os

/// MarkdownUI's parsed tree consists of immutable value types, but its public
/// MarkdownContent type predates Sendable. This wrapper publishes only immutable
/// parsed values; all construction happens on the parse actor before publication.
final class MacPreparedAnswer: @unchecked Sendable {
  struct MarkdownSegment: @unchecked Sendable {
    let text: String
    let useLaTeX: Bool
    let markdownContent: MarkdownContent?
    let columnAlignments: [MacTableColumnAlignment]
  }

  let source: String
  let blocks: [MacAnswerContentBlock]
  let markdown: [String: MarkdownContent]
  let markdownSegments: [String: [MarkdownSegment]]
  let inlineMathSources: Set<String>

  init(source: String) {
    self.source = source
    let blocks = MacAnswerContentParser.parse(source)
    self.blocks = blocks
    var markdown: [String: MarkdownContent] = [:]
    var markdownSegments: [String: [MarkdownSegment]] = [:]
    var inlineMathSources: Set<String> = []

    for block in blocks {
      switch block {
      case .markdown(let text):
        let segments = MacAnswerContentParser.splitMarkdownForInlineMath(text).map { segment in
          if segment.useLaTeX {
            inlineMathSources.insert(segment.text)
            return MarkdownSegment(
              text: segment.text,
              useLaTeX: true,
              markdownContent: nil,
              columnAlignments: []
            )
          }
          let content = MarkdownContent(segment.text)
          markdown[segment.text] = content
          return MarkdownSegment(
            text: segment.text,
            useLaTeX: false,
            markdownContent: content,
            columnAlignments: MacMarkdownTableAlignment.columnAlignments(in: segment.text) ?? []
          )
        }
        markdownSegments[text] = segments

      case .table(let table):
        // Preserve pre-parsed Markdown fallback for any caller inspecting the
        // cached MarkdownContent map directly.
        if markdown[table.rawMarkdown] == nil {
          markdown[table.rawMarkdown] = MarkdownContent(table.rawMarkdown)
        }

      case .code, .math:
        break
      }
    }

    self.markdown = markdown
    self.markdownSegments = markdownSegments
    self.inlineMathSources = inlineMathSources
  }

  static func shouldUseInlineMathRenderer(_ markdown: String) -> Bool {
    let segments = MacAnswerContentParser.splitMarkdownForInlineMath(markdown)
    return segments.count == 1 && segments[0].useLaTeX
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
