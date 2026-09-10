import BYOKchatProviderCore
import Foundation
import Testing

@testable import BYOKmac

@Suite("macOS live message presentation")
struct MacLiveMessagePresentationTests {
  @Test("Newest source wins over stale async render work")
  @MainActor
  func newestSourceWins() async {
    let presentation = MacLiveMessagePresentation(messageID: "test-message")
    let older = (0..<500)
      .map { "Older paragraph \($0)" }
      .joined(separator: "\n\n")

    _ = presentation.apply(content: older, reasoning: "", usage: nil)
    _ = presentation.apply(content: "Newest answer", reasoning: "", usage: nil)

    for _ in 0..<200 {
      if presentation.answerSnapshot.tailBlocks == [.markdown("Newest answer")] {
        break
      }
      try? await Task.sleep(for: .milliseconds(5))
    }

    #expect(presentation.content == "Newest answer")
    #expect(presentation.answerSnapshot.stableBlocks.isEmpty)
    #expect(presentation.answerSnapshot.tailBlocks == [.markdown("Newest answer")])
  }

  @Test("Cancelling a live presentation clears owned render work")
  @MainActor
  func cancellationClearsOwnedRenderWork() {
    let presentation = MacLiveMessagePresentation(messageID: "cancel-message")

    _ = presentation.apply(
      content: "Streaming answer",
      reasoning: "Streaming reasoning",
      usage: nil
    )

    #expect(presentation.hasPendingRenderWork)

    presentation.cancelPendingRenders()

    #expect(!presentation.hasPendingRenderWork)
  }
}
