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
    codeBackground: Color,
    muted: Bool = false
  ) -> AttributedString {
    let stabilized = stabilizedSource(source)
    let lines = stabilized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let listLevels = normalizedStreamingListLevels(for: lines)
    var output = AttributedString()

    for (index, line) in lines.enumerated() {
      if index > 0 {
        output.append(AttributedString("\n"))
      }
      output.append(
        formattedLine(
          line,
          normalizedListLevel: listLevels[index],
          textSize: textSize,
          foregroundColor: foregroundColor,
          mutedColor: mutedColor,
          accentColor: accentColor,
          codeBackground: codeBackground,
          muted: muted
        )
      )
    }

    return output
  }

  private static func normalizedStreamingListLevels(for lines: [String]) -> [Int?] {
    var result: [Int?] = Array(repeating: nil, count: lines.count)
    var index = 0
    while index < lines.count {
      guard let rawIndent = rawListLineIndent(for: lines[index]) else {
        index += 1
        continue
      }
      var groupStart = index
      var rawIndents: [Int] = [rawIndent]
      index += 1
      while index < lines.count, let nextIndent = rawListLineIndent(for: lines[index]) {
        rawIndents.append(nextIndent)
        index += 1
      }
      let normalized = MacSelectableMarkdownBuilder.normalizedListIndentLevels(for: rawIndents)
      for level in normalized {
        result[groupStart] = level
        groupStart += 1
      }
    }
    return result
  }

  private static func rawListLineIndent(for line: String) -> Int? {
    let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
    guard trimmed.hasPrefix("- [x] ")
      || trimmed.hasPrefix("- [X] ")
      || trimmed.hasPrefix("- [ ] ")
      || trimmed.hasPrefix("- ")
      || trimmed.hasPrefix("* ")
      || trimmed.hasPrefix("+ ")
    else { return nil }
    return line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { total, ch in
      total + (ch == "\t" ? 4 : 1)
    }
  }

  private static func formattedLine(
    _ line: String,
    normalizedListLevel: Int?,
    textSize: CGFloat,
    foregroundColor: Color,
    mutedColor: Color,
    accentColor: Color,
    codeBackground: Color,
    muted: Bool
  ) -> AttributedString {
    let trimmedLeading = line.drop(while: { $0 == " " || $0 == "\t" })

    // Headings (# .. ######)
    if trimmedLeading.hasPrefix("#") {
      let hashes = trimmedLeading.prefix(while: { $0 == "#" })
      let afterHashes = trimmedLeading.dropFirst(hashes.count)
      if (1...6).contains(hashes.count), afterHashes.first == " " {
        let headingText = String(afterHashes.dropFirst())
        let scale = MacSelectableMarkdownBuilder.headingScale(for: hashes.count)
        let weight: Font.Weight = hashes.count <= 2 ? .bold : .semibold
        let headingForeground: Color = switch hashes.count {
        case 5: mutedColor
        case 6: muted ? mutedColor : accentColor
        default: foregroundColor
        }
        return parseInlineMarkdown(
          headingText,
          baseFont: .system(size: textSize * scale, weight: weight),
          baseFontSize: textSize * scale,
          baseWeight: weight,
          codeFontSize: textSize * scale * 0.9,
          foregroundColor: headingForeground,
          mutedColor: mutedColor,
          accentColor: accentColor,
          codeBackground: codeBackground,
          muted: muted
        )
      }
    }

    // Blockquote (> ...)
    if trimmedLeading.hasPrefix("> ") || trimmedLeading == ">" {
      let body = trimmedLeading.hasPrefix("> ")
        ? String(trimmedLeading.dropFirst(2))
        : ""
      var prefix = AttributedString("▎ ")
      prefix.font = .system(size: textSize, weight: .semibold)
      prefix.foregroundColor = accentColor.opacity(0.72)
      let content = parseInlineMarkdown(
        body,
        baseFont: .system(size: textSize),
        baseFontSize: textSize,
        baseWeight: .regular,
        codeFontSize: textSize * 0.9,
        foregroundColor: mutedColor,
        mutedColor: mutedColor,
        accentColor: accentColor,
        codeBackground: codeBackground,
        muted: muted
      )
      prefix.append(content)
      return prefix
    }

    // Task list / unordered list prefix
    let indentLevel = normalizedListLevel ?? 0
    let indent = String(repeating: "  ", count: min(indentLevel, 6))
    if trimmedLeading.hasPrefix("- [x] ") || trimmedLeading.hasPrefix("- [X] ") {
      var prefix = AttributedString("\(indent)☑ ")
      prefix.font = .system(size: textSize, weight: .medium)
      prefix.foregroundColor = accentColor
      prefix.append(
        parseInlineMarkdown(
          String(trimmedLeading.dropFirst(6)),
          baseFont: .system(size: textSize),
          baseFontSize: textSize,
          baseWeight: .regular,
          codeFontSize: textSize * 0.9,
          foregroundColor: foregroundColor,
          mutedColor: mutedColor,
          accentColor: accentColor,
          codeBackground: codeBackground,
          muted: muted
        )
      )
      return prefix
    }
    if trimmedLeading.hasPrefix("- [ ] ") {
      var prefix = AttributedString("\(indent)☐ ")
      prefix.font = .system(size: textSize, weight: .medium)
      prefix.foregroundColor = mutedColor
      prefix.append(
        parseInlineMarkdown(
          String(trimmedLeading.dropFirst(6)),
          baseFont: .system(size: textSize),
          baseFontSize: textSize,
          baseWeight: .regular,
          codeFontSize: textSize * 0.9,
          foregroundColor: foregroundColor,
          mutedColor: mutedColor,
          accentColor: accentColor,
          codeBackground: codeBackground,
          muted: muted
        )
      )
      return prefix
    }
    if trimmedLeading.hasPrefix("- ") || trimmedLeading.hasPrefix("* ") || trimmedLeading.hasPrefix("+ ") {
      let bullet = MacSelectableMarkdownBuilder.unorderedBulletMarker(forIndentLevel: indentLevel)
      let bulletSize = MacSelectableMarkdownBuilder.bulletFontSize(for: textSize, indentLevel: indentLevel)
      let bulletWeight: Font.Weight = switch indentLevel {
      case 0: .bold
      case 1: .semibold
      default: .medium
      }
      let bulletBaseColor = muted ? mutedColor : foregroundColor
      let bulletOpacity: Double = indentLevel == 0 ? (muted ? 0.90 : 0.80) : (muted ? 0.75 : 0.68)

      var prefix = AttributedString(indent)
      prefix.font = .system(size: textSize, weight: .regular)
      var bulletPart = AttributedString(bullet)
      bulletPart.swiftUI.font = .system(size: bulletSize, weight: bulletWeight)
      bulletPart.swiftUI.foregroundColor = bulletBaseColor.opacity(bulletOpacity)
      let baselineOffset = MacSelectableMarkdownBuilder.bulletBaselineOffset(
        for: textSize,
        indentLevel: indentLevel
      )
      if baselineOffset != 0 {
        bulletPart.swiftUI.baselineOffset = baselineOffset
      }
      prefix.append(bulletPart)
      var spacePart = AttributedString(" ")
      spacePart.font = .system(size: textSize, weight: .regular)
      prefix.append(spacePart)
      prefix.append(
        parseInlineMarkdown(
          String(trimmedLeading.dropFirst(2)),
          baseFont: .system(size: textSize),
          baseFontSize: textSize,
          baseWeight: .regular,
          codeFontSize: textSize * 0.9,
          foregroundColor: foregroundColor,
          mutedColor: mutedColor,
          accentColor: accentColor,
          codeBackground: codeBackground,
          muted: muted
        )
      )
      return prefix
    }

    return parseInlineMarkdown(
      line,
      baseFont: .system(size: textSize),
      baseFontSize: textSize,
      baseWeight: .regular,
      codeFontSize: textSize * 0.9,
      foregroundColor: foregroundColor,
      mutedColor: mutedColor,
      accentColor: accentColor,
      codeBackground: codeBackground,
      muted: muted
    )
  }

  private static func parseInlineMarkdown(
    _ text: String,
    baseFont: Font,
    baseFontSize: CGFloat,
    baseWeight: Font.Weight,
    codeFontSize: CGFloat,
    foregroundColor: Color,
    mutedColor: Color,
    accentColor: Color,
    codeBackground: Color,
    muted: Bool
  ) -> AttributedString {
    guard !text.isEmpty else { return AttributedString() }

    let options = AttributedString.MarkdownParsingOptions(
      interpretedSyntax: .inlineOnlyPreservingWhitespace
    )
    var attributed = (try? AttributedString(markdown: text, options: options))
      ?? AttributedString(text)

    let strongWeight: Font.Weight = baseWeight == .bold ? .bold : .semibold
    let codeWeight: Font.Weight = baseWeight == .bold ? .semibold : (baseWeight == .semibold ? .medium : .regular)
    let hasFootnoteRefs = text.contains("[^") && MacAnswerContentParser.inlineFootnoteReferenceRegex != nil

    attributed.foregroundColor = foregroundColor
    for run in attributed.runs {
      let range = run.range
      if run.link != nil {
        attributed[range].foregroundColor = accentColor
      }
      if let intent = run.inlinePresentationIntent {
        if intent.contains(.code) {
          attributed[range].font = .system(size: codeFontSize, weight: codeWeight, design: .monospaced)
          attributed[range].backgroundColor = codeBackground
        } else if intent.contains(.stronglyEmphasized) && intent.contains(.emphasized) {
          attributed[range].font = baseFont.weight(strongWeight).italic()
        } else if intent.contains(.stronglyEmphasized) {
          attributed[range].font = baseFont.weight(strongWeight)
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

    guard hasFootnoteRefs, let regex = MacAnswerContentParser.inlineFootnoteReferenceRegex else {
      return attributed
    }

    let supSize = max(9.5, round(baseFontSize * 0.68))
    let supBaseline = round(baseFontSize * 0.34)
    let supColor = muted ? mutedColor : accentColor
    var output = AttributedString()

    for run in attributed.runs {
      let isCode = run.inlinePresentationIntent?.contains(.code) == true
      let segment = String(attributed[run.range].characters)
      guard !isCode, run.link == nil, segment.contains("[^") else {
        output.append(AttributedString(attributed[run.range]))
        continue
      }

      let fullRange = NSRange(segment.startIndex..<segment.endIndex, in: segment)
      let matches = regex.matches(in: segment, range: fullRange)
      guard !matches.isEmpty else {
        output.append(AttributedString(attributed[run.range]))
        continue
      }

      let segmentCount = segment.count
      var cursorOffset = 0
      for match in matches {
        guard match.numberOfRanges >= 2,
          let matchRange = Range(match.range, in: segment),
          let labelRange = Range(match.range(at: 1), in: segment)
        else { continue }

        let matchStartOffset = segment.distance(from: segment.startIndex, to: matchRange.lowerBound)
        let matchEndOffset = segment.distance(from: segment.startIndex, to: matchRange.upperBound)
        guard matchStartOffset >= cursorOffset,
          matchEndOffset > matchStartOffset,
          matchEndOffset <= segmentCount
        else { continue }

        if matchStartOffset > cursorOffset {
          let lower = attributed.characters.index(run.range.lowerBound, offsetBy: cursorOffset)
          let upper = attributed.characters.index(run.range.lowerBound, offsetBy: matchStartOffset)
          output.append(AttributedString(attributed[lower..<upper]))
        }

        let label = String(segment[labelRange])
        var badge = AttributedString("\u{2009}\(label)")
        badge.swiftUI.font = .system(size: supSize, weight: .semibold).monospacedDigit()
        badge.swiftUI.baselineOffset = supBaseline
        badge.swiftUI.foregroundColor = supColor
        output.append(badge)
        cursorOffset = matchEndOffset
      }

      if cursorOffset < segmentCount {
        let lower = attributed.characters.index(run.range.lowerBound, offsetBy: cursorOffset)
        output.append(AttributedString(attributed[lower..<run.range.upperBound]))
      }
    }

    return output
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
  static let blockquoteAttributeKey = NSAttributedString.Key("pro.byok.mac.blockquote")
  static let thematicBreakAttributeKey = NSAttributedString.Key("pro.byok.mac.thematicBreak")
  static let inlineCodeAttributeKey = NSAttributedString.Key("pro.byok.mac.inlineCode")

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

  static func headingScale(for level: Int) -> CGFloat {
    switch level {
    case 1: 1.5
    case 2: 1.3
    case 3: 1.14
    case 4: 1.02
    case 5: 0.94
    default: 0.88
    }
  }

  static func unorderedBulletMarker(forIndentLevel indentLevel: Int) -> String {
    switch indentLevel {
    case 0: "•"
    case 1: "◦"
    default: "▪"
    }
  }

  static func bulletFontSize(for textSize: CGFloat, indentLevel: Int) -> CGFloat {
    switch indentLevel {
    case 0: round(textSize * 1.18)
    case 1: round(textSize * 1.10)
    default: round(textSize * 1.05)
    }
  }

  static func bulletBaselineOffset(for textSize: CGFloat, indentLevel: Int) -> CGFloat {
    switch indentLevel {
    case 0: -round(textSize * 0.04)
    default: 0
    }
  }

  /// Maps raw leading-space counts within a list group to logical nesting
  /// depths (`0, 1, 2, ...`) so both 2-space and 4-space LLM indentation step
  /// cleanly from `•` → `◦` → `▪`.
  static func normalizedListIndentLevels(for rawIndents: [Int]) -> [Int] {
    var stack: [Int] = []
    var levels: [Int] = []
    levels.reserveCapacity(rawIndents.count)

    for raw in rawIndents {
      while let top = stack.last, raw < top {
        stack.removeLast()
      }
      if stack.isEmpty || raw > stack.last! {
        stack.append(raw)
      }
      levels.append(max(0, stack.count - 1))
    }
    return levels
  }

  static func blockquoteVerticalPadding(for textSize: CGFloat) -> CGFloat {
    ceil(textSize * 0.48)
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
        case .footnotes(let footnotes):
          result.append(renderFootnotesBlock(footnotes, style: style))
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
    let lines = markdown.components(separatedBy: .newlines)
    var renderedBlocks: [NSMutableAttributedString] = []
    var index = 0
    var blockquoteCounter = 0

    let bodyLineSpacing = style.textSize * 0.32
    let listLineSpacing = style.textSize * 0.28
    let paragraphGap = style.textSize * 0.70
    let listItemGap = style.textSize * 0.30
    let listTrailingGap = style.textSize * 0.72
    let blockquoteVerticalPad = blockquoteVerticalPadding(for: style.textSize)

    while index < lines.count {
      let line = lines[index]
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty {
        index += 1
        continue
      }

      let isFirstBlock = renderedBlocks.isEmpty

      // Thematic break (drawn full-width in MacSelectableTextView.drawBackground)
      if isThematicBreak(trimmed) {
        let para = NSMutableParagraphStyle()
        para.paragraphSpacingBefore = isFirstBlock ? 0 : style.textSize * 0.25
        para.paragraphSpacing = style.textSize * 0.72
        let rule = NSMutableAttributedString(
          string: "\u{00A0}",
          attributes: [
            .font: NSFont.systemFont(ofSize: max(6, style.textSize * 0.5)),
            .foregroundColor: NSColor.clear,
            .paragraphStyle: para,
            thematicBreakAttributeKey: true,
            markdownSourceAttributeKey: trimmed,
          ]
        )
        renderedBlocks.append(rule)
        index += 1
        continue
      }

      // ATX Heading
      if let heading = parseHeading(trimmed) {
        let scale = headingScale(for: heading.level)
        let weight: NSFont.Weight = heading.level <= 2 ? .bold : .semibold
        let color: NSColor = switch heading.level {
        case 5: style.mutedColor
        case 6: style.muted ? style.mutedColor : style.accentColor
        default: style.muted ? style.mutedColor : style.textColor
        }
        let spacingBefore: CGFloat = switch heading.level {
        case 1: style.textSize * 0.85
        case 2: style.textSize * 0.72
        case 3: style.textSize * 0.58
        default: style.textSize * 0.45
        }
        let spacingAfter: CGFloat = switch heading.level {
        case 1: style.textSize * 0.35
        case 2: style.textSize * 0.30
        case 3: style.textSize * 0.26
        default: style.textSize * 0.22
        }
        let para = NSMutableParagraphStyle()
        para.lineSpacing = style.textSize * 0.18
        para.paragraphSpacingBefore = isFirstBlock ? 0 : spacingBefore
        para.paragraphSpacing = spacingAfter

        let rendered = renderInlineMarkdown(
          heading.text,
          fontSize: style.textSize * scale,
          fontWeight: weight,
          foregroundColor: color,
          style: style,
          paragraphStyle: para,
          rawSource: trimmed
        )
        renderedBlocks.append(rendered)
        index += 1
        continue
      }

      // Blockquote group (rounded card + full-height accent bar drawn in MacSelectableTextView)
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
        blockquoteCounter += 1
        let quoteID = blockquoteCounter
        let innerPara = NSMutableParagraphStyle()
        innerPara.firstLineHeadIndent = 16
        innerPara.headIndent = 16
        innerPara.tailIndent = -12
        innerPara.lineSpacing = bodyLineSpacing
        innerPara.paragraphSpacing = style.textSize * 0.25

        let combined = quoteLines.joined(separator: "\n")
        let rawSource = rawLines.joined(separator: "\n")
        let rendered = renderInlineMarkdown(
          combined.isEmpty ? " " : combined,
          fontSize: style.textSize,
          fontWeight: .regular,
          foregroundColor: style.mutedColor,
          style: style,
          paragraphStyle: innerPara,
          rawSource: rawSource
        )
        adjustParagraphSpacing(
          in: rendered,
          firstSpacingBefore: isFirstBlock ? 0 : style.textSize * 0.45,
          lastSpacingAfter: paragraphGap + blockquoteVerticalPad
        )
        rendered.addAttribute(
          blockquoteAttributeKey,
          value: quoteID,
          range: NSRange(location: 0, length: rendered.length)
        )
        rendered.addAttribute(
          markdownSourceAttributeKey,
          value: rawSource,
          range: NSRange(location: 0, length: rendered.length)
        )
        renderedBlocks.append(rendered)
        continue
      }

      // List item (unordered, task, or ordered) with tab-stopped hanging indents
      if parseListItem(line) != nil {
        var parsedItems: [(item: ParsedListItem, rawLine: String)] = []
        while index < lines.count, let item = parseListItem(lines[index]) {
          parsedItems.append((item: item, rawLine: lines[index]))
          index += 1
        }

        let normalizedLevels = normalizedListIndentLevels(for: parsedItems.map(\.item.rawIndent))
        let orderedMarkerFont = NSFont.monospacedDigitSystemFont(ofSize: style.textSize, weight: .medium)
        var maxOrderedWidthByIndent: [Int: CGFloat] = [:]
        for (itemOffset, entry) in parsedItems.enumerated() {
          let indentLevel = normalizedLevels[itemOffset]
          if case .ordered(let marker) = entry.item.kind {
            let width = ceil((marker as NSString).size(withAttributes: [.font: orderedMarkerFont]).width)
            maxOrderedWidthByIndent[indentLevel] = max(
              maxOrderedWidthByIndent[indentLevel] ?? 0,
              width
            )
          }
        }

        let indentStep = round(style.textSize * 1.2)
        let defaultMarkerColumn = round(style.textSize * 1.35)
        let unorderedMarkerColumn = round(style.textSize * 0.95)
        let listGroup = NSMutableAttributedString()
        let rawGroupSource = parsedItems.map(\.rawLine).joined(separator: "\n")

        for (itemOffset, entry) in parsedItems.enumerated() {
          let item = entry.item
          let indentLevel = normalizedLevels[itemOffset]
          let isLastItem = itemOffset == parsedItems.count - 1
          let clampedIndent = min(indentLevel, 6)
          let baseIndent = CGFloat(clampedIndent) * indentStep
          let markerStart = baseIndent + round(style.textSize * 0.25)
          let markerColumn: CGFloat
          switch item.kind {
          case .unordered:
            markerColumn = unorderedMarkerColumn
          case .ordered:
            if let maxOrderedWidth = maxOrderedWidthByIndent[indentLevel] {
              markerColumn = max(defaultMarkerColumn, maxOrderedWidth + round(style.textSize * 0.45))
            } else {
              markerColumn = defaultMarkerColumn
            }
          case .task:
            markerColumn = defaultMarkerColumn
          }
          let textStart = markerStart + markerColumn

          let para = NSMutableParagraphStyle()
          para.firstLineHeadIndent = markerStart
          para.headIndent = textStart
          para.tabStops = [NSTextTab(textAlignment: .left, location: textStart)]
          para.lineSpacing = listLineSpacing
          para.paragraphSpacing = isLastItem ? listTrailingGap : listItemGap

          let prefix: NSAttributedString
          switch item.kind {
          case .task(let isCompleted):
            let color = isCompleted ? style.accentColor : style.mutedColor
            prefix = taskMarkerPrefix(
              isCompleted: isCompleted,
              textSize: style.textSize,
              markerColor: color,
              paragraphStyle: para
            )
          case .unordered:
            let marker = unorderedBulletMarker(forIndentLevel: indentLevel)
            let bulletSize = bulletFontSize(for: style.textSize, indentLevel: indentLevel)
            let bulletWeight: NSFont.Weight = switch indentLevel {
            case 0: .bold
            case 1: .semibold
            default: .medium
            }
            let baseMarkerColor = style.muted ? style.mutedColor : style.textColor
            let markerAlpha: CGFloat = indentLevel == 0
              ? (style.muted ? 0.90 : 0.80)
              : (style.muted ? 0.75 : 0.68)
            var bulletAttrs: [NSAttributedString.Key: Any] = [
              .font: NSFont.systemFont(ofSize: bulletSize, weight: bulletWeight),
              .foregroundColor: baseMarkerColor.withAlphaComponent(markerAlpha),
              .paragraphStyle: para,
            ]
            let baseline = bulletBaselineOffset(for: style.textSize, indentLevel: indentLevel)
            if baseline != 0 {
              bulletAttrs[.baselineOffset] = baseline
            }
            let mutablePrefix = NSMutableAttributedString(string: marker, attributes: bulletAttrs)
            mutablePrefix.append(
              NSAttributedString(
                string: "\t",
                attributes: [
                  .font: NSFont.systemFont(ofSize: style.textSize, weight: .regular),
                  .paragraphStyle: para,
                ]
              )
            )
            prefix = mutablePrefix
          case .ordered(let marker):
            let baseMarkerColor = style.muted ? style.mutedColor : style.textColor
            let markerAlpha: CGFloat = style.muted ? 0.90 : 0.75
            prefix = NSAttributedString(
              string: marker + "\t",
              attributes: [
                .font: orderedMarkerFont,
                .foregroundColor: baseMarkerColor.withAlphaComponent(markerAlpha),
                .paragraphStyle: para,
              ]
            )
          }

          listGroup.append(prefix)
          listGroup.append(
            renderInlineMarkdown(
              item.body,
              fontSize: style.textSize,
              fontWeight: .regular,
              foregroundColor: style.muted ? style.mutedColor : style.textColor,
              style: style,
              paragraphStyle: para,
              rawSource: entry.rawLine
            )
          )

          if !isLastItem {
            listGroup.append(
              NSAttributedString(
                string: "\n",
                attributes: [
                  .font: NSFont.systemFont(ofSize: style.textSize, weight: .regular),
                  .paragraphStyle: para,
                ]
              )
            )
          }
        }

        listGroup.addAttribute(
          markdownSourceAttributeKey,
          value: rawGroupSource,
          range: NSRange(location: 0, length: listGroup.length)
        )
        renderedBlocks.append(listGroup)
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
      para.lineSpacing = bodyLineSpacing
      para.paragraphSpacing = paragraphGap

      let rendered = renderInlineMarkdown(
        joined,
        fontSize: style.textSize,
        fontWeight: .regular,
        foregroundColor: style.muted ? style.mutedColor : style.textColor,
        style: style,
        paragraphStyle: para,
        rawSource: joined
      )
      renderedBlocks.append(rendered)
    }

    let output = NSMutableAttributedString()
    for (blockIndex, block) in renderedBlocks.enumerated() {
      let isLastBlock = blockIndex == renderedBlocks.count - 1
      if isLastBlock {
        adjustParagraphSpacing(in: block, lastSpacingAfter: 0)
      }
      output.append(block)
      if !isLastBlock {
        var newlineAttrs: [NSAttributedString.Key: Any] = [
          .font: NSFont.systemFont(ofSize: style.textSize, weight: .regular)
        ]
        if block.length > 0 {
          let lastIdx = block.length - 1
          if let font = block.attribute(.font, at: lastIdx, effectiveRange: nil) {
            newlineAttrs[.font] = font
          }
          if let para = block.attribute(.paragraphStyle, at: lastIdx, effectiveRange: nil) {
            newlineAttrs[.paragraphStyle] = para
          }
        }
        output.append(NSAttributedString(string: "\n", attributes: newlineAttrs))
      }
    }

    return output
  }

  private static func adjustParagraphSpacing(
    in attributed: NSMutableAttributedString,
    firstSpacingBefore: CGFloat? = nil,
    lastSpacingAfter: CGFloat? = nil
  ) {
    let nsString = attributed.string as NSString
    guard nsString.length > 0 else { return }

    if let firstSpacingBefore {
      let firstRange = nsString.paragraphRange(for: NSRange(location: 0, length: 0))
      var updates: [(NSRange, NSParagraphStyle)] = []
      attributed.enumerateAttribute(.paragraphStyle, in: firstRange, options: []) { value, range, _ in
        let mutable = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
          ?? NSMutableParagraphStyle()
        mutable.paragraphSpacingBefore = firstSpacingBefore
        updates.append((range, mutable))
      }
      for (range, para) in updates {
        attributed.addAttribute(.paragraphStyle, value: para, range: range)
      }
    }

    if let lastSpacingAfter {
      let lastRange = nsString.paragraphRange(for: NSRange(location: nsString.length - 1, length: 0))
      var updates: [(NSRange, NSParagraphStyle)] = []
      attributed.enumerateAttribute(.paragraphStyle, in: lastRange, options: []) { value, range, _ in
        let mutable = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
          ?? NSMutableParagraphStyle()
        mutable.paragraphSpacing = lastSpacingAfter
        updates.append((range, mutable))
      }
      for (range, para) in updates {
        attributed.addAttribute(.paragraphStyle, value: para, range: range)
      }
    }
  }

  @MainActor
  private static func taskMarkerPrefix(
    isCompleted: Bool,
    textSize: CGFloat,
    markerColor: NSColor,
    paragraphStyle: NSParagraphStyle
  ) -> NSAttributedString {
    let baseFont = NSFont.systemFont(ofSize: textSize, weight: .regular)
    let symbolSize = max(11, textSize * 0.88)
    let symbolName = isCompleted ? "checkmark.circle.fill" : "circle"
    let config = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .semibold)
    if let symbol = NSImage(
      systemSymbolName: symbolName,
      accessibilityDescription: isCompleted ? "Completed" : "Incomplete"
    )?.withSymbolConfiguration(config),
      symbol.size.width > 0,
      symbol.size.height > 0
    {
      let scale: CGFloat = 2
      let pixelWidth = max(1, Int(ceil(symbol.size.width * scale)))
      let pixelHeight = max(1, Int(ceil(symbol.size.height * scale)))
      if let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelWidth,
        pixelsHigh: pixelHeight,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      ), let graphicsContext = NSGraphicsContext(bitmapImageRep: rep) {
        rep.size = symbol.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        let drawRect = NSRect(origin: .zero, size: symbol.size)
        symbol.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
        markerColor.setFill()
        drawRect.fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()

        let tinted = NSImage(size: symbol.size)
        tinted.addRepresentation(rep)
        tinted.isTemplate = false

        let attachment = NSTextAttachment()
        attachment.image = tinted
        let yOffset = round((baseFont.capHeight - symbol.size.height) / 2)
        attachment.bounds = CGRect(origin: CGPoint(x: 0, y: yOffset), size: symbol.size)

        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttributes(
          [
            .font: baseFont,
            .paragraphStyle: paragraphStyle,
          ],
          range: NSRange(location: 0, length: result.length)
        )
        result.append(
          NSAttributedString(
            string: "\t",
            attributes: [
              .font: baseFont,
              .foregroundColor: markerColor,
              .paragraphStyle: paragraphStyle,
            ]
          )
        )
        return result
      }
    }

    return NSAttributedString(
      string: (isCompleted ? "☑" : "☐") + "\t",
      attributes: [
        .font: NSFont.systemFont(ofSize: textSize, weight: .medium),
        .foregroundColor: markerColor,
        .paragraphStyle: paragraphStyle,
      ]
    )
  }

  private static func renderCodeBlock(
    language: String?,
    content: String,
    rawMarkdown: String,
    style: Style
  ) -> NSAttributedString {
    let codeFont = NSFont.monospacedSystemFont(ofSize: max(11, style.textSize - 2), weight: .regular)
    let para = NSMutableParagraphStyle()
    para.firstLineHeadIndent = 10
    para.headIndent = 10
    para.lineSpacing = 3
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
  private static func renderFootnotesBlock(
    _ footnotes: [MacParsedFootnote],
    style: Style
  ) -> NSAttributedString {
    let noteFontSize = max(11.5, style.textSize - 2)
    let markerFont = NSFont.monospacedDigitSystemFont(ofSize: noteFontSize, weight: .semibold)
    let maxMarkerWidth = footnotes.reduce(CGFloat(0)) { current, note in
      let w = ceil(("\(note.label)." as NSString).size(withAttributes: [.font: markerFont]).width)
      return max(current, w)
    }
    let textStart = max(round(noteFontSize * 1.6), maxMarkerWidth + round(noteFontSize * 0.5))

    let output = NSMutableAttributedString()
    for (offset, footnote) in footnotes.enumerated() {
      let isLast = offset == footnotes.count - 1
      let para = NSMutableParagraphStyle()
      para.firstLineHeadIndent = 0
      para.headIndent = textStart
      para.tabStops = [NSTextTab(textAlignment: .left, location: textStart)]
      para.lineSpacing = noteFontSize * 0.28
      para.paragraphSpacing = isLast ? 0 : noteFontSize * 0.35

      let marker = NSAttributedString(
        string: "\(footnote.label).\t",
        attributes: [
          .font: markerFont,
          .foregroundColor: style.muted ? style.mutedColor : style.accentColor,
          .paragraphStyle: para,
        ]
      )
      output.append(marker)
      output.append(
        renderInlineMarkdown(
          footnote.body,
          fontSize: noteFontSize,
          fontWeight: .regular,
          foregroundColor: style.mutedColor,
          style: style,
          paragraphStyle: para,
          rawSource: footnote.rawMarkdown
        )
      )
      if !isLast {
        output.append(
          NSAttributedString(
            string: "\n",
            attributes: [
              .font: NSFont.systemFont(ofSize: noteFontSize, weight: .regular),
              .paragraphStyle: para,
            ]
          )
        )
      }
    }

    output.addAttribute(
      markdownSourceAttributeKey,
      value: footnotes.map(\.rawMarkdown).joined(separator: "\n\n"),
      range: NSRange(location: 0, length: output.length)
    )
    return output
  }

  @MainActor
  private static func italicVariant(of font: NSFont) -> NSFont {
    let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
    if let converted = NSFont(descriptor: descriptor, size: font.pointSize) {
      return converted
    }
    return NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
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
    let italicFont = italicVariant(of: baseFont)
    let boldItalicFont = italicVariant(of: boldFont)
    let codeWeight: NSFont.Weight = fontWeight == .bold ? .semibold : (fontWeight == .semibold ? .medium : .regular)
    let codeFont = NSFont.monospacedSystemFont(ofSize: fontSize * 0.9, weight: codeWeight)

    let options = AttributedString.MarkdownParsingOptions(
      interpretedSyntax: .inlineOnlyPreservingWhitespace
    )
    let parsed = (try? AttributedString(markdown: text, options: options))
      ?? AttributedString(text)

    let output = NSMutableAttributedString()
    let supSize = max(9.5, round(fontSize * 0.68))
    let supFont = NSFont.monospacedDigitSystemFont(ofSize: supSize, weight: .semibold)
    let supBaseline = round(fontSize * 0.34)
    let supColor = style.muted ? style.mutedColor : style.accentColor

    for run in parsed.runs {
      let segment = String(parsed[run.range].characters)
      var attrs: [NSAttributedString.Key: Any] = [
        .font: baseFont,
        .foregroundColor: foregroundColor,
        .paragraphStyle: paragraphStyle,
        markdownSourceAttributeKey: rawSource,
      ]

      let isCode = run.inlinePresentationIntent?.contains(.code) == true
      if let intent = run.inlinePresentationIntent {
        if isCode {
          attrs[.font] = codeFont
          attrs[inlineCodeAttributeKey] = true
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

      if !isCode, run.link == nil, segment.contains("[^"),
        let regex = MacAnswerContentParser.inlineFootnoteReferenceRegex
      {
        let fullRange = NSRange(segment.startIndex..<segment.endIndex, in: segment)
        let matches = regex.matches(in: segment, range: fullRange)
        if !matches.isEmpty {
          var cursor = segment.startIndex
          let supAttrs: [NSAttributedString.Key: Any] = [
            .font: supFont,
            .foregroundColor: supColor,
            .baselineOffset: supBaseline,
            .paragraphStyle: paragraphStyle,
            markdownSourceAttributeKey: rawSource,
          ]
          for match in matches {
            guard match.numberOfRanges >= 2,
              let matchRange = Range(match.range, in: segment),
              let labelRange = Range(match.range(at: 1), in: segment)
            else { continue }

            if matchRange.lowerBound > cursor {
              output.append(NSAttributedString(string: String(segment[cursor..<matchRange.lowerBound]), attributes: attrs))
            }
            let label = String(segment[labelRange])
            output.append(NSAttributedString(string: "\u{2009}\(label)", attributes: supAttrs))
            cursor = matchRange.upperBound
          }
          if cursor < segment.endIndex {
            output.append(NSAttributedString(string: String(segment[cursor..<segment.endIndex]), attributes: attrs))
          }
          continue
        }
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
    enum Kind {
      case unordered
      case ordered(marker: String)
      case task(isCompleted: Bool)
    }

    let rawIndent: Int
    let kind: Kind
    let body: String
  }

  private static func parseListItem(_ line: String) -> ParsedListItem? {
    let leadingSpaces = line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { total, ch in
      total + (ch == "\t" ? 4 : 1)
    }
    let trimmed = line.trimmingCharacters(in: .whitespaces)

    if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
      return ParsedListItem(
        rawIndent: leadingSpaces,
        kind: .task(isCompleted: true),
        body: String(trimmed.dropFirst(6))
      )
    }
    if trimmed.hasPrefix("- [ ] ") {
      return ParsedListItem(
        rawIndent: leadingSpaces,
        kind: .task(isCompleted: false),
        body: String(trimmed.dropFirst(6))
      )
    }
    if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
      return ParsedListItem(
        rawIndent: leadingSpaces,
        kind: .unordered,
        body: String(trimmed.dropFirst(2))
      )
    }
    if let matchEnd = orderedMarkerEndIndex(in: trimmed) {
      let marker = String(trimmed[..<matchEnd]).trimmingCharacters(in: .whitespaces)
      let body = String(trimmed[matchEnd...])
      return ParsedListItem(
        rawIndent: leadingSpaces,
        kind: .ordered(marker: marker),
        body: body
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

  static func isThematicBreak(_ trimmed: String) -> Bool {
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
      codeBackgroundColor: NSColor(theme.codeSurface.opacity(0.85)),
      codeBlockBackgroundColor: NSColor(theme.codeSurface),
      separatorColor: NSColor(theme.separator.opacity(0.70)),
      findQuery: findQuery,
      activeFindOccurrence: activeFindOccurrence
    )

    let attributed = MacSelectableMarkdownBuilder.attributedString(
      for: source,
      includeStructuredBlocks: includeStructuredBlocks,
      style: style
    )
    container.setAttributedString(attributed, style: style)
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
  private var topInset: CGFloat = 0
  private var bottomInset: CGFloat = 0

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

  func setAttributedString(_ value: NSAttributedString, style: MacSelectableMarkdownBuilder.Style) {
    attributedStorage = value
    let verticalPad = MacSelectableMarkdownBuilder.blockquoteVerticalPadding(for: style.textSize)
    let startsWithBlockquote = value.length > 0
      && value.attribute(MacSelectableMarkdownBuilder.blockquoteAttributeKey, at: 0, effectiveRange: nil) != nil
    let endsWithBlockquote = value.length > 0
      && value.attribute(MacSelectableMarkdownBuilder.blockquoteAttributeKey, at: value.length - 1, effectiveRange: nil) != nil
    topInset = startsWithBlockquote ? verticalPad : 0
    bottomInset = endsWithBlockquote ? verticalPad : 0

    textView.topContentInset = topInset
    textView.blockquoteVerticalPadding = verticalPad
    textView.blockquoteBackgroundColor = style.textColor.withAlphaComponent(style.isDark ? 0.05 : 0.035)
    textView.blockquoteAccentColor = style.accentColor.withAlphaComponent(0.72)
    textView.inlineCodeBackgroundColor = style.codeBackgroundColor
    textView.thematicBreakColor = style.separatorColor
    textView.linkTextAttributes = [
      .foregroundColor: style.accentColor,
      .cursor: NSCursor.pointingHand,
    ]
    textView.textStorage?.setAttributedString(value)
    textView.needsDisplay = true
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
    return ceil(manager.usedRect(for: container).height) + topInset + bottomInset
  }

  override func layout() {
    super.layout()
    let width = max(bounds.width, 1)
    textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
    textView.frame = bounds
    textView.needsDisplay = true
  }
}

@MainActor
final class MacSelectableTextView: NSTextView {
  var topContentInset: CGFloat = 0
  var blockquoteVerticalPadding: CGFloat = 8
  var blockquoteBackgroundColor: NSColor = NSColor.labelColor.withAlphaComponent(0.035)
  var blockquoteAccentColor: NSColor = NSColor.controlAccentColor.withAlphaComponent(0.72)
  var inlineCodeBackgroundColor: NSColor = NSColor.quaternaryLabelColor
  var thematicBreakColor: NSColor = NSColor.separatorColor

  override var textContainerOrigin: NSPoint {
    NSPoint(x: 0, y: topContentInset)
  }

  override func drawBackground(in rect: NSRect) {
    drawCustomDecorations(in: rect)
    super.drawBackground(in: rect)
  }

  private func drawCustomDecorations(in rect: NSRect) {
    guard let layoutManager = self.layoutManager,
      let textContainer = self.textContainer,
      let storage = self.textStorage,
      storage.length > 0
    else { return }

    let origin = textContainerOrigin
    let viewWidth = bounds.width
    let containerRect = rect
      .offsetBy(dx: -origin.x, dy: -origin.y)
      .insetBy(dx: 0, dy: -blockquoteVerticalPadding)
    let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: containerRect, in: textContainer)
    guard visibleGlyphRange.length > 0 else { return }
    let visibleCharRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)
    let fullDocRange = NSRange(location: 0, length: storage.length)

    // 1. Blockquote rounded cards + full-height accent bar
    var drawnBlockquoteIDs = Set<Int>()
    storage.enumerateAttribute(
      MacSelectableMarkdownBuilder.blockquoteAttributeKey,
      in: visibleCharRange,
      options: []
    ) { value, effectiveRange, _ in
      guard let quoteID = value as? Int, drawnBlockquoteIDs.insert(quoteID).inserted else { return }
      var fullBlockRange = NSRange(location: 0, length: 0)
      _ = storage.attribute(
        MacSelectableMarkdownBuilder.blockquoteAttributeKey,
        at: effectiveRange.location,
        longestEffectiveRange: &fullBlockRange,
        in: fullDocRange
      )
      let glyphRange = layoutManager.glyphRange(forCharacterRange: fullBlockRange, actualCharacterRange: nil)
      guard glyphRange.length > 0 else { return }

      var unionRect = NSRect.null
      layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, _, _ in
        unionRect = unionRect.isNull ? usedRect : unionRect.union(usedRect)
      }
      guard !unionRect.isNull else { return }

      let cardRect = NSRect(
        x: origin.x,
        y: unionRect.minY + origin.y - blockquoteVerticalPadding,
        width: max(viewWidth, 1),
        height: unionRect.height + blockquoteVerticalPadding * 2
      )

      NSGraphicsContext.saveGraphicsState()
      let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: 9, yRadius: 9)
      cardPath.addClip()
      blockquoteBackgroundColor.setFill()
      cardPath.fill()

      let accentBarRect = NSRect(
        x: cardRect.minX,
        y: cardRect.minY,
        width: 3,
        height: cardRect.height
      )
      blockquoteAccentColor.setFill()
      accentBarRect.fill()
      NSGraphicsContext.restoreGraphicsState()
    }

    // 2. Full-width thematic breaks
    storage.enumerateAttribute(
      MacSelectableMarkdownBuilder.thematicBreakAttributeKey,
      in: visibleCharRange,
      options: []
    ) { value, effectiveRange, _ in
      guard (value as? Bool) == true else { return }
      let glyphRange = layoutManager.glyphRange(forCharacterRange: effectiveRange, actualCharacterRange: nil)
      guard glyphRange.length > 0 else { return }
      let usedRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
      let ruleY = floor(usedRect.midY + origin.y)
      let ruleRect = NSRect(x: origin.x, y: ruleY, width: max(viewWidth, 1), height: 1)
      thematicBreakColor.setFill()
      ruleRect.fill()
    }

    // 3. Rounded inline code pills
    storage.enumerateAttribute(
      MacSelectableMarkdownBuilder.inlineCodeAttributeKey,
      in: visibleCharRange,
      options: []
    ) { value, effectiveRange, _ in
      guard (value as? Bool) == true else { return }
      let glyphRange = layoutManager.glyphRange(forCharacterRange: effectiveRange, actualCharacterRange: nil)
      guard glyphRange.length > 0 else { return }
      inlineCodeBackgroundColor.setFill()
      layoutManager.enumerateEnclosingRects(
        forGlyphRange: glyphRange,
        withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
        in: textContainer
      ) { enclosingRect, _ in
        var pillRect = enclosingRect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -2.0, dy: -0.5)
        let minX = max(0, pillRect.minX)
        let maxX = min(viewWidth, pillRect.maxX)
        pillRect.origin.x = minX
        pillRect.size.width = max(0, maxX - minX)
        guard pillRect.width > 0, pillRect.height > 0 else { return }
        NSBezierPath(roundedRect: pillRect, xRadius: 4, yRadius: 4).fill()
      }
    }
  }

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
