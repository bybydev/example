import Testing

@testable import BYOKmac

@Suite("macOS transcript scroll policy")
struct MacTranscriptScrollPolicyTests {
  @Test("Near-bottom detection uses viewport geometry instead of row visibility")
  func nearBottomGeometryContract() {
    #expect(
      MacTranscriptScrollPolicy.isNearBottom(
        visibleMaxY: 980,
        contentHeight: 1_000
      )
    )
    #expect(
      !MacTranscriptScrollPolicy.isNearBottom(
        visibleMaxY: 900,
        contentHeight: 1_000
      )
    )
    #expect(
      MacTranscriptScrollPolicy.isNearBottom(
        visibleMaxY: 0,
        contentHeight: 0
      )
    )
  }

  @Test("Content growth follows only after initial scroll while generating")
  func contentGrowthFollowContract() {
    #expect(
      MacTranscriptScrollPolicy.shouldFollowContentGrowth(
        hasCompletedInitialScroll: true,
        followsLatest: true,
        isUserDraggingTimeline: false,
        isGenerating: true
      )
    )
    #expect(
      !MacTranscriptScrollPolicy.shouldFollowContentGrowth(
        hasCompletedInitialScroll: false,
        followsLatest: true,
        isUserDraggingTimeline: false,
        isGenerating: true
      )
    )
    #expect(
      !MacTranscriptScrollPolicy.shouldFollowContentGrowth(
        hasCompletedInitialScroll: true,
        followsLatest: false,
        isUserDraggingTimeline: false,
        isGenerating: true
      )
    )
    #expect(
      !MacTranscriptScrollPolicy.shouldFollowContentGrowth(
        hasCompletedInitialScroll: true,
        followsLatest: true,
        isUserDraggingTimeline: true,
        isGenerating: true
      )
    )
    #expect(
      !MacTranscriptScrollPolicy.shouldFollowContentGrowth(
        hasCompletedInitialScroll: true,
        followsLatest: true,
        isUserDraggingTimeline: false,
        isGenerating: false
      )
    )
  }

  @Test("Jump-to-latest depends on position after initial scroll, not gesture phase")
  func jumpVisibilityContract() {
    #expect(
      MacTranscriptScrollPolicy.shouldShowJumpToLatest(
        isNearBottom: false,
        hasCompletedInitialScroll: true
      )
    )
    #expect(
      !MacTranscriptScrollPolicy.shouldShowJumpToLatest(
        isNearBottom: true,
        hasCompletedInitialScroll: true
      )
    )
    #expect(
      !MacTranscriptScrollPolicy.shouldShowJumpToLatest(
        isNearBottom: false,
        hasCompletedInitialScroll: false
      )
    )
  }
}
