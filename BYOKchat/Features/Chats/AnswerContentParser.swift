import CoreGraphics
import Foundation

enum MarkdownTableAlignment: Equatable, Hashable, Sendable {
  case leading
  case center
  case trailing
}

struct ParsedMarkdownTable: Equatable, Sendable {
  let headers: [String]
  let alignments: [MarkdownTableAlignment]
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
          let plain = AnswerContentParser.plainTableCellText(cell)
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
          return plain
        }
        .joined(separator: "\t")
      }
      .joined(separator: "\n")
  }
}

enum MarkdownTableLayout {
  static let cellHorizontalPadding: CGFloat = 12
  static let cellVerticalPadding: CGFloat = 9

  struct Metrics: Equatable, Sendable {
    let columnWidths: [CGFloat]
    let totalWidth: CGFloat
    let overflowsViewport: Bool
  }

  /// Computes deterministic, content-aware column widths that scale cleanly with
  /// Dynamic Type, fit compact tables to the available viewport without awkward
  /// gaps, and keep wide multi-column tables comfortably scrollable without
  /// SwiftUI List height collapse.
  static func compute(
    for table: ParsedMarkdownTable,
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
          // Distribute spare space weighted by content length so description
          // columns expand much more than tiny `#` or status columns.
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
      // Gently trim wrapping-friendly columns when the table barely exceeds the
      // viewport so 2–3 column tables avoid an annoying 15pt horizontal scroll.
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
    return Metrics(
      columnWidths: widths,
      totalWidth: finalTotal,
      overflowsViewport: finalTotal > safeAvailableWidth + 1
    )
  }

  private struct CellStats {
    let maxLineUnits: CGFloat
    let longestWordUnits: CGFloat
  }

  private static func measureCell(_ raw: String) -> CellStats {
    let plain = AnswerContentParser.plainTableCellText(raw)
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

    // Reserve reasonable width for inline images inside table cells.
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
    case 0x21, 0x27, 0x2C, 0x2E, 0x3A, 0x3B, 0x49, 0x69, 0x6C, 0x7C: // ! ' , . : ; I i l |
      return 0.55
    case 0x40, 0x4D, 0x57, 0x6D, 0x77, 0x25: // @ M W m w %
      return 1.2
    default:
      return 1.0
    }
  }
}

enum AnswerContentBlock: Equatable, Sendable {
  case markdown(String)
  case code(language: String?, content: String)
  case math(String)
  case table(ParsedMarkdownTable)
}

struct ParsedAnswerBlock: Equatable, Sendable {
  let block: AnswerContentBlock
  let isClosed: Bool
}

struct MarkdownMathSegment: Equatable, Sendable {
  let text: String
  let useLaTeX: Bool
}

struct AnswerSource: Identifiable, Hashable, Sendable {
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

enum AnswerContentParser {
  private static let inlineMathRegex = try? NSRegularExpression(
    pattern: #"(?<![\\$\d])\$(?![$\s])(?:\\.|[^$\n])+(?<!\s)(?<!\\)\$(?![$\d])|\\\((?:\\.|[^\\\n])+\\\)"#
  )
  private static let markdownLinkRegex = try? NSRegularExpression(
    pattern: #"(?<!!)\[([^\]]+)\]\((https?://(?:[^\s()]+|\([^\s()]*\))+)\)"#
  )
  private static let orderedListRegex = try? NSRegularExpression(pattern: #"^\d+[.)]\s"#)
  private static let inlineMarkdownFormattingRegex = try? NSRegularExpression(
    pattern: #"(?:`[^`\n]+`|\*\*[^*\n]+\*\*|__[^_\n]+__|~~[^~\n]+~~|!?\[[^\]]+\]\([^)]+\))"#
  )

  static func parse(_ text: String) -> [AnswerContentBlock] {
    parseDetailed(text).map(\.block)
  }

  static func parseDetailed(_ text: String) -> [ParsedAnswerBlock] {
    let lines = text.components(separatedBy: .newlines)
    var blocks: [ParsedAnswerBlock] = []
    var markdownLines: [String] = []
    var index = 0

    func flushMarkdown() {
      let value = trimBlankLines(markdownLines.joined(separator: "\n"))
      markdownLines.removeAll(keepingCapacity: true)
      guard !value.isEmpty else { return }
      blocks.append(ParsedAnswerBlock(block: .markdown(value), isClosed: true))
    }

    while index < lines.count {
      let line = lines[index]
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      if let fence = fenceOpening(trimmed) {
        flushMarkdown()
        index += 1
        var codeLines: [String] = []
        var isClosed = false
        while index < lines.count {
          let candidate = lines[index]
          if isFenceClosing(candidate.trimmingCharacters(in: .whitespaces), for: fence) {
            isClosed = true
            break
          }
          codeLines.append(candidate)
          index += 1
        }
        if isClosed, index < lines.count { index += 1 }
        blocks.append(
          ParsedAnswerBlock(
            block: .code(
              language: fence.language,
              content: trimTrailingNewlines(codeLines.joined(separator: "\n"))
            ),
            isClosed: isClosed
          )
        )
        continue
      }

      if trimmed == "$$" || trimmed == "\\[" {
        flushMarkdown()
        let terminator = trimmed == "$$" ? "$$" : "\\]"
        index += 1
        var mathLines: [String] = []
        var isClosed = false
        while index < lines.count {
          let candidate = lines[index]
          if candidate.trimmingCharacters(in: .whitespaces) == terminator {
            isClosed = true
            break
          }
          mathLines.append(candidate)
          index += 1
        }
        if isClosed, index < lines.count { index += 1 }
        let math = trimBlankLines(mathLines.joined(separator: "\n"))
        if !math.isEmpty {
          blocks.append(ParsedAnswerBlock(block: .math(math), isClosed: isClosed))
        }
        continue
      }

      if trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$"), trimmed.count > 4 {
        flushMarkdown()
        let start = trimmed.index(trimmed.startIndex, offsetBy: 2)
        let end = trimmed.index(trimmed.endIndex, offsetBy: -2)
        let math = String(trimmed[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !math.isEmpty {
          blocks.append(ParsedAnswerBlock(block: .math(math), isClosed: true))
        }
        index += 1
        continue
      }

      if trimmed.hasPrefix("\\["), trimmed.hasSuffix("\\]"), trimmed.count > 4 {
        flushMarkdown()
        let start = trimmed.index(trimmed.startIndex, offsetBy: 2)
        let end = trimmed.index(trimmed.endIndex, offsetBy: -2)
        let math = String(trimmed[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !math.isEmpty {
          blocks.append(ParsedAnswerBlock(block: .math(math), isClosed: true))
        }
        index += 1
        continue
      }

      if let parsedTable = parseTable(in: lines, startingAt: index) {
        flushMarkdown()
        blocks.append(
          ParsedAnswerBlock(
            block: .table(parsedTable.table),
            isClosed: parsedTable.isClosed
          )
        )
        index = parsedTable.nextIndex
        continue
      }

      markdownLines.append(line)
      index += 1
    }

    flushMarkdown()
    return blocks
  }

  static func sources(in blocks: [AnswerContentBlock], limit: Int = 50) -> [AnswerSource] {
    var values: [AnswerSource] = []
    var seen = Set<String>()

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
        guard seen.insert(key).inserted else { continue }
        values.append(source)
        if values.count >= limit { return values }
      }
    }

    return values
  }

  static func containsInlineMath(_ text: String) -> Bool {
    guard text.contains("$") || text.contains("\\(") else { return false }
    guard let inlineMathRegex else { return false }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return inlineMathRegex.firstMatch(in: text, range: range) != nil
  }

  /// Splits a markdown chunk by blank-line paragraphs so plain inline-math
  /// paragraphs can render with LaTeXSwiftUI without disabling math elsewhere
  /// when a heading/list exists, and without breaking bold/code/links inside
  /// rich paragraphs.
  static func splitMarkdownForInlineMath(_ markdown: String) -> [MarkdownMathSegment] {
    guard containsInlineMath(markdown) else {
      return [MarkdownMathSegment(text: markdown, useLaTeX: false)]
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

    var segments: [MarkdownMathSegment] = []
    var pendingMarkdown: [String] = []

    func flushPendingMarkdown() {
      guard !pendingMarkdown.isEmpty else { return }
      segments.append(
        MarkdownMathSegment(text: pendingMarkdown.joined(separator: "\n\n"), useLaTeX: false)
      )
      pendingMarkdown.removeAll(keepingCapacity: true)
    }

    for chunk in chunks {
      if shouldRenderChunkAsInlineMath(chunk) {
        flushPendingMarkdown()
        segments.append(MarkdownMathSegment(text: chunk, useLaTeX: true))
      } else {
        pendingMarkdown.append(chunk)
      }
    }
    flushPendingMarkdown()

    return segments.isEmpty ? [MarkdownMathSegment(text: markdown, useLaTeX: false)] : segments
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

  /// True only for HTTP/HTTPS URLs with a non-empty host, which is required by
  /// `SFSafariViewController` to avoid throwing `NSInvalidArgumentException`.
  static func isValidBrowsableURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
      return false
    }
    guard let host = url.host, !host.isEmpty else { return false }
    return true
  }

  static func shouldRenderCellAsInlineMath(_ cell: String) -> Bool {
    guard containsInlineMath(cell) else { return false }
    if let inlineMarkdownFormattingRegex {
      let range = NSRange(cell.startIndex..<cell.endIndex, in: cell)
      if inlineMarkdownFormattingRegex.firstMatch(in: cell, range: range) != nil {
        return false
      }
    }
    return true
  }

  /// Strips inline Markdown syntax so table column widths and TSV export use
  /// visible cell text rather than hidden URLs or formatting delimiters.
  static func plainTableCellText(_ cell: String) -> String {
    guard !cell.isEmpty else { return "" }
    var result = cell
    // Markdown images: ![alt](url) -> alt
    if result.contains("![") {
      result = result.replacingOccurrences(
        of: #"!\[([^\]]*)\]\([^)\s]+[^)]*\)"#,
        with: "$1",
        options: .regularExpression
      )
    }
    // Markdown links: [label](url) -> label
    if result.contains("](") {
      result = result.replacingOccurrences(
        of: #"\[([^\]]+)\]\((?:[^\s()]+|\([^\s()]*\))+\)"#,
        with: "$1",
        options: .regularExpression
      )
    }
    // Inline code spans: `code` -> code
    if result.contains("`") {
      result = result.replacingOccurrences(
        of: #"`+([^`]+)`+"#,
        with: "$1",
        options: .regularExpression
      )
    }
    // Bold, strikethrough, and emphasis markers
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
    // Common backslash escapes outside code
    if result.contains("\\") {
      result = result.replacingOccurrences(
        of: #"\\([\\`*_{}\[\]()#+\-.!|])"#,
        with: "$1",
        options: .regularExpression
      )
    }
    return result
  }

  private static func shouldRenderChunkAsInlineMath(_ chunk: String) -> Bool {
    guard containsInlineMath(chunk) else { return false }
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

  private struct ParsedTableSlice {
    let table: ParsedMarkdownTable
    let nextIndex: Int
    let isClosed: Bool
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

      // Stop if another table starts immediately below without a blank line.
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
    let table = ParsedMarkdownTable(
      headers: headers,
      alignments: alignments,
      rows: rows,
      rawMarkdown: rawMarkdown
    )
    return ParsedTableSlice(
      table: table,
      nextIndex: rowIndex,
      isClosed: rowIndex < lines.count
    )
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

  static func parseTableDelimiterRow(_ line: String) -> [MarkdownTableAlignment]? {
    guard !hasIndentedCodePrefix(line) else { return nil }
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty,
      !trimmed.hasPrefix(">"),
      trimmed.contains("|"),
      trimmed.contains("-")
    else { return nil }

    let rawCells = splitRawPipeCells(trimmed, respectCodeSpans: false)
    guard !rawCells.isEmpty else { return nil }

    var alignments: [MarkdownTableAlignment] = []
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

  /// Splits a GFM table row into cells while stripping at most one optional
  /// leading and trailing pipe, honoring escaped pipes (`\|`) and pipes inside
  /// matched inline code spans (`` `a | b` ``).
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
          // Per GFM spec, `\|` produces a literal pipe inside both normal text and code spans.
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

  /// Converts HTML `<br>`, `<br/>`, `<br />` tags outside matched backtick code
  /// spans into real newlines so multi-line LLM table cells render cleanly.
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

  private static func markdownSources(_ markdown: String) -> [AnswerSource] {
    var sources: [AnswerSource] = []
    let fullRange = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)

    if let markdownLinkRegex {
      for match in markdownLinkRegex.matches(in: markdown, range: fullRange) {
        guard
          match.numberOfRanges >= 3,
          let titleRange = Range(match.range(at: 1), in: markdown),
          let urlRange = Range(match.range(at: 2), in: markdown),
          let url = sanitizedURL(String(markdown[urlRange]))
        else { continue }
        sources.append(AnswerSource(url: url, title: String(markdown[titleRange])))
      }
    }

    guard markdown.contains("."),
      let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    else { return sources }

    let linkedKeys = Set(sources.map { normalizedURLKey($0.url) })
    for match in detector.matches(in: markdown, range: fullRange) {
      guard let rawURL = match.url,
        let url = sanitizedURL(rawURL.absoluteString) ?? (isValidBrowsableURL(rawURL) ? rawURL : nil)
      else { continue }
      let key = normalizedURLKey(url)
      guard !linkedKeys.contains(key) else { continue }
      sources.append(AnswerSource(url: url, title: nil))
    }
    return sources
  }

  private struct FenceOpening {
    let character: Character
    let length: Int
    let language: String?
  }

  private static func fenceOpening(_ trimmedLine: String) -> FenceOpening? {
    guard let first = trimmedLine.first, first == "`" || first == "~" else { return nil }
    let fenceLength = trimmedLine.prefix(while: { $0 == first }).count
    guard fenceLength >= 3 else { return nil }

    let remainder = String(trimmedLine.dropFirst(fenceLength))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    // Per CommonMark, backtick fence info strings cannot contain backticks.
    if first == "`", remainder.contains("`") { return nil }

    let language = remainder.split(whereSeparator: \.isWhitespace).first.map(String.init)
    return FenceOpening(character: first, length: fenceLength, language: language)
  }

  private static func isFenceClosing(_ trimmedLine: String, for opening: FenceOpening) -> Bool {
    guard trimmedLine.count >= opening.length else { return false }
    return trimmedLine.allSatisfy { $0 == opening.character }
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
}
