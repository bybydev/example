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
}
