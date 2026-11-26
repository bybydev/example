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

  @Test("Reasoning render work is deferred until reasoning is expanded")
  @MainActor
  func reasoningRenderIsDeferredWhileCollapsed() async {
    let presentation = MacLiveMessagePresentation(messageID: "lazy-reasoning")

    _ = presentation.apply(content: "", reasoning: "Step 1: analyze input", usage: nil)
    #expect(!presentation.hasPendingRenderWork)
    #expect(presentation.reasoningSnapshot.revision == 0)

    presentation.setReasoningRenderEnabled(true)
    for _ in 0..<200 {
      if presentation.reasoningSnapshot.tailBlocks == [.markdown("Step 1: analyze input")] {
        break
      }
      try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(presentation.reasoningSnapshot.tailBlocks == [.markdown("Step 1: analyze input")])

    presentation.setReasoningRenderEnabled(false)
    _ = presentation.apply(content: "", reasoning: "Step 2: hidden update", usage: nil)
    #expect(!presentation.hasPendingRenderWork)
  }

  @Test("Reasoning duration formatter formats seconds and minute-second spans")
  func reasoningDurationFormatterOutput() {
    #expect(MacReasoningDurationFormatter.format(seconds: 0) == "1s")
    #expect(MacReasoningDurationFormatter.format(seconds: 12) == "12s")
    #expect(MacReasoningDurationFormatter.format(seconds: 60) == "1m")
    #expect(MacReasoningDurationFormatter.format(seconds: 95) == "1m 35s")
  }
}
