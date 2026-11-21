import Foundation
import Testing

@testable import BYOKchat

@Suite("Answer content parsing")
struct AnswerContentParserTests {
  @Test("Separates Markdown, code, Mermaid, and display math in order")
  func parsesMixedAnswer() {
    let text = """
    Intro with **Markdown**.

    ```swift
    let value = 42
    ```

    $$
    E = mc^2
    $$

    ```mermaid
    flowchart LR
      A --> B
    ```

    Done.
    """

    #expect(
      AnswerContentParser.parse(text) == [
        .markdown("Intro with **Markdown**."),
        .code(language: "swift", content: "let value = 42"),
        .math("E = mc^2"),
        .code(language: "mermaid", content: "flowchart LR\n  A --> B"),
        .markdown("Done."),
      ]
    )
  }

  @Test("Supports tilde fences and one-line display math")
  func parsesAlternateDelimiters() {
    let text = """
    ~~~python
    print("hello")
    ~~~
    $$x^2 + y^2 = z^2$$
    """

    #expect(
      AnswerContentParser.parse(text) == [
        .code(language: "python", content: "print(\"hello\")"),
        .math("x^2 + y^2 = z^2"),
      ]
    )
  }

  @Test("Extracts and deduplicates sources outside code blocks")
  func extractsSources() {
    let text = """
    Read [Swift](https://swift.org/documentation/) and https://example.com/page.

    ```text
    https://secret.example/internal
    ```

    Duplicate: https://example.com/page#section
    """

    let blocks = AnswerContentParser.parse(text)
    let sources = AnswerContentParser.sources(in: blocks)

    #expect(sources.count == 2)
    #expect(sources[0].displayTitle == "Swift")
    #expect(sources[0].url.absoluteString == "https://swift.org/documentation/")
    #expect(sources[1].url.absoluteString == "https://example.com/page")
  }

  @Test("Detects inline math without treating escaped dollars as equations")
  func detectsInlineMath() {
    #expect(AnswerContentParser.containsInlineMath("Euler: $e^{i\\pi}+1=0$"))
    #expect(AnswerContentParser.containsInlineMath("Use \\(x + y\\) here"))
    #expect(!AnswerContentParser.containsInlineMath("Price: \\$9.99"))
  }

  @Test("Recognizes Mermaid language aliases")
  func recognizesMermaid() {
    #expect(AnswerContentParser.isMermaidLanguage("mermaid"))
    #expect(AnswerContentParser.isMermaidLanguage("MMD"))
    #expect(!AnswerContentParser.isMermaidLanguage("swift"))
  }

  @Test("Supports nested longer code fences and reports unclosed streaming fences")
  func parsesNestedAndUnclosedFences() {
    let nested = """
    ````markdown
    ```swift
    let x = 1
    ```
    ````
    """
    let nestedBlocks = AnswerContentParser.parseDetailed(nested)
    #expect(nestedBlocks.count == 1)
    #expect(nestedBlocks[0].isClosed)
    #expect(
      nestedBlocks[0].block == .code(
        language: "markdown",
        content: "```swift\nlet x = 1\n```"
      )
    )

    let streamingMermaid = """
    ```mermaid
    flowchart LR
      A -->
    """
    let streamingBlocks = AnswerContentParser.parseDetailed(streamingMermaid)
    #expect(streamingBlocks.count == 1)
    #expect(!streamingBlocks[0].isClosed)
    #expect(
      streamingBlocks[0].block == .code(
        language: "mermaid",
        content: "flowchart LR\n  A -->"
      )
    )
  }

  @Test("Does not mistake currency ranges for inline math and splits math paragraphs cleanly")
  func inlineMathAndParagraphSplitting() {
    #expect(!AnswerContentParser.containsInlineMath("Tickets cost $10-$20 each."))
    #expect(!AnswerContentParser.containsInlineMath("Compare $5/$10 tiers."))
    #expect(!AnswerContentParser.containsInlineMath("Between $5 and $10."))
    #expect(AnswerContentParser.containsInlineMath("Value $x$ is positive."))

    let mixed = """
    # Physics

    Einstein showed $E = mc^2$ in 1905.

    - See **notes** at [docs](https://example.com) and $a + b$
    """
    let segments = AnswerContentParser.splitMarkdownForInlineMath(mixed)
    #expect(segments.count == 3)
    #expect(segments[0] == MarkdownMathSegment(text: "# Physics", useLaTeX: false))
    #expect(
      segments[1] == MarkdownMathSegment(
        text: "Einstein showed $E = mc^2$ in 1905.",
        useLaTeX: true
      )
    )
    #expect(
      segments[2] == MarkdownMathSegment(
        text: "- See **notes** at [docs](https://example.com) and $a + b$",
        useLaTeX: false
      )
    )
  }

  @Test("Preserves balanced parentheses in URLs and rejects hostless browser URLs")
  func sourcesAndURLValidation() {
    let text = "Read [Swift](https://en.wikipedia.org/wiki/Swift_(programming_language)) and [broken](https://)."
    let sources = AnswerContentParser.sources(in: AnswerContentParser.parse(text))
    #expect(sources.count == 1)
    #expect(
      sources[0].url.absoluteString == "https://en.wikipedia.org/wiki/Swift_(programming_language)"
    )
    if let hostless = URL(string: "https://") {
      #expect(!AnswerContentParser.isValidBrowsableURL(hostless))
    }
    if let javascript = URL(string: "javascript:alert(1)") {
      #expect(!AnswerContentParser.isValidBrowsableURL(javascript))
    }
    if let valid = URL(string: "https://example.com") {
      #expect(AnswerContentParser.isValidBrowsableURL(valid))
    }
  }

  @Test("Response image scanner skips fenced code blocks and deduplicates PNG data URIs safely")
  func responseImageScannerEdgeCases() {
    let pngPrefix = Data(repeating: 0xAA, count: 48)
    let firstPayload = (pngPrefix + Data([0x01, 0x02])).base64EncodedString()
    let secondPayload = (pngPrefix + Data([0x03, 0x04])).base64EncodedString()
    let markdown = """
    ```markdown
    ![Ignored](https://example.com/in-code-block.png)
    ```

    ![First](data:image/png;base64,\(firstPayload))
    ![Second](data:image/png;base64,\(secondPayload))
    """
    let candidates = ResponseImageScanner.imageCandidates(in: markdown)
    #expect(candidates.count == 2)
    #expect(candidates[0].id != candidates[1].id)
    #expect(candidates[0].label == "First")
    #expect(candidates[1].label == "Second")
  }

  @Test("Code block preview truncates long single-line blobs with clear labels")
  func codeBlockPreviewSupport() {
    let singleLongLine = String(repeating: "a", count: 2_500)
    let collapsed = HighlightedCodeBlockSupport.preview(for: singleLongLine, isExpanded: false)
    #expect(collapsed.isLong)
    #expect(collapsed.displayedContent.count < singleLongLine.count)
    #expect(collapsed.toggleLabel == "Show full code")

    let multiLine = (1...20).map { "line \($0)" }.joined(separator: "\n")
    let collapsedLines = HighlightedCodeBlockSupport.preview(for: multiLine, isExpanded: false)
    #expect(collapsedLines.isLong)
    #expect(collapsedLines.toggleLabel == "Show all 20 lines")

    let expanded = HighlightedCodeBlockSupport.preview(for: multiLine, isExpanded: true)
    #expect(expanded.displayedContent == multiLine)
    #expect(expanded.toggleLabel == "Collapse code")
  }

  @Test("ChatViewSupport validates markdown filenames, renames, and message edits")
  func chatViewSupportHelpers() {
    #expect(ChatViewSupport.markdownFilename(for: "🚀🔥???") == "BYOKchat-conversation")
    #expect(ChatViewSupport.markdownFilename(for: "  Hello,   World!  ") == "Hello-World")
    #expect(ChatViewSupport.markdownFilename(for: nil) == "BYOKchat-conversation")

    #expect(!ChatViewSupport.canSaveRename(draft: "   ", currentTitle: "Chat"))
    #expect(!ChatViewSupport.canSaveRename(draft: " Chat ", currentTitle: "Chat"))
    #expect(ChatViewSupport.canSaveRename(draft: "New Title", currentTitle: "Chat"))

    #expect(!ChatViewSupport.canSaveEditedMessage(draft: "   ", original: "Hello"))
    #expect(!ChatViewSupport.canSaveEditedMessage(draft: " Hello \n", original: "Hello"))
    #expect(ChatViewSupport.canSaveEditedMessage(draft: "Hello!", original: "Hello"))
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

    let blocks = AnswerContentParser.parse(text)
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

    let blocks = AnswerContentParser.parse(text)
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
    #expect(AnswerContentParser.shouldRenderCellAsInlineMath("$E = mc^2$"))
    #expect(!AnswerContentParser.shouldRenderCellAsInlineMath("**$E = mc^2$**"))

    #expect(second.headers == ["", "Col A", "Col B"])
    #expect(second.alignments == [.leading, .center, .center])
    #expect(second.rows == [["Row 1", "X", "Y"]])

    #expect(third.headers == ["Only Header"])
    #expect(third.alignments == [.center])
    #expect(third.rows.isEmpty)
  }

  @Test("Rejects malformed table delimiters and preserves links/images inside tables")
  func rejectsInvalidTablesAndExtractsTableMedia() {
    let malformed = """
    A | B
    :::---::: | ---
    1 | 2

    ```markdown
    | In Code | Ignored |
    | --- | --- |
    | 1 | 2 |
    ```

    | Resource | Preview |
    | --- | --- |
    | [Apple](https://apple.com) | ![Logo](https://example.com/logo.png) |
    """

    let blocks = AnswerContentParser.parse(malformed)
    let tables = blocks.compactMap { block -> ParsedMarkdownTable? in
      guard case .table(let table) = block else { return nil }
      return table
    }
    #expect(tables.count == 1)
    #expect(tables[0].headers == ["Resource", "Preview"])

    let sources = AnswerContentParser.sources(in: blocks)
    #expect(sources.contains { $0.url.absoluteString == "https://apple.com" })

    #expect(ResponseImageScanner.hasImageCandidates(in: malformed))
    let images = ResponseImageScanner.imageCandidates(in: malformed)
    #expect(images.count == 1)
    #expect(images[0].label == "Logo")
  }

  @Test("Computes content-aware, Dynamic-Type-scaled table column widths")
  func computesAdaptiveTableColumnWidths() {
    let compactTable = ParsedMarkdownTable(
      headers: ["#", "Feature", "Description"],
      alignments: [.trailing, .leading, .leading],
      rows: [
        ["1", "Offline", "Runs models locally with Ollama and LM Studio without cloud calls."],
        ["2", "Export", "Save full conversations to Markdown."],
      ],
      rawMarkdown: ""
    )

    let metrics = MarkdownTableLayout.compute(
      for: compactTable,
      availableWidth: 360,
      fontSize: 15,
      fillsWidth: true
    )
    #expect(metrics.columnWidths.count == 3)
    #expect(metrics.columnWidths[0] < metrics.columnWidths[2])
    #expect(metrics.columnWidths[2] > 170)

    let wideTable = ParsedMarkdownTable(
      headers: ["Metric", "Claude", "GPT", "Gemini", "DeepSeek", "Llama"],
      alignments: Array(repeating: .leading, count: 6),
      rows: [["Context Window", "200K tokens", "1M tokens", "1M tokens", "128K tokens", "128K tokens"]],
      rawMarkdown: ""
    )
    let wideMetrics = MarkdownTableLayout.compute(
      for: wideTable,
      availableWidth: 360,
      fontSize: 15,
      fillsWidth: true
    )
    #expect(wideMetrics.overflowsViewport)
    #expect(wideMetrics.totalWidth > 360)

    let largeTypeMetrics = MarkdownTableLayout.compute(
      for: wideTable,
      availableWidth: 360,
      fontSize: 24,
      fillsWidth: true
    )
    #expect(largeTypeMetrics.totalWidth > wideMetrics.totalWidth)
  }
}
