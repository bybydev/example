import AppKit
import BYOKchatProviderCore
import Foundation
import MacAppFoundation
import SwiftUI

// MARK: - Transcript Environment Keys

private struct MacTranscriptFontSizeKey: EnvironmentKey {
  static let defaultValue: CGFloat = 15
}

struct MacTranscriptFindContext: Equatable, Sendable {
  let query: String
  let activeMessageID: ChatMessageID?
  let activeOccurrenceInMessage: Int?

  static let empty = MacTranscriptFindContext(
    query: "",
    activeMessageID: nil,
    activeOccurrenceInMessage: nil
  )

  var isActive: Bool {
    !query.isEmpty
  }
}

private struct MacTranscriptFindContextKey: EnvironmentKey {
  static let defaultValue = MacTranscriptFindContext.empty
}

extension EnvironmentValues {
  var macTranscriptFontSize: CGFloat {
    get { self[MacTranscriptFontSizeKey.self] }
    set { self[MacTranscriptFontSizeKey.self] = newValue }
  }

  var macTranscriptFind: MacTranscriptFindContext {
    get { self[MacTranscriptFindContextKey.self] }
    set { self[MacTranscriptFindContextKey.self] = newValue }
  }
}

// MARK: - In-Conversation Find Support

struct MacTranscriptFindMatch: Equatable, Sendable {
  let messageID: ChatMessageID
  let occurrenceInMessage: Int
}

struct MacTranscriptFindIndex: Equatable, Sendable {
  let query: String
  let matches: [MacTranscriptFindMatch]
  let countsByMessageID: [ChatMessageID: Int]

  static let empty = MacTranscriptFindIndex(query: "", matches: [], countsByMessageID: [:])

  var totalMatches: Int { matches.count }
}

enum MacTranscriptFindSupport {
  static func search(query rawQuery: String, in messages: [ChatMessage]) -> MacTranscriptFindIndex {
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return .empty }

    var matches: [MacTranscriptFindMatch] = []
    var counts: [ChatMessageID: Int] = [:]

    for message in messages {
      var messageMatchCount = 0
      for text in [message.content, message.reasoning] where !text.isEmpty {
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
          let found = text.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive],
            range: searchStart..<text.endIndex
          )
        {
          matches.append(
            MacTranscriptFindMatch(
              messageID: message.id,
              occurrenceInMessage: messageMatchCount
            )
          )
          messageMatchCount += 1
          searchStart = found.upperBound
        }
      }
      if messageMatchCount > 0 {
        counts[message.id] = messageMatchCount
      }
    }

    return MacTranscriptFindIndex(
      query: query,
      matches: matches,
      countsByMessageID: counts
    )
  }

  static func containsMatch(in text: String, query: String) -> Bool {
    guard !query.isEmpty, !text.isEmpty else { return false }
    return text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
  }

  static func applyHighlights(
    to attributed: AttributedString,
    query: String,
    highlightColor: Color,
    activeColor: Color,
    activeOccurrence: Int? = nil
  ) -> AttributedString {
    guard !query.isEmpty else { return attributed }
    let plain = String(attributed.characters)
    guard containsMatch(in: plain, query: query) else { return attributed }

    var result = attributed
    var searchStart = plain.startIndex
    var occurrence = 0

    while searchStart < plain.endIndex,
      let found = plain.range(
        of: query,
        options: [.caseInsensitive, .diacriticInsensitive],
        range: searchStart..<plain.endIndex
      )
    {
      let lowerOffset = plain.distance(from: plain.startIndex, to: found.lowerBound)
      let upperOffset = plain.distance(from: plain.startIndex, to: found.upperBound)
      let attrStart = result.characters.index(result.startIndex, offsetBy: lowerOffset)
      let attrEnd = result.characters.index(result.startIndex, offsetBy: upperOffset)
      let isCurrent = activeOccurrence == occurrence
      result[attrStart..<attrEnd].backgroundColor = isCurrent ? activeColor : highlightColor
      occurrence += 1
      searchStart = found.upperBound
    }

    return result
  }

  static func applyNSColorHighlights(
    to attributed: NSMutableAttributedString,
    query: String,
    highlightColor: NSColor,
    activeColor: NSColor,
    activeOccurrence: Int? = nil
  ) {
    guard !query.isEmpty, attributed.length > 0 else { return }
    let nsString = attributed.string as NSString
    var searchLocation = 0
    var occurrence = 0

    while searchLocation < nsString.length {
      let remaining = NSRange(location: searchLocation, length: nsString.length - searchLocation)
      let found = nsString.range(
        of: query,
        options: [.caseInsensitive, .diacriticInsensitive],
        range: remaining
      )
      guard found.location != NSNotFound, found.length > 0 else { break }
      let isCurrent = activeOccurrence == occurrence
      attributed.addAttribute(
        .backgroundColor,
        value: isCurrent ? activeColor : highlightColor,
        range: found
      )
      occurrence += 1
      searchLocation = found.location + found.length
    }
  }
}

// MARK: - Progressive Streaming Inline Markdown

enum MacStreamingTailFormatter {
  private static let unfinishedLinkTailRegex = try? NSRegularExpression(
    pattern: #"\[([^\]\n]+)\]\([^)\n]*$"#
  )

  /// Hides incomplete trailing math (`$...`, `\(...`) and half-streamed
  /// Markdown link destinations (`[label](https://...`) so raw syntax does
  /// not flicker on screen while tokens arrive.
  static func stabilizedSource(_ source: String) -> String {
    var result = stabilizeInlineMath(source)

    if let regex = unfinishedLinkTailRegex, result.contains("](") {
      let fullRange = NSRange(result.startIndex..<result.endIndex, in: result)
      if let match = regex.firstMatch(in: result, range: fullRange),
        match.numberOfRanges >= 2,
        let matchRange = Range(match.range, in: result),
        let labelRange = Range(match.range(at: 1), in: result)
      {
        let label = String(result[labelRange])
        result.replaceSubrange(matchRange, with: label + "…")
      }
    }

    return result
  }

  private static func stabilizeInlineMath(_ source: String) -> String {
    guard !MacAnswerContentParser.isLikelyBalancedInlineMath(source) else { return source }

    var lastUnescapedDollar: String.Index?
    var escaped = false
    for index in source.indices {
      let character = source[index]
      if escaped {
        escaped = false
        continue
      }
      if character == "\\" {
        escaped = true
      } else if character == "$" {
        lastUnescapedDollar = index
      }
    }

    if let start = lastUnescapedDollar {
      return String(source[..<start]) + "…"
    }

    if let range = source.range(of: "\\(", options: .backwards),
      source.range(of: "\\)", range: range.upperBound..<source.endIndex) == nil
    {
      return String(source[..<range.lowerBound]) + "…"
    }

    return source
  }

  /// Renders a lightweight inline-formatted `AttributedString` for the active
  /// streaming tail without invoking MarkdownUI's full layout pass per token.
  static func formattedAttributedString(
    _ source: String,
    textSize: CGFloat,
    foregroundColor: Color,
    mutedColor: Color,
    accentColor: Color,
    codeBackground: Color
  ) -> AttributedString {
    let stabilized = stabilizedSource(source)
    let lines = stabilized.split(separator: "\n", omittingEmptySubsequences: false)
    var output = AttributedString()

    for (index, rawLine) in lines.enumerated() {
      if index > 0 {
        output.append(AttributedString("\n"))
      }
      let line = String(rawLine)
      output.append(
        formattedLine(
          line,
          textSize: textSize,
          foregroundColor: foregroundColor,
          mutedColor: mutedColor,
          accentColor: accentColor,
          codeBackground: codeBackground
        )
      )
    }

    return output
  }

  private static func formattedLine(
    _ line: String,
    textSize: CGFloat,
    foregroundColor: Color,
    mutedColor: Color,
    accentColor: Color,
    codeBackground: Color
  ) -> AttributedString {
    let trimmedLeading = line.drop(while: { $0 == " " || $0 == "\t" })

    // Headings (# .. ######)
    if trimmedLeading.hasPrefix("#") {
      let hashes = trimmedLeading.prefix(while: { $0 == "#" })
      let afterHashes = trimmedLeading.dropFirst(hashes.count)
      if (1...6).contains(hashes.count), afterHashes.first == " " {
        let headingText = String(afterHashes.dropFirst())
        let scale: CGFloat = switch hashes.count {
        case 1: 1.45
        case 2: 1.28
        case 3: 1.14
        case 4: 1.02
        case 5: 0.94
        default: 0.88
        }
        let weight: Font.Weight = hashes.count <= 2 ? .bold : .semibold
        var attr = parseInlineMarkdown(
          headingText,
          baseFont: .system(size: textSize * scale, weight: weight),
          codeFontSize: textSize * scale * 0.9,
          foregroundColor: hashes.count == 5 ? mutedColor : (hashes.count == 6 ? accentColor : foregroundColor),
          accentColor: accentColor,
          codeBackground: codeBackground
        )
        attr.font = .system(size: textSize * scale, weight: weight)
        return attr
      }
    }

    // Blockquote (> ...)
    if trimmedLeading.hasPrefix("> ") || trimmedLeading == ">" {
      let body = trimmedLeading.hasPrefix("> ")
        ? String(trimmedLeading.dropFirst(2))
        : ""
      var prefix = AttributedString("▎ ")
      prefix.foregroundColor = accentColor.opacity(0.7)
      let content = parseInlineMarkdown(
        body,
        baseFont: .system(size: textSize),
        codeFontSize: textSize * 0.9,
        foregroundColor: mutedColor,
        accentColor: accentColor,
        codeBackground: codeBackground
      )
      prefix.append(content)
      return prefix
    }

    // Task list / unordered list prefix
    let indentCount = line.distance(from: line.startIndex, to: trimmedLeading.startIndex)
    let indent = String(repeating: " ", count: indentCount)
    if trimmedLeading.hasPrefix("- [x] ") || trimmedLeading.hasPrefix("- [X] ") {
      var prefix = AttributedString("\(indent)☑ ")
      prefix.foregroundColor = accentColor
      prefix.append(
        parseInlineMarkdown(
          String(trimmedLeading.dropFirst(6)),
          baseFont: .system(size: textSize),
          codeFontSize: textSize * 0.9,
          foregroundColor: foregroundColor,
          accentColor: accentColor,
          codeBackground: codeBackground
        )
      )
      return prefix
    }
    if trimmedLeading.hasPrefix("- [ ] ") {
      var prefix = AttributedString("\(indent)☐ ")
      prefix.foregroundColor = mutedColor
      prefix.append(
        parseInlineMarkdown(
          String(trimmedLeading.dropFirst(6)),
          baseFont: .system(size: textSize),
          codeFontSize: textSize * 0.9,
          foregroundColor: foregroundColor,
          accentColor: accentColor,
          codeBackground: codeBackground
        )
      )
      return prefix
    }
    if trimmedLeading.hasPrefix("- ") || trimmedLeading.hasPrefix("* ") {
      var prefix = AttributedString("\(indent)• ")
      prefix.foregroundColor = mutedColor
      prefix.append(
        parseInlineMarkdown(
          String(trimmedLeading.dropFirst(2)),
          baseFont: .system(size: textSize),
          codeFontSize: textSize * 0.9,
          foregroundColor: foregroundColor,
          accentColor: accentColor,
          codeBackground: codeBackground
        )
      )
      return prefix
    }

    return parseInlineMarkdown(
      line,
      baseFont: .system(size: textSize),
      codeFontSize: textSize * 0.9,
      foregroundColor: foregroundColor,
      accentColor: accentColor,
      codeBackground: codeBackground
    )
  }

  private static func parseInlineMarkdown(
    _ text: String,
    baseFont: Font,
    codeFontSize: CGFloat,
    foregroundColor: Color,
    accentColor: Color,
    codeBackground: Color
  ) -> AttributedString {
    guard !text.isEmpty else { return AttributedString() }

    let options = AttributedString.MarkdownParsingOptions(
      interpretedSyntax: .inlineOnlyPreservingWhitespace
    )
    var attributed = (try? AttributedString(markdown: text, options: options))
      ?? AttributedString(text)

    attributed.foregroundColor = foregroundColor
    for run in attributed.runs {
      let range = run.range
      if run.link != nil {
        attributed[range].foregroundColor = accentColor
      }
      if let intent = run.inlinePresentationIntent {
        if intent.contains(.code) {
          attributed[range].font = .system(size: codeFontSize, design: .monospaced)
          attributed[range].backgroundColor = codeBackground
        } else if intent.contains(.stronglyEmphasized) && intent.contains(.emphasized) {
          attributed[range].font = baseFont.bold().italic()
        } else if intent.contains(.stronglyEmphasized) {
          attributed[range].font = baseFont.weight(.semibold)
        } else if intent.contains(.emphasized) {
          attributed[range].font = baseFont.italic()
        } else {
          attributed[range].font = baseFont
        }
        if intent.contains(.strikethrough) {
          attributed[range].strikethroughStyle = .single
        }
      } else {
        attributed[range].font = baseFont
      }
    }

    return attributed
  }
}

// MARK: - Structured Citation Merging & Inline Annotation

enum MacCitationSupport {
  /// Merges structured provider citations (OpenAI `url_citation`, Anthropic
  /// web-search citations, Gemini grounding chunks) with Markdown-extracted
  /// sources, preserving provider titles/snippets and deduplicating by URL.
  static func mergedSources(
    structuredCitations: [ChatCitation]?,
    extractedSources: [MacAnswerSource],
    limit: Int = 50
  ) -> [MacAnswerSource] {
    guard limit > 0 else { return [] }
    var values: [MacAnswerSource] = []
    var indexByKey: [String: Int] = [:]

    func appendSource(_ source: MacAnswerSource) {
      let key = MacAnswerContentParser.normalizedURLKey(source.url)
      if let existingIndex = indexByKey[key] {
        let existing = values[existingIndex]
        let mergedTitle = existing.title ?? source.title
        let mergedSnippet = existing.snippet ?? source.snippet
        let mergedIsProvider = existing.isProviderCitation || source.isProviderCitation
        if mergedTitle != existing.title
          || mergedSnippet != existing.snippet
          || mergedIsProvider != existing.isProviderCitation
        {
          values[existingIndex] = MacAnswerSource(
            url: existing.url,
            title: mergedTitle,
            snippet: mergedSnippet,
            isProviderCitation: mergedIsProvider
          )
        }
        return
      }
      guard values.count < limit else { return }
      indexByKey[key] = values.count
      values.append(source)
    }

    for citation in structuredCitations ?? [] {
      let rawURL = citation.url.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let url = URL(string: rawURL),
        MacAnswerContentParser.isValidBrowsableURL(url)
      else { continue }
      let cleanTitle = citation.title?.trimmingCharacters(in: .whitespacesAndNewlines)
      let cleanSnippet = citation.snippet?.trimmingCharacters(in: .whitespacesAndNewlines)
      appendSource(
        MacAnswerSource(
          url: url,
          title: (cleanTitle?.isEmpty == false) ? cleanTitle : nil,
          snippet: (cleanSnippet?.isEmpty == false) ? cleanSnippet : nil,
          isProviderCitation: true
        )
      )
    }

    for source in extractedSources {
      appendSource(source)
    }

    return values
  }

  /// Inserts inline clickable citation markers (`[1](url)`) into Markdown at
  /// structured `endIndex` positions when the response does not already link
  /// the cited URL inline.
  static func annotateInlineCitations(
    in markdown: String,
    citations: [ChatCitation]?,
    mergedSources: [MacAnswerSource]
  ) -> String {
    guard let citations, !citations.isEmpty, !markdown.isEmpty else { return markdown }

    var numberByKey: [String: Int] = [:]
    for (idx, source) in mergedSources.enumerated() {
      numberByKey[MacAnswerContentParser.normalizedURLKey(source.url)] = idx + 1
    }

    struct Insertion {
      let offset: Int
      let badge: String
      let number: Int
    }

    let utf16Length = markdown.utf16.count
    var insertionsByOffset: [Int: [Insertion]] = [:]
    var seenOffsetAndNumber = Set<String>()

    for citation in citations {
      guard let endIndex = citation.endIndex,
        endIndex > 0,
        endIndex <= utf16Length,
        let url = URL(string: citation.url.trimmingCharacters(in: .whitespacesAndNewlines)),
        MacAnswerContentParser.isValidBrowsableURL(url)
      else { continue }

      let key = MacAnswerContentParser.normalizedURLKey(url)
      guard let number = numberByKey[key] else { continue }
      let dedup = "\(endIndex):\(number)"
      guard seenOffsetAndNumber.insert(dedup).inserted else { continue }

      // Avoid inserting a duplicate link if the URL is already right at endIndex.
      let windowStart = max(0, endIndex - 16)
      let windowEnd = min(utf16Length, endIndex + citation.url.utf16.count + 16)
      let startUTF16 = markdown.utf16.index(markdown.utf16.startIndex, offsetBy: windowStart)
      let endUTF16 = markdown.utf16.index(markdown.utf16.startIndex, offsetBy: windowEnd)
      let startIdx = startUTF16.samePosition(in: markdown) ?? String.Index(utf16Offset: windowStart, in: markdown)
      let endIdx = endUTF16.samePosition(in: markdown) ?? String.Index(utf16Offset: windowEnd, in: markdown)
      if startIdx <= endIdx, markdown[startIdx..<endIdx].contains(citation.url) {
        continue
      }

      insertionsByOffset[endIndex, default: []].append(
        Insertion(offset: endIndex, badge: " [\(number)](\(url.absoluteString))", number: number)
      )
    }

    guard !insertionsByOffset.isEmpty else { return markdown }

    var result = markdown
    for offset in insertionsByOffset.keys.sorted(by: >) {
      guard offset <= result.utf16.count else { continue }
      let utf16Idx = result.utf16.index(result.utf16.startIndex, offsetBy: offset)
      let index = utf16Idx.samePosition(in: result) ?? String.Index(utf16Offset: offset, in: result)
      let badges = insertionsByOffset[offset]!
        .sorted { $0.number < $1.number }
        .map(\.badge)
        .joined()
      result.insert(contentsOf: badges, at: index)
    }
    return result
  }
}

// MARK: - Cross-Block Selectable Markdown Text View (AppKit NSTextView)

enum MacSelectableMarkdownBuilder {
  static let markdownSourceAttributeKey = NSAttributedString.Key("pro.byok.mac.markdownSource")

  struct Style: Equatable {
    let textSize: CGFloat
    let muted: Bool
    let isDark: Bool
    let themeID: MacAppThemeID
    let textColor: NSColor
    let mutedColor: NSColor
    let accentColor: NSColor
    let codeBackgroundColor: NSColor
    let codeBlockBackgroundColor: NSColor
    let separatorColor: NSColor
    let findQuery: String
    let activeFindOccurrence: Int?
  }

  /// Returns true when a Markdown segment can be rendered natively inside
  /// `MacSelectableMarkdownTextView` (giving smooth cross-paragraph drag
  /// selection and Copy as Markdown) without losing inline images or math.
  static func canRenderNatively(_ markdown: String) -> Bool {
    guard !markdown.isEmpty else { return false }
    if markdown.contains("![") { return false }
    if MacAnswerContentParser.containsInlineMath(markdown) { return false }
    return true
  }

  /// Renders a Markdown string (or full multi-block assistant message including
  /// fenced code blocks and tables) into an `NSAttributedString` with attached
  /// source Markdown ranges so users can copy any selection as Markdown.
  @MainActor
  static func attributedString(
    for source: String,
    includeStructuredBlocks: Bool,
    style: Style
  ) -> NSAttributedString {
    let result = NSMutableAttributedString()

    if includeStructuredBlocks {
      let blocks = MacAnswerContentParser.parse(source)
      for (index, block) in blocks.enumerated() {
        if index > 0 {
          result.append(NSAttributedString(string: "\n\n"))
        }
        switch block {
        case .markdown(let md):
          result.append(renderMarkdownBlock(md, style: style))
        case .code(let language, let content, _):
          let fenceHeader = language.map { "```\($0)\n" } ?? "```\n"
          let rawMarkdown = "\(fenceHeader)\(content)\n```"
          result.append(renderCodeBlock(language: language, content: content, rawMarkdown: rawMarkdown, style: style))
        case .math(let expression, _):
          let rawMarkdown = "$$\n\(expression)\n$$"
          result.append(renderCodeBlock(language: "math", content: expression, rawMarkdown: rawMarkdown, style: style))
        case .table(let table):
          result.append(renderTableBlock(table, style: style))
        case .callout(let kind, let body):
          let prefix = "> [!\(kind.rawValue.uppercased())]\n"
          let rendered = renderMarkdownBlock("**\(kind.title)**\n\n\(body)", style: style)
          let mutable = NSMutableAttributedString(attributedString: rendered)
          let rawLines = body.components(separatedBy: .newlines).map { "> \($0)" }.joined(separator: "\n")
          mutable.addAttribute(
            markdownSourceAttributeKey,
            value: prefix + rawLines,
            range: NSRange(location: 0, length: mutable.length)
          )
          result.append(mutable)
        case .details(let summary, let body, _):
          let rendered = renderMarkdownBlock("**\(summary)**\n\n\(body)", style: style)
          let mutable = NSMutableAttributedString(attributedString: rendered)
          mutable.addAttribute(
            markdownSourceAttributeKey,
            value: "<details>\n<summary>\(summary)</summary>\n\n\(body)\n</details>",
            range: NSRange(location: 0, length: mutable.length)
          )
          result.append(mutable)
        }
      }
    } else {
      result.append(renderMarkdownBlock(source, style: style))
    }

    if !style.findQuery.isEmpty {
      MacTranscriptFindSupport.applyNSColorHighlights(
        to: result,
        query: style.findQuery,
        highlightColor: style.accentColor.withAlphaComponent(style.isDark ? 0.34 : 0.24),
        activeColor: style.accentColor.withAlphaComponent(style.isDark ? 0.62 : 0.48),
        activeOccurrence: style.activeFindOccurrence
      )
    }

    return result
  }

  static func markdownSnippet(
    from attributedString: NSAttributedString,
    selectedRange: NSRange
  ) -> String {
    guard selectedRange.length > 0,
      selectedRange.location != NSNotFound,
      selectedRange.location + selectedRange.length <= attributedString.length
    else {
      return ""
    }

    let selectedPlain = (attributedString.string as NSString).substring(with: selectedRange)
    var collectedBlocks: [String] = []
    var seenRanges = Set<String>()

    attributedString.enumerateAttribute(
      markdownSourceAttributeKey,
      in: selectedRange,
      options: []
    ) { value, effectiveRange, _ in
      guard let raw = value as? String, !raw.isEmpty else { return }
      // Check if the selection covers the full block or only part of a single line.
      var fullBlockRange = NSRange(location: 0, length: 0)
      _ = attributedString.attribute(
        markdownSourceAttributeKey,
        at: effectiveRange.location,
        longestEffectiveRange: &fullBlockRange,
        in: NSRange(location: 0, length: attributedString.length)
      )
      let key = "\(fullBlockRange.location):\(fullBlockRange.length)"
      guard seenRanges.insert(key).inserted else { return }
      let coversWholeBlock = selectedRange.location <= fullBlockRange.location
        && (selectedRange.location + selectedRange.length) >= (fullBlockRange.location + fullBlockRange.length)
      if coversWholeBlock || seenRanges.count > 1 {
        collectedBlocks.append(raw)
      }
    }

    if collectedBlocks.count > 1 {
      return collectedBlocks.joined(separator: "\n\n")
    }
    if collectedBlocks.count == 1, selectedPlain.count >= max(1, collectedBlocks[0].count / 2) {
      return collectedBlocks[0]
    }
    return selectedPlain
  }

  @MainActor
  private static func renderMarkdownBlock(
    _ markdown: String,
    style: Style
  ) -> NSAttributedString {
    let output = NSMutableAttributedString()
    let lines = markdown.components(separatedBy: .newlines)
    var index = 0
    var needsBlockGap = false

    func appendBlock(_ blockAttr: NSAttributedString, spacingBefore: CGFloat = 0) {
      if needsBlockGap {
        let separator = NSMutableAttributedString(string: "\n")
        let sepStyle = NSMutableParagraphStyle()
        sepStyle.lineHeightMultiple = spacingBefore > 0 ? 0.55 : 0.45
        separator.addAttributes(
          [.font: NSFont.systemFont(ofSize: max(6, style.textSize * 0.45)), .paragraphStyle: sepStyle],
          range: NSRange(location: 0, length: 1)
        )
        output.append(separator)
      }
      output.append(blockAttr)
      needsBlockGap = true
    }

    while index < lines.count {
      let line = lines[index]
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty {
        index += 1
        continue
      }

      // Thematic break
      if isThematicBreak(trimmed) {
        let rule = NSMutableAttributedString(
          string: "────────────────────────",
          attributes: [
            .font: NSFont.systemFont(ofSize: style.textSize * 0.7),
            .foregroundColor: style.separatorColor,
            markdownSourceAttributeKey: trimmed,
          ]
        )
        appendBlock(rule, spacingBefore: 4)
        index += 1
        continue
      }

      // ATX Heading
      if let heading = parseHeading(trimmed) {
        let scale: CGFloat = switch heading.level {
        case 1: 1.5
        case 2: 1.3
        case 3: 1.14
        case 4: 1.02
        case 5: 0.94
        default: 0.88
        }
        let weight: NSFont.Weight = heading.level <= 2 ? .bold : .semibold
        let color: NSColor = switch heading.level {
        case 5: style.mutedColor
        case 6: style.accentColor
        default: style.muted ? style.mutedColor : style.textColor
        }
        let para = NSMutableParagraphStyle()
        para.lineSpacing = style.textSize * 0.16
        para.paragraphSpacingBefore = needsBlockGap ? style.textSize * 0.45 : 0
        para.paragraphSpacing = style.textSize * 0.25

        let rendered = renderInlineMarkdown(
          heading.text,
          fontSize: style.textSize * scale,
          fontWeight: weight,
          foregroundColor: color,
          style: style,
          paragraphStyle: para,
          rawSource: trimmed
        )
        appendBlock(rendered)
        index += 1
        continue
      }

      // Blockquote group
      if trimmed.hasPrefix(">") {
        var quoteLines: [String] = []
        var rawLines: [String] = []
        while index < lines.count {
          let candidate = lines[index].trimmingCharacters(in: .whitespaces)
          guard candidate.hasPrefix(">") else { break }
          rawLines.append(lines[index])
          let stripped = candidate.dropFirst()
          quoteLines.append(stripped.hasPrefix(" ") ? String(stripped.dropFirst()) : String(stripped))
          index += 1
        }
        let para = NSMutableParagraphStyle()
        para.firstLineHeadIndent = 12
        para.headIndent = 12
        para.lineSpacing = style.textSize * 0.18
        para.paragraphSpacing = style.textSize * 0.35

        let combined = quoteLines.joined(separator: "\n")
        let rendered = NSMutableAttributedString(
          string: "▎ ",
          attributes: [
            .font: NSFont.systemFont(ofSize: style.textSize, weight: .semibold),
            .foregroundColor: style.accentColor.withAlphaComponent(0.72),
            .paragraphStyle: para,
          ]
        )
        rendered.append(
          renderInlineMarkdown(
            combined,
            fontSize: style.textSize,
            fontWeight: .regular,
            foregroundColor: style.mutedColor,
            style: style,
            paragraphStyle: para,
            rawSource: rawLines.joined(separator: "\n")
          )
        )
        rendered.addAttribute(
          markdownSourceAttributeKey,
          value: rawLines.joined(separator: "\n"),
          range: NSRange(location: 0, length: rendered.length)
        )
        appendBlock(rendered)
        continue
      }

      // List item (unordered, task, or ordered)
      if parseListItem(line) != nil {
        let listGroup = NSMutableAttributedString()
        var rawGroupLines: [String] = []
        var itemIndex = 0
        while index < lines.count, let item = parseListItem(lines[index]) {
          if itemIndex > 0 {
            listGroup.append(NSAttributedString(string: "\n"))
          }
          rawGroupLines.append(lines[index])
          let indent = CGFloat(min(item.indentLevel, 6)) * 16
          let para = NSMutableParagraphStyle()
          para.firstLineHeadIndent = indent + 4
          para.headIndent = indent + 20
          para.lineSpacing = style.textSize * 0.15
          para.paragraphSpacing = style.textSize * 0.22

          let markerColor: NSColor = item.isAccentMarker ? style.accentColor : style.mutedColor
          let prefix = NSAttributedString(
            string: item.marker + " ",
            attributes: [
              .font: NSFont.systemFont(ofSize: style.textSize, weight: .medium),
              .foregroundColor: markerColor,
              .paragraphStyle: para,
            ]
          )
          listGroup.append(prefix)
          listGroup.append(
            renderInlineMarkdown(
              item.body,
              fontSize: style.textSize,
              fontWeight: .regular,
              foregroundColor: style.muted ? style.mutedColor : style.textColor,
              style: style,
              paragraphStyle: para,
              rawSource: lines[index]
            )
          )
          index += 1
          itemIndex += 1
        }
        listGroup.addAttribute(
          markdownSourceAttributeKey,
          value: rawGroupLines.joined(separator: "\n"),
          range: NSRange(location: 0, length: listGroup.length)
        )
        appendBlock(listGroup)
        continue
      }

      // Ordinary paragraph (collect consecutive non-special lines)
      var paraLines: [String] = []
      while index < lines.count {
        let candidate = lines[index]
        let candidateTrimmed = candidate.trimmingCharacters(in: .whitespaces)
        if candidateTrimmed.isEmpty
          || isThematicBreak(candidateTrimmed)
          || parseHeading(candidateTrimmed) != nil
          || candidateTrimmed.hasPrefix(">")
          || parseListItem(candidate) != nil
        {
          break
        }
        paraLines.append(candidate)
        index += 1
      }
      let joined = paraLines.joined(separator: "\n")
      let para = NSMutableParagraphStyle()
      para.lineSpacing = style.textSize * 0.2
      para.paragraphSpacing = style.textSize * 0.35

      let rendered = renderInlineMarkdown(
        joined,
        fontSize: style.textSize,
        fontWeight: .regular,
        foregroundColor: style.muted ? style.mutedColor : style.textColor,
        style: style,
        paragraphStyle: para,
        rawSource: joined
      )
      appendBlock(rendered)
    }

    return output
  }

  private static func renderCodeBlock(
    language: String?,
    content: String,
    rawMarkdown: String,
    style: Style
  ) -> NSAttributedString {
    let codeFont = NSFont(name: "Menlo-Regular", size: max(11, style.textSize - 2))
      ?? NSFont.monospacedSystemFont(ofSize: max(11, style.textSize - 2), weight: .regular)
    let para = NSMutableParagraphStyle()
    para.firstLineHeadIndent = 10
    para.headIndent = 10
    para.lineSpacing = 2.5
    para.paragraphSpacing = 6

    let output = NSMutableAttributedString()
    if let language, !language.isEmpty {
      let header = NSAttributedString(
        string: language.uppercased() + "\n",
        attributes: [
          .font: NSFont.monospacedSystemFont(ofSize: max(9.5, style.textSize - 4), weight: .semibold),
          .foregroundColor: style.mutedColor,
          .paragraphStyle: para,
        ]
      )
      output.append(header)
    }
    output.append(
      NSAttributedString(
        string: content,
        attributes: [
          .font: codeFont,
          .foregroundColor: style.textColor,
          .backgroundColor: style.codeBlockBackgroundColor,
          .paragraphStyle: para,
        ]
      )
    )
    output.addAttribute(
      markdownSourceAttributeKey,
      value: rawMarkdown,
      range: NSRange(location: 0, length: output.length)
    )
    return output
  }

  private static func renderTableBlock(
    _ table: MacParsedMarkdownTable,
    style: Style
  ) -> NSAttributedString {
    let monoFont = NSFont.monospacedSystemFont(ofSize: max(11, style.textSize - 2), weight: .regular)
    let headerFont = NSFont.monospacedSystemFont(ofSize: max(11, style.textSize - 2), weight: .semibold)
    let para = NSMutableParagraphStyle()
    para.lineSpacing = 3
    para.paragraphSpacing = 4

    let output = NSMutableAttributedString()
    let headerLine = table.headers.map(MacAnswerContentParser.plainTableCellText).joined(separator: "  |  ")
    output.append(
      NSAttributedString(
        string: headerLine,
        attributes: [
          .font: headerFont,
          .foregroundColor: style.textColor,
          .paragraphStyle: para,
        ]
      )
    )
    for row in table.rows {
      let line = "\n" + row.map(MacAnswerContentParser.plainTableCellText).joined(separator: "  |  ")
      output.append(
        NSAttributedString(
          string: line,
          attributes: [
            .font: monoFont,
            .foregroundColor: style.textColor,
            .paragraphStyle: para,
          ]
        )
      )
    }
    output.addAttribute(
      markdownSourceAttributeKey,
      value: table.markdownText,
      range: NSRange(location: 0, length: output.length)
    )
    return output
  }

  @MainActor
  private static func renderInlineMarkdown(
    _ text: String,
    fontSize: CGFloat,
    fontWeight: NSFont.Weight,
    foregroundColor: NSColor,
    style: Style,
    paragraphStyle: NSParagraphStyle,
    rawSource: String
  ) -> NSMutableAttributedString {
    let baseFont = NSFont.systemFont(ofSize: fontSize, weight: fontWeight)
    let boldFont = NSFont.systemFont(ofSize: fontSize, weight: fontWeight == .bold ? .bold : .semibold)
    let italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
    let boldItalicFont = NSFontManager.shared.convert(boldFont, toHaveTrait: .italicFontMask)
    let codeFont = NSFont(name: "Menlo-Regular", size: fontSize * 0.9)
      ?? NSFont.monospacedSystemFont(ofSize: fontSize * 0.9, weight: .regular)

    let options = AttributedString.MarkdownParsingOptions(
      interpretedSyntax: .inlineOnlyPreservingWhitespace
    )
    let parsed = (try? AttributedString(markdown: text, options: options))
      ?? AttributedString(text)

    let output = NSMutableAttributedString()
    for run in parsed.runs {
      let segment = String(parsed[run.range].characters)
      var attrs: [NSAttributedString.Key: Any] = [
        .font: baseFont,
        .foregroundColor: foregroundColor,
        .paragraphStyle: paragraphStyle,
        markdownSourceAttributeKey: rawSource,
      ]

      if let intent = run.inlinePresentationIntent {
        if intent.contains(.code) {
          attrs[.font] = codeFont
          attrs[.backgroundColor] = style.codeBackgroundColor
        } else if intent.contains(.stronglyEmphasized) && intent.contains(.emphasized) {
          attrs[.font] = boldItalicFont
        } else if intent.contains(.stronglyEmphasized) {
          attrs[.font] = boldFont
        } else if intent.contains(.emphasized) {
          attrs[.font] = italicFont
        }
        if intent.contains(.strikethrough) {
          attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
      }

      if let link = run.link {
        attrs[.link] = link
        attrs[.foregroundColor] = style.accentColor
      }

      output.append(NSAttributedString(string: segment, attributes: attrs))
    }

    return output
  }

  private struct ParsedHeading {
    let level: Int
    let text: String
  }

  private static func parseHeading(_ trimmed: String) -> ParsedHeading? {
    guard trimmed.hasPrefix("#") else { return nil }
    let hashes = trimmed.prefix(while: { $0 == "#" })
    guard (1...6).contains(hashes.count) else { return nil }
    let rest = trimmed.dropFirst(hashes.count)
    guard rest.first == " " else { return nil }
    return ParsedHeading(level: hashes.count, text: String(rest.dropFirst()))
  }

  private struct ParsedListItem {
    let indentLevel: Int
    let marker: String
    let body: String
    let isAccentMarker: Bool
  }

  private static func parseListItem(_ line: String) -> ParsedListItem? {
    let leadingSpaces = line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { total, ch in
      total + (ch == "\t" ? 2 : 1)
    }
    let indentLevel = leadingSpaces / 2
    let trimmed = line.trimmingCharacters(in: .whitespaces)

    if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
      return ParsedListItem(
        indentLevel: indentLevel,
        marker: "☑",
        body: String(trimmed.dropFirst(6)),
        isAccentMarker: true
      )
    }
    if trimmed.hasPrefix("- [ ] ") {
      return ParsedListItem(
        indentLevel: indentLevel,
        marker: "☐",
        body: String(trimmed.dropFirst(6)),
        isAccentMarker: false
      )
    }
    if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
      return ParsedListItem(
        indentLevel: indentLevel,
        marker: "•",
        body: String(trimmed.dropFirst(2)),
        isAccentMarker: false
      )
    }
    if let matchEnd = orderedMarkerEndIndex(in: trimmed) {
      let marker = String(trimmed[..<matchEnd]).trimmingCharacters(in: .whitespaces)
      let body = String(trimmed[matchEnd...])
      return ParsedListItem(
        indentLevel: indentLevel,
        marker: marker,
        body: body,
        isAccentMarker: false
      )
    }
    return nil
  }

  private static func orderedMarkerEndIndex(in trimmed: String) -> String.Index? {
    var cursor = trimmed.startIndex
    var digits = 0
    while cursor < trimmed.endIndex, trimmed[cursor].isASCII, trimmed[cursor].isNumber {
      digits += 1
      cursor = trimmed.index(after: cursor)
    }
    guard digits > 0, digits <= 4, cursor < trimmed.endIndex else { return nil }
    let punct = trimmed[cursor]
    guard punct == "." || punct == ")" else { return nil }
    let afterPunct = trimmed.index(after: cursor)
    guard afterPunct < trimmed.endIndex, trimmed[afterPunct] == " " else { return nil }
    return trimmed.index(after: afterPunct)
  }

  private static func isThematicBreak(_ trimmed: String) -> Bool {
    guard !trimmed.contains("|") else { return false }
    let stripped = trimmed.filter { !$0.isWhitespace }
    guard stripped.count >= 3, let first = stripped.first, first == "-" || first == "*" || first == "_" else {
      return false
    }
    return stripped.allSatisfy { $0 == first }
  }
}

@MainActor
struct MacSelectableMarkdownTextView: NSViewRepresentable {
  let source: String
  var includeStructuredBlocks: Bool = false
  var textSize: CGFloat = 15
  var muted: Bool = false
  var findQuery: String = ""
  var activeFindOccurrence: Int? = nil

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.macAppTheme) private var theme

  private var renderKey: RenderKey {
    RenderKey(
      source: source,
      includeStructuredBlocks: includeStructuredBlocks,
      textSize: Int(textSize.rounded()),
      muted: muted,
      isDark: colorScheme == .dark,
      themeID: MacThemeFoundation.store.effectiveThemeID(hasPro: MacPurchaseStore.manager.hasPro),
      findQuery: findQuery,
      activeFindOccurrence: activeFindOccurrence
    )
  }

  private struct RenderKey: Hashable {
    let source: String
    let includeStructuredBlocks: Bool
    let textSize: Int
    let muted: Bool
    let isDark: Bool
    let themeID: MacAppThemeID
    let findQuery: String
    let activeFindOccurrence: Int?
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> MacPassthroughSelectableTextContainer {
    let container = MacPassthroughSelectableTextContainer()
    container.textView.delegate = context.coordinator
    updateContainer(container)
    return container
  }

  func updateNSView(_ nsView: MacPassthroughSelectableTextContainer, context: Context) {
    nsView.textView.delegate = context.coordinator
    updateContainer(nsView)
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize,
    nsView: MacPassthroughSelectableTextContainer,
    context: Context
  ) -> CGSize? {
    let width = max(proposal.width ?? 640, 1)
    let height = nsView.measureHeight(forWidth: width)
    return CGSize(width: width, height: max(height, 1))
  }

  private func updateContainer(_ container: MacPassthroughSelectableTextContainer) {
    let key = renderKey
    let wrappedKey = AnyHashable(key)
    guard container.lastRenderKey != wrappedKey else { return }
    container.lastRenderKey = wrappedKey

    let style = MacSelectableMarkdownBuilder.Style(
      textSize: textSize,
      muted: muted,
      isDark: colorScheme == .dark,
      themeID: key.themeID,
      textColor: NSColor(theme.textPrimary),
      mutedColor: NSColor(theme.textMuted),
      accentColor: NSColor(theme.accent),
      codeBackgroundColor: NSColor(theme.codeSurface).withAlphaComponent(0.85),
      codeBlockBackgroundColor: NSColor(theme.codeSurface),
      separatorColor: NSColor(theme.separator),
      findQuery: findQuery,
      activeFindOccurrence: activeFindOccurrence
    )

    let attributed = MacSelectableMarkdownBuilder.attributedString(
      for: source,
      includeStructuredBlocks: includeStructuredBlocks,
      style: style
    )
    container.setAttributedString(attributed, linkColor: style.accentColor)
  }

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
      let url: URL?
      if let direct = link as? URL {
        url = direct
      } else if let raw = link as? String {
        url = URL(string: raw)
      } else {
        url = nil
      }
      guard let url, MacAnswerContentParser.isValidBrowsableURL(url) else { return false }
      NSWorkspace.shared.open(url)
      return true
    }
  }
}

@MainActor
final class MacPassthroughSelectableTextContainer: NSView {
  let textView: MacSelectableTextView
  fileprivate var lastRenderKey: AnyHashable?
  private var attributedStorage = NSAttributedString()

  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    let textStorage = NSTextStorage()
    let layoutManager = NSLayoutManager()
    textStorage.addLayoutManager(layoutManager)
    let textContainer = NSTextContainer(size: NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude))
    textContainer.widthTracksTextView = false
    textContainer.heightTracksTextView = false
    textContainer.lineFragmentPadding = 0
    layoutManager.addTextContainer(textContainer)

    textView = MacSelectableTextView(frame: .zero, textContainer: textContainer)
    super.init(frame: frameRect)

    textView.isEditable = false
    textView.isSelectable = true
    textView.drawsBackground = false
    textView.backgroundColor = .clear
    textView.isVerticallyResizable = false
    textView.isHorizontallyResizable = false
    textView.textContainerInset = .zero
    textView.isAutomaticLinkDetectionEnabled = false
    textView.isAutomaticDataDetectionEnabled = false
    textView.translatesAutoresizingMaskIntoConstraints = true
    addSubview(textView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func setAttributedString(_ value: NSAttributedString, linkColor: NSColor) {
    attributedStorage = value
    textView.linkTextAttributes = [
      .foregroundColor: linkColor,
      .cursor: NSCursor.pointingHand,
    ]
    textView.textStorage?.setAttributedString(value)
    needsLayout = true
  }

  func measureHeight(forWidth width: CGFloat) -> CGFloat {
    guard attributedStorage.length > 0, width > 1 else { return 1 }
    // Measure on a detached layout stack so SwiftUI sizeThatFits never mutates
    // the live NSTextView geometry or reenters AttributeGraph.
    let storage = NSTextStorage(attributedString: attributedStorage)
    let manager = NSLayoutManager()
    storage.addLayoutManager(manager)
    let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    manager.addTextContainer(container)
    manager.ensureLayout(for: container)
    return ceil(manager.usedRect(for: container).height)
  }

  override func layout() {
    super.layout()
    let width = max(bounds.width, 1)
    textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
    textView.frame = bounds
  }
}

@MainActor
final class MacSelectableTextView: NSTextView {
  override func scrollWheel(with event: NSEvent) {
    // Forward all wheel/trackpad scrolling so the enclosing SwiftUI List scrolls smoothly.
    nextResponder?.scrollWheel(with: event)
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    let baseMenu = super.menu(for: event) ?? NSMenu()
    let selection = selectedRange()
    if selection.length > 0 {
      let item = NSMenuItem(
        title: "Copy as Markdown",
        action: #selector(copySelectionAsMarkdown(_:)),
        keyEquivalent: ""
      )
      item.target = self
      let insertIndex = baseMenu.items.firstIndex(where: { $0.action == #selector(NSText.copy(_:)) })
        .map { $0 + 1 } ?? 0
      baseMenu.insertItem(item, at: insertIndex)
    }
    return baseMenu
  }

  @objc private func copySelectionAsMarkdown(_ sender: Any?) {
    guard let storage = textStorage else { return }
    let markdown = MacSelectableMarkdownBuilder.markdownSnippet(
      from: storage,
      selectedRange: selectedRange()
    )
    guard !markdown.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(markdown, forType: .string)
  }
}
