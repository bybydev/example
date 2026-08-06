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
}
