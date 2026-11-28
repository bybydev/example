import AppKit
import QuartzCore
import SwiftUI

enum MacScrollWheelRouting {
  enum Axis: Equatable, Sendable {
    case horizontal
    case vertical
  }

  enum Decision: Equatable, Sendable {
    case passthrough
    case consume
    case horizontal(delta: CGFloat)
  }

  private static let discreteWheelPointsPerLine: CGFloat = 12
  private static let horizontalAxisBias: CGFloat = 1.15

  static func usesHorizontalTableScroll(modifierFlags: NSEvent.ModifierFlags) -> Bool {
    modifierFlags.contains(.shift)
  }

  static func horizontalDelta(deltaX: CGFloat, deltaY: CGFloat) -> CGFloat {
    abs(deltaY) >= abs(deltaX) ? deltaY : deltaX
  }

  static func route(
    deltaX: CGFloat,
    deltaY: CGFloat,
    hasPreciseDeltas: Bool,
    modifierFlags: NSEvent.ModifierFlags,
    phase: NSEvent.Phase,
    momentumPhase: NSEvent.Phase,
    canScrollHorizontally: Bool,
    lockedAxis: inout Axis?
  ) -> Decision {
    if phase == .mayBegin || phase == .began {
      lockedAxis = nil
    }

    if phase == .cancelled || momentumPhase == .cancelled {
      let wasHorizontal = lockedAxis == .horizontal
      lockedAxis = nil
      return wasHorizontal ? .consume : .passthrough
    }

    let isDiscreteEvent = phase.isEmpty && momentumPhase.isEmpty
    if isDiscreteEvent {
      lockedAxis = nil
    }

    let scale: CGFloat = hasPreciseDeltas ? 1 : discreteWheelPointsPerLine

    guard canScrollHorizontally else {
      if momentumPhase == .ended {
        lockedAxis = nil
      }
      return .passthrough
    }

    if usesHorizontalTableScroll(modifierFlags: modifierFlags) {
      let rawDelta = horizontalDelta(deltaX: deltaX, deltaY: deltaY)
      if !isDiscreteEvent && phase != .mayBegin {
        lockedAxis = .horizontal
      }
      if momentumPhase == .ended {
        lockedAxis = nil
      }
      if rawDelta != 0 {
        return .horizontal(delta: rawDelta * scale)
      }
      return phase == .mayBegin ? .passthrough : .consume
    }

    if phase == .mayBegin {
      return .passthrough
    }

    if phase.isEmpty && !momentumPhase.isEmpty {
      let wasHorizontal = lockedAxis == .horizontal
      if momentumPhase == .ended {
        lockedAxis = nil
      }
      guard wasHorizontal else {
        return .passthrough
      }
      return deltaX != 0 ? .horizontal(delta: deltaX * scale) : .consume
    }

    if isDiscreteEvent {
      if deltaX != 0 && abs(deltaX) > abs(deltaY) {
        return .horizontal(delta: deltaX * scale)
      }
      return .passthrough
    }

    if lockedAxis == nil {
      if deltaX == 0 && deltaY == 0 {
        return .consume
      }
      if abs(deltaX) > abs(deltaY) * horizontalAxisBias {
        lockedAxis = .horizontal
      } else {
        lockedAxis = .vertical
      }
    }

    switch lockedAxis {
    case .horizontal:
      return deltaX != 0 ? .horizontal(delta: deltaX * scale) : .consume
    case .vertical, .none:
      return .passthrough
    }
  }
}

/// A lightweight clipped host for wide inline chat content (tables, code blocks,
/// and Mermaid source).
///
/// Vertical wheel/trackpad events are not handled here and continue through the
/// responder chain to the enclosing chat transcript. Horizontal trackpad swipes,
/// horizontal scroll wheels, and Shift + Scroll pan horizontally when content
/// overflows. This avoids nesting another NSScrollView inside SwiftUI List and
/// avoids redispatching wheel events between scroll views.
@MainActor
struct MacHorizontalPassthroughScrollView<Content: View>: NSViewRepresentable {
  private let showsHorizontalIndicator: Bool
  private let allowsContentHitTesting: Bool
  private let contentKey: AnyHashable?
  private let content: Content

  init(
    showsHorizontalIndicator: Bool = false,
    allowsContentHitTesting: Bool = true,
    contentKey: AnyHashable? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.showsHorizontalIndicator = showsHorizontalIndicator
    self.allowsContentHitTesting = allowsContentHitTesting
    self.contentKey = contentKey
    self.content = content()
  }

  func makeNSView(context: Context) -> MacShiftHorizontalClipView<Content> {
    MacShiftHorizontalClipView(
      rootView: content,
      showsHorizontalIndicator: showsHorizontalIndicator,
      allowsContentHitTesting: allowsContentHitTesting,
      contentKey: contentKey
    )
  }

  func updateNSView(
    _ nsView: MacShiftHorizontalClipView<Content>,
    context: Context
  ) {
    nsView.showsHorizontalIndicator = showsHorizontalIndicator
    nsView.allowsContentHitTesting = allowsContentHitTesting
    nsView.updateRootView(content, contentKey: contentKey)
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize,
    nsView: MacShiftHorizontalClipView<Content>,
    context: Context
  ) -> CGSize? {
    nsView.sizeThatFits(proposedWidth: proposal.width)
  }
}

@MainActor
private final class MacPassthroughHostingView<Content: View>: NSHostingView<Content> {
  var onIntrinsicContentSizeInvalidated: (() -> Void)?
  var onDidLayout: (() -> Void)?

  override func invalidateIntrinsicContentSize() {
    super.invalidateIntrinsicContentSize()
    onIntrinsicContentSizeInvalidated?()
  }

  override func layout() {
    super.layout()
    onDidLayout?()
  }
}

@MainActor
final class MacShiftHorizontalClipView<Content: View>: NSView {
  private let hostingView: MacPassthroughHostingView<Content>
  private let indicatorLayer = CALayer()
  private var lastContentKey: AnyHashable?
  private var lastMeasuredIdealSize: CGSize = .zero
  private var documentWidth: CGFloat = 1
  private var horizontalOffset: CGFloat = 0
  private var lockedGestureAxis: MacScrollWheelRouting.Axis?
  private var isUpdatingRootView = false
  private var isApplyingLayout = false
  private var idealSizeSyncTask: Task<Void, Never>?
  private var isIndicatorHighlighted = false
  private var indicatorFadeTask: Task<Void, Never>?

  var showsHorizontalIndicator: Bool {
    didSet {
      guard showsHorizontalIndicator != oldValue else { return }
      updateIndicatorLayer()
    }
  }

  var allowsContentHitTesting: Bool

  override var isFlipped: Bool { true }

  init(
    rootView: Content,
    showsHorizontalIndicator: Bool = false,
    allowsContentHitTesting: Bool = true,
    contentKey: AnyHashable? = nil
  ) {
    self.showsHorizontalIndicator = showsHorizontalIndicator
    self.allowsContentHitTesting = allowsContentHitTesting
    self.lastContentKey = contentKey
    hostingView = MacPassthroughHostingView(rootView: rootView)
    super.init(frame: .zero)

    wantsLayer = true
    layer?.masksToBounds = true
    hostingView.translatesAutoresizingMaskIntoConstraints = true
    hostingView.onIntrinsicContentSizeInvalidated = { [weak self] in
      guard let self, !self.isUpdatingRootView else { return }
      self.needsLayout = true
      self.invalidateIntrinsicContentSize()
    }
    hostingView.onDidLayout = { [weak self] in
      guard let self, !self.isUpdatingRootView, !self.isApplyingLayout else { return }
      self.scheduleIdealSizeSyncIfNeeded()
    }
    addSubview(hostingView)

    indicatorLayer.cornerRadius = 1.75
    indicatorLayer.zPosition = 10
    indicatorLayer.isHidden = true
    layer?.addSublayer(indicatorLayer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    if newWindow == nil {
      idealSizeSyncTask?.cancel()
      idealSizeSyncTask = nil
      indicatorFadeTask?.cancel()
      indicatorFadeTask = nil
      lockedGestureAxis = nil
    }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateIndicatorColor()
  }

  func updateRootView(_ rootView: Content, contentKey: AnyHashable? = nil) {
    if let contentKey, let lastContentKey, contentKey == lastContentKey {
      return
    }
    lastContentKey = contentKey
    isUpdatingRootView = true
    defer { isUpdatingRootView = false }
    hostingView.rootView = rootView
    hostingView.invalidateIntrinsicContentSize()
    needsLayout = true
  }

  private func measureIdealSize() -> CGSize {
    let ideal = hostingView.fittingSize
    lastMeasuredIdealSize = ideal
    return ideal
  }

  private func scheduleIdealSizeSyncIfNeeded() {
    guard idealSizeSyncTask == nil else { return }
    idealSizeSyncTask = Task { @MainActor [weak self] in
      guard let self, !Task.isCancelled else { return }
      self.idealSizeSyncTask = nil
      let ideal = self.hostingView.fittingSize
      let changed =
        abs(ideal.width - self.lastMeasuredIdealSize.width) > 0.5
        || abs(ideal.height - self.lastMeasuredIdealSize.height) > 0.5
      guard changed else { return }
      self.lastMeasuredIdealSize = ideal
      self.needsLayout = true
      self.invalidateIntrinsicContentSize()
    }
  }

  func sizeThatFits(proposedWidth: CGFloat?) -> CGSize {
    // SwiftUI can probe several widths while its layout graph is updating.
    // Only measure here: changing the hosting view's frame or forcing layout
    // reenters that graph and can abort inside AttributeGraph on macOS 15.
    let ideal = measureIdealSize()
    let viewportWidth = max(proposedWidth ?? ideal.width, 1)
    return CGSize(width: viewportWidth, height: max(ideal.height, 1))
  }

  override func layout() {
    super.layout()
    isApplyingLayout = true
    defer { isApplyingLayout = false }
    // Apply geometry only after the parent has assigned the actual viewport.
    let ideal = measureIdealSize()
    documentWidth = max(bounds.width, ideal.width, 1)
    horizontalOffset = min(horizontalOffset, max(documentWidth - bounds.width, 0))
    let targetFrame = NSRect(
      x: -horizontalOffset,
      y: 0,
      width: documentWidth,
      height: max(ideal.height, bounds.height, 1)
    )
    if hostingView.frame != targetFrame {
      hostingView.frame = targetFrame
    }
    updateIndicatorLayer()
  }

  private func applyHorizontalOffset() {
    isApplyingLayout = true
    defer { isApplyingLayout = false }
    let targetOrigin = NSPoint(x: -horizontalOffset, y: 0)
    if hostingView.frame.origin != targetOrigin {
      var frame = hostingView.frame
      frame.origin = targetOrigin
      hostingView.frame = frame
    }
    updateIndicatorLayer()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    if !allowsContentHitTesting {
      guard !isHiddenOrHasHiddenAncestor, alphaValue > 0.01 else { return nil }
      let isInside = superview?.isMousePoint(point, in: frame) ?? frame.contains(point)
      return isInside ? self : nil
    }
    return super.hitTest(point)
  }

  override func scrollWheel(with event: NSEvent) {
    let maximumOffset = max(documentWidth - bounds.width, 0)
    let decision = MacScrollWheelRouting.route(
      deltaX: event.scrollingDeltaX,
      deltaY: event.scrollingDeltaY,
      hasPreciseDeltas: event.hasPreciseScrollingDeltas,
      modifierFlags: event.modifierFlags,
      phase: event.phase,
      momentumPhase: event.momentumPhase,
      canScrollHorizontally: maximumOffset > 0.5,
      lockedAxis: &lockedGestureAxis
    )

    switch decision {
    case .passthrough:
      // NSView's default implementation forwards unhandled scrolling through
      // the responder chain, allowing the enclosing List to scroll normally.
      super.scrollWheel(with: event)
    case .consume:
      break
    case .horizontal(let delta):
      guard delta != 0, maximumOffset > 0.5 else { return }
      let updatedOffset = min(max(horizontalOffset - delta, 0), maximumOffset)
      if updatedOffset != horizontalOffset {
        horizontalOffset = updatedOffset
        applyHorizontalOffset()
      }
      highlightIndicatorTemporarily()
    }
  }

  private func updateIndicatorLayer() {
    if indicatorLayer.superlayer == nil, let backingLayer = layer {
      backingLayer.addSublayer(indicatorLayer)
    }
    let maximumOffset = max(documentWidth - bounds.width, 0)
    guard showsHorizontalIndicator, maximumOffset > 0.5, bounds.width > 24, bounds.height > 10 else {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      indicatorLayer.isHidden = true
      CATransaction.commit()
      return
    }

    let horizontalInset: CGFloat = 6
    let indicatorHeight: CGFloat = 3.5
    let bottomInset: CGFloat = 3
    let trackWidth = max(bounds.width - horizontalInset * 2, 0)
    let visibleRatio = bounds.width / max(documentWidth, 1)
    let thumbWidth = min(trackWidth, max(28, trackWidth * visibleRatio))
    let progress = min(max(horizontalOffset / maximumOffset, 0), 1)
    let thumbX = horizontalInset + progress * max(trackWidth - thumbWidth, 0)
    let thumbY = max(bounds.height - indicatorHeight - bottomInset, 0)

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    indicatorLayer.isHidden = false
    indicatorLayer.frame = CGRect(
      x: thumbX,
      y: thumbY,
      width: thumbWidth,
      height: indicatorHeight
    )
    CATransaction.commit()
    updateIndicatorColor()
  }

  private func updateIndicatorColor() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      indicatorLayer.backgroundColor = NSColor.labelColor
        .withAlphaComponent(isIndicatorHighlighted ? 0.36 : 0.16)
        .cgColor
    }
  }

  private func highlightIndicatorTemporarily() {
    guard showsHorizontalIndicator else { return }
    if !isIndicatorHighlighted {
      isIndicatorHighlighted = true
      updateIndicatorColor()
    }
    indicatorFadeTask?.cancel()
    indicatorFadeTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(900))
      guard let self, !Task.isCancelled else { return }
      self.isIndicatorHighlighted = false
      self.updateIndicatorColor()
    }
  }
}
