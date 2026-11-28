import AppKit
import BYOKchatProviderCore
import Foundation
import MacAppFoundation
import SwiftUI
import Testing
@testable import BYOKmac

@Suite("Mac Transcript Renderer Improvements")
struct MacTranscriptRendererSupportTests {
  @Test("Transcript font size preference clamps, persists, and resets")
  @MainActor
  func transcriptFontSizePreferences() {
    let suiteName = "MacTranscriptRendererSupportTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let preferences = MacPreferencesModel(defaults: defaults)
    #expect(preferences.transcriptFontSize == MacPreferencesModel.defaultTranscriptFontSize)

    preferences.increaseTranscriptFontSize()
    #expect(preferences.transcriptFontSize == 16)

    for _ in 0..<20 {
      preferences.increaseTranscriptFontSize()
    }
    #expect(preferences.transcriptFontSize == MacPreferencesModel.maximumTranscriptFontSize)
    #expect(!preferences.canIncreaseTranscriptFontSize)

    let reloaded = MacPreferencesModel(defaults: defaults)
    #expect(reloaded.transcriptFontSize == MacPreferencesModel.maximumTranscriptFontSize)

    reloaded.resetTranscriptFontSize()
    #expect(reloaded.transcriptFontSize == MacPreferencesModel.defaultTranscriptFontSize)

    for _ in 0..<20 {
      reloaded.decreaseTranscriptFontSize()
    }
    #expect(reloaded.transcriptFontSize == MacPreferencesModel.minimumTranscriptFontSize)
    #expect(!reloaded.canDecreaseTranscriptFontSize)
  }

  @Test("In-conversation find indexes matches across message content and reasoning")
  func inChatFindIndexesMatches() {
    let first = ChatMessage(role: .user, content: "Explain Swift concurrency", status: .complete)
    let second = ChatMessage(
      role: .assistant,
      content: "Swift uses structured concurrency. SWIFT actors isolate state.",
      reasoning: "Need to mention swift tasks",
      status: .complete
    )

    let index = MacTranscriptFindSupport.search(query: "swift", in: [first, second])
    #expect(index.totalMatches == 4)
    #expect(index.countsByMessageID[first.id] == 1)
    #expect(index.countsByMessageID[second.id] == 3)
    #expect(index.matches[0] == MacTranscriptFindMatch(messageID: first.id, occurrenceInMessage: 0))
    #expect(index.matches[3] == MacTranscriptFindMatch(messageID: second.id, occurrenceInMessage: 2))

    #expect(MacTranscriptFindSupport.search(query: "   ", in: [first, second]).totalMatches == 0)
  }

  @Test("Streaming tail formatter stabilizes unfinished links/math and formats inline Markdown")
  func streamingTailFormatting() {
    let stabilizedLink = MacStreamingTailFormatter.stabilizedSource(
      "Check [Swift Docs](https://swift.org/doc"
    )
    #expect(stabilizedLink == "Check Swift Docs…")

    let stabilizedMath = MacStreamingTailFormatter.stabilizedSource("Value is $x + 1")
    #expect(stabilizedMath == "Value is …")

    let formatted = MacStreamingTailFormatter.formattedAttributedString(
      "## Summary\n- Use `Task` with **actors**",
      textSize: 15,
      foregroundColor: .primary,
      mutedColor: .secondary,
      accentColor: .accentColor,
      codeBackground: .gray.opacity(0.1)
    )
    let plain = String(formatted.characters)
    #expect(plain.contains("Summary"))
    #expect(plain.contains("• Use Task with actors"))
    #expect(!plain.contains("**"))
    #expect(!plain.contains("##"))
  }

  @Test("Structured provider citations merge cleanly with extracted links and annotate offsets")
  func structuredCitationsMergeAndAnnotate() {
    let structured = [
      ChatCitation(
        url: "https://swift.org/concurrency",
        title: "Swift Concurrency",
        snippet: "Structured concurrency in Swift.",
        startIndex: 0,
        endIndex: 25
      ),
      ChatCitation(
        url: "https://developer.apple.com/documentation/swift",
        title: "Apple Developer",
        snippet: nil,
        startIndex: nil,
        endIndex: nil
      ),
    ]
    let extracted = [
      MacAnswerSource(url: URL(string: "https://swift.org/concurrency")!, title: nil),
      MacAnswerSource(url: URL(string: "https://example.com/extra")!, title: "Extra"),
    ]

    let merged = MacCitationSupport.mergedSources(
      structuredCitations: structured,
      extractedSources: extracted
    )
    #expect(merged.count == 3)
    #expect(merged[0].displayTitle == "Swift Concurrency")
    #expect(merged[0].snippet == "Structured concurrency in Swift.")
    #expect(merged[0].isProviderCitation)
    #expect(merged[1].displayTitle == "Apple Developer")
    #expect(merged[2].displayTitle == "Extra")

    let annotated = MacCitationSupport.annotateInlineCitations(
      in: "Swift supports structured concurrency natively.",
      citations: structured,
      mergedSources: merged
    )
    #expect(annotated.contains("[1](https://swift.org/concurrency)"))
  }

  @Test("Selectable Markdown builds attributed document and extracts Copy as Markdown")
  @MainActor
  func selectableMarkdownBuilderAndCopyAsMarkdown() {
    let markdown = """
    ## Overview

    First paragraph with **bold** and `inline`.

    - First item
    - Second item
    """
    #expect(MacSelectableMarkdownBuilder.canRenderNatively("## Overview\n\nSimple text."))
    #expect(!MacSelectableMarkdownBuilder.canRenderNatively("![img](https://example.com/a.png)"))
    #expect(!MacSelectableMarkdownBuilder.canRenderNatively("Equation $x^2$ here"))

    let style = MacSelectableMarkdownBuilder.Style(
      textSize: 15,
      muted: false,
      isDark: false,
      themeID: .githubLight,
      textColor: .labelColor,
      mutedColor: .secondaryLabelColor,
      accentColor: .controlAccentColor,
      codeBackgroundColor: .quaternaryLabelColor,
      separatorColor: .separatorColor,
      findQuery: "bold",
      activeFindOccurrence: 0
    )
    let attributed = MacSelectableMarkdownBuilder.attributedString(
      for: markdown,
      style: style
    )
    #expect(attributed.string.contains("Overview"))
    #expect(attributed.string.contains("First item"))

    let fullRange = NSRange(location: 0, length: attributed.length)
    let copiedMarkdown = MacSelectableMarkdownBuilder.markdownSnippet(
      from: attributed,
      selectedRange: fullRange
    )
    #expect(copiedMarkdown.contains("## Overview"))
    #expect(copiedMarkdown.contains("- First item"))
  }

  @Test("Streaming tail formatter preserves inline styles inside headings and renders nested bullets")
  func streamingTailFormattingHeadingsAndNestedBullets() {
    let source = """
    # Heading with `code` and **bold**
    - Top item
      - Nested item
        + Deep item
    """
    let formatted = MacStreamingTailFormatter.formattedAttributedString(
      source,
      textSize: 15,
      foregroundColor: .primary,
      mutedColor: .secondary,
      accentColor: .accentColor,
      codeBackground: .gray.opacity(0.1)
    )
    let plain = String(formatted.characters)
    #expect(plain.contains("Heading with code and bold"))
    #expect(plain.contains("• Top item"))
    #expect(plain.contains("◦ Nested item"))
    #expect(plain.contains("▪ Deep item"))

    let codeRun = formatted.runs.first { run in
      String(formatted[run.range].characters) == "code"
    }
    #expect(codeRun?.backgroundColor != nil)
  }

  @Test("Selectable Markdown uses tab-stopped lists, custom blockquote/rule/code attributes, and clean trailing spacing")
  @MainActor
  func selectableMarkdownUnifiedTypographyAndSpacing() {
    let markdown = """
    Intro paragraph.

    - Outer item
      - Inner item
        - Deep item

    After list.

    > Quoted line one
    > Quoted line two

    ---

    Use `swift test` here.
    """

    let style = MacSelectableMarkdownBuilder.Style(
      textSize: 15,
      muted: false,
      isDark: true,
      themeID: .githubDarkDimmed,
      textColor: .labelColor,
      mutedColor: .secondaryLabelColor,
      accentColor: .controlAccentColor,
      codeBackgroundColor: .quaternaryLabelColor,
      separatorColor: .separatorColor,
      findQuery: "",
      activeFindOccurrence: nil
    )

    let attributed = MacSelectableMarkdownBuilder.attributedString(
      for: markdown,
      style: style
    )
    let text = attributed.string
    let nsText = text as NSString

    // Nested bullets use tab stops and stepped markers without misaligned spaces.
    #expect(text.contains("•\tOuter item"))
    #expect(text.contains("◦\tInner item"))
    #expect(text.contains("▪\tDeep item"))

    // Blockquotes do not inject literal "▎ " glyphs, and carry the custom decoration attribute.
    #expect(!text.contains("▎"))
    let quoteRange = nsText.range(of: "Quoted line one")
    #expect(quoteRange.location != NSNotFound)
    #expect(
      attributed.attribute(
        MacSelectableMarkdownBuilder.blockquoteAttributeKey,
        at: quoteRange.location,
        effectiveRange: nil
      ) != nil
    )

    // Thematic breaks do not inject stubby Unicode dashes, and carry the custom rule attribute.
    #expect(!text.contains("────"))
    var foundRuleAttribute = false
    attributed.enumerateAttribute(
      MacSelectableMarkdownBuilder.thematicBreakAttributeKey,
      in: NSRange(location: 0, length: attributed.length),
      options: []
    ) { value, _, _ in
      if (value as? Bool) == true {
        foundRuleAttribute = true
      }
    }
    #expect(foundRuleAttribute)

    // Inline code uses custom rounded-pill attribute instead of raw .backgroundColor.
    let codeRange = nsText.range(of: "swift test")
    #expect(codeRange.location != NSNotFound)
    #expect(
      (attributed.attribute(
        MacSelectableMarkdownBuilder.inlineCodeAttributeKey,
        at: codeRange.location,
        effectiveRange: nil
      ) as? Bool) == true
    )
    #expect(attributed.attribute(.backgroundColor, at: codeRange.location, effectiveRange: nil) == nil)

    // Last list item gets wider trailing gap than sibling items; final block clears trailing paragraphSpacing.
    let outerRange = nsText.range(of: "Outer item")
    let deepRange = nsText.range(of: "Deep item")
    let outerPara = attributed.attribute(.paragraphStyle, at: outerRange.location, effectiveRange: nil) as? NSParagraphStyle
    let deepPara = attributed.attribute(.paragraphStyle, at: deepRange.location, effectiveRange: nil) as? NSParagraphStyle
    let finalPara = attributed.attribute(.paragraphStyle, at: attributed.length - 1, effectiveRange: nil) as? NSParagraphStyle
    #expect((outerPara?.tabStops.first?.location ?? 0) == (outerPara?.headIndent ?? -1))
    #expect((deepPara?.paragraphSpacing ?? 0) > (outerPara?.paragraphSpacing ?? 999))
    #expect((finalPara?.paragraphSpacing ?? -1) == 0)

    // Copy as Markdown preserves original quote and thematic break syntax.
    let copied = MacSelectableMarkdownBuilder.markdownSnippet(
      from: attributed,
      selectedRange: NSRange(location: 0, length: attributed.length)
    )
    #expect(copied.contains("> Quoted line one"))
    #expect(copied.contains("---"))
  }

  @Test("ChatMessage citations field decodes backwards-compatibly when omitted")
  func chatMessageCitationsBackwardsCompatibility() throws {
    let original = ChatMessage(
      role: .assistant,
      content: "Hello",
      citations: [ChatCitation(url: "https://example.com", title: "Example")],
      status: .complete
    )
    let encoded = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ChatMessage.self, from: encoded)
    #expect(decoded.citations?.count == 1)
    #expect(decoded.citations?.first?.url == "https://example.com")

    let legacy = ChatMessage(role: .assistant, content: "Legacy", status: .complete)
    let legacyData = try JSONEncoder().encode(legacy)
    let decodedLegacy = try JSONDecoder().decode(ChatMessage.self, from: legacyData)
    #expect(decodedLegacy.citations == nil)
  }

  @Test("User message link detection handles uppercase schemes, ignores filenames, and trims trailing punctuation")
  func userMessageLinkDetectionEdgeCases() {
    let prompt = "Check (HTTPS://SWIFT.ORG/docs). Also edit README.md and App.swift, or visit www.apple.com/macos!"
    let matches = MacUserMessageTextSupport.linkMatches(in: prompt)

    #expect(matches.count == 2)
    #expect(matches[0].url.absoluteString == "HTTPS://SWIFT.ORG/docs")
    #expect(matches[1].url.absoluteString == "https://www.apple.com/macos")
  }

  @Test("Parses GFM callouts and HTML details disclosures and extracts links from both")
  func calloutAndDetailsParsing() {
    let text = """
    > [!WARNING]
    > Check [Apple Docs](https://developer.apple.com) before migrating.
    > Second line of warning.

    <details>
    <summary>Advanced Configuration</summary>

    See https://swift.org/package-manager for details.
    </details>
    """

    let blocks = MacAnswerContentParser.parse(text)
    #expect(blocks.count == 2)

    guard case .callout(let kind, let calloutBody) = blocks[0] else {
      Issue.record("Expected callout block")
      return
    }
    #expect(kind == .warning)
    #expect(calloutBody.contains("Apple Docs"))
    #expect(calloutBody.contains("Second line"))

    guard case .details(let summary, let detailsBody, let isComplete) = blocks[1] else {
      Issue.record("Expected details block")
      return
    }
    #expect(summary == "Advanced Configuration")
    #expect(detailsBody.contains("swift.org/package-manager"))
    #expect(isComplete)

    let sources = MacAnswerContentParser.sources(in: blocks)
    #expect(sources.count == 2)
    #expect(sources[0].url.absoluteString == "https://developer.apple.com")
    #expect(sources[1].url.absoluteString == "https://swift.org/package-manager")

    let streamingSplit = MacAnswerContentParser.splitStreamingSource(
      "Intro paragraph.\n\n<details>\n<summary>Logs</summary>\nLine 1"
    )
    #expect(streamingSplit.stable.contains("Intro paragraph."))
    #expect(streamingSplit.tail.contains("<details>"))
  }

  @Test("Sandboxed HTML and SVG artifact preview enforces strict CSP")
  func sandboxedArtifactPreviewSupport() {
    #expect(MacArtifactPreviewSupport.kind(for: "html", content: "<h1>Hi</h1>") == .html)
    #expect(MacArtifactPreviewSupport.kind(for: "svg", content: "<svg></svg>") == .svg)
    #expect(MacArtifactPreviewSupport.kind(for: "xml", content: "<svg viewBox='0 0 10 10'></svg>") == .svg)
    #expect(MacArtifactPreviewSupport.kind(for: "swift", content: "let x = 1") == nil)

    let fragmentDoc = MacArtifactPreviewSupport.sandboxedDocument(
      for: "<p>Hello</p>",
      kind: .html,
      isDark: true
    )
    #expect(fragmentDoc.contains("Content-Security-Policy"))
    #expect(fragmentDoc.contains("default-src 'none'"))
    #expect(fragmentDoc.contains("<p>Hello</p>"))

    let fullDoc = MacArtifactPreviewSupport.sandboxedDocument(
      for: "<html><head><title>Demo</title></head><body>Hi</body></html>",
      kind: .html,
      isDark: false
    )
    #expect(fullDoc.contains("Content-Security-Policy"))
    #expect(fullDoc.contains("<title>Demo</title>"))

    let svgDoc = MacArtifactPreviewSupport.sandboxedDocument(
      for: "<svg width=\"20\" height=\"20\"></svg>",
      kind: .svg,
      isDark: false
    )
    #expect(svgDoc.contains("Content-Security-Policy"))
    #expect(svgDoc.contains("<svg width=\"20\" height=\"20\"></svg>"))
  }

  @Test("JSON syntax highlighter preserves text for valid JSON and plain text")
  func jsonSyntaxHighlighterPreservesContent() {
    let payload = """
    {
      "query": "swift 6",
      "limit": 10,
      "ok": true,
      "error": null
    }
    """
    let highlighted = MacJSONSyntaxHighlighter.highlight(
      payload,
      isDark: true,
      accentColor: .accentColor,
      textColor: .primary,
      mutedColor: .secondary
    )
    #expect(String(highlighted.characters) == payload)

    let plain = "plain tool output"
    let plainResult = MacJSONSyntaxHighlighter.highlight(
      plain,
      isDark: false,
      accentColor: .accentColor,
      textColor: .primary,
      mutedColor: .secondary
    )
    #expect(String(plainResult.characters) == plain)
  }

  @Test("Parses GFM footnote blocks, preserves multi-line continuations, ignores code, and extracts sources")
  func gfmFootnoteParsingAndSourceExtraction() {
    let text = """
    Swift 6 enables strict concurrency[^1] with actors[^note].

    ```markdown
    [^9]: Inside fenced code block
    ```

        [^8]: Inside 4-space indented code

    **Footnotes / Sources:**
    [^1]: Swift Language Guide - *Concurrency*: https://docs.swift.org/swift-book/

    [^note]: Actors isolate mutable state.
      Continued explanation with [Apple Docs](https://developer.apple.com/swift/).
    """

    let blocks = MacAnswerContentParser.parse(text)
    let footnoteBlocks = blocks.compactMap { block -> [MacParsedFootnote]? in
      if case .footnotes(let items) = block { return items }
      return nil
    }
    #expect(footnoteBlocks.count == 1)
    let footnotes = footnoteBlocks[0]
    #expect(footnotes.count == 2)
    #expect(footnotes[0].label == "1")
    #expect(footnotes[0].body.contains("https://docs.swift.org/swift-book/"))
    #expect(footnotes[0].rawMarkdown.hasPrefix("[^1]:"))
    #expect(footnotes[1].label == "note")
    #expect(footnotes[1].body.contains("Actors isolate mutable state."))
    #expect(footnotes[1].body.contains("Continued explanation"))

    let sources = MacAnswerContentParser.sources(in: blocks)
    #expect(sources.count == 2)
    #expect(sources[0].url.absoluteString == "https://docs.swift.org/swift-book/")
    #expect(sources[1].url.absoluteString == "https://developer.apple.com/swift/")

    let groupedSplit = MacAnswerContentParser.splitStreamingSource(
      "Intro paragraph.\n\n[^1]: First note.\n\n    Continued note.\n\n[^2]: Second note."
    )
    #expect(groupedSplit.stable == "Intro paragraph.\n\n")
    #expect(groupedSplit.tail.contains("[^1]: First note."))
    #expect(groupedSplit.tail.contains("[^2]: Second note."))

    let finalizedSplit = MacAnswerContentParser.splitStreamingSource(
      "[^1]: First note.\n\nNext paragraph."
    )
    #expect(finalizedSplit.stable.contains("[^1]: First note."))
    #expect(finalizedSplit.tail == "Next paragraph.")
  }

  @Test("Inline footnote references render as raised superscripts outside code and preserve raw Markdown on copy")
  @MainActor
  func inlineFootnoteSuperscriptStylingAndCopyAsMarkdown() {
    let prose = "See Descript[^1] and CapCut[^note], but keep `[^2]` literal."

    // Streaming tail path
    let tailFormatted = MacStreamingTailFormatter.formattedAttributedString(
      prose,
      textSize: 15,
      foregroundColor: .primary,
      mutedColor: .secondary,
      accentColor: .accentColor,
      codeBackground: .gray.opacity(0.1)
    )
    let tailPlain = String(tailFormatted.characters)
    #expect(!tailPlain.contains("[^1]"))
    #expect(!tailPlain.contains("[^note]"))
    #expect(tailPlain.contains("\u{2009}1"))
    #expect(tailPlain.contains("\u{2009}note"))
    #expect(tailPlain.contains("[^2]"))

    let supRun = tailFormatted.runs.first { run in
      String(tailFormatted[run.range].characters) == "\u{2009}1"
    }
    #expect((supRun?.baselineOffset ?? 0) > 0)

    // Completed selectable Markdown prose path
    let style = MacSelectableMarkdownBuilder.Style(
      textSize: 15,
      muted: false,
      isDark: true,
      themeID: .githubDarkDimmed,
      textColor: .labelColor,
      mutedColor: .secondaryLabelColor,
      accentColor: .controlAccentColor,
      codeBackgroundColor: .quaternaryLabelColor,
      separatorColor: .separatorColor,
      findQuery: "",
      activeFindOccurrence: nil
    )
    let attributed = MacSelectableMarkdownBuilder.attributedString(
      for: prose,
      style: style
    )
    let nsText = attributed.string as NSString
    #expect(!attributed.string.contains("[^1]"))
    #expect(!attributed.string.contains("[^note]"))
    #expect(attributed.string.contains("\u{2009}1"))
    #expect(attributed.string.contains("\u{2009}note"))
    #expect(attributed.string.contains("[^2]"))

    let supRange = nsText.range(of: "\u{2009}1")
    #expect(supRange.location != NSNotFound)
    let baseline = attributed.attribute(.baselineOffset, at: supRange.location, effectiveRange: nil) as? CGFloat
    #expect((baseline ?? 0) > 0)

    let copied = MacSelectableMarkdownBuilder.markdownSnippet(
      from: attributed,
      selectedRange: NSRange(location: 0, length: attributed.length)
    )
    #expect(copied.contains("See Descript[^1]"))
    #expect(copied.contains("`[^2]`"))
  }

  @Test("List bullets normalize 4-space nesting cleanly and render bolder/larger at primary-tinted contrast")
  @MainActor
  func listBulletHierarchyAndVisualWeight() {
    #expect(MacSelectableMarkdownBuilder.normalizedListIndentLevels(for: [0, 4, 4, 8, 0]) == [0, 1, 1, 2, 0])
    #expect(MacSelectableMarkdownBuilder.normalizedListIndentLevels(for: [0, 2, 4, 2, 0]) == [0, 1, 2, 1, 0])

    let markdown = """
    - Top level
        - Four-space child
            - Eight-space leaf
    """

    // Streaming tail normalizes 4-space nesting identically to selectable Markdown.
    let tailFormatted = MacStreamingTailFormatter.formattedAttributedString(
      markdown,
      textSize: 15,
      foregroundColor: .primary,
      mutedColor: .secondary,
      accentColor: .accentColor,
      codeBackground: .gray.opacity(0.1)
    )
    let tailPlain = String(tailFormatted.characters)
    #expect(tailPlain.contains("• Top level"))
    #expect(tailPlain.contains("◦ Four-space child"))
    #expect(tailPlain.contains("▪ Eight-space leaf"))

    // Selectable Markdown renders level-0 bullet larger than body text and normalizes 4-space nesting.
    let style = MacSelectableMarkdownBuilder.Style(
      textSize: 15,
      muted: false,
      isDark: true,
      themeID: .githubDarkDimmed,
      textColor: .white,
      mutedColor: .gray,
      accentColor: .controlAccentColor,
      codeBackgroundColor: .quaternaryLabelColor,
      separatorColor: .separatorColor,
      findQuery: "",
      activeFindOccurrence: nil
    )
    let attributed = MacSelectableMarkdownBuilder.attributedString(
      for: markdown,
      style: style
    )
    let text = attributed.string
    #expect(text.contains("•\tTop level"))
    #expect(text.contains("◦\tFour-space child"))
    #expect(text.contains("▪\tEight-space leaf"))

    let bulletRange = (text as NSString).range(of: "•")
    #expect(bulletRange.location != NSNotFound)
    let bulletFont = attributed.attribute(.font, at: bulletRange.location, effectiveRange: nil) as? NSFont
    #expect((bulletFont?.pointSize ?? 0) > style.textSize)

    let bulletPara = attributed.attribute(.paragraphStyle, at: bulletRange.location, effectiveRange: nil) as? NSParagraphStyle
    let bulletColumn = (bulletPara?.headIndent ?? 0) - (bulletPara?.firstLineHeadIndent ?? 0)
    #expect(bulletColumn == round(style.textSize * 0.95))

    // Multi-digit ordered lists right-align single-digit numbers to share the same text column.
    let orderedMarkdown = (1...10).map { "\($0). Step \($0)" }.joined(separator: "\n")
    let orderedAttr = MacSelectableMarkdownBuilder.attributedString(
      for: orderedMarkdown,
      style: style
    )
    let orderedText = orderedAttr.string as NSString
    let firstRange = orderedText.range(of: "1.")
    let tenthRange = orderedText.range(of: "10.")
    let firstPara = orderedAttr.attribute(.paragraphStyle, at: firstRange.location, effectiveRange: nil) as? NSParagraphStyle
    let tenthPara = orderedAttr.attribute(.paragraphStyle, at: tenthRange.location, effectiveRange: nil) as? NSParagraphStyle
    #expect((firstPara?.headIndent ?? 0) == (tenthPara?.headIndent ?? -1))
    #expect((firstPara?.firstLineHeadIndent ?? 0) > (tenthPara?.firstLineHeadIndent ?? 999))
  }

  @Test("O(1) LRU cache promotes accessed entries, tracks cost deltas, and ignores oversized items")
  @MainActor
  func lruCachePromotionAndCostEviction() {
    let cache = MacLRUCache<String, Int>(countLimit: 3, costLimit: 10)
    cache.insert(1, for: "a", cost: 4)
    cache.insert(2, for: "b", cost: 4)
    #expect(cache.count == 2)
    #expect(cache.totalCost == 8)

    // Promote "a" so "b" becomes least-recently-used.
    #expect(cache.value(for: "a") == 1)

    // Inserting "c" (cost 4) pushes totalCost to 12 > 10, evicting "b" instead of "a".
    let evicted = cache.insert(3, for: "c", cost: 4)
    #expect(evicted == [2])
    #expect(cache.value(for: "a") == 1)
    #expect(cache.value(for: "b") == nil)
    #expect(cache.value(for: "c") == 3)
    #expect(cache.totalCost == 8)

    // Updating an existing key adjusts totalCost in place without duplicating nodes.
    cache.insert(30, for: "c", cost: 2)
    #expect(cache.count == 2)
    #expect(cache.totalCost == 6)
    #expect(cache.value(for: "c") == 30)

    // Oversized item (> costLimit) is rejected without evicting existing entries.
    let oversizedEvicted = cache.insert(99, for: "huge", cost: 25)
    #expect(oversizedEvicted.isEmpty)
    #expect(cache.value(for: "huge") == nil)
    #expect(cache.value(for: "a") == 1)
    #expect(cache.value(for: "c") == 30)
  }

  @Test("Selectable Markdown render cache uses LRU eviction for rendered entries and heights")
  @MainActor
  func selectableMarkdownRenderCacheLRU() {
    let cache = MacSelectableMarkdownRenderCache(
      entryLimit: 2,
      entryCharacterLimit: 40,
      heightLimit: 2
    )
    let entryA = MacSelectableMarkdownRenderCache.makeEntry(
      from: NSAttributedString(string: "Alpha paragraph")
    )
    let entryB = MacSelectableMarkdownRenderCache.makeEntry(
      from: NSAttributedString(string: "Beta paragraph")
    )
    let entryC = MacSelectableMarkdownRenderCache.makeEntry(
      from: NSAttributedString(string: "Gamma paragraph")
    )

    cache.store(entryA, for: AnyHashable("a"))
    cache.store(entryB, for: AnyHashable("b"))
    // Touch "a" so "b" is evicted when "c" arrives.
    #expect(cache.entry(for: AnyHashable("a")) != nil)
    cache.store(entryC, for: AnyHashable("c"))
    #expect(cache.entry(for: AnyHashable("a")) != nil)
    #expect(cache.entry(for: AnyHashable("b")) == nil)
    #expect(cache.entry(for: AnyHashable("c")) != nil)

    cache.storeHeight(42, for: AnyHashable("a"), widthHalfPoints: 1_200)
    cache.storeHeight(64, for: AnyHashable("b"), widthHalfPoints: 1_200)
    #expect(cache.height(for: AnyHashable("a"), widthHalfPoints: 1_200) == 42)
    cache.storeHeight(88, for: AnyHashable("c"), widthHalfPoints: 1_200)
    #expect(cache.height(for: AnyHashable("a"), widthHalfPoints: 1_200) == 42)
    #expect(cache.height(for: AnyHashable("b"), widthHalfPoints: 1_200) == nil)
    #expect(cache.height(for: AnyHashable("c"), widthHalfPoints: 1_200) == 88)
  }

  @Test("Selectable text container pool reuses laid-out views by key, defers attached releases, and cleans state")
  @MainActor
  func selectableTextContainerPoolLifecycle() {
    final class DummyDelegate: NSObject, NSTextViewDelegate {}

    let pool = MacSelectableTextContainerPool(
      countLimit: 2,
      characterCostLimit: 10_000,
      maxSingleContainerCharacters: 500,
      spareLimit: 2
    )
    let style = MacSelectableMarkdownBuilder.Style(
      textSize: 15,
      muted: false,
      isDark: false,
      themeID: .githubLight,
      textColor: .labelColor,
      mutedColor: .secondaryLabelColor,
      accentColor: .controlAccentColor,
      codeBackgroundColor: .quaternaryLabelColor,
      separatorColor: .separatorColor,
      findQuery: "",
      activeFindOccurrence: nil
    )

    let keyA = AnyHashable("prose-a")
    let containerA = pool.acquire(forKey: keyA)
    let entryA = MacSelectableMarkdownRenderCache.makeEntry(
      from: MacSelectableMarkdownBuilder.attributedString(
        for: "Hello **world** with `code`.",
        style: style
      )
    )
    let delegate = DummyDelegate()
    containerA.lastRenderKey = keyA
    containerA.textView.delegate = delegate
    containerA.setRenderedEntry(entryA, style: style)
    containerA.frame = NSRect(x: 12, y: 8, width: 640, height: 32)
    containerA.layoutSubtreeIfNeeded()
    containerA.textView.setSelectedRange(NSRange(location: 0, length: 5))
    #expect(containerA.lastLayoutWidth == 640)

    // While containerA is still mounted, a second acquire for keyA must return a distinct instance.
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 100))
    host.addSubview(containerA)
    let concurrentSameKey = pool.acquire(forKey: keyA)
    #expect(concurrentSameKey !== containerA)

    // Releasing while still attached to a superview defers pooling until detached.
    pool.release(containerA)
    #expect(containerA.textView.delegate == nil)
    #expect(containerA.textView.selectedRange().length == 0)
    #expect(pool.pendingCount == 1)
    #expect(pool.keyedCount == 0)

    // Once SwiftUI detaches the view from its host, it transitions into the keyed pool automatically.
    containerA.removeFromSuperview()
    #expect(pool.pendingCount == 0)
    #expect(pool.keyedCount == 1)

    // Scrolling back into view reuses the exact laid-out container without resetting layout width.
    let remountedA = pool.acquire(forKey: keyA)
    #expect(remountedA === containerA)
    #expect(remountedA.lastRenderKey == keyA)
    #expect(remountedA.lastLayoutWidth == 640)
    #expect(pool.keyedCount == 0)

    // Return A, then insert B and C while promoting A so LRU eviction moves B into cleared spares.
    pool.release(remountedA)
    let keyB = AnyHashable("prose-b")
    let containerB = pool.acquire(forKey: keyB)
    containerB.lastRenderKey = keyB
    containerB.setRenderedEntry(entryA, style: style)
    pool.release(containerB)

    // Promote A so B is LRU, then release C to evict B into spareContainers.
    let touchedA = pool.acquire(forKey: keyA)
    #expect(touchedA === containerA)
    pool.release(touchedA)

    let keyC = AnyHashable("prose-c")
    let containerC = concurrentSameKey
    containerC.lastRenderKey = keyC
    containerC.setRenderedEntry(entryA, style: style)
    pool.release(containerC)

    #expect(pool.keyedCount == 2)
    #expect(pool.spareCount == 1)
    #expect(containerB.characterCost == 0)
    #expect(containerB.lastRenderKey == nil)

    // A brand-new key reuses the evicted spare instead of allocating a fresh TextKit stack.
    let reusedFromSpare = pool.acquire(forKey: AnyHashable("prose-d"))
    #expect(reusedFromSpare === containerB)
  }
}
