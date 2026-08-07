import Foundation

enum AnswerContentBlock: Equatable, Sendable {
  case markdown(String)
  case code(language: String?, content: String)
  case math(String)
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
  static func parse(_ text: String) -> [AnswerContentBlock] {
    let lines = text.components(separatedBy: .newlines)
    var blocks: [AnswerContentBlock] = []
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
        while index < lines.count {
          let candidate = lines[index]
          if candidate.trimmingCharacters(in: .whitespaces).hasPrefix(fence.marker) {
            break
          }
          codeLines.append(candidate)
          index += 1
        }
        if index < lines.count { index += 1 }
        blocks.append(
          .code(
            language: fence.language,
            content: trimTrailingNewlines(codeLines.joined(separator: "\n"))
          )
        )
        continue
      }

      if trimmed == "$$" || trimmed == "\\[" {
        flushMarkdown()
        let terminator = trimmed == "$$" ? "$$" : "\\]"
        index += 1
        var mathLines: [String] = []
        while index < lines.count {
          let candidate = lines[index]
          if candidate.trimmingCharacters(in: .whitespaces) == terminator {
            break
          }
          mathLines.append(candidate)
          index += 1
        }
        if index < lines.count { index += 1 }
        let math = trimBlankLines(mathLines.joined(separator: "\n"))
        if !math.isEmpty { blocks.append(.math(math)) }
        continue
      }

      if trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$"), trimmed.count > 4 {
        flushMarkdown()
        let start = trimmed.index(trimmed.startIndex, offsetBy: 2)
        let end = trimmed.index(trimmed.endIndex, offsetBy: -2)
        let math = String(trimmed[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !math.isEmpty { blocks.append(.math(math)) }
        index += 1
        continue
      }

      if trimmed.hasPrefix("\\["), trimmed.hasSuffix("\\]"), trimmed.count > 4 {
        flushMarkdown()
        let start = trimmed.index(trimmed.startIndex, offsetBy: 2)
        let end = trimmed.index(trimmed.endIndex, offsetBy: -2)
        let math = String(trimmed[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !math.isEmpty { blocks.append(.math(math)) }
        index += 1
        continue
      }

      markdownLines.append(line)
      index += 1
    }

    flushMarkdown()
    return blocks
  }

  static func sources(in blocks: [AnswerContentBlock], limit: Int = 8) -> [AnswerSource] {
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

  private static func markdownSources(_ markdown: String) -> [AnswerSource] {
    var sources: [AnswerSource] = []
    let fullRange = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
    let markdownLinkPattern = #"(?<!!)\[([^\]]+)\]\((https?://[^\s)]+)\)"#

    if let expression = try? NSRegularExpression(pattern: markdownLinkPattern) {
      for match in expression.matches(in: markdown, range: fullRange) {
        guard
          match.numberOfRanges >= 3,
          let titleRange = Range(match.range(at: 1), in: markdown),
          let urlRange = Range(match.range(at: 2), in: markdown),
          let url = sanitizedURL(String(markdown[urlRange]))
        else { continue }
        sources.append(AnswerSource(url: url, title: String(markdown[titleRange])))
      }
    }

    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    else { return sources }

    let linkedKeys = Set(sources.map { normalizedURLKey($0.url) })
    for match in detector.matches(in: markdown, range: fullRange) {
      guard let url = match.url, isHTTPURL(url) else { continue }
      let key = normalizedURLKey(url)
      guard !linkedKeys.contains(key) else { continue }
      sources.append(AnswerSource(url: url, title: nil))
    }
    return sources
  }

  private static func fenceOpening(_ trimmedLine: String) -> (marker: String, language: String?)? {
    let marker: String
    if trimmedLine.hasPrefix("```") {
      marker = "```"
    } else if trimmedLine.hasPrefix("~~~") {
      marker = "~~~"
    } else {
      return nil
    }

    let rawLanguage = String(trimmedLine.dropFirst(marker.count))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let language = rawLanguage.split(whereSeparator: \.isWhitespace).first.map(String.init)
    return (marker, language)
  }

  private static func sanitizedURL(_ value: String) -> URL? {
    let punctuation = CharacterSet(charactersIn: ".,;:!?)]}")
    let trimmed = value.trimmingCharacters(in: punctuation)
    guard let url = URL(string: trimmed), isHTTPURL(url) else { return nil }
    return url
  }

  private static func isHTTPURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return scheme == "http" || scheme == "https"
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
