import AppKit
import SwiftUI

enum MacScrollWheelRouting {
  static func usesHorizontalTableScroll(modifierFlags: NSEvent.ModifierFlags) -> Bool {
    modifierFlags.contains(.shift)
  }

  static func horizontalDelta(deltaX: CGFloat, deltaY: CGFloat) -> CGFloat {
    abs(deltaY) >= abs(deltaX) ? deltaY : deltaX
  }
}

/// A lightweight clipped host for wide Markdown tables.
///
/// Normal wheel/trackpad events are not handled here and continue through the
/// responder chain to the enclosing chat transcript. Holding Shift opts into
/// horizontal table scrolling. This avoids nesting another NSScrollView inside
/// SwiftUI List and avoids redispatching wheel events between scroll views.
@MainActor
struct MacHorizontalPassthroughScrollView<Content: View>: NSViewRepresentable {
  private let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  func makeNSView(context: Context) -> MacShiftHorizontalClipView<Content> {
    MacShiftHorizontalClipView(rootView: content)
  }

  func updateNSView(
    _ nsView: MacShiftHorizontalClipView<Content>,
    context: Context
  ) {
    nsView.updateRootView(content)
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
final class MacShiftHorizontalClipView<Content: View>: NSView {
  private let hostingView: NSHostingView<Content>
  private var documentWidth: CGFloat = 1
  private var horizontalOffset: CGFloat = 0

  override var isFlipped: Bool { true }

  init(rootView: Content) {
    hostingView = NSHostingView(rootView: rootView)
    super.init(frame: .zero)

    wantsLayer = true
    layer?.masksToBounds = true
    hostingView.translatesAutoresizingMaskIntoConstraints = true
    addSubview(hostingView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func updateRootView(_ rootView: Content) {
    hostingView.rootView = rootView
    hostingView.invalidateIntrinsicContentSize()
    needsLayout = true
  }

  func sizeThatFits(proposedWidth: CGFloat?) -> CGSize {
    // SwiftUI can probe several widths while its layout graph is updating.
    // Only measure here: changing the hosting view's frame or forcing layout
    // reenters that graph and can abort inside AttributeGraph on macOS 15.
    let ideal = hostingView.fittingSize
    let viewportWidth = max(proposedWidth ?? ideal.width, 1)
    return CGSize(width: viewportWidth, height: max(ideal.height, 1))
  }

  override func layout() {
    super.layout()
    // Apply geometry only after the parent has assigned the actual viewport.
    let ideal = hostingView.fittingSize
    documentWidth = max(bounds.width, ideal.width, 1)
    horizontalOffset = min(horizontalOffset, max(documentWidth - bounds.width, 0))
    hostingView.frame = NSRect(
      x: -horizontalOffset,
      y: 0,
      width: documentWidth,
      height: max(ideal.height, bounds.height, 1)
    )
  }

  override func scrollWheel(with event: NSEvent) {
    guard MacScrollWheelRouting.usesHorizontalTableScroll(modifierFlags: event.modifierFlags) else {
      // NSView's default implementation forwards unhandled scrolling through
      // the responder chain, allowing the enclosing List to scroll normally.
      super.scrollWheel(with: event)
      return
    }

    let delta = MacScrollWheelRouting.horizontalDelta(
      deltaX: event.scrollingDeltaX,
      deltaY: event.scrollingDeltaY
    )
    guard delta != 0 else { return }

    let maximumOffset = max(documentWidth - bounds.width, 0)
    guard maximumOffset > 0 else { return }

    horizontalOffset = min(max(horizontalOffset - delta, 0), maximumOffset)
    needsLayout = true
  }
}
