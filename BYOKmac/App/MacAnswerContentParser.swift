import CoreGraphics
import Foundation

struct MacParsedMarkdownTable: Equatable, Sendable {
  let headers: [String]
  let alignments: [MacTableColumnAlignment]
  let rows: [[String]]
  let rawMarkdown: String

  var columnCount: Int { headers.count }

  var markdownText: String { rawMarkdown }

  /// Tab-separated plain text suited for pasting into Numbers, Excel, or Google Sheets.
  var tsvText: String {
    let allRows = [headers] + rows
    return allRows
      .map { row in
        row.map { cell in
          MacAnswerContentParser.plainTableCellText(cell)
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .joined(separator: "\t")
      }
      .joined(separator: "\n")
  }
}

enum MacMarkdownTableLayout {
  static let cellHorizontalPadding: CGFloat = 12
  static let cellVerticalPadding: CGFloat = 9

  struct Metrics: Equatable, Sendable {
    let columnWidths: [CGFloat]
    let totalWidth: CGFloat
    let overflowsViewport: Bool
  }

  private struct CacheKey: Hashable, Sendable {
    let rawMarkdown: String
    let availableWidthBucket: Int
    let fontSizeTenths: Int
    let fillsWidth: Bool
    let maxColumnWidthBucket: Int?
  }

  private final class MetricsCache: @unchecked Sendable {
    static let shared = MetricsCache()

    private let lock = NSLock()
    private var values: [CacheKey: Metrics] = [:]
    private var order: [CacheKey] = []
    private let limit = 128

    func value(for key: CacheKey) -> Metrics? {
      lock.lock()
      defer { lock.unlock() }
      return values[key]
    }

    func insert(_ metrics: Metrics, for key: CacheKey) {
      lock.lock()
      defer { lock.unlock() }
      if values[key] == nil {
        order.append(key)
      }
      values[key] = metrics
      if order.count > limit {
        values.removeValue(forKey: order.removeFirst())
      }
    }
  }

  /// Computes deterministic, content-aware column widths that fit compact tables
  /// cleanly to the available viewport while keeping wide multi-column tables
  /// comfortably scrollable.
  static func compute(
    for table: MacParsedMarkdownTable,
    availableWidth: CGFloat,
    fontSize: CGFloat,
    fillsWidth: Bool,
    maxColumnWidthOverride: CGFloat? = nil
  ) -> Metrics {
    let columnCount = table.headers.count
    guard columnCount > 0 else {
      return Metrics(columnWidths: [], totalWidth: 0, overflowsViewport: false)
    }

    let safeFontSize = max(11, fontSize)
    let safeAvailableWidth = max(180, availableWidth)
    let cacheKey = CacheKey(
      rawMarkdown: table.rawMarkdown,
      availableWidthBucket: Int((safeAvailableWidth / 4).rounded()),
      fontSizeTenths: Int((safeFontSize * 10).rounded()),
      fillsWidth: fillsWidth,
      maxColumnWidthBucket: maxColumnWidthOverride.map { Int($0.rounded()) }
    )
    if let cached = MetricsCache.shared.value(for: cacheKey) {
      return cached
    }
    let charWidth = safeFontSize * 0.54
    let horizontalInset = cellHorizontalPadding * 2
    let minColumnWidth = max(54, ceil(safeFontSize * 3.6))
    let defaultMaxColumnWidth = min(
      max(220, safeAvailableWidth * 0.68),
      ceil(safeFontSize * 18.5)
    )
    let maxColumnWidth = max(
      minColumnWidth + 24,
      maxColumnWidthOverride ?? defaultMaxColumnWidth
    )

    let sampledRows = table.rows.prefix(60)
    var headerUnits = Array(repeating: CGFloat(0), count: columnCount)
    var maxLineUnits = Array(repeating: CGFloat(0), count: columnCount)
    var longestWordUnits = Array(repeating: CGFloat(0), count: columnCount)
    var contentWeight = Array(repeating: CGFloat(1), count: columnCount)

    for col in 0..<columnCount {
      let headerStats = measureCell(table.headers[col])
      headerUnits[col] = headerStats.maxLineUnits
      longestWordUnits[col] = max(longestWordUnits[col], headerStats.longestWordUnits)
      contentWeight[col] = max(contentWeight[col], headerStats.maxLineUnits)
    }

    for row in sampledRows {
      for col in 0..<min(columnCount, row.count) {
        let stats = measureCell(row[col])
        maxLineUnits[col] = max(maxLineUnits[col], stats.maxLineUnits)
        longestWordUnits[col] = max(longestWordUnits[col], stats.longestWordUnits)
        contentWeight[col] = max(contentWeight[col], stats.maxLineUnits)
      }
    }

    var widths: [CGFloat] = []
    var floors: [CGFloat] = []
    widths.reserveCapacity(columnCount)
    floors.reserveCapacity(columnCount)

    for col in 0..<columnCount {
      let headerDesired = ceil(headerUnits[col] * charWidth * 1.12) + horizontalInset
      let bodyDesired = ceil(maxLineUnits[col] * charWidth * 1.04) + horizontalInset
      let wordFloor = ceil(min(longestWordUnits[col], 20) * charWidth) + horizontalInset
      let desired = max(headerDesired, bodyDesired, wordFloor)
      let clamped = min(max(desired, minColumnWidth), maxColumnWidth)
      widths.append(clamped)
      floors.append(min(max(wordFloor, minColumnWidth), clamped))
    }

    let naturalTotal = widths.reduce(0, +)

    if naturalTotal <= safeAvailableWidth {
      if fillsWidth {
        let spare = safeAvailableWidth - naturalTotal
        if spare > 0.5 {
          let weights = contentWeight.map { max(CGFloat(2), min($0, 48)) }
          let totalWeight = weights.reduce(0, +)
          if totalWeight > 0 {
            var allocated: CGFloat = 0
            for col in 0..<columnCount {
              if col == columnCount - 1 {
                widths[col] += max(0, spare - allocated)
              } else {
                let share = floor(spare * (weights[col] / totalWeight))
                widths[col] += share
                allocated += share
              }
            }
          }
        }
      }
    } else if naturalTotal <= safeAvailableWidth * 1.14 {
      let deficit = naturalTotal - safeAvailableWidth
      let reducible = zip(widths, floors).map { width, floorWidth in
        let softFloor = max(floorWidth, minColumnWidth + 32)
        return max(0, width - softFloor)
      }
      let totalReducible = reducible.reduce(0, +)
      if totalReducible >= deficit, totalReducible > 0 {
        var trimmed: CGFloat = 0
        for col in 0..<columnCount where reducible[col] > 0 {
          let cut = min(reducible[col], ceil(deficit * (reducible[col] / totalReducible)))
          let applied = min(cut, max(0, deficit - trimmed))
          widths[col] -= applied
          trimmed += applied
        }
      }
    }

    let finalTotal = widths.reduce(0, +)
    let result = Metrics(
      columnWidths: widths,
      totalWidth: finalTotal,
      overflowsViewport: finalTotal > safeAvailableWidth + 1
    )
    MetricsCache.shared.insert(result, for: cacheKey)
    return result
  }

  private struct CellStats {
    let maxLineUnits: CGFloat
    let longestWordUnits: CGFloat
  }

  private static func measureCell(_ raw: String) -> CellStats {
    let plain = MacAnswerContentParser.plainTableCellText(raw)
    guard !plain.isEmpty else {
      return CellStats(maxLineUnits: 1, longestWordUnits: 1)
    }

    var maxLine: CGFloat = 0
    var maxWord: CGFloat = 0

    for line in plain.components(separatedBy: .newlines) {
      var lineUnits: CGFloat = 0
      var currentWord: CGFloat = 0
      for scalar in line.unicodeScalars {
        if CharacterSet.whitespaces.contains(scalar) {
          maxWord = max(maxWord, currentWord)
          currentWord = 0
          lineUnits += 0.45
        } else {
          let unit = scalarDisplayWidth(scalar)
          lineUnits += unit
          currentWord += unit
        }
      }
      maxWord = max(maxWord, currentWord)
      maxLine = max(maxLine, lineUnits)
    }

    if raw.contains("![") {
      maxLine = max(maxLine, 14)
    }

    return CellStats(maxLineUnits: maxLine, longestWordUnits: maxWord)
  }

  private static func scalarDisplayWidth(_ scalar: Unicode.Scalar) -> CGFloat {
    let value = scalar.value
    // CJK Unified Ideographs, Hiragana, Katakana, Hangul, Fullwidth Forms, Emoji
    if (0x1100...0x115F).contains(value)
      || (0x2E80...0xA4CF).contains(value)
      || (0xAC00...0xD7A3).contains(value)
      || (0xF900...0xFAFF).contains(value)
      || (0xFE10...0xFE6F).contains(value)
      || (0xFF00...0xFF60).contains(value)
      || (0xFFE0...0xFFE6).contains(value)
      || (0x1F300...0x1FAFF).contains(value)
      || (0x20000...0x3FFFF).contains(value)
    {
      return 1.85
    }
    switch value {
    case 0x21, 0x27, 0x2C, 0x2E, 0x3A, 0x3B, 0x49, 0x69, 0x6C, 0x7C:
      return 0.55
    case 0x40, 0x4D, 0x57, 0x6D, 0x77, 0x25:
      return 1.2
    default:
      return 1.0
    }
  }
}

struct MacMarkdownMathSegment: Equatable, Sendable {
  let text: String
  let useLaTeX: Bool
}

struct MacAnswerSource: Identifiable, Hashable, Sendable {
  let url: URL
  let title: String?

  var id: String { url.absoluteString }

  var host: String {
    url.host(percentEncoded: false) ?? url.host ?? url.absoluteString
  }

  var displayTitle: String {
    let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? host : trimmed
  }
}

enum MacAnswerContentBlock: Equatable, Sendable {
  case markdown(String)
  case code(language: String?, content: String, isComplete: Bool)
  case math(String, isComplete: Bool)
  case table(MacParsedMarkdownTable)
}

enum MacAnswerContentParser {
  private static let inlineMathRegex = try? NSRegularExpression(
    pattern: #"(?<![\\$\d])\$(?![$\s])(?:\\.|[^$\n])+(?<!\s)(?<!\\)\$(?![$\d])|\\\((?:\\.|[^\\\n])+\\\)"#
  )
  private static let markdownLinkRegex = try? NSRegularExpression(
    pattern: #"(?<!!)\[([^\]]+)\]\((https?://(?:[^\s()]+|\([^\s()]*\))+)\)"#
  )
  private static let markdownImageRegex = try? NSRegularExpression(
    pattern: #"!\[[^\]]*\]\((?:[^\s()]+|\([^\s()]*\))+(?:\s+(?:"[^"]*"|'[^']*'))?\)"#
  )
  private static let orderedListRegex = try? NSRegularExpression(pattern: #"^\d+[.)]\s"#)
  private static let inlineMarkdownFormattingRegex = try? NSRegularExpression(
    pattern: #"(?:`[^`\n]+`|\*\*[^*\n]+\*\*|__[^_\n]+__|~~[^~\n]+~~|!?\[[^\]]+\]\([^)]+\))"#
  )

  private struct FenceOpening {
    let markerCharacter: Character
    let markerLength: Int
    let language: String?
  }

  private enum StreamingMode {
    case markdown
    case fence(startUTF8: Int, opening: FenceOpening)
    case math(startUTF8: Int, terminator: String)
  }

  private enum MarkdownContinuationKind: Equatable {
    case ordinary
    case list
    case blockquote
    case table
    case indented
    case html

    var canContinueAcrossBlankLine: Bool {
      switch self {
      case .list, .blockquote, .indented, .html: true
      case .ordinary, .table: false
      }
    }
  }

  private struct StreamingLine {
    let text: String
    let startUTF8: Int
    let endUTF8: Int
  }

  private struct ParsedTableSlice {
    let table: MacParsedMarkdownTable
    let nextIndex: Int
  }

  static func parse(_ text: String) -> [MacAnswerContentBlock] {
    let lines = text.components(separatedBy: .newlines)
    var blocks: [MacAnswerContentBlock] = []
    var markdownLines: [String] = []
    var index = 0

    func flushMarkdown() {
      let value = trimBlankLines(markdownLines.joined(separator: "\n"))
      markdownLines.removeAll(keepingCapacity: true)
      guard !value.isEmpty else { return }
      blocks.append(.markdown(value))
    }

    while index < lines.count {
      let line = lines[index]
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      if let fence = fenceOpening(trimmed) {
        flushMarkdown()
        index += 1
        var codeLines: [String] = []
        var isComplete = false
        while index < lines.count {
          let candidate = lines[index]
          if isFenceClosing(candidate.trimmingCharacters(in: .whitespaces), opening: fence) {
            isComplete = true
            index += 1
            break
          }
          codeLines.append(candidate)
          index += 1
        }
        blocks.append(
          .code(
            language: fence.language,
            content: trimTrailingNewlines(codeLines.joined(separator: "\n")),
            isComplete: isComplete
          )
        )
        continue
      }

      if trimmed == "$$" || trimmed == "\\[" {
        flushMarkdown()
        let terminator = trimmed == "$$" ? "$$" : "\\]"
        index += 1
        var mathLines: [String] = []
        var isComplete = false
        while index < lines.count {
          let candidate = lines[index]
          if candidate.trimmingCharacters(in: .whitespaces) == terminator {
            isComplete = true
            index += 1
            break
          }
          mathLines.append(candidate)
          index += 1
        }
        let math = trimBlankLines(mathLines.joined(separator: "\n"))
        if !math.isEmpty { blocks.append(.math(math, isComplete: isComplete)) }
        continue
      }

      if trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$"), trimmed.count > 4 {
        flushMarkdown()
        let start = trimmed.index(trimmed.startIndex, offsetBy: 2)
        let end = trimmed.index(trimmed.endIndex, offsetBy: -2)
        let math = String(trimmed[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !math.isEmpty { blocks.append(.math(math, isComplete: true)) }
        index += 1
        continue
      }

      if trimmed.hasPrefix("\\["), trimmed.hasSuffix("\\]"), trimmed.count > 4 {
        flushMarkdown()
        let start = trimmed.index(trimmed.startIndex, offsetBy: 2)
        let end = trimmed.index(trimmed.endIndex, offsetBy: -2)
        let math = String(trimmed[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !math.isEmpty { blocks.append(.math(math, isComplete: true)) }
        index += 1
        continue
      }

      if let parsedTable = parseTable(in: lines, startingAt: index) {
        flushMarkdown()
        blocks.append(.table(parsedTable.table))
        index = parsedTable.nextIndex
        continue
      }

      markdownLines.append(line)
      index += 1
    }

    flushMarkdown()
    return blocks
  }

  static func sources(in text: String, limit: Int = 50) -> [MacAnswerSource] {
    sources(in: parse(text), limit: limit)
  }

  static func sources(in blocks: [MacAnswerContentBlock], limit: Int = 50) -> [MacAnswerSource] {
    guard limit > 0 else { return [] }
    var values: [MacAnswerSource] = []
    var indexByKey: [String: Int] = [:]

    for block in blocks {
      let markdown: String
      switch block {
      case .markdown(let text):
        markdown = text
      case .table(let table):
        markdown = table.rawMarkdown
      case .code, .math:
        continue
      }

      for source in markdownSources(markdown) {
        let key = normalizedURLKey(source.url)
        if let existingIndex = indexByKey[key] {
          if values[existingIndex].title == nil,
            let title = source.title?.trimmingCharacters(in: .whitespacesAndNewlines),
            !title.isEmpty
          {
            values[existingIndex] = MacAnswerSource(url: values[existingIndex].url, title: title)
          }
          continue
        }
        guard values.count < limit else { return values }
        indexByKey[key] = values.count
        values.append(source)
      }
    }

    return values
  }

  /// Returns the source that can no longer change Markdown interpretation and
  /// one mutable suffix. This intentionally stays conservative: unfinished
  /// lists, quotes, indented blocks, HTML-ish blocks, fences and display math
  /// remain in the tail until a structurally distinct block begins.
  static func splitStreamingSource(_ source: String) -> (stable: String, tail: String) {
    guard !source.isEmpty else { return ("", "") }

    let lines = streamingLines(source)
    var mode: StreamingMode = .markdown
    var stableEndUTF8 = 0
    var markdownKind: MarkdownContinuationKind?
    var blankSeenInContinuation = false

    for line in lines {
      let trimmed = line.text.trimmingCharacters(in: .whitespaces)

      switch mode {
      case .fence(_, let opening):
        if isFenceClosing(trimmed, opening: opening) {
          stableEndUTF8 = line.endUTF8
          mode = .markdown
          markdownKind = nil
          blankSeenInContinuation = false
        }
        continue

      case .math(_, let terminator):
        if trimmed == terminator {
          stableEndUTF8 = line.endUTF8
          mode = .markdown
          markdownKind = nil
          blankSeenInContinuation = false
        }
        continue

      case .markdown:
        break
      }

      if let opening = fenceOpening(trimmed) {
        stableEndUTF8 = max(stableEndUTF8, line.startUTF8)
        mode = .fence(startUTF8: line.startUTF8, opening: opening)
        markdownKind = nil
        blankSeenInContinuation = false
        continue
      }

      if trimmed == "$$" || trimmed == "\\[" {
        stableEndUTF8 = max(stableEndUTF8, line.startUTF8)
        mode = .math(
          startUTF8: line.startUTF8,
          terminator: trimmed == "$$" ? "$$" : "\\]"
        )
        markdownKind = nil
        blankSeenInContinuation = false
        continue
      }

      if trimmed.isEmpty {
        guard let kind = markdownKind else {
          stableEndUTF8 = max(stableEndUTF8, line.endUTF8)
          continue
        }

        if kind.canContinueAcrossBlankLine {
          blankSeenInContinuation = true
        } else {
          stableEndUTF8 = line.endUTF8
          markdownKind = nil
          blankSeenInContinuation = false
        }
        continue
      }

      let nextKind = markdownContinuationKind(for: line.text)
      if let currentKind = markdownKind, blankSeenInContinuation {
        if currentKind != nextKind {
          stableEndUTF8 = max(stableEndUTF8, line.startUTF8)
          markdownKind = nextKind
        }
        blankSeenInContinuation = false
      } else if markdownKind == nil {
        markdownKind = nextKind
      }
    }

    let bytes = source.utf8
    let safeStableCount = min(stableEndUTF8, bytes.count)
    let stable = String(decoding: bytes.prefix(safeStableCount), as: UTF8.self)
    let tail = String(decoding: bytes.dropFirst(safeStableCount), as: UTF8.self)
    return (stable, tail)
  }

  static func containsInlineMath(_ text: String) -> Bool {
    guard text.contains("$") || text.contains("\\(") else { return false }
    guard let inlineMathRegex else { return false }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return inlineMathRegex.firstMatch(in: text, range: range) != nil
  }

  /// Splits a markdown block by blank-line paragraphs so plain inline-math
  /// paragraphs render with LaTeXSwiftUI without disabling math when headings or
  /// lists appear in the same block, and without breaking bold/code/links inside
  /// rich paragraphs.
  static func splitMarkdownForInlineMath(_ markdown: String) -> [MacMarkdownMathSegment] {
    guard containsInlineMath(markdown) else {
      return [MacMarkdownMathSegment(text: markdown, useLaTeX: false)]
    }

    let lines = markdown.components(separatedBy: .newlines)
    var chunks: [String] = []
    var current: [String] = []

    for line in lines {
      if line.trimmingCharacters(in: .whitespaces).isEmpty {
        if !current.isEmpty {
          chunks.append(current.joined(separator: "\n"))
          current.removeAll(keepingCapacity: true)
        }
      } else {
        current.append(line)
      }
    }
    if !current.isEmpty {
      chunks.append(current.joined(separator: "\n"))
    }

    var segments: [MacMarkdownMathSegment] = []
    var pendingMarkdown: [String] = []

    func flushPendingMarkdown() {
      guard !pendingMarkdown.isEmpty else { return }
      segments.append(
        MacMarkdownMathSegment(text: pendingMarkdown.joined(separator: "\n\n"), useLaTeX: false)
      )
      pendingMarkdown.removeAll(keepingCapacity: true)
    }

    for chunk in chunks {
      if shouldRenderChunkAsInlineMath(chunk) {
        flushPendingMarkdown()
        segments.append(MacMarkdownMathSegment(text: chunk, useLaTeX: true))
      } else {
        pendingMarkdown.append(chunk)
      }
    }
    flushPendingMarkdown()

    return segments.isEmpty ? [MacMarkdownMathSegment(text: markdown, useLaTeX: false)] : segments
  }

  static func isMermaidLanguage(_ language: String?) -> Bool {
    guard let language else { return false }
    var normalized = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let delimiterIndex = normalized.firstIndex(where: { $0 == "{" || $0 == "," || $0 == ";" }) {
      normalized = String(normalized[..<delimiterIndex]).trimmingCharacters(in: .whitespaces)
    }
    switch normalized {
    case "mermaid", "mmd", "mermaidjs", "mermaid-js": return true
    default: return false
    }
  }

  static func isValidBrowsableURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
      return false
    }
    guard let host = url.host, !host.isEmpty else { return false }
    return true
  }

  static func shouldRenderCellAsInlineMath(_ cell: String) -> Bool {
    guard containsInlineMath(cell), isLikelyBalancedInlineMath(cell) else { return false }
    if let inlineMarkdownFormattingRegex {
      let range = NSRange(cell.startIndex..<cell.endIndex, in: cell)
      if inlineMarkdownFormattingRegex.firstMatch(in: cell, range: range) != nil {
        return false
      }
    }
    return true
  }

  static func isLikelyBalancedInlineMath(_ text: String) -> Bool {
    var escaped = false
    var dollarCount = 0
    var openParens = 0
    var index = text.startIndex

    while index < text.endIndex {
      let character = text[index]
      if escaped {
        escaped = false
        index = text.index(after: index)
        continue
      }
      if character == "\\" {
        let next = text.index(after: index)
        if next < text.endIndex {
          let nextCharacter = text[next]
          if nextCharacter == "(" { openParens += 1 }
          if nextCharacter == ")" { openParens = max(0, openParens - 1) }
        }
        escaped = true
      } else if character == "$" {
        dollarCount += 1
      }
      index = text.index(after: index)
    }

    return dollarCount.isMultiple(of: 2) && openParens == 0
  }

  /// Strips inline Markdown syntax so table column widths and TSV export use
  /// visible cell text rather than hidden URLs or formatting delimiters.
  static func plainTableCellText(_ cell: String) -> String {
    guard !cell.isEmpty else { return "" }
    var result = cell
    if result.contains("![") {
      result = result.replacingOccurrences(
        of: #"!\[([^\]]*)\]\([^)\s]+[^)]*\)"#,
        with: "$1",
        options: .regularExpression
      )
    }
    if result.contains("](") {
      result = result.replacingOccurrences(
        of: #"\[([^\]]+)\]\((?:[^\s()]+|\([^\s()]*\))+\)"#,
        with: "$1",
        options: .regularExpression
      )
    }
    if result.contains("`") {
      result = result.replacingOccurrences(
        of: #"`+([^`]+)`+"#,
        with: "$1",
        options: .regularExpression
      )
    }
    if result.contains("*") || result.contains("_") || result.contains("~") {
      result = result.replacingOccurrences(
        of: #"\*\*([^*]+)\*\*"#,
        with: "$1",
        options: .regularExpression
      )
      result = result.replacingOccurrences(
        of: #"__([^_]+)__"#,
        with: "$1",
        options: .regularExpression
      )
      result = result.replacingOccurrences(
        of: #"~~([^~]+)~~"#,
        with: "$1",
        options: .regularExpression
      )
      result = result.replacingOccurrences(
        of: #"(?<!\w)\*([^*\n]+)\*(?!\w)"#,
        with: "$1",
        options: .regularExpression
      )
      result = result.replacingOccurrences(
        of: #"(?<!\w)_([^_\n]+)_(?!\w)"#,
        with: "$1",
        options: .regularExpression
      )
    }
    if result.contains("\\") {
      result = result.replacingOccurrences(
        of: #"\\([\\`*_{}\[\]()#+\-.!|])"#,
        with: "$1",
        options: .regularExpression
      )
    }
    return result
  }

  static func parseTableDelimiterRow(_ line: String) -> [MacTableColumnAlignment]? {
    guard !hasIndentedCodePrefix(line) else { return nil }
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty,
      !trimmed.hasPrefix(">"),
      trimmed.contains("|"),
      trimmed.contains("-")
    else { return nil }

    let rawCells = splitRawPipeCells(trimmed, respectCodeSpans: false)
    guard !rawCells.isEmpty else { return nil }

    var alignments: [MacTableColumnAlignment] = []
    alignments.reserveCapacity(rawCells.count)

    for cell in rawCells {
      let token = cell.trimmingCharacters(in: .whitespaces)
      var slice = token[...]
      let hasLeadingColon = slice.first == ":"
      if hasLeadingColon { slice = slice.dropFirst() }
      let hasTrailingColon = slice.last == ":"
      if hasTrailingColon { slice = slice.dropLast() }
      guard !slice.isEmpty, slice.allSatisfy({ $0 == "-" }) else { return nil }

      switch (hasLeadingColon, hasTrailingColon) {
      case (true, true): alignments.append(.center)
      case (false, true): alignments.append(.trailing)
      default: alignments.append(.leading)
      }
    }

    return alignments
  }

  private static func shouldRenderChunkAsInlineMath(_ chunk: String) -> Bool {
    guard containsInlineMath(chunk), isLikelyBalancedInlineMath(chunk) else { return false }
    for line in chunk.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("#")
        || trimmed.hasPrefix(">")
        || trimmed.hasPrefix("- ")
        || trimmed.hasPrefix("* ")
        || trimmed.hasPrefix("+ ")
        || trimmed.hasPrefix("|")
        || parseTableDelimiterRow(line) != nil
      {
        return false
      }
      if let orderedListRegex {
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        if orderedListRegex.firstMatch(in: trimmed, range: range) != nil {
          return false
        }
      }
    }
    if let inlineMarkdownFormattingRegex {
      let range = NSRange(chunk.startIndex..<chunk.endIndex, in: chunk)
      if inlineMarkdownFormattingRegex.firstMatch(in: chunk, range: range) != nil {
        return false
      }
    }
    return true
  }

  private static func parseTable(in lines: [String], startingAt index: Int) -> ParsedTableSlice? {
    guard index + 1 < lines.count else { return nil }
    let headerLine = lines[index]
    let delimiterLine = lines[index + 1]

    guard isTableCandidateHeaderLine(headerLine),
      let alignments = parseTableDelimiterRow(delimiterLine)
    else { return nil }

    let headers = splitTableRowCells(headerLine, normalizeCellContent: true)
    guard !headers.isEmpty, headers.count == alignments.count else { return nil }

    var rows: [[String]] = []
    var rowIndex = index + 2
    let columnCount = headers.count

    while rowIndex < lines.count {
      let candidate = lines[rowIndex]
      let trimmed = candidate.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty
        || hasIndentedCodePrefix(candidate)
        || fenceOpening(trimmed) != nil
        || trimmed == "$$"
        || trimmed == "\\["
        || (trimmed.hasPrefix("$$") && trimmed.hasSuffix("$$") && trimmed.count > 4)
        || (trimmed.hasPrefix("\\[") && trimmed.hasSuffix("\\]") && trimmed.count > 4)
        || trimmed.hasPrefix("#")
        || trimmed.hasPrefix(">")
        || isThematicBreak(trimmed)
        || (!trimmed.hasPrefix("|") && isListMarker(trimmed))
        || !trimmed.contains("|")
      {
        break
      }

      if rowIndex + 1 < lines.count,
        isTableCandidateHeaderLine(candidate),
        let nextAlignments = parseTableDelimiterRow(lines[rowIndex + 1]),
        splitTableRowCells(candidate, normalizeCellContent: false).count == nextAlignments.count
      {
        break
      }

      var cells = splitTableRowCells(candidate, normalizeCellContent: true)
      if cells.count < columnCount {
        cells.append(contentsOf: repeatElement("", count: columnCount - cells.count))
      } else if cells.count > columnCount {
        cells = Array(cells.prefix(columnCount))
      }
      rows.append(cells)
      rowIndex += 1
    }

    let rawMarkdown = lines[index..<rowIndex].joined(separator: "\n")
    let table = MacParsedMarkdownTable(
      headers: headers,
      alignments: alignments,
      rows: rows,
      rawMarkdown: rawMarkdown
    )
    return ParsedTableSlice(table: table, nextIndex: rowIndex)
  }

  private static func hasIndentedCodePrefix(_ line: String) -> Bool {
    var spaces = 0
    for character in line {
      if character == " " {
        spaces += 1
        if spaces >= 4 { return true }
      } else if character == "\t" {
        return true
      } else {
        break
      }
    }
    return false
  }

  private static func isListMarker(_ trimmedLine: String) -> Bool {
    if trimmedLine.hasPrefix("- ") || trimmedLine.hasPrefix("* ") || trimmedLine.hasPrefix("+ ") {
      return true
    }
    if let orderedListRegex {
      let range = NSRange(trimmedLine.startIndex..<trimmedLine.endIndex, in: trimmedLine)
      if orderedListRegex.firstMatch(in: trimmedLine, range: range) != nil {
        return true
      }
    }
    return false
  }

  private static func isThematicBreak(_ trimmedLine: String) -> Bool {
    guard !trimmedLine.contains("|") else { return false }
    let stripped = trimmedLine.filter { !$0.isWhitespace }
    guard stripped.count >= 3, let first = stripped.first, first == "-" || first == "*" || first == "_"
    else { return false }
    return stripped.allSatisfy { $0 == first }
  }

  private static func isTableCandidateHeaderLine(_ line: String) -> Bool {
    guard !hasIndentedCodePrefix(line) else { return false }
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, trimmed.contains("|") else { return false }
    if trimmed.hasPrefix("#") || trimmed.hasPrefix(">") || fenceOpening(trimmed) != nil {
      return false
    }
    if !trimmed.hasPrefix("|") && isListMarker(trimmed) {
      return false
    }
    return true
  }

  private static func splitTableRowCells(
    _ line: String,
    normalizeCellContent: Bool
  ) -> [String] {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    let rawCells = splitRawPipeCells(trimmed, respectCodeSpans: true)
    guard normalizeCellContent else { return rawCells }
    return rawCells.map { raw in
      let trimmedCell = raw.trimmingCharacters(in: .whitespaces)
      return replaceHTMLBreaksOutsideCode(trimmedCell)
    }
  }

  private static func splitRawPipeCells(
    _ trimmedLine: String,
    respectCodeSpans: Bool
  ) -> [String] {
    var slice = trimmedLine[...]
    if slice.first == "|" {
      slice = slice.dropFirst()
    }
    if slice.last == "|", !hasUnescapedTrailingBackslashBeforeLastPipe(slice) {
      slice = slice.dropLast()
    }

    let chars = Array(slice)
    var cells: [String] = []
    var current = ""
    var index = 0
    var codeDelimiterLength: Int? = nil

    while index < chars.count {
      let ch = chars[index]

      if respectCodeSpans, ch == "`" {
        var runLength = 0
        while index + runLength < chars.count, chars[index + runLength] == "`" {
          runLength += 1
        }
        if let activeLength = codeDelimiterLength {
          if runLength == activeLength {
            codeDelimiterLength = nil
          }
          current.append(contentsOf: repeatElement("`", count: runLength))
          index += runLength
          continue
        } else if hasMatchingBacktickRun(in: chars, from: index + runLength, length: runLength) {
          codeDelimiterLength = runLength
          current.append(contentsOf: repeatElement("`", count: runLength))
          index += runLength
          continue
        } else {
          current.append(contentsOf: repeatElement("`", count: runLength))
          index += runLength
          continue
        }
      }

      if ch == "\\", index + 1 < chars.count {
        let next = chars[index + 1]
        if next == "|" {
          current.append("|")
          index += 2
          continue
        }
        if next == "\\", codeDelimiterLength == nil {
          current.append("\\")
          current.append("\\")
          index += 2
          continue
        }
      }

      if ch == "|", codeDelimiterLength == nil {
        cells.append(current)
        current.removeAll(keepingCapacity: true)
        index += 1
        continue
      }

      current.append(ch)
      index += 1
    }

    cells.append(current)
    return cells
  }

  private static func hasUnescapedTrailingBackslashBeforeLastPipe(_ slice: Substring) -> Bool {
    guard slice.last == "|" else { return false }
    var backslashes = 0
    var cursor = slice.index(before: slice.endIndex)
    while cursor > slice.startIndex {
      cursor = slice.index(before: cursor)
      if slice[cursor] == "\\" {
        backslashes += 1
      } else {
        break
      }
    }
    return backslashes % 2 == 1
  }

  private static func hasMatchingBacktickRun(
    in chars: [Character],
    from start: Int,
    length: Int
  ) -> Bool {
    var index = start
    while index < chars.count {
      if chars[index] == "`" {
        var runLength = 0
        while index + runLength < chars.count, chars[index + runLength] == "`" {
          runLength += 1
        }
        if runLength == length { return true }
        index += runLength
      } else {
        index += 1
      }
    }
    return false
  }

  private static func replaceHTMLBreaksOutsideCode(_ text: String) -> String {
    guard text.contains("<") else { return text }
    let chars = Array(text)
    var output = ""
    output.reserveCapacity(chars.count)
    var index = 0
    var codeDelimiterLength: Int? = nil

    while index < chars.count {
      let ch = chars[index]

      if ch == "`" {
        var runLength = 0
        while index + runLength < chars.count, chars[index + runLength] == "`" {
          runLength += 1
        }
        if let activeLength = codeDelimiterLength {
          if runLength == activeLength { codeDelimiterLength = nil }
        } else if hasMatchingBacktickRun(in: chars, from: index + runLength, length: runLength) {
          codeDelimiterLength = runLength
        }
        output.append(contentsOf: repeatElement("`", count: runLength))
        index += runLength
        continue
      }

      if codeDelimiterLength == nil, ch == "<",
        let breakEnd = matchHTMLBreakTag(in: chars, startingAt: index)
      {
        while output.last == " " || output.last == "\t" {
          output.removeLast()
        }
        output.append("\n")
        index = breakEnd
        while index < chars.count, chars[index] == " " || chars[index] == "\t" {
          index += 1
        }
        continue
      }

      output.append(ch)
      index += 1
    }

    return output
  }

  private static func matchHTMLBreakTag(in chars: [Character], startingAt start: Int) -> Int? {
    guard start + 3 < chars.count,
      chars[start] == "<",
      chars[start + 1].lowercased() == "b",
      chars[start + 2].lowercased() == "r"
    else { return nil }

    var cursor = start + 3
    while cursor < chars.count, chars[cursor] == " " || chars[cursor] == "\t" {
      cursor += 1
    }
    if cursor < chars.count, chars[cursor] == "/" {
      cursor += 1
      while cursor < chars.count, chars[cursor] == " " || chars[cursor] == "\t" {
        cursor += 1
      }
    }
    guard cursor < chars.count, chars[cursor] == ">" else { return nil }
    return cursor + 1
  }

  private static func fenceOpening(_ trimmedLine: String) -> FenceOpening? {
    guard let first = trimmedLine.first, first == "`" || first == "~" else { return nil }
    let markerLength = trimmedLine.prefix { $0 == first }.count
    guard markerLength >= 3 else { return nil }

    let rawLanguage = String(trimmedLine.dropFirst(markerLength))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if first == "`", rawLanguage.contains("`") { return nil }
    let language = rawLanguage.split(whereSeparator: \.isWhitespace).first.map(String.init)
    return FenceOpening(
      markerCharacter: first,
      markerLength: markerLength,
      language: language
    )
  }

  private static func isFenceClosing(_ trimmedLine: String, opening: FenceOpening) -> Bool {
    guard trimmedLine.first == opening.markerCharacter else { return false }
    let markerLength = trimmedLine.prefix { $0 == opening.markerCharacter }.count
    guard markerLength >= opening.markerLength else { return false }
    return trimmedLine.dropFirst(markerLength).trimmingCharacters(in: .whitespaces).isEmpty
  }

  private static func streamingLines(_ source: String) -> [StreamingLine] {
    let values = source.split(separator: "\n", omittingEmptySubsequences: false)
    var result: [StreamingLine] = []
    result.reserveCapacity(values.count)
    var offset = 0

    for (index, value) in values.enumerated() {
      let text = String(value)
      let hasNewline = index < values.count - 1
      let end = offset + text.utf8.count + (hasNewline ? 1 : 0)
      result.append(StreamingLine(text: text, startUTF8: offset, endUTF8: end))
      offset = end
    }
    return result
  }

  private static func markdownContinuationKind(for line: String) -> MarkdownContinuationKind {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix(">") { return .blockquote }
    if line.hasPrefix("    ") || line.hasPrefix("\t") { return .indented }
    if trimmed.hasPrefix("|") { return .table }
    if trimmed.hasPrefix("<") { return .html }
    if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
      return .list
    }
    if trimmed.range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil {
      return .list
    }
    return .ordinary
  }

  private static func trimBlankLines(_ value: String) -> String {
    var lines = value.components(separatedBy: .newlines)
    while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
      lines.removeFirst()
    }
    while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
      lines.removeLast()
    }
    return lines.joined(separator: "\n")
  }

  private static func trimTrailingNewlines(_ value: String) -> String {
    value.replacingOccurrences(of: #"\n+$"#, with: "", options: .regularExpression)
  }

  private struct PositionedSource {
    let location: Int
    let source: MacAnswerSource
  }

  private static func markdownSources(_ markdown: String) -> [MacAnswerSource] {
    let cleaned = stripMarkdownImages(from: stripInlineCodeSpans(from: markdown))
    guard !cleaned.isEmpty else { return [] }

    let fullRange = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
    var positioned: [PositionedSource] = []
    var linkedRanges: [NSRange] = []

    if let markdownLinkRegex {
      for match in markdownLinkRegex.matches(in: cleaned, range: fullRange) {
        guard
          match.numberOfRanges >= 3,
          let titleRange = Range(match.range(at: 1), in: cleaned),
          let urlRange = Range(match.range(at: 2), in: cleaned),
          let url = sanitizedURL(String(cleaned[urlRange]))
        else { continue }
        let rawTitle = String(cleaned[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        linkedRanges.append(match.range)
        positioned.append(
          PositionedSource(
            location: match.range.location,
            source: MacAnswerSource(url: url, title: rawTitle.isEmpty ? nil : rawTitle)
          )
        )
      }
    }

    if cleaned.contains("."),
      let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    {
      for match in detector.matches(in: cleaned, range: fullRange) {
        guard !linkedRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else {
          continue
        }
        guard let rawURL = match.url,
          let textRange = Range(match.range, in: cleaned)
        else { continue }

        let matchedText = String(cleaned[textRange])
        let loweredMatch = matchedText.lowercased()
        guard loweredMatch.hasPrefix("http://")
          || loweredMatch.hasPrefix("https://")
          || loweredMatch.hasPrefix("www.")
        else { continue }

        let resolvedURL: URL?
        if loweredMatch.hasPrefix("http://") || loweredMatch.hasPrefix("https://") {
          resolvedURL = sanitizedURL(matchedText) ?? sanitizedURL(rawURL.absoluteString)
        } else {
          resolvedURL = sanitizedURL(rawURL.absoluteString) ?? (isValidBrowsableURL(rawURL) ? rawURL : nil)
        }
        guard let url = resolvedURL else { continue }
        positioned.append(
          PositionedSource(
            location: match.range.location,
            source: MacAnswerSource(url: url, title: nil)
          )
        )
      }
    }

    return positioned
      .sorted { $0.location < $1.location }
      .map(\.source)
  }

  /// Replaces matched backtick inline code spans with spaces so links or image
  /// markdown inside inline code are ignored during extraction.
  static func stripInlineCodeSpans(from text: String) -> String {
    guard text.contains("`") else { return text }
    let chars = Array(text)
    var output = ""
    output.reserveCapacity(chars.count)
    var index = 0

    while index < chars.count {
      if chars[index] == "`" {
        var runLength = 0
        while index + runLength < chars.count, chars[index + runLength] == "`" {
          runLength += 1
        }
        if let closeStart = findMatchingBacktickRun(in: chars, from: index + runLength, length: runLength) {
          output.append(" ")
          index = closeStart + runLength
          continue
        }
        output.append(contentsOf: repeatElement("`", count: runLength))
        index += runLength
        continue
      }
      output.append(chars[index])
      index += 1
    }

    return output
  }

  private static func findMatchingBacktickRun(
    in chars: [Character],
    from start: Int,
    length: Int
  ) -> Int? {
    var index = start
    while index < chars.count {
      if chars[index] == "`" {
        var runLength = 0
        while index + runLength < chars.count, chars[index + runLength] == "`" {
          runLength += 1
        }
        if runLength == length { return index }
        index += runLength
      } else {
        index += 1
      }
    }
    return nil
  }

  private static func stripMarkdownImages(from text: String) -> String {
    guard text.contains("!["), let markdownImageRegex else { return text }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return markdownImageRegex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
  }

  private static func sanitizedURL(_ value: String) -> URL? {
    var trimmed = value
    let trailingSimplePunctuation: Set<Character> = [".", ",", ";", ":", "!", "?"]
    while let last = trimmed.last {
      if trailingSimplePunctuation.contains(last) {
        trimmed.removeLast()
      } else if last == ")" {
        let openCount = trimmed.filter { $0 == "(" }.count
        let closeCount = trimmed.filter { $0 == ")" }.count
        guard closeCount > openCount else { break }
        trimmed.removeLast()
      } else if last == "]" {
        let openCount = trimmed.filter { $0 == "[" }.count
        let closeCount = trimmed.filter { $0 == "]" }.count
        guard closeCount > openCount else { break }
        trimmed.removeLast()
      } else if last == "}" {
        let openCount = trimmed.filter { $0 == "{" }.count
        let closeCount = trimmed.filter { $0 == "}" }.count
        guard closeCount > openCount else { break }
        trimmed.removeLast()
      } else {
        break
      }
    }
    guard let url = URL(string: trimmed), isValidBrowsableURL(url) else { return nil }
    return url
  }

  private static func normalizedURLKey(_ url: URL) -> String {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.fragment = nil
    if components?.path == "/" { components?.path = "" }
    return (components?.url ?? url).absoluteString.lowercased()
  }
}
