import CoreGraphics
import Foundation
import Testing

@testable import BYOKmac

@Suite("macOS answer content parsing")
struct MacAnswerContentParserTests {
  @Test("Long outer fence keeps shorter nested fence as code")
  func preservesNestedShorterFence() {
    let text = """
    ````markdown
    # Example
    ```swift
    let value = 42
    ```
    ````
    """

    #expect(
      MacAnswerContentParser.parse(text) == [
        .code(
          language: "markdown",
          content: "# Example\n```swift\nlet value = 42\n```",
          isComplete: true
        )
      ]
    )
  }

  @Test("Fence-like code text does not close a block")
  func rejectsFenceWithTrailingText() {
    let text = """
    ```swift
    let value = 42
    ```example
    """

    #expect(
      MacAnswerContentParser.parse(text) == [
        .code(
          language: "swift",
          content: "let value = 42\n```example",
          isComplete: false
        )
      ]
    )
  }

  @Test("Open code fence remains entirely mutable")
  func openCodeFenceStaysInTail() {
    let split = MacAnswerContentParser.splitStreamingSource(
      "Intro.\n\n```swift\nlet value = 42"
    )

    #expect(split.stable == "Intro.\n\n")
    #expect(split.tail == "```swift\nlet value = 42")
    #expect(
      MacAnswerContentParser.parse(split.tail) == [
        .code(language: "swift", content: "let value = 42", isComplete: false)
      ]
    )
  }

  @Test("Closed code fence becomes stable")
  func closedCodeFenceBecomesStable() {
    let source = "```swift\nlet value = 42\n```\n"
    let split = MacAnswerContentParser.splitStreamingSource(source)

    #expect(split.stable == source)
    #expect(split.tail.isEmpty)
  }

  @Test("Open display math remains mutable until delimiter closes")
  func displayMathStaysInTail() {
    let open = MacAnswerContentParser.splitStreamingSource("$$\nE = mc^2")
    #expect(open.stable.isEmpty)
    #expect(open.tail == "$$\nE = mc^2")

    let closedSource = "$$\nE = mc^2\n$$\n"
    let closed = MacAnswerContentParser.splitStreamingSource(closedSource)
    #expect(closed.stable == closedSource)
    #expect(closed.tail.isEmpty)
  }

  @Test("Active GFM table remains one mutable tail")
  func tableStaysMutable() {
    let active = """
    | Name | Score |
    | :--- | ---: |
    | Ada | 10 |
    """
    let activeSplit = MacAnswerContentParser.splitStreamingSource(active)
    #expect(activeSplit.stable.isEmpty)
    #expect(activeSplit.tail == active)

    let followed = active + "\n\nNext paragraph"
    let followedSplit = MacAnswerContentParser.splitStreamingSource(followed)
    #expect(followedSplit.stable == active + "\n\n")
    #expect(followedSplit.tail == "Next paragraph")
  }

  @Test("Inline math balance ignores escaped dollars")
  func inlineMathBalance() {
    #expect(MacAnswerContentParser.isLikelyBalancedInlineMath("Price: \\$9 and $x$"))
    #expect(!MacAnswerContentParser.isLikelyBalancedInlineMath("Value: $x"))
  }

  @Test("Does not mistake currency ranges for inline math and splits math paragraphs cleanly")
  func inlineMathAndParagraphSplitting() {
    #expect(!MacAnswerContentParser.containsInlineMath("Tickets cost $10-$20 each."))
    #expect(!MacAnswerContentParser.containsInlineMath("Compare $5/$10 tiers."))
    #expect(!MacAnswerContentParser.containsInlineMath("Between $5 and $10."))
    #expect(!MacAnswerContentParser.containsInlineMath("Price: \\$9.99"))
    #expect(MacAnswerContentParser.containsInlineMath("Value $x$ is positive."))
    #expect(MacAnswerContentParser.containsInlineMath("Euler: $e^{i\\pi}+1=0$"))
    #expect(MacAnswerContentParser.containsInlineMath("Use \\(x + y\\) here"))

    let mixed = """
    # Physics

    Einstein showed $E = mc^2$ in 1905.

    - See **notes** at [docs](https://example.com) and $a + b$
    """
    let segments = MacAnswerContentParser.splitMarkdownForInlineMath(mixed)
    #expect(segments.count == 3)
    #expect(segments[0] == MacMarkdownMathSegment(text: "# Physics", useLaTeX: false))
    #expect(
      segments[1] == MacMarkdownMathSegment(
        text: "Einstein showed $E = mc^2$ in 1905.",
        useLaTeX: true
      )
    )
    #expect(
      segments[2] == MacMarkdownMathSegment(
        text: "- See **notes** at [docs](https://example.com) and $a + b$",
        useLaTeX: false
      )
    )
  }

  @Test("Recognizes Mermaid language aliases and attribute suffixes")
  func recognizesMermaid() {
    #expect(MacAnswerContentParser.isMermaidLanguage("mermaid"))
    #expect(MacAnswerContentParser.isMermaidLanguage("MMD"))
    #expect(MacAnswerContentParser.isMermaidLanguage("mermaid-js"))
    #expect(MacAnswerContentParser.isMermaidLanguage("mermaidjs"))
    #expect(MacAnswerContentParser.isMermaidLanguage("mermaid{theme=dark}"))
    #expect(MacAnswerContentParser.isMermaidLanguage("mermaid,title=Flow"))
    #expect(MacAnswerContentParser.isMermaidLanguage("mermaid;align=center"))
    #expect(!MacAnswerContentParser.isMermaidLanguage("swift"))
    #expect(!MacAnswerContentParser.isMermaidLanguage("markdown"))
  }

  @Test("Parses GFM tables with alignments, escaped pipes, code pipes, <br>, and ragged rows")
  func parsesRichGFMTables() {
    let text = """
    Summary:
    | # | Expression | Notes |
    | ---: | :---: | :--- |
    | 1 | `a | b` | Bitwise OR<br>Inline `<br>` stays literal |
    | 2 | `foo \\| bar` | Escaped \\| pipe | Extra ignored |
    | 3 | |
    """

    let blocks = MacAnswerContentParser.parse(text)
    #expect(blocks.count == 2)
    #expect(blocks[0] == .markdown("Summary:"))

    guard case .table(let table) = blocks[1] else {
      Issue.record("Expected second block to be a parsed table")
      return
    }
    #expect(table.headers == ["#", "Expression", "Notes"])
    #expect(table.alignments == [.trailing, .center, .leading])
    #expect(table.rows.count == 3)
    #expect(table.rows[0] == ["1", "`a | b`", "Bitwise OR\nInline `<br>` stays literal"])
    #expect(table.rows[1] == ["2", "`foo | bar`", "Escaped | pipe"])
    #expect(table.rows[2] == ["3", "", ""])
    #expect(
      table.tsvText
        == "#\tExpression\tNotes\n1\ta | b\tBitwise OR Inline <br> stays literal\n2\tfoo | bar\tEscaped | pipe\n3\t\t"
    )
  }

  @Test("Parses pipeless tables, multiple tables with distinct alignments, and header-only tables")
  func parsesPipelessAndMultipleTables() {
    let text = """
    Formula | Meaning
    --- | ---:
    $E = mc^2$ | Mass-energy

    | | Col A | Col B |
    | --- | :---: | :---: |
    | Row 1 | X | Y |

    | Only Header |
    | :---: |
    """

    let blocks = MacAnswerContentParser.parse(text)
    #expect(blocks.count == 3)

    guard case .table(let first) = blocks[0],
      case .table(let second) = blocks[1],
      case .table(let third) = blocks[2]
    else {
      Issue.record("Expected three separate table blocks")
      return
    }

    #expect(first.headers == ["Formula", "Meaning"])
    #expect(first.alignments == [.leading, .trailing])
    #expect(first.rows == [["$E = mc^2$", "Mass-energy"]])
    #expect(MacAnswerContentParser.shouldRenderCellAsInlineMath("$E = mc^2$"))
    #expect(!MacAnswerContentParser.shouldRenderCellAsInlineMath("**$E = mc^2$**"))

    #expect(second.headers == ["", "Col A", "Col B"])
    #expect(second.alignments == [.leading, .center, .center])
    #expect(second.rows == [["Row 1", "X", "Y"]])

    #expect(third.headers == ["Only Header"])
    #expect(third.alignments == [.center])
    #expect(third.rows.isEmpty)
  }

  @Test("Rejects malformed table delimiters and ignores tables inside fenced code")
  func rejectsInvalidTables() {
    let text = """
    A | B
    :::---::: | ---
    1 | 2

    ```markdown
    | In Code | Ignored |
    | --- | --- |
    | 1 | 2 |
    ```

    | Valid | Column |
    | --- | ---: |
    | A | 1 |
    """

    let blocks = MacAnswerContentParser.parse(text)
    let tables = blocks.compactMap { block -> MacParsedMarkdownTable? in
      guard case .table(let table) = block else { return nil }
      return table
    }
    #expect(tables.count == 1)
    #expect(tables[0].headers == ["Valid", "Column"])
    #expect(tables[0].alignments == [.leading, .trailing])
  }

  @Test("Computes content-aware and CJK-aware table column widths")
  func computesAdaptiveTableColumnWidths() {
    let compactTable = MacParsedMarkdownTable(
      headers: ["#", "Feature", "Description"],
      alignments: [.trailing, .leading, .leading],
      rows: [
        ["1", "Offline", "Runs models locally with Ollama and LM Studio without cloud calls."],
        ["2", "Export", "Save full conversations to Markdown."],
      ],
      rawMarkdown: ""
    )

    let metrics = MacMarkdownTableLayout.compute(
      for: compactTable,
      availableWidth: 420,
      fontSize: 14,
      fillsWidth: true
    )
    #expect(metrics.columnWidths.count == 3)
    #expect(metrics.columnWidths[0] < metrics.columnWidths[2])
    #expect(metrics.columnWidths[2] > 180)

    let cjkTable = MacParsedMarkdownTable(
      headers: ["ASCII", "日本語"],
      alignments: [.leading, .leading],
      rows: [["abcde", "日本語の長い文章"]],
      rawMarkdown: ""
    )
    let cjkMetrics = MacMarkdownTableLayout.compute(
      for: cjkTable,
      availableWidth: 600,
      fontSize: 14,
      fillsWidth: false
    )
    #expect(cjkMetrics.columnWidths[1] > cjkMetrics.columnWidths[0])

    let wideTable = MacParsedMarkdownTable(
      headers: ["Metric", "Claude", "GPT", "Gemini", "DeepSeek", "Llama"],
      alignments: Array(repeating: .leading, count: 6),
      rows: [["Context Window", "200K tokens", "1M tokens", "1M tokens", "128K tokens", "128K tokens"]],
      rawMarkdown: ""
    )
    let wideMetrics = MacMarkdownTableLayout.compute(
      for: wideTable,
      availableWidth: 360,
      fontSize: 14,
      fillsWidth: true
    )
    #expect(wideMetrics.overflowsViewport)
    #expect(wideMetrics.totalWidth > 360)
  }

  @Test("Classifies Mermaid diagrams, strips YAML frontmatter, flags unsupported types, and sizes proportionally")
  func mermaidDiagramSupportHelpers() {
    let frontmatterFlow = """
    ---
    title: "Request Pipeline"
    ---
    %% comment before header
    flowchart LR
      A --> B
    """
    let flowAnalysis = MacMermaidDiagramSupport.analyze(frontmatterFlow)
    #expect(!flowAnalysis.isEmpty)
    #expect(flowAnalysis.title == "Request Pipeline")
    #expect(flowAnalysis.kindLabel == "FLOWCHART")
    #expect(flowAnalysis.headerLabel == "FLOWCHART · Request Pipeline")
    #expect(flowAnalysis.unsupportedKindName == nil)
    #expect(!flowAnalysis.renderSource.contains("---"))
    #expect(flowAnalysis.renderSource.contains("flowchart LR"))

    let seqAnalysis = MacMermaidDiagramSupport.analyze(
      "%%{init: {'theme': 'dark'}}%%\nsequenceDiagram\n  Alice->>Bob: Hi"
    )
    #expect(seqAnalysis.kindLabel == "SEQUENCE")
    #expect(seqAnalysis.unsupportedKindName == nil)

    let ganttAnalysis = MacMermaidDiagramSupport.analyze(
      "gantt\n  title Roadmap\n  section A\n  Task :a1, 2026-01-01, 5d"
    )
    #expect(ganttAnalysis.kindLabel == "GANTT")
    #expect(ganttAnalysis.unsupportedKindName == "Gantt charts")

    let pieAnalysis = MacMermaidDiagramSupport.analyze(
      "pie title Pets\n  \"Dogs\" : 60\n  \"Cats\" : 40"
    )
    #expect(pieAnalysis.kindLabel == "PIE CHART")
    #expect(pieAnalysis.unsupportedKindName == "Pie charts")

    let c4Analysis = MacMermaidDiagramSupport.analyze("C4Context\n  Person(user, \"User\")")
    #expect(c4Analysis.kindLabel == "C4 DIAGRAM")
    #expect(c4Analysis.unsupportedKindName == "C4 diagrams")

    let emptyAnalysis = MacMermaidDiagramSupport.analyze("   \n\t  ")
    #expect(emptyAnalysis.isEmpty)

    let wideHeight = MacMermaidDiagramSupport.inlineHeight(
      for: CGRect(x: 0, y: 0, width: 1200, height: 280),
      availableWidth: 340
    )
    #expect(wideHeight == MacMermaidDiagramSupport.minInlineHeight)

    let mediumHeight = MacMermaidDiagramSupport.inlineHeight(
      for: CGRect(x: 0, y: 0, width: 320, height: 260),
      availableWidth: 340
    )
    #expect(mediumHeight == 280)

    let tallHeight = MacMermaidDiagramSupport.inlineHeight(
      for: CGRect(x: 0, y: 0, width: 300, height: 900),
      availableWidth: 340
    )
    #expect(tallHeight == MacMermaidDiagramSupport.maxInlineHeight)

    #expect(
      MacMermaidDiagramSupport.inlineHeight(for: .zero, availableWidth: 340)
        == MacMermaidDiagramSupport.defaultInlineHeight
    )

    #expect(
      MacMermaidDiagramSupport.renderScale(
        for: CGSize(width: 600, height: 400),
        desiredScale: 3.0
      ) == 3.0
    )
    let hugeScale = MacMermaidDiagramSupport.renderScale(
      for: CGSize(width: 3200, height: 1200),
      desiredScale: 3.0,
      maxPixelDimension: 4096
    )
    #expect(hugeScale < 1.3)
    #expect(hugeScale >= 1.0)
  }

  @Test("Validates and decodes response image URLs and data URIs")
  func responseImageSupport() throws {
    let httpsURL = try #require(URL(string: "https://example.com/photo.png"))
    #expect(MacMarkdownImageSupport.isSupportedURL(httpsURL))
    let meta = MacMarkdownImageSupport.metadata(for: httpsURL)
    #expect(meta.filename == "photo.png")
    #expect(meta.mimeType == "image/png")

    let hostless = try #require(URL(string: "https://"))
    #expect(!MacMarkdownImageSupport.isSupportedURL(hostless))

    let payload = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
    let dataURL = try #require(URL(string: "data:image/png;base64,\(payload)"))
    #expect(MacMarkdownImageSupport.isSupportedURL(dataURL))
    let decoded = try #require(MacMarkdownImageSupport.decodeDataURI(dataURL))
    #expect(decoded.data == Data([0x89, 0x50, 0x4E, 0x47]))
    #expect(decoded.filename == "image.png")
    #expect(decoded.mimeType == "image/png")
  }

  @Test("Extracts and deduplicates sources from markdown, bare URLs, and tables while ignoring code and images")
  func extractsAndDeduplicatesSources() {
    let text = """
    Read [Swift](https://swift.org/documentation/) and https://example.com/page.
    Also check www.apple.com/macos, ignore ChatView.swift and README.md.

    Inline code `https://inline-code.example/hidden` and `[CodeLink](https://code-link.example)` stay excluded.
    Images ![Banner](https://cdn.example.com/banner.png) are not citation sources.

    ```text
    https://secret.example/internal
    [Fenced](https://fenced.example/doc)
    ```

    $$
    https://math.example/ignored
    $$

    | Resource | Preview |
    | --- | --- |
    | [Wikipedia](https://en.wikipedia.org/wiki/Swift_(programming_language)) | ![Logo](https://cdn.example.com/logo.png) |

    Duplicates: https://example.com/page#section and [Swift Docs](https://SWIFT.ORG/documentation/).
    """

    let blocks = MacAnswerContentParser.parse(text)
    let sources = MacAnswerContentParser.sources(in: blocks)

    #expect(sources == MacAnswerContentParser.sources(in: text))
    #expect(sources.count == 4)

    #expect(sources[0].displayTitle == "Swift")
    #expect(sources[0].host == "swift.org")
    #expect(sources[0].url.absoluteString == "https://swift.org/documentation/")

    #expect(sources[1].title == nil)
    #expect(sources[1].displayTitle == "example.com")
    #expect(sources[1].url.absoluteString == "https://example.com/page")

    #expect(sources[2].host == "www.apple.com")
    #expect(sources[2].url.path == "/macos")

    #expect(sources[3].displayTitle == "Wikipedia")
    #expect(
      sources[3].url.absoluteString == "https://en.wikipedia.org/wiki/Swift_(programming_language)"
    )
  }

  @Test("Preserves source order, upgrades bare URL title when later linked, enforces limit, and rejects invalid URLs")
  func sourceOrderingTitleUpgradeAndValidation() {
    let text = """
    First https://first.example/ and then [Second](https://second.example/guide).
    Later [First Guide](https://first.example) and [Broken](https://) and [JS](javascript:alert(1)).
    """

    let allSources = MacAnswerContentParser.sources(in: text)
    #expect(allSources.count == 2)
    #expect(allSources[0].url.absoluteString == "https://first.example/")
    #expect(allSources[0].displayTitle == "First Guide")
    #expect(allSources[1].url.absoluteString == "https://second.example/guide")
    #expect(allSources[1].displayTitle == "Second")

    let limited = MacAnswerContentParser.sources(in: text, limit: 1)
    #expect(limited.count == 1)
    #expect(limited[0].url.absoluteString == "https://first.example/")

    if let hostless = URL(string: "https://") {
      #expect(!MacAnswerContentParser.isValidBrowsableURL(hostless))
    }
    if let javascript = URL(string: "javascript:alert(1)") {
      #expect(!MacAnswerContentParser.isValidBrowsableURL(javascript))
    }
    if let valid = URL(string: "https://example.com") {
      #expect(MacAnswerContentParser.isValidBrowsableURL(valid))
    }
  }

  @Test("Cleans formatted link titles, handles title attributes and angle destinations, ignores numeric citation titles, and preserves case-sensitive paths")
  func sourceExtractionEdgeCases() {
    let text = """
    Read [Use `Task` safely](https://swift.org/concurrency) and [**Apple Docs**](https://apple.com "Apple Home").
    Also see [`URLSession`](<https://developer.apple.com/documentation/foundation/urlsession>) and [Upper](HTTPS://DOCS.EXAMPLE.COM/Guide).
    Citation markers [1](https://news.example.com/story?id=42) and [[2]](https://blog.example.com/).
    Emphasized **https://spec.example.com/v2** and <https://ref.example.com/rfc>.
    Case-sensitive short links: https://youtu.be/AbCdEf and https://youtu.be/abcdef.
    Ignored inline code link `[Fake](https://fake.example/nope)` and `![Img](https://img.example/a.png)`.
    """

    let sources = MacAnswerContentParser.sources(in: text)
    #expect(sources.count == 10)

    #expect(sources[0].displayTitle == "Use Task safely")
    #expect(sources[0].displayPath == "/concurrency")
    #expect(sources[0].hasDistinctTitle)

    #expect(sources[1].displayTitle == "Apple Docs")
    #expect(sources[1].url.absoluteString == "https://apple.com")
    #expect(sources[1].displayPath == nil)

    #expect(sources[2].displayTitle == "URLSession")
    #expect(sources[2].url.absoluteString == "https://developer.apple.com/documentation/foundation/urlsession")

    #expect(sources[3].displayTitle == "Upper")
    #expect(sources[3].url.absoluteString == "HTTPS://DOCS.EXAMPLE.COM/Guide")

    #expect(sources[4].title == nil)
    #expect(sources[4].displayTitle == "news.example.com")
    #expect(sources[4].displayPath == "/story?id=42")
    #expect(!sources[4].hasDistinctTitle)

    #expect(sources[5].title == nil)
    #expect(sources[5].displayTitle == "blog.example.com")
    #expect(sources[5].displayPath == nil)

    #expect(sources[6].url.absoluteString == "https://spec.example.com/v2")
    #expect(sources[7].url.absoluteString == "https://ref.example.com/rfc")

    #expect(sources[8].url.absoluteString == "https://youtu.be/AbCdEf")
    #expect(sources[9].url.absoluteString == "https://youtu.be/abcdef")
  }
}
