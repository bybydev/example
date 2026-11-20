import Foundation

enum AnswerContentBlock: Equatable, Sendable {
  case markdown(String)
  case code(language: String?, content: String)
  case math(String)
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
      guard case .markdown(let markdown) = block else { continue }
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
    switch language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "mermaid", "mmd": return true
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
