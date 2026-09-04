import Foundation
import Testing

@testable import BYOKmac

@Suite("macOS streaming answer renderer")
struct MacStreamingAnswerRendererTests {
  @Test("Appending a second paragraph freezes the first")
  func freezesCompletedParagraph() async {
    let renderer = MacStreamingAnswerRenderer()

    let first = await renderer.update(source: "First paragraph.")
    #expect(first.stableBlocks.isEmpty)
    #expect(first.tailBlocks == [.markdown("First paragraph.")])

    let second = await renderer.update(source: "First paragraph.\n\nSecond paragraph")
    #expect(second.stableBlocks.count == 1)
    #expect(second.stableBlocks[0].id == 0)
    #expect(second.stableBlocks[0].block == .markdown("First paragraph."))
    #expect(second.tailBlocks == [.markdown("Second paragraph")])
  }

  @Test("Stable block IDs do not change while later text streams")
  func stableIDsRemainStable() async {
    let renderer = MacStreamingAnswerRenderer()

    let first = await renderer.update(source: "One.\n\nTwo")
    #expect(first.stableBlocks.map(\.id) == [0])

    let second = await renderer.update(source: "One.\n\nTwo grows")
    #expect(second.stableBlocks.map(\.id) == [0])
    #expect(second.stableBlocks.first?.block == .markdown("One."))

    let third = await renderer.update(source: "One.\n\nTwo grows.\n\nThree")
    #expect(third.stableBlocks.map(\.id) == [0, 1])
    #expect(third.tailBlocks == [.markdown("Three")])
  }

  @Test("Only the mutable tail changes for additional tokens")
  func replacesOnlyTail() async {
    let renderer = MacStreamingAnswerRenderer()

    let first = await renderer.update(source: "Stable.\n\nTail")
    let second = await renderer.update(source: "Stable.\n\nTail keeps growing")

    #expect(first.stableBlocks == second.stableBlocks)
    #expect(first.tailBlocks == [.markdown("Tail")])
    #expect(second.tailBlocks == [.markdown("Tail keeps growing")])
  }

  @Test("Non-prefix edit resets stable renderer state")
  func resetsForNonPrefixEdit() async {
    let renderer = MacStreamingAnswerRenderer()

    let initial = await renderer.update(source: "Old stable.\n\nOld tail")
    #expect(initial.stableBlocks.count == 1)

    let edited = await renderer.update(source: "Entirely rewritten")
    #expect(edited.stableBlocks.isEmpty)
    #expect(edited.tailBlocks == [.markdown("Entirely rewritten")])

    let completed = await renderer.update(source: "Entirely rewritten", complete: true)
    #expect(completed.stableBlocks.map(\.id) == [0])
    #expect(completed.stableBlocks.map(\.block) == [.markdown("Entirely rewritten")])
    #expect(completed.tailBlocks.isEmpty)
  }

  @Test("Completion freezes all remaining content")
  func completionFreezesTail() async {
    let renderer = MacStreamingAnswerRenderer()

    let live = await renderer.update(source: "Last paragraph")
    #expect(live.stableBlocks.isEmpty)
    #expect(!live.tailBlocks.isEmpty)

    let final = await renderer.update(source: "Last paragraph", complete: true)
    #expect(final.stableBlocks.count == 1)
    #expect(final.stableBlocks[0].block == .markdown("Last paragraph"))
    #expect(final.tailBlocks.isEmpty)
  }

  @Test("Incomplete code remains tail and completed code becomes stable")
  func codeEnhancementWaitsForStability() async {
    let renderer = MacStreamingAnswerRenderer()

    let live = await renderer.update(source: "```swift\nlet value = 42")
    #expect(live.stableBlocks.isEmpty)
    #expect(
      live.tailBlocks == [
        .code(language: "swift", content: "let value = 42", isComplete: false)
      ]
    )

    let finalSource = "```swift\nlet value = 42\n```\n"
    let stable = await renderer.update(source: finalSource)
    #expect(stable.stableBlocks.count == 1)
    #expect(
      stable.stableBlocks[0].block ==
        .code(language: "swift", content: "let value = 42", isComplete: true)
    )
    #expect(stable.tailBlocks.isEmpty)
  }

  @Test("Mermaid and display math remain tail until structurally complete")
  func richBlocksWaitForStability() async {
    let mermaid = MacStreamingAnswerRenderer()
    let openDiagram = await mermaid.update(source: "```mermaid\nflowchart LR\nA --> B")
    #expect(openDiagram.stableBlocks.isEmpty)
    #expect(openDiagram.tailBlocks.count == 1)

    let closedDiagram = await mermaid.update(
      source: "```mermaid\nflowchart LR\nA --> B\n```\n"
    )
    #expect(closedDiagram.stableBlocks.count == 1)
    #expect(closedDiagram.tailBlocks.isEmpty)

    let math = MacStreamingAnswerRenderer()
    let openMath = await math.update(source: "$$\nE = mc^2")
    #expect(openMath.stableBlocks.isEmpty)
    #expect(openMath.tailBlocks == [.math("E = mc^2", isComplete: false)])

    let closedMath = await math.update(source: "$$\nE = mc^2\n$$\n")
    #expect(closedMath.stableBlocks.count == 1)
    #expect(closedMath.stableBlocks[0].block == .math("E = mc^2", isComplete: true))
    #expect(closedMath.tailBlocks.isEmpty)
  }

  @Test("Long streamed prose keeps one bounded mutable tail")
  func longResponseKeepsTailBounded() async {
    let renderer = MacStreamingAnswerRenderer()
    var source = "Paragraph 0"
    var snapshot = await renderer.update(source: source)

    for index in 1...250 {
      source += "\n\nParagraph \(index)"
      snapshot = await renderer.update(source: source)
    }

    #expect(snapshot.stableBlocks.count == 250)
    #expect(snapshot.stableBlocks.map(\.id) == Array(0..<250))
    #expect(snapshot.tailBlocks == [.markdown("Paragraph 250")])
  }
}
