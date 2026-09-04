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

  @Test("Recognizes Mermaid aliases")
  func recognizesMermaid() {
    #expect(MacAnswerContentParser.isMermaidLanguage("mermaid"))
    #expect(MacAnswerContentParser.isMermaidLanguage("MMD"))
    #expect(!MacAnswerContentParser.isMermaidLanguage("swift"))
  }
}
