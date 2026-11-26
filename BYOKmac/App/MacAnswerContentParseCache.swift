import CryptoKit
import Foundation
import MarkdownUI
import os

/// Compact cache key that avoids hashing or comparing multi-megabyte strings
/// (such as inline `data:image/...;base64,...` responses) on the main thread.
nonisolated struct MacAnswerCacheKey: Hashable, Sendable {
  private enum Backing: Hashable, Sendable {
    case exact(String)
    case sampled(utf8Count: Int, digest: Data)
  }

  private let backing: Backing

  init(source: String) {
    let utf8 = source.utf8
    let count = utf8.count
    if count <= 2_048 {
      backing = .exact(source)
    } else {
      var sample = Data()
      sample.reserveCapacity(800)
      sample.append(contentsOf: "\(count):".utf8)
      sample.append(contentsOf: utf8.prefix(256))
      let midStart = utf8.index(utf8.startIndex, offsetBy: max(0, (count / 2) - 128))
      let midEnd = utf8.index(midStart, offsetBy: min(256, count - (count / 2) + 128))
      sample.append(contentsOf: utf8[midStart..<midEnd])
      sample.append(contentsOf: utf8.suffix(256))
      let digest = Data(SHA256.hash(data: sample).prefix(16))
      backing = .sampled(utf8Count: count, digest: digest)
    }
  }
}

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

  let cacheKey: MacAnswerCacheKey
  let source: String
  let blocks: [MacAnswerContentBlock]
  let markdown: [String: MarkdownContent]
  let markdownSegments: [String: [MarkdownSegment]]
  let inlineMathSources: Set<String>
  let sources: [MacAnswerSource]
  let hasSavableImages: Bool

  init(source: String) {
    self.cacheKey = MacAnswerCacheKey(source: source)
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

      case .callout(_, let body):
        if markdown[body] == nil {
          markdown[body] = MarkdownContent(body)
        }

      case .details(_, let body, _):
        if !body.isEmpty, markdown[body] == nil {
          markdown[body] = MarkdownContent(body)
        }

      case .code, .math:
        break
      }
    }

    self.markdown = markdown
    self.markdownSegments = markdownSegments
    self.inlineMathSources = inlineMathSources
    self.sources = MacAnswerContentParser.sources(in: blocks)
    self.hasSavableImages = MacResponseImageScanner.hasImageCandidates(in: blocks)
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
  private var values: [MacAnswerCacheKey: MacPreparedAnswer] = [:]
  private var order: [MacAnswerCacheKey] = []
  private var sourceBytes = 0
  private let limit: Int
  private let byteLimit: Int

  init(limit: Int, byteLimit: Int) {
    self.limit = max(limit, 1)
    self.byteLimit = max(byteLimit, 1)
  }

  func value(for source: String) -> MacPreparedAnswer? {
    value(forKey: MacAnswerCacheKey(source: source))
  }

  func value(forKey key: MacAnswerCacheKey) -> MacPreparedAnswer? {
    lock.lock()
    defer { lock.unlock() }
    guard let value = values[key] else { return nil }
    order.removeAll { $0 == key }
    order.append(key)
    return value
  }

  func insert(_ value: MacPreparedAnswer) {
    lock.lock()
    defer { lock.unlock() }
    let cost = value.source.utf8.count
    guard cost <= byteLimit else { return }
    let key = value.cacheKey
    if let existing = values[key] {
      sourceBytes -= existing.source.utf8.count
    }
    sourceBytes += cost
    values[key] = value
    order.removeAll { $0 == key }
    order.append(key)
    while order.count > limit || sourceBytes > byteLimit {
      let evictedKey = order.removeFirst()
      if let evicted = values.removeValue(forKey: evictedKey) {
        sourceBytes -= evicted.source.utf8.count
      }
    }
  }
}

/// Bounded by entry count and total source bytes (not an estimate of AST memory).
/// Parsing runs off the main actor and results are reused across row lifetimes.
actor MacAnswerContentParseCache {
  static let shared = MacAnswerContentParseCache()
  private static let log = OSLog(subsystem: "pro.byok.BYOKchat", category: "ChatSwitch")
  private nonisolated let storage: MacPreparedAnswerStorage

  init(limit: Int = 64, byteLimit: Int = 32 * 1_024 * 1_024) {
    storage = MacPreparedAnswerStorage(limit: limit, byteLimit: byteLimit)
  }

  nonisolated func cachedAnswer(for source: String) -> MacPreparedAnswer? {
    storage.value(for: source)
  }

  nonisolated func cachedAnswer(forKey key: MacAnswerCacheKey) -> MacPreparedAnswer? {
    storage.value(forKey: key)
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

  /// Prepares multiple unique assistant responses concurrently off the main actor
  /// so opening a conversation doesn't serialize parsing or trigger cascading
  /// row relayouts after mount.
  nonisolated func prepareBatch(_ sources: [String]) async throws -> [MacAnswerCacheKey: MacPreparedAnswer] {
    try Task.checkCancellation()
    var results: [MacAnswerCacheKey: MacPreparedAnswer] = [:]
    var uncached: [(key: MacAnswerCacheKey, source: String)] = []
    var seen: Set<MacAnswerCacheKey> = []
    results.reserveCapacity(sources.count)

    for source in sources where !source.isEmpty {
      let key = MacAnswerCacheKey(source: source)
      guard seen.insert(key).inserted else { continue }
      if let cached = storage.value(forKey: key) {
        results[key] = cached
      } else {
        uncached.append((key: key, source: source))
      }
    }

    guard !uncached.isEmpty else { return results }

    let parsedPairs = try await withThrowingTaskGroup(
      of: (MacAnswerCacheKey, MacPreparedAnswer).self,
      returning: [(MacAnswerCacheKey, MacPreparedAnswer)].self
    ) { group in
      // Keep at least one core free for the main thread on low-core Macs.
      let maxConcurrency = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount - 1))
      var nextIndex = 0

      func enqueueNext() {
        guard nextIndex < uncached.count else { return }
        let item = uncached[nextIndex]
        nextIndex += 1
        let storage = self.storage
        group.addTask(priority: .userInitiated) {
          try Task.checkCancellation()
          if let cached = storage.value(forKey: item.key) {
            return (item.key, cached)
          }
          let signpostID = OSSignpostID(log: Self.log)
          os_signpost(.begin, log: Self.log, name: "Prepare Markdown", signpostID: signpostID)
          defer { os_signpost(.end, log: Self.log, name: "Prepare Markdown", signpostID: signpostID) }
          let prepared = MacPreparedAnswer(source: item.source)
          try Task.checkCancellation()
          storage.insert(prepared)
          return (item.key, prepared)
        }
      }

      for _ in 0..<min(maxConcurrency, uncached.count) {
        enqueueNext()
      }

      var collected: [(MacAnswerCacheKey, MacPreparedAnswer)] = []
      collected.reserveCapacity(uncached.count)
      while let pair = try await group.next() {
        collected.append(pair)
        enqueueNext()
      }
      return collected
    }

    for (key, prepared) in parsedPairs {
      results[key] = prepared
    }
    return results
  }
}
