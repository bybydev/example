import AppKit
import Observation
import SwiftUI
import XCTest
@testable import BYOKmac

@MainActor
@Observable
private final class AsyncSizedModel {
  var width: CGFloat = 900
  var height: CGFloat = 54
}

private struct AsyncSizedView: View {
  let model: AsyncSizedModel
  var body: some View {
    Color.clear.frame(width: model.width, height: model.height)
  }
}

final class MacScrollWheelRoutingTests: XCTestCase {
  @MainActor
  func testNativeScrollObservationWithoutGesturePhases() async throws {
    let frame = NSRect(x: 0, y: 0, width: 300, height: 200)
    let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let container = NSView(frame: frame)
    let scroll = NSScrollView(frame: frame)
    // An unflipped document's bottom is at y = 0.
    scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 1_000))
    let observer = MacTranscriptScrollObservationView(frame: frame)
    var snapshots: [MacTranscriptScrollSnapshot] = []
    observer.onChange = { _, current in snapshots.append(current) }
    container.addSubview(scroll)
    container.addSubview(observer)
    window.contentView = container
    observer.observe(scroll)
    defer {
      observer.stopObserving()
      window.close()
    }

    scroll.contentView.scroll(to: NSPoint(x: 0, y: 500))
    NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
    await drainMainQueue()

    let away = try XCTUnwrap(snapshots.last)
    XCTAssertFalse(away.isNearBottom)
    XCTAssertFalse(away.isUserScrolling)
    XCTAssertTrue(away.userDidScroll)

    // Geometry alone must also update visibility, e.g. after a keyboard or
    // programmatic scroll back to the bottom.
    scroll.contentView.scroll(to: .zero)
    await drainMainQueue()
    XCTAssertTrue(try XCTUnwrap(snapshots.last).isNearBottom)

    observer.isEnabled = false
    let countWhileInactive = snapshots.count
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 500))
    NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
    await drainMainQueue()
    XCTAssertEqual(snapshots.count, countWhileInactive)

    observer.isEnabled = true
    await drainMainQueue()
    XCTAssertFalse(try XCTUnwrap(snapshots.last).isNearBottom)
  }

  @MainActor
  func testLiveScrollWhileAwayFromBottomCoalescesRedundantCallbacks() async throws {
    let frame = NSRect(x: 0, y: 0, width: 300, height: 200)
    let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let container = NSView(frame: frame)
    let scroll = NSScrollView(frame: frame)
    scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 2_000))
    let observer = MacTranscriptScrollObservationView(frame: frame)
    var snapshots: [MacTranscriptScrollSnapshot] = []
    observer.onChange = { _, current in snapshots.append(current) }
    container.addSubview(scroll)
    container.addSubview(observer)
    window.contentView = container
    observer.observe(scroll)
    defer {
      observer.stopObserving()
      window.close()
    }

    // Move away from the bottom once.
    NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 400))
    NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
    await drainMainQueue()
    let countAfterLeavingBottom = snapshots.count
    XCTAssertFalse(try XCTUnwrap(snapshots.last).isNearBottom)

    // Subsequent live-scroll frames while still away from bottom should not emit redundant snapshots.
    for step in 1...15 {
      scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(400 + step * 30)))
      NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
      await drainMainQueue()
    }
    XCTAssertEqual(snapshots.count, countAfterLeavingBottom)

    // Ending live scroll publishes once to clear isUserScrolling.
    NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
    await drainMainQueue()
    XCTAssertEqual(snapshots.count, countAfterLeavingBottom + 1)
    XCTAssertFalse(try XCTUnwrap(snapshots.last).isUserScrolling)
  }

  @MainActor
  private func drainMainQueue() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
  }

  @MainActor
  func testMeasurementDoesNotChangeHostedFrame() throws {
    let view = MacShiftHorizontalClipView(rootView: Color.clear.frame(width: 800, height: 120))
    view.frame = NSRect(x: 0, y: 0, width: 300, height: 120)
    view.layoutSubtreeIfNeeded()
    let host = try XCTUnwrap(view.subviews.first)
    let frame = host.frame

    // List may probe unrelated widths while measuring a row. Those probes
    // must not resize or synchronously lay out the nested SwiftUI host.
    for width: CGFloat in [200, 1_000, 300, 0] {
      let size = view.sizeThatFits(proposedWidth: width)
      XCTAssertEqual(size.width, max(width, 1))
      XCTAssertEqual(size.height, 120, accuracy: 0.5)
      XCTAssertEqual(host.frame, frame)
    }
  }

  @MainActor
  func testLayoutUsesActualViewportAfterSpeculativeMeasurement() throws {
    let view = MacShiftHorizontalClipView(rootView: Color.clear.frame(width: 800, height: 120))
    _ = view.sizeThatFits(proposedWidth: 1_000)
    view.frame = NSRect(x: 0, y: 0, width: 300, height: 120)
    view.layoutSubtreeIfNeeded()
    let host = try XCTUnwrap(view.subviews.first)
    XCTAssertEqual(host.frame.width, 800, accuracy: 0.5)
    XCTAssertEqual(host.frame.height, 120, accuracy: 0.5)

    view.updateRootView(Color.clear.frame(width: 900, height: 240))
    XCTAssertEqual(view.sizeThatFits(proposedWidth: 300).height, 240, accuracy: 0.5)
    view.frame.size = NSSize(width: 1_100, height: 240)
    view.layoutSubtreeIfNeeded()
    XCTAssertEqual(host.frame.width, 1_100, accuracy: 0.5)
    XCTAssertEqual(host.frame.height, 240, accuracy: 0.5)
  }

  @MainActor
  func testUpdateRootViewSkipsRedundantWorkWhenContentKeyMatches() throws {
    let view = MacShiftHorizontalClipView(
      rootView: Color.clear.frame(width: 800, height: 120),
      contentKey: "v1"
    )
    XCTAssertEqual(view.sizeThatFits(proposedWidth: 300).height, 120, accuracy: 0.5)

    // Matching contentKey skips replacing rootView and re-measuring fittingSize.
    view.updateRootView(Color.clear.frame(width: 800, height: 300), contentKey: "v1")
    XCTAssertEqual(view.sizeThatFits(proposedWidth: 300).height, 120, accuracy: 0.5)

    // A new contentKey invalidates the cached ideal size and updates content.
    view.updateRootView(Color.clear.frame(width: 800, height: 300), contentKey: "v2")
    XCTAssertEqual(view.sizeThatFits(proposedWidth: 300).height, 300, accuracy: 0.5)
  }

  @MainActor
  func testAsyncHostedContentResizeUpdatesSizeWithoutReplacingRootView() async throws {
    let model = AsyncSizedModel()
    let view = MacShiftHorizontalClipView(
      rootView: AsyncSizedView(model: model),
      contentKey: "equation-1"
    )
    XCTAssertEqual(view.sizeThatFits(proposedWidth: 600).height, 54, accuracy: 0.5)
    view.frame = NSRect(x: 0, y: 0, width: 600, height: 54)
    view.layoutSubtreeIfNeeded()
    let host = try XCTUnwrap(view.subviews.first)
    XCTAssertEqual(host.frame.width, 900, accuracy: 0.5)

    // Simulate async LaTeX completion shrinking width and growing height while contentKey stays fixed.
    model.width = 220
    model.height = 110
    await drainMainQueue()
    view.layoutSubtreeIfNeeded()

    let updated = view.sizeThatFits(proposedWidth: 600)
    XCTAssertEqual(updated.height, 110, accuracy: 0.5)
    view.frame = NSRect(x: 0, y: 0, width: 600, height: 110)
    view.layoutSubtreeIfNeeded()
    XCTAssertEqual(host.frame.width, 600, accuracy: 0.5)
    XCTAssertEqual(host.frame.height, 110, accuracy: 0.5)
  }

  func testDisplayMathInputCollapsesMultiLineAlignedBlocksAndPreservesComments() {
    let aligned = """
      \\begin{aligned}
      \\text{Attention}(Q, K, V) &= \\text{softmax}\\!\\left(\\frac{QK^\\top}{\\sqrt{d_k}}\\right) V \\\\
      \\mathcal{L}_{\\text{CE}} &= -\\frac{1}{N} \\sum_{i=1}^{N} \\log p_\\theta(y_i \\mid x_i)
      \\end{aligned}
      """
    let rendered = MacMathAnswerView.renderedDisplayInput(for: aligned)
    XCTAssertTrue(rendered.hasPrefix("$$\\begin{aligned} "))
    XCTAssertTrue(rendered.hasSuffix(" \\end{aligned}$$"))
    XCTAssertFalse(rendered.contains("\n"))

    let escapedPercent = "50\\% \\\\\n100\\%"
    XCTAssertEqual(
      MacMathAnswerView.renderedDisplayInput(for: escapedPercent),
      "$$50\\% \\\\ 100\\%$$"
    )

    let withComment = "x = 1 % comment\ny = 2"
    XCTAssertEqual(
      MacMathAnswerView.renderedDisplayInput(for: withComment),
      "$$x = 1 % comment\ny = 2$$"
    )
  }

  func testHorizontalTableScrollRequiresShift() {
    XCTAssertFalse(MacScrollWheelRouting.usesHorizontalTableScroll(modifierFlags: []))
    XCTAssertTrue(MacScrollWheelRouting.usesHorizontalTableScroll(modifierFlags: [.shift]))
    XCTAssertTrue(MacScrollWheelRouting.usesHorizontalTableScroll(modifierFlags: [.shift, .command]))
  }

  func testVerticalWheelDeltaBecomesHorizontalWhileShifted() {
    XCTAssertEqual(MacScrollWheelRouting.horizontalDelta(deltaX: 0, deltaY: 12), 12)
    XCTAssertEqual(MacScrollWheelRouting.horizontalDelta(deltaX: 3, deltaY: 8), 8)
  }

  func testLargerHorizontalDeltaIsPreservedWhileShifted() {
    XCTAssertEqual(MacScrollWheelRouting.horizontalDelta(deltaX: 11, deltaY: 3), 11)
    XCTAssertEqual(MacScrollWheelRouting.horizontalDelta(deltaX: -9, deltaY: -2), -9)
  }

  func testVerticalMouseWheelAlwaysPassesThrough() {
    var axis: MacScrollWheelRouting.Axis?
    let decision = MacScrollWheelRouting.route(
      deltaX: 0,
      deltaY: -3,
      hasPreciseDeltas: false,
      modifierFlags: [],
      phase: [],
      momentumPhase: [],
      canScrollHorizontally: true,
      lockedAxis: &axis
    )
    XCTAssertEqual(decision, .passthrough)
    XCTAssertNil(axis)
  }

  func testShiftMouseWheelScalesDiscreteDeltaHorizontally() {
    var axis: MacScrollWheelRouting.Axis?
    let decision = MacScrollWheelRouting.route(
      deltaX: 0,
      deltaY: -2,
      hasPreciseDeltas: false,
      modifierFlags: [.shift],
      phase: [],
      momentumPhase: [],
      canScrollHorizontally: true,
      lockedAxis: &axis
    )
    XCTAssertEqual(decision, .horizontal(delta: -24))
  }

  func testTrackpadVerticalGestureLocksVerticalAndNeverHijacksDrift() {
    var axis: MacScrollWheelRouting.Axis?

    XCTAssertEqual(
      MacScrollWheelRouting.route(
        deltaX: 0, deltaY: 0, hasPreciseDeltas: true, modifierFlags: [],
        phase: .mayBegin, momentumPhase: [], canScrollHorizontally: true, lockedAxis: &axis
      ),
      .passthrough
    )
    XCTAssertEqual(
      MacScrollWheelRouting.route(
        deltaX: -1, deltaY: -10, hasPreciseDeltas: true, modifierFlags: [],
        phase: .began, momentumPhase: [], canScrollHorizontally: true, lockedAxis: &axis
      ),
      .passthrough
    )
    XCTAssertEqual(axis, .vertical)

    // Subsequent horizontal drift within the same vertical swipe must stay passthrough.
    XCTAssertEqual(
      MacScrollWheelRouting.route(
        deltaX: -8, deltaY: -1, hasPreciseDeltas: true, modifierFlags: [],
        phase: .changed, momentumPhase: [], canScrollHorizontally: true, lockedAxis: &axis
      ),
      .passthrough
    )
    XCTAssertEqual(
      MacScrollWheelRouting.route(
        deltaX: -5, deltaY: -1, hasPreciseDeltas: true, modifierFlags: [],
        phase: [], momentumPhase: .changed, canScrollHorizontally: true, lockedAxis: &axis
      ),
      .passthrough
    )
    XCTAssertEqual(
      MacScrollWheelRouting.route(
        deltaX: 0, deltaY: 0, hasPreciseDeltas: true, modifierFlags: [],
        phase: [], momentumPhase: .ended, canScrollHorizontally: true, lockedAxis: &axis
      ),
      .passthrough
    )
    XCTAssertNil(axis)
  }

  func testTrackpadHorizontalGesturePansAndKeepsMomentum() {
    var axis: MacScrollWheelRouting.Axis?

    XCTAssertEqual(
      MacScrollWheelRouting.route(
        deltaX: -9, deltaY: -1, hasPreciseDeltas: true, modifierFlags: [],
        phase: .began, momentumPhase: [], canScrollHorizontally: true, lockedAxis: &axis
      ),
      .horizontal(delta: -9)
    )
    XCTAssertEqual(axis, .horizontal)

    XCTAssertEqual(
      MacScrollWheelRouting.route(
        deltaX: -6, deltaY: -5, hasPreciseDeltas: true, modifierFlags: [],
        phase: .changed, momentumPhase: [], canScrollHorizontally: true, lockedAxis: &axis
      ),
      .horizontal(delta: -6)
    )
    XCTAssertEqual(
      MacScrollWheelRouting.route(
        deltaX: 0, deltaY: 0, hasPreciseDeltas: true, modifierFlags: [],
        phase: .ended, momentumPhase: [], canScrollHorizontally: true, lockedAxis: &axis
      ),
      .consume
    )
    XCTAssertEqual(
      MacScrollWheelRouting.route(
        deltaX: -4, deltaY: 0, hasPreciseDeltas: true, modifierFlags: [],
        phase: [], momentumPhase: .changed, canScrollHorizontally: true, lockedAxis: &axis
      ),
      .horizontal(delta: -4)
    )
    XCTAssertEqual(
      MacScrollWheelRouting.route(
        deltaX: 0, deltaY: 0, hasPreciseDeltas: true, modifierFlags: [],
        phase: [], momentumPhase: .ended, canScrollHorizontally: true, lockedAxis: &axis
      ),
      .consume
    )
    XCTAssertNil(axis)
  }

  func testUnownedMomentumPassingOverCodeBlockPassesThrough() {
    var axis: MacScrollWheelRouting.Axis?
    let decision = MacScrollWheelRouting.route(
      deltaX: -6,
      deltaY: -1,
      hasPreciseDeltas: true,
      modifierFlags: [],
      phase: [],
      momentumPhase: .changed,
      canScrollHorizontally: true,
      lockedAxis: &axis
    )
    XCTAssertEqual(decision, .passthrough)
    XCTAssertNil(axis)
  }

  func testNonOverflowingBlockAlwaysPassesThrough() {
    var axis: MacScrollWheelRouting.Axis?
    let decision = MacScrollWheelRouting.route(
      deltaX: -12,
      deltaY: 0,
      hasPreciseDeltas: true,
      modifierFlags: [],
      phase: .began,
      momentumPhase: [],
      canScrollHorizontally: false,
      lockedAxis: &axis
    )
    XCTAssertEqual(decision, .passthrough)
    XCTAssertNil(axis)
  }

  @MainActor
  func testDisablingContentHitTestingInterceptsNestedScrollViews() {
    let nestedScrollContent = ScrollView(.horizontal) {
      Color.clear.frame(width: 900, height: 80)
    }

    let interactiveView = MacShiftHorizontalClipView(
      rootView: nestedScrollContent,
      allowsContentHitTesting: true
    )
    interactiveView.frame = NSRect(x: 10, y: 20, width: 320, height: 80)
    interactiveView.layoutSubtreeIfNeeded()
    let interactiveHit = interactiveView.hitTest(NSPoint(x: 60, y: 50))
    XCTAssertNotNil(interactiveHit)
    XCTAssertFalse(interactiveHit === interactiveView)

    let passthroughView = MacShiftHorizontalClipView(
      rootView: nestedScrollContent,
      allowsContentHitTesting: false
    )
    passthroughView.frame = NSRect(x: 10, y: 20, width: 320, height: 80)
    passthroughView.layoutSubtreeIfNeeded()
    // Points inside frame resolve directly to MacShiftHorizontalClipView instead
    // of descending into nested NSScrollView instances (e.g. LaTeXSwiftUI blockViews).
    XCTAssertTrue(passthroughView.hitTest(NSPoint(x: 60, y: 50)) === passthroughView)
    // Points outside frame and hidden states still return nil.
    XCTAssertNil(passthroughView.hitTest(NSPoint(x: 5, y: 50)))
    XCTAssertNil(passthroughView.hitTest(NSPoint(x: 400, y: 50)))
    passthroughView.isHidden = true
    XCTAssertNil(passthroughView.hitTest(NSPoint(x: 60, y: 50)))
  }

  @MainActor
  func testSizeThatFitsAndLayoutReuseCachedIdealSize() {
    let view = MacShiftHorizontalClipView(
      rootView: Color.clear.frame(width: 800, height: 120),
      contentKey: "v1"
    )
    XCTAssertEqual(view.sizeThatFits(proposedWidth: 300).height, 120, accuracy: 0.5)
    XCTAssertEqual(view.idealSizeMeasurementCount, 1)

    _ = view.sizeThatFits(proposedWidth: 500)
    _ = view.sizeThatFits(proposedWidth: 220)
    view.frame = NSRect(x: 0, y: 0, width: 300, height: 120)
    view.layoutSubtreeIfNeeded()
    XCTAssertEqual(view.idealSizeMeasurementCount, 1)

    view.updateRootView(Color.clear.frame(width: 800, height: 240), contentKey: "v1")
    _ = view.sizeThatFits(proposedWidth: 300)
    XCTAssertEqual(view.idealSizeMeasurementCount, 1)

    view.updateRootView(Color.clear.frame(width: 800, height: 240), contentKey: "v2")
    XCTAssertEqual(view.sizeThatFits(proposedWidth: 300).height, 240, accuracy: 0.5)
    XCTAssertEqual(view.idealSizeMeasurementCount, 2)
  }

  @MainActor
  func testInactiveClipViewHidesAndSkipsIdealSizeMeasurement() {
    let view = MacShiftHorizontalClipView(
      rootView: Color.clear.frame(width: 800, height: 120),
      contentKey: "v1"
    )
    XCTAssertFalse(view.isHidden)
    XCTAssertEqual(view.sizeThatFits(proposedWidth: 300).height, 120, accuracy: 0.5)
    XCTAssertEqual(view.idealSizeMeasurementCount, 1)

    view.isActive = false
    XCTAssertTrue(view.isHidden)

    view.updateRootView(Color.clear.frame(width: 800, height: 300), contentKey: "v2")
    XCTAssertEqual(view.sizeThatFits(proposedWidth: 300).height, 120, accuracy: 0.5)
    view.frame = NSRect(x: 0, y: 0, width: 300, height: 120)
    view.layoutSubtreeIfNeeded()
    XCTAssertEqual(view.idealSizeMeasurementCount, 1)

    view.isActive = true
    XCTAssertFalse(view.isHidden)
    XCTAssertEqual(view.sizeThatFits(proposedWidth: 300).height, 300, accuracy: 0.5)
    XCTAssertEqual(view.idealSizeMeasurementCount, 2)
  }

  @MainActor
  func testNonKeyWindowSuppressesOnDidLayoutIdealSizeResync() async throws {
    let frame = NSRect(x: 0, y: 0, width: 400, height: 200)
    let window = NSWindow(
      contentRect: frame,
      styleMask: .borderless,
      backing: .buffered,
      defer: true
    )
    window.isReleasedWhenClosed = false
    let container = NSView(frame: frame)
    let view = MacShiftHorizontalClipView(
      rootView: Color.clear.frame(width: 800, height: 120),
      contentKey: "v1"
    )
    view.frame = NSRect(x: 0, y: 0, width: 300, height: 120)
    container.addSubview(view)
    window.contentView = container
    defer { window.close() }

    XCTAssertFalse(window.isKeyWindow)
    _ = view.sizeThatFits(proposedWidth: 300)
    view.layoutSubtreeIfNeeded()
    let baselineCount = view.idealSizeMeasurementCount

    let host = try XCTUnwrap(view.subviews.first)
    host.needsLayout = true
    host.layoutSubtreeIfNeeded()
    await drainMainQueue()

    XCTAssertEqual(view.idealSizeMeasurementCount, baselineCount)
  }
}
