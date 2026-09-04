import Foundation

enum MacAnswerContentBlock: Equatable, Sendable {
  case markdown(String)
  case code(language: String?, content: String, isComplete: Bool)
  case math(String, isComplete: Bool)
}

enum MacAnswerContentParser {
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
          if candidate.trimmingCharacters(in: .whitespaces).hasPrefix(fence.marker) {
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
