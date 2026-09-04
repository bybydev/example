import Foundation

enum MacTableColumnAlignment: Equatable, Sendable {
  case leading
  case center
  case trailing
}

enum MacMarkdownTableAlignment {
  /// Mirrors the iOS GFM delimiter-row recovery used when fixed-width table
  /// cells leave MarkdownUI's grid alignment with no horizontal slack.
  static func columnAlignments(in markdown: String) -> [MacTableColumnAlignment]? {
    var fenceCharacter: Character?
    var fenceLength = 0

    for line in markdown.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      if let first = trimmed.first, first == "`" || first == "~" {
        let runLength = trimmed.prefix { $0 == first }.count
        if runLength >= 3 {
          if fenceCharacter == nil {
            fenceCharacter = first
            fenceLength = runLength
            continue
          }
          if fenceCharacter == first,
            runLength >= fenceLength,
            trimmed.dropFirst(runLength).trimmingCharacters(in: .whitespaces).isEmpty
          {
            fenceCharacter = nil
            fenceLength = 0
            continue
          }
        }
      }

      guard fenceCharacter == nil, isDelimiterRow(trimmed) else { continue }

      let cells = trimmed
        .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
        .components(separatedBy: "|")
      let result = cells.map { cell -> MacTableColumnAlignment in
        let value = cell.trimmingCharacters(in: .whitespaces)
        switch (value.hasPrefix(":"), value.hasSuffix(":")) {
        case (true, true): return .center
        case (false, true): return .trailing
        default: return .leading
        }
      }
      return result.isEmpty ? nil : result
    }

    return nil
  }

  private static func isDelimiterRow(_ line: String) -> Bool {
    guard line.contains("|"), line.contains("-") else { return false }
    let cells = line
      .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
      .components(separatedBy: "|")
    return !cells.isEmpty && cells.allSatisfy { cell in
      let value = cell.trimmingCharacters(in: .whitespaces)
      let body = value.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
      return !body.isEmpty && body.allSatisfy { $0 == "-" }
        && value.contains("-")
    }
  }
}
