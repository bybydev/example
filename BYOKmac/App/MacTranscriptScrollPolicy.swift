import AppKit
import SwiftUI

enum MacTranscriptScrollPolicy {
  private static let nearBottomTolerance: CGFloat = 24

  static func isNearBottom(
    visibleMaxY: CGFloat,
    contentHeight: CGFloat
  ) -> Bool {
    contentHeight <= 0 || visibleMaxY >= contentHeight - nearBottomTolerance
  }

  static func shouldFollowContentGrowth(
    hasCompletedInitialScroll: Bool,
    followsLatest: Bool,
    isUserDraggingTimeline: Bool,
    isGenerating: Bool
  ) -> Bool {
    hasCompletedInitialScroll
      && followsLatest
      && !isUserDraggingTimeline
      && isGenerating
  }

  static func shouldShowJumpToLatest(
    isNearBottom: Bool,
    hasCompletedInitialScroll: Bool
  ) -> Bool {
    hasCompletedInitialScroll && !isNearBottom
  }
}

struct MacTranscriptScrollSnapshot: Equatable {
  let isNearBottom: Bool
  let contentHeight: CGFloat
  let isUserScrolling: Bool
  let userDidScroll: Bool
}

/// Observe List's native scroll view, including mouse-wheel and keyboard scrolling.
/// Deliver changes after AppKit's layout/notification stack has unwound.
@MainActor
struct MacTranscriptScrollObserver: NSViewRepresentable {
  var isEnabled = true
  var connection: MacTranscriptScrollConnection? = nil
  let onChange: (MacTranscriptScrollSnapshot?, MacTranscriptScrollSnapshot) -> Void

  func makeNSView(context: Context) -> MacTranscriptScrollObservationView {
    let view = MacTranscriptScrollObservationView()
    view.onChange = onChange
    view.connection = connection
    connection?.onConnect = { [weak view] in view?.scheduleUpdate() }
    view.isEnabled = isEnabled
    return view
  }

  func updateNSView(_ nsView: MacTranscriptScrollObservationView, context: Context) {
    nsView.onChange = onChange
    nsView.connection = connection
    nsView.isEnabled = isEnabled
    nsView.scheduleUpdate()
  }

  static func dismantleNSView(_ nsView: MacTranscriptScrollObservationView, coordinator: ()) {
    nsView.connection?.onConnect = nil
    nsView.stopObserving()
  }
}

@MainActor
final class MacTranscriptScrollObservationView: NSView {
  var onChange: ((MacTranscriptScrollSnapshot?, MacTranscriptScrollSnapshot) -> Void)?
  var connection: MacTranscriptScrollConnection?
  private weak var scrollView: NSScrollView?
  private weak var documentView: NSView?
  var isEnabled = true {
    didSet {
      guard isEnabled != oldValue else { return }
      if isEnabled {
        scheduleUpdate()
      } else {
        // Keep the exact List association while dormant. Rediscovering from a
        // common ancestor could otherwise attach to another retained chat.
        NotificationCenter.default.removeObserver(self)
        isObserving = false
        previous = nil
        isUserScrolling = false
        userDidScroll = false
      }
    }
  }
  private var isObserving = false
  private var previous: MacTranscriptScrollSnapshot?
  private var updateScheduled = false
  private var isUserScrolling = false
  private var userDidScroll = false

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil {
      stopObserving()
    } else {
      scheduleUpdate()
    }
  }

  override func layout() {
    super.layout()
    scheduleUpdate()
  }

  func scheduleUpdate() {
    guard isEnabled, !updateScheduled else { return }
    updateScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.updateScheduled = false
      guard self.isEnabled, self.window != nil else { return }
      if let connected = self.connection?.scrollView, connected !== self.scrollView {
        self.observe(connected)
      }
      if self.scrollView?.window !== self.window
        || self.scrollView?.documentView !== self.documentView
      {
        if let list = self.connection?.scrollView ?? (self.connection == nil ? self.findListScrollView() : nil) {
          self.observe(list)
        } else {
          self.stopObserving()
        }
      }
      if let scroll = self.scrollView, !self.isObserving { self.observe(scroll) }
      self.publishSnapshot()
    }
  }

  private func findListScrollView() -> NSScrollView? {
    // The background is a sibling of List's AppKit view. Search the nearest
    // ancestor first, and only accept a table-backed scroll view, not a code
    // block or the composer editor.
    func find(in view: NSView) -> NSScrollView? {
      if let scroll = view as? NSScrollView {
        return scroll.documentView is NSTableView ? scroll : nil
      }
      for child in view.subviews {
        if let scroll = find(in: child) { return scroll }
      }
      return nil
    }

    var ancestor = superview
    while let view = ancestor {
      if let scroll = find(in: view) { return scroll }
      ancestor = view.superview
    }
    return nil
  }

  func observe(_ scroll: NSScrollView) {
    guard isEnabled else { return }
    guard !isObserving || scroll !== scrollView || scroll.documentView !== documentView else { return }
    stopObserving()
    scrollView = scroll
    documentView = scroll.documentView
    isObserving = true
    scroll.clipsToBounds = true
    scroll.contentView.clipsToBounds = true
    scroll.automaticallyAdjustsContentInsets = false
    scroll.contentInsets = NSEdgeInsets()
    let center = NotificationCenter.default
    for name in [
      NSScrollView.willStartLiveScrollNotification,
      NSScrollView.didLiveScrollNotification,
      NSScrollView.didEndLiveScrollNotification,
    ] {
      center.addObserver(self, selector: #selector(scrollChanged(_:)), name: name, object: scroll)
    }
    scroll.contentView.postsBoundsChangedNotifications = true
    center.addObserver(
      self, selector: #selector(geometryChanged(_:)),
      name: NSView.boundsDidChangeNotification, object: scroll.contentView
    )
    if let documentView {
      documentView.postsFrameChangedNotifications = true
      center.addObserver(
        self, selector: #selector(geometryChanged(_:)),
        name: NSView.frameDidChangeNotification, object: documentView
      )
    }
  }

  func stopObserving() {
    NotificationCenter.default.removeObserver(self)
    isObserving = false
    scrollView = nil
    documentView = nil
    previous = nil
    isUserScrolling = false
    userDidScroll = false
  }

  @objc private func scrollChanged(_ notification: Notification) {
    switch notification.name {
    case NSScrollView.willStartLiveScrollNotification:
      isUserScrolling = true
    case NSScrollView.didEndLiveScrollNotification:
      isUserScrolling = false
    default:
      // Legacy mouse wheels can send didLiveScroll without a start/end pair.
      userDidScroll = true
    }
    scheduleUpdate()
  }

  @objc private func geometryChanged(_ notification: Notification) {
    scheduleUpdate()
  }

  private func publishSnapshot() {
    guard let scrollView, let documentView else { return }
    let visible = scrollView.documentVisibleRect
    let distanceToBottom = documentView.isFlipped
      ? documentView.bounds.maxY - visible.maxY
      : visible.minY - documentView.bounds.minY
    let height = documentView.bounds.height
    let current = MacTranscriptScrollSnapshot(
      isNearBottom: MacTranscriptScrollPolicy.isNearBottom(
        visibleMaxY: height - distanceToBottom, contentHeight: height
      ),
      contentHeight: height,
      isUserScrolling: isUserScrolling,
      userDidScroll: userDidScroll
    )
    userDidScroll = false
    guard current != previous || current.userDidScroll else { return }
    let old = previous
    previous = current
    onChange?(old, current)
  }
}


/// Row anchors resolve their enclosing List directly. The connection outlives
/// recycled rows, so scrolling the last row off screen does not stop tracking.
@MainActor
final class MacTranscriptScrollConnection {
  weak var scrollView: NSScrollView?
  var onConnect: (() -> Void)?

  func connect(_ scroll: NSScrollView) {
    guard scroll !== scrollView else { return }
    scrollView = scroll
    onConnect?()
  }
}

@MainActor
struct MacTranscriptScrollAnchor: NSViewRepresentable {
  let connection: MacTranscriptScrollConnection

  func makeNSView(context: Context) -> MacTranscriptScrollAnchorView {
    MacTranscriptScrollAnchorView(connection: connection)
  }

  func updateNSView(_ nsView: MacTranscriptScrollAnchorView, context: Context) {}
}

@MainActor
final class MacTranscriptScrollAnchorView: NSView {
  private let connection: MacTranscriptScrollConnection

  init(connection: MacTranscriptScrollConnection) {
    self.connection = connection
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    DispatchQueue.main.async { [weak self] in
      guard let self, self.window != nil, let scroll = self.enclosingScrollView else { return }
      self.connection.connect(scroll)
    }
  }
}
