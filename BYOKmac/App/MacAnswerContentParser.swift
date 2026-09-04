import Foundation

enum MacAnswerContentBlock: Equatable, Sendable {
  case markdown(String)
  case code(language: String?, content: String, isComplete: Bool)
  case math(String, isComplete: Bool)
}

enum MacAnswerContentParser {
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

      markdownLines.append(line)
      index += 1
    }

    flushMarkdown()
    return blocks
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
    let pattern = #"(?<!\\)\$(?!\s)(?:\\.|[^$\n])+(?<!\s)(?<!\\)\$|\\\((?:\\.|[^\\\n])+\\\)"#
    return text.range(of: pattern, options: .regularExpression) != nil
  }

  static func isMermaidLanguage(_ language: String?) -> Bool {
    guard let language else { return false }
    switch language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "mermaid", "mmd": return true
    default: return false
    }
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

  private static func fenceOpening(_ trimmedLine: String) -> FenceOpening? {
    guard let first = trimmedLine.first, first == "`" || first == "~" else { return nil }
    let markerLength = trimmedLine.prefix { $0 == first }.count
    guard markerLength >= 3 else { return nil }

    let rawLanguage = String(trimmedLine.dropFirst(markerLength))
      .trimmingCharacters(in: .whitespacesAndNewlines)
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
}
