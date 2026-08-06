import Foundation
import SwiftUI
import UIKit

struct MarkdownMessageContent: View {
  let text: String

  private var blocks: [MarkdownBlock] {
    MarkdownBlockParser.parse(text)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        blockView(block)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .textSelection(.enabled)
  }

  @ViewBuilder
  private func blockView(_ block: MarkdownBlock) -> some View {
    switch block {
    case .paragraph(let value):
      markdownText(value)
        .font(.system(size: 17))
        .lineSpacing(5)

    case .heading(let level, let value):
      markdownText(value)
        .font(headingFont(level))
        .padding(.top, level <= 2 ? 4 : 1)

    case .unorderedList(let items):
      VStack(alignment: .leading, spacing: 8) {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
          listRow(item: item, marker: "•")
        }
      }

    case .orderedList(let start, let items):
      VStack(alignment: .leading, spacing: 8) {
        ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
          listRow(item: item, marker: "\(start + offset).")
        }
      }

    case .quote(let value):
      HStack(alignment: .top, spacing: 12) {
        RoundedRectangle(cornerRadius: 1.5)
          .fill(Color.secondary.opacity(0.45))
          .frame(width: 3)

        markdownText(value)
          .font(.system(size: 16))
          .italic()
          .foregroundStyle(.secondary)
          .lineSpacing(4)
      }
      .fixedSize(horizontal: false, vertical: true)

    case .divider:
      Divider()
        .padding(.vertical, 3)

    case .code(let language, let value):
      CodeBlockView(language: language, code: value)

    case .table(let headers, let rows):
      MarkdownTableView(headers: headers, rows: rows)
    }
  }

  private func markdownText(_ value: String) -> Text {
    Text(inlineMarkdown(value))
      .foregroundStyle(.primary)
      .tint(.accentColor)
  }

  private func listRow(item: MarkdownListItem, marker: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 9) {
      if let isChecked = item.isChecked {
        Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 15, weight: .medium))
          .foregroundStyle(isChecked ? Color.accentColor : Color.secondary)
          .frame(width: 22, alignment: .trailing)
          .accessibilityLabel(isChecked ? "Completed" : "Not completed")
      } else {
        Text(marker)
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(width: 22, alignment: .trailing)
      }

      markdownText(item.text)
        .font(.system(size: 17))
        .lineSpacing(4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func headingFont(_ level: Int) -> Font {
    switch level {
    case 1: .system(size: 26, weight: .bold)
    case 2: .system(size: 22, weight: .bold)
    case 3: .system(size: 19, weight: .semibold)
    default: .system(size: 17, weight: .semibold)
    }
  }
}

private struct MarkdownTableView: View {
  let headers: [String]
  let rows: [[String]]

  private var columnCount: Int {
    max(headers.count, rows.map(\.count).max() ?? 0)
  }

  var body: some View {
    ScrollView(.horizontal) {
      VStack(alignment: .leading, spacing: 0) {
        tableRow(headers, isHeader: true)
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
          tableRow(row, isHeader: false)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
      )
    }
    .scrollIndicators(.visible)
  }

  private func tableRow(_ cells: [String], isHeader: Bool) -> some View {
    HStack(alignment: .top, spacing: 0) {
      ForEach(0..<columnCount, id: \.self) { index in
        Text(inlineMarkdown(index < cells.count ? cells[index] : ""))
          .font(.system(size: 14, weight: isHeader ? .semibold : .regular))
          .lineSpacing(3)
          .frame(width: 156, alignment: .leading)
          .frame(minHeight: 42, alignment: .leading)
          .padding(.horizontal, 10)
          .padding(.vertical, 9)
          .background(
            isHeader
              ? Color(uiColor: .secondarySystemBackground)
              : Color(uiColor: .systemBackground)
          )
          .overlay(
            Rectangle()
              .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
          )
      }
    }
  }
}

private struct MarkdownListItem {
  let text: String
  let isChecked: Bool?
}

private enum MarkdownBlock {
  case paragraph(String)
  case heading(level: Int, text: String)
  case unorderedList([MarkdownListItem])
  case orderedList(start: Int, items: [MarkdownListItem])
  case quote(String)
  case divider
  case code(language: String?, value: String)
  case table(headers: [String], rows: [[String]])
}

private enum MarkdownBlockParser {
  static func parse(_ text: String) -> [MarkdownBlock] {
    let lines = text
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .components(separatedBy: "\n")

    var blocks: [MarkdownBlock] = []
    var paragraphLines: [String] = []
    var index = 0

    func flushParagraph() {
      let value = paragraphLines.joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !value.isEmpty {
        blocks.append(.paragraph(value))
      }
      paragraphLines.removeAll(keepingCapacity: true)
    }

    while index < lines.count {
      let line = lines[index]
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      if trimmed.isEmpty {
        flushParagraph()
        index += 1
        continue
      }

      if trimmed.hasPrefix("```") {
        flushParagraph()
        let languageValue = String(trimmed.dropFirst(3))
          .trimmingCharacters(in: .whitespacesAndNewlines)
        var codeLines: [String] = []
        index += 1
        while index < lines.count,
          !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```")
        {
          codeLines.append(lines[index])
          index += 1
        }
        if index < lines.count { index += 1 }
        blocks.append(
          .code(
            language: languageValue.isEmpty ? nil : languageValue,
            value: codeLines.joined(separator: "\n")
          )
        )
        continue
      }

      if let heading = heading(from: trimmed) {
        flushParagraph()
        blocks.append(.heading(level: heading.level, text: heading.text))
        index += 1
        continue
      }

      if isDivider(trimmed) {
        flushParagraph()
        blocks.append(.divider)
        index += 1
        continue
      }

      if isTableStart(lines: lines, index: index) {
        flushParagraph()
        let headers = tableCells(line)
        index += 2
        var rows: [[String]] = []
        while index < lines.count {
          let candidate = lines[index].trimmingCharacters(in: .whitespaces)
          guard !candidate.isEmpty, candidate.contains("|") else { break }
          rows.append(tableCells(lines[index]))
          index += 1
        }
        blocks.append(.table(headers: headers, rows: rows))
        continue
      }

      if trimmed.hasPrefix(">") {
        flushParagraph()
        var quoteLines: [String] = []
        while index < lines.count {
          let candidate = lines[index].trimmingCharacters(in: .whitespaces)
          guard candidate.hasPrefix(">") else { break }
          quoteLines.append(
            String(candidate.dropFirst())
              .trimmingCharacters(in: .whitespaces)
          )
          index += 1
        }
        blocks.append(.quote(quoteLines.joined(separator: "\n")))
        continue
      }

      if let firstItem = unorderedItem(from: trimmed) {
        flushParagraph()
        var items = [firstItem]
        index += 1
        while index < lines.count,
          let item = unorderedItem(
            from: lines[index].trimmingCharacters(in: .whitespaces)
          )
        {
          items.append(item)
          index += 1
        }
        blocks.append(.unorderedList(items))
        continue
      }

      if let firstItem = orderedItem(from: trimmed) {
        flushParagraph()
        var items = [firstItem.item]
        let start = firstItem.number
        index += 1
        while index < lines.count,
          let item = orderedItem(
            from: lines[index].trimmingCharacters(in: .whitespaces)
          )
        {
          items.append(item.item)
          index += 1
        }
        blocks.append(.orderedList(start: start, items: items))
        continue
      }

      paragraphLines.append(line)
      index += 1
    }

    flushParagraph()
    return blocks
  }

  private static func heading(from value: String) -> (level: Int, text: String)? {
    let level = value.prefix { $0 == "#" }.count
    guard (1...6).contains(level), value.dropFirst(level).first == " " else { return nil }
    let text = String(value.dropFirst(level + 1))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    return (level, text)
  }

  private static func unorderedItem(from value: String) -> MarkdownListItem? {
    guard value.count >= 2 else { return nil }
    let prefixes = ["- ", "* ", "+ "]
    guard let prefix = prefixes.first(where: value.hasPrefix) else { return nil }
    return listItem(from: String(value.dropFirst(prefix.count)))
  }

  private static func orderedItem(
    from value: String
  ) -> (number: Int, item: MarkdownListItem)? {
    guard let dot = value.firstIndex(of: ".") else { return nil }
    let numberText = value[..<dot]
    guard !numberText.isEmpty,
      numberText.allSatisfy(\.isNumber),
      let number = Int(numberText)
    else { return nil }

    let afterDot = value.index(after: dot)
    guard afterDot < value.endIndex, value[afterDot] == " " else { return nil }
    let itemStart = value.index(after: afterDot)
    return (number, listItem(from: String(value[itemStart...])))
  }

  private static func listItem(from value: String) -> MarkdownListItem {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    let lowercased = trimmed.lowercased()
    if lowercased.hasPrefix("[x] ") {
      return .init(text: String(trimmed.dropFirst(4)), isChecked: true)
    }
    if lowercased.hasPrefix("[ ] ") {
      return .init(text: String(trimmed.dropFirst(4)), isChecked: false)
    }
    return .init(text: trimmed, isChecked: nil)
  }

  private static func isDivider(_ value: String) -> Bool {
    let compact = value.filter { !$0.isWhitespace }
    guard compact.count >= 3, let first = compact.first,
      first == "-" || first == "*" || first == "_"
    else { return false }
    return compact.allSatisfy { $0 == first }
  }

  private static func isTableStart(lines: [String], index: Int) -> Bool {
    guard index + 1 < lines.count, lines[index].contains("|") else { return false }
    let delimiterCells = tableCells(lines[index + 1])
    guard !delimiterCells.isEmpty else { return false }
    return delimiterCells.allSatisfy { cell in
      let normalized = cell
        .trimmingCharacters(in: .whitespaces)
        .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
      return normalized.count >= 3 && normalized.allSatisfy { $0 == "-" }
    }
  }

  private static func tableCells(_ line: String) -> [String] {
    var value = line.trimmingCharacters(in: .whitespaces)
    if value.hasPrefix("|") { value.removeFirst() }
    if value.hasSuffix("|") { value.removeLast() }
    return value.split(separator: "|", omittingEmptySubsequences: false).map {
      String($0).trimmingCharacters(in: .whitespaces)
    }
  }
}

private func inlineMarkdown(_ value: String) -> AttributedString {
  let options = AttributedString.MarkdownParsingOptions(
    interpretedSyntax: .inlineOnlyPreservingWhitespace,
    failurePolicy: .returnPartiallyParsedIfPossible
  )
  return (try? AttributedString(markdown: value, options: options)) ?? AttributedString(value)
}

struct CodeBlockView: View {
  let language: String?
  let code: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(language ?? "Code")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Button("Copy Code", systemImage: "doc.on.doc") {
          UIPasteboard.general.string = code
        }
        .labelStyle(.iconOnly)
        .font(.system(size: 15))
        .frame(width: 36, height: 36)
        .accessibilityLabel("Copy code block")
      }

      ScrollView(.horizontal) {
        Text(code)
          .font(.system(size: 15, design: .monospaced))
          .lineSpacing(4)
          .textSelection(.enabled)
          .fixedSize(horizontal: true, vertical: false)
      }
    }
    .padding(12)
    .background(
      Color(uiColor: .secondarySystemBackground),
      in: RoundedRectangle(cornerRadius: 16, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
    )
  }
}
