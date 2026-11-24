import Foundation

enum MacTableColumnAlignment: Equatable, Hashable, Sendable {
  case leading
  case center
  case trailing
}

enum MacMarkdownTableAlignment {
  /// Recovers GFM delimiter-row column alignments for tables that remain inside
  /// `.markdown` segments (for example nested inside blockquotes or list items).
  static func columnAlignments(in markdown: String) -> [MacTableColumnAlignment]? {
    guard markdown.contains("|"), markdown.contains("-") else { return nil }
    var fenceCharacter: Character?
    var fenceLength = 0

    for line in markdown.components(separatedBy: .newlines) {
      var trimmed = line.trimmingCharacters(in: .whitespaces)
      while trimmed.hasPrefix(">") {
        trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
      }

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

      guard fenceCharacter == nil,
        let alignments = MacAnswerContentParser.parseTableDelimiterRow(trimmed)
      else { continue }
      return alignments
    }

    return nil
  }
}
