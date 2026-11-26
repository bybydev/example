import AppKit
import SwiftUI
import XCTest
@testable import BYOKmac

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
}
