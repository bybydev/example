import Foundation
import Testing

@testable import BYOKmac

@Suite("macOS Markdown table alignment")
struct MacMarkdownTableAlignmentTests {
  @Test("Recovers leading center and trailing GFM alignment")
  func recoversColumnAlignment() {
    let markdown = """
    | Name | Status | Score |
    | :--- | :---: | ---: |
    | Ada | Ready | 10 |
    """

    #expect(
      MacMarkdownTableAlignment.columnAlignments(in: markdown) == [
        .leading,
        .center,
        .trailing,
      ]
    )
  }

  @Test("Ignores delimiter-looking rows inside fenced code")
  func ignoresFencedDelimiterRows() {
    let markdown = """
    ````markdown
    | Fake | Table |
    | :---: | ---: |
    ````

    | Real | Table |
    | ---: | :---: |
    """

    #expect(
      MacMarkdownTableAlignment.columnAlignments(in: markdown) == [
        .trailing,
        .center,
      ]
    )
  }

  @Test("Returns nil when no GFM delimiter row exists")
  func returnsNilWithoutTable() {
    #expect(MacMarkdownTableAlignment.columnAlignments(in: "Plain paragraph") == nil)
  }
}
