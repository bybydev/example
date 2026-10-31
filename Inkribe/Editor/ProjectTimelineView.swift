import AppFoundation
import SwiftUI
import UIKit

struct ProjectTimelineView: UIViewRepresentable {
    @Environment(\.appFoundationTheme) private var theme
    let session: EditorSession
    var isActive: Bool
    var onInteraction: () -> Void
    var onCaption: (UUID) -> Void
    var onClip: (UUID) -> Void
    var onMusic: () -> Void
    var onCaptions: () -> Void

    func makeUIView(context: Context) -> TimelineViewport { TimelineViewport(frame: .zero) }
    func updateUIView(_ view: TimelineViewport, context: Context) {
        view.onInteraction = onInteraction
        view.onCaption = onCaption; view.onClip = onClip
        view.onMusic = onMusic; view.onCaptions = onCaptions
        view.onOriginalMute = { [weak session] in
            guard let session else { return }
            session.setOriginalAudioMuted(session.document?.isOriginalAudioMuted != true)
        }
        view.onSeek = { [weak session] in session?.scrub(seconds: $0) }
        view.onScale = { [weak session] in session?.workspace.timelineScale = $0 }
        view.onTimingBegin = { [weak session] in session?.beginTimelineTiming(cueID: $0, operation: $1) }
        view.onTimingCurrent = { [weak session] in session?.timelineTimingIsCurrent($0) ?? false }
        view.onTimingCommit = { [weak session] in session?.commitTimelineTiming($0, interval: $1) ?? false }
        view.onClipTrimBegin = { [weak session] in session?.beginClipTrim($0, edge: $1) }
        view.onClipTrimCurrent = { [weak session] in session?.clipTrimIsCurrent($0) ?? false }
        view.onClipTrimPreview = { [weak session] in session?.previewClipTrim($0, range: $1) }
        view.onClipTrimEnd = { [weak session] plan, range in
            if let range { session?.commitClipTrim(plan, range: range) }
            else { session?.cancelClipTrim(plan) }
        }
        view.update(snapshot: session.timelineSnapshot, urls: session.timelineSourceURLs,
            seconds: EditorTime.seconds(session.time), playing: session.isPlaying, scale: session.workspace.timelineScale,
            selectedCaption: session.workspace.timelineCueID, selectedClip: session.workspace.timelineClipID,
            accent: UIColor(theme.accentColor), enabled: isActive)
    }
    static func dismantleUIView(_ view: TimelineViewport, coordinator: ()) { view.stop() }
}

/// UIScrollView owns horizontal drag/deceleration. A viewport-sized canvas draws
/// only the current time window; programmatic playback never feeds back a seek.
@MainActor
final class TimelineViewport: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let scroll = UIScrollView()
    private let canvas = TimelineTrackCanvas(frame: .zero)
    private let playhead = UIView()
    private let thumbnails = TimelineThumbnailLoader()
    private let musicWaveform = TimelineMusicWaveform()
    private var snapshot: ProjectTimelineSnapshot?
    private var scale = 48.0
    private var seconds = 0.0
    private var enabled = true
    private var wasPlaying = false
    private var updatingOffset = false
    private var pinching = false
    private var pinchInitialScale = 48.0
    private var pinchTime = 0.0
    private var pendingSeek: Double?
    private var seekTask: Task<Void, Never>?
    private var seekToken = UUID()
    private var previousSize = CGSize.zero
    private var accessibilityOffset = -Double.infinity
    private var accessibilityDirty = true
    private var thumbnailWindow: String?
    var onInteraction: (() -> Void)?
    var onCaption: ((UUID) -> Void)?
    var onClip: ((UUID) -> Void)?
    var onMusic: (() -> Void)?
    var onCaptions: (() -> Void)?
    var onOriginalMute: (() -> Void)?
    var onSeek: ((Double) -> Void)?
    var onScale: ((Double) -> Void)?
    var onTimingBegin: ((UUID, TimelineTimingOperation) -> TimelineCaptionTiming?)?
    var onTimingCurrent: ((TimelineCaptionTiming) -> Bool)?
    var onTimingCommit: ((TimelineCaptionTiming, MediaInterval) -> Bool)?
    var onClipTrimBegin: ((UUID, ClipTrimEdge) -> TimelineClipTrim?)?
    var onClipTrimCurrent: ((TimelineClipTrim) -> Bool)?
    var onClipTrimPreview: ((TimelineClipTrim, ClipSourceTrim) -> Void)?
    var onClipTrimEnd: ((TimelineClipTrim, ClipSourceTrim?) -> Void)?
    private var clipPan: UIPanGestureRecognizer?
    private var pendingClipHit: (UUID, ClipTrimEdge)?
    private var clipGesture: ActiveClipTrim?
    private var timingPan: UIPanGestureRecognizer?
    private var timingHold: UILongPressGestureRecognizer?
    private var pinchRecognizer: UIPinchGestureRecognizer?
    private var pendingTimingHit: (UUID, TimelineTimingOperation)?
    private var pendingHoldCue: UUID?
    private var timingGesture: ActiveTimelineTiming?
    private var timingOwner: UIGestureRecognizer?
    private var timingLink: CADisplayLink?
    private var timingTick = 0.0

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        scroll.delegate = self
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.decelerationRate = .fast
        scroll.isDirectionalLockEnabled = true
        scroll.alwaysBounceVertical = false
        scroll.addSubview(canvas)
        addSubview(scroll)
        playhead.backgroundColor = .label
        playhead.layer.cornerRadius = 1
        playhead.isUserInteractionEnabled = false
        playhead.isAccessibilityElement = false
        addSubview(playhead)
        canvas.thumbnails = thumbnails
        canvas.musicWaveform = musicWaveform
        musicWaveform.onChange = { [weak canvas] in canvas?.setNeedsDisplay() }
        thumbnails.onChange = { [weak canvas] in canvas?.setNeedsDisplay() }
        canvas.onCaption = { [weak self] id in
            guard let self, self.enabled else { return }
            self.canvas.timingMessage = nil
            self.stopUserScrolling(); self.onInteraction?(); self.onCaption?(id)
        }
        canvas.onClip = { [weak self] id in
            guard let self, self.enabled else { return }
            self.canvas.timingMessage = nil
            self.stopUserScrolling(); self.onInteraction?(); self.onClip?(id)
        }
        canvas.onMusic = { [weak self] in
            guard let self, self.enabled else { return }
            self.stopUserScrolling(); self.onInteraction?(); self.onMusic?()
        }
        canvas.onCaptions = { [weak self] in
            guard let self, self.enabled else { return }
            self.stopUserScrolling(); self.onInteraction?(); self.onCaptions?()
        }
        canvas.onOriginalMute = { [weak self] in
            guard let self, self.enabled else { return }
            self.stopUserScrolling(); self.onInteraction?(); self.onOriginalMute?()
        }
        canvas.onSeek = { [weak self] time in
            guard let self, self.enabled else { return }
            self.stopUserScrolling(); self.onInteraction?(); self.seek(to: time, final: true)
        }
        canvas.onZoom = { [weak self] factor in self?.zoom(by: factor) }
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)
        pinchRecognizer = pinch
        let pan = UIPanGestureRecognizer(target: self, action: #selector(timingPanned(_:)))
        pan.maximumNumberOfTouches = 1; pan.delegate = self
        addGestureRecognizer(pan); timingPan = pan
        scroll.panGestureRecognizer.require(toFail: pan)
        canvas.requireTapFailure(of: pan)
        let clip = UIPanGestureRecognizer(target: self, action: #selector(clipPanned(_:)))
        clip.maximumNumberOfTouches = 1; clip.delegate = self
        addGestureRecognizer(clip); clipPan = clip
        scroll.panGestureRecognizer.require(toFail: clip)
        canvas.requireTapFailure(of: clip)
        canvas.onClipTrimAction = { [weak self] in self?.accessibleClipTrim(id: $0, edge: $1, delta: $2) ?? false }
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(timingHeld(_:)))
        hold.minimumPressDuration = 0.3; hold.allowableMovement = 12; hold.delegate = self
        addGestureRecognizer(hold); timingHold = hold
        canvas.requireTapFailure(of: hold)
        canvas.onTimingAction = { [weak self] in self?.accessibleTiming(cueID: $0, operation: $1, delta: $2) ?? false }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var userIsScrolling: Bool { scroll.isDragging || scroll.isDecelerating || pinching || timingGesture != nil || clipGesture != nil }

    func update(snapshot: ProjectTimelineSnapshot?, urls: [UUID: URL], seconds: Double, playing: Bool, scale: Double,
                selectedCaption: UUID?, selectedClip: UUID?, accent: UIColor, enabled: Bool) {
        let changed = self.snapshot?.id != snapshot?.id
        let sourceChanged = canvas.sourceURLs != urls
        let selectionChanged = canvas.selectedCaptionID != selectedCaption || canvas.selectedClipID != selectedClip
        self.snapshot = snapshot; self.seconds = seconds; self.enabled = enabled
        if !enabled || (playing && !wasPlaying) {
            finishClipTrim(commit: false)
            finishTiming(commit: false)
            stopUserScrolling()
        }
        if let edit = timingGesture, changed || selectionChanged,
           (onTimingCurrent?(edit.plan) != true || selectedCaption != edit.plan.cueID) {
            finishTiming(commit: false)
            canvas.timingMessage = "Caption changed; try again"
        }
        if let edit = clipGesture, changed || selectionChanged,
           (onClipTrimCurrent?(edit.plan) != true || selectedClip != edit.plan.clip.id) {
            finishClipTrim(commit: false)
            canvas.timingMessage = "Clip changed; try again"
        }
        wasPlaying = playing
        isUserInteractionEnabled = enabled
        canvas.snapshot = snapshot; canvas.sourceURLs = urls; canvas.accent = accent
        canvas.selectedCaptionID = selectedCaption; canvas.selectedClipID = selectedClip
        accessibilityDirty = accessibilityDirty || changed || selectionChanged
        if changed || sourceChanged { thumbnailWindow = nil }
        // A project edit (e.g. trim) invalidates an in-flight drag/seek context.
        if changed {
            cancelPendingSeek()
            if scroll.isDecelerating { stopUserScrolling() }
        }
        if !pinching && timingGesture == nil && clipGesture == nil { self.scale = clampedScale(scale) }
        updateGeometry()
        if !userIsScrolling { setOffset(seconds * self.scale) }
        refreshViewport()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let resized = previousSize != bounds.size
        if resized { finishClipTrim(commit: false); finishTiming(commit: false); stopUserScrolling() }
        updatingOffset = true
        scroll.frame = bounds
        playhead.frame = CGRect(x: bounds.midX - 1, y: 0, width: 2,
            height: min(bounds.height, CGFloat(TimelineGeometry.captionTop + TimelineGeometry.captionHeight + 8)))
        if resized {
            previousSize = bounds.size
            scale = clampedScale(scale)
            updateGeometry()
            setOffset(seconds * scale)
            accessibilityDirty = true; thumbnailWindow = nil
        }
        updatingOffset = false
        refreshViewport()
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        thumbnailWindow = nil
        if window == nil { finishClipTrim(commit: false); finishTiming(commit: false); cancelPendingSeek() }
        refreshViewport()
    }
    private func clampedScale(_ value: Double) -> Double {
        let duration = max(0.001, snapshot?.duration ?? 1)
        let minimum = min(12, Double(max(1, bounds.width)) / duration)
        // Bound UIKit content coordinates as well as thumbnail memory.
        let maximum = max(minimum, min(320, 8_000_000 / duration))
        return min(maximum, max(minimum, value.isFinite ? value : 48))
    }
    private func updateGeometry() {
        scroll.contentSize = CGSize(width: max(bounds.width, CGFloat((snapshot?.duration ?? 0) * scale) + bounds.width),
            height: bounds.height)
        canvas.pointsPerSecond = scale
    }
    private func setOffset(_ value: Double) {
        let bounded = max(0, min((snapshot?.duration ?? 0) * scale, value))
        guard abs(Double(scroll.contentOffset.x) - bounded) > 0.01 else { return }
        updatingOffset = true
        scroll.setContentOffset(CGPoint(x: bounded, y: 0), animated: false)
        updatingOffset = false
    }
    private func refreshViewport() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        canvas.frame = CGRect(origin: CGPoint(x: scroll.contentOffset.x, y: 0), size: bounds.size)
        canvas.contentOffsetX = Double(scroll.contentOffset.x)
        canvas.updateLayerControls()
        canvas.setNeedsDisplay()
        if accessibilityDirty || abs(canvas.contentOffsetX - accessibilityOffset) >= 48 {
            canvas.updateAccessibility()
            accessibilityOffset = canvas.contentOffsetX; accessibilityDirty = false
        }
        updateThumbnails()
        updateMusicWaveform()
    }

    private func updateMusicWaveform() {
        let request: MusicWaveformRequest? = snapshot?.music.flatMap { music in
            canvas.sourceURLs[music.asset.id].map { url in
                MusicWaveformRequest(assetID: music.asset.id, fingerprint: music.asset.sha256, url: url,
                    duration: EditorTime.seconds(music.asset.metadata.duration))
            }
        }
        musicWaveform.update(request, enabled: enabled && window != nil)
    }
    private func updateThumbnails() {
        guard let snapshot else { thumbnails.update([], enabled: false); return }
        let active = enabled && window != nil
        // Refresh on half-tile boundaries, not every AVPlayer tick. Prefetch one
        // screen in each direction; visible tile midpoints sort ahead of neighbors.
        let bucket = Int(floor(canvas.contentOffsetX / 32))
        let key = "\(snapshot.id)/\(bucket)/\(scale)/\(Int(bounds.width))/\(active)"
        guard thumbnailWindow != key else { return }
        thumbnailWindow = key
        let range = canvas.visibleRange(padding: Double(bounds.width))
        let visible = canvas.visibleRange()
        var candidates: [(TimelineFrameRequest, Double)] = []
        for clip in snapshot.visibleClips(range) where clip.kind == .video && clip.end > range.lowerBound {
            // At far zoom-out a subpixel clip is a boundary stripe, not a decoder.
            guard (clip.end - clip.start) * scale >= 2 else { continue }
            for tile in TimelineGeometry.tiles(clip: clip, range: range, scale: scale,
                projectID: snapshot.projectID, urls: canvas.sourceURLs) {
                guard let request = tile.request else { continue }
                let middle = (tile.start + tile.end) / 2
                let outside = middle < visible.lowerBound || middle > visible.upperBound
                candidates.append((request, abs(middle - centerTime) + (outside ? Double(bounds.width) / scale * 4 : 0)))
            }
        }
        candidates.sort { $0.1 < $1.1 }
        thumbnails.update(candidates.map(\.0), enabled: active)
    }
    private var centerTime: Double {
        min(snapshot?.duration ?? 0, max(0, Double(scroll.contentOffset.x) / scale))
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        cancelPendingSeek()
        onInteraction?()
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        refreshViewport()
        guard enabled, !updatingOffset, !pinching, scrollView.isDragging || scrollView.isDecelerating else { return }
        seek(to: centerTime, final: false)
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !updatingOffset && enabled && !decelerate && !pinching { seek(to: centerTime, final: true) }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        if !updatingOffset && enabled && !pinching { seek(to: centerTime, final: true) }
    }
    private func seek(to time: Double, final: Bool) {
        if final {
            cancelPendingSeek()
            seconds = time
            onSeek?(time)
            return
        }
        pendingSeek = time
        guard seekTask == nil else { return }
        let token = UUID(); seekToken = token
        seekTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
            guard let self, self.seekToken == token, let value = self.pendingSeek else { return }
            self.seekTask = nil; self.pendingSeek = nil
            self.seconds = value; self.onSeek?(value)
        }
    }
    private func stopUserScrolling() {
        cancelPendingSeek()
        updatingOffset = true
        if scroll.isDragging {
            scroll.panGestureRecognizer.isEnabled = false
            scroll.panGestureRecognizer.isEnabled = true
        }
        scroll.setContentOffset(scroll.contentOffset, animated: false)
        updatingOffset = false
    }
    private func cancelPendingSeek() {
        seekTask?.cancel(); seekTask = nil; pendingSeek = nil; seekToken = UUID()
    }
    @objc private func pinched(_ pinch: UIPinchGestureRecognizer) {
        guard snapshot != nil, timingGesture == nil, clipGesture == nil else { return }
        let location = Double(pinch.location(in: self).x)
        switch pinch.state {
        case .began:
            pinching = true
            cancelPendingSeek()
            onInteraction?()
            scroll.panGestureRecognizer.isEnabled = false
            scroll.setContentOffset(scroll.contentOffset, animated: false)
            pinchInitialScale = scale
            pinchTime = max(0, min(snapshot?.duration ?? 0,
                (Double(scroll.contentOffset.x) + location - Double(bounds.width / 2)) / scale))
        case .changed:
            scale = clampedScale(pinchInitialScale * Double(pinch.scale))
            updateGeometry()
            setOffset(pinchTime * scale + Double(bounds.width / 2) - location)
            seek(to: centerTime, final: false)
            onScale?(scale)
            accessibilityDirty = true
            refreshViewport()
        case .ended, .cancelled, .failed:
            guard pinching else { return }
            scroll.panGestureRecognizer.isEnabled = true
            if enabled {
                onScale?(scale)
                seek(to: centerTime, final: true)
            }
            pinching = false
            accessibilityDirty = true; refreshViewport()
        default: break
        }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        (gestureRecognizer is UIPinchGestureRecognizer && otherGestureRecognizer === scroll.panGestureRecognizer) ||
            (otherGestureRecognizer is UIPinchGestureRecognizer && gestureRecognizer === scroll.panGestureRecognizer)
    }
    private func zoom(by factor: Double) {
        guard enabled, timingGesture == nil, clipGesture == nil else { return }
        stopUserScrolling()
        onInteraction?()
        let time = centerTime
        scale = clampedScale(scale * factor)
        updateGeometry(); setOffset(time * scale)
        onScale?(scale)
        seek(to: time, final: true)
        accessibilityDirty = true; refreshViewport()
    }
    // UIView already owns this Objective-C selector. Override it in the class
    // body rather than redeclaring a delegate witness in a Swift extension.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === clipPan, let pan = clipPan {
            let delta = pan.translation(in: self)
            return enabled && clipGesture == nil && timingGesture == nil && !pinching && pendingClipHit != nil && abs(delta.x) > abs(delta.y)
        }
        if gestureRecognizer === timingPan, let pan = timingPan {
            let delta = pan.translation(in: self)
            return enabled && clipGesture == nil && timingGesture == nil && !pinching && pendingTimingHit != nil && abs(delta.x) > abs(delta.y)
        }
        if gestureRecognizer === timingHold { return enabled && clipGesture == nil && timingGesture == nil && !pinching && pendingHoldCue != nil }
        return clipGesture == nil && timingGesture == nil && super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    func stop() {
        enabled = false
        finishClipTrim(commit: false)
        finishTiming(commit: false)
        cancelPendingSeek()
        scroll.delegate = nil
        thumbnails.stop()
        musicWaveform.stop()
        onMusic = nil; onCaptions = nil; onOriginalMute = nil
        canvas.onMusic = nil; canvas.onCaptions = nil; canvas.onOriginalMute = nil
        onInteraction = nil; onCaption = nil; onClip = nil; onSeek = nil; onScale = nil
        canvas.onCaption = nil; canvas.onClip = nil; canvas.onSeek = nil; canvas.onZoom = nil; canvas.onTimingAction = nil
        onTimingBegin = nil; onTimingCurrent = nil; onTimingCommit = nil
        onClipTrimBegin = nil; onClipTrimCurrent = nil; onClipTrimPreview = nil; onClipTrimEnd = nil
        canvas.onClipTrimAction = nil
    }
}


private struct ActiveClipTrim {
    let plan: TimelineClipTrim
    let initialX: Double
    let initialOffset: Double
    var touchX: Double
    var extraDelta = 0.0
    var proposed: ClipSourceTrim
}

private struct ActiveTimelineTiming {
    let plan: TimelineCaptionTiming
    let caption: ProjectTimelineSnapshot.Caption
    let initialX: Double
    let initialOffset: Double
    let originalSeconds: Double
    var touchX: Double
    var proposed: MediaInterval
}

extension TimelineViewport {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var touchedView = touch.view
        while let view = touchedView, view !== self {
            if view is UIControl { return false }
            touchedView = view.superview
        }
        if clipGesture != nil { finishClipTrim(commit: false); return false }
        if gestureRecognizer === clipPan {
            pendingClipHit = enabled && !pinching && timingGesture == nil ? canvas.clipTrimHit(at: touch.location(in: canvas)) : nil
            return pendingClipHit != nil
        }
        if timingGesture != nil {
            // A second finger must not turn a held caption into a centroid jump.
            finishTiming(commit: false, restorePlayhead: true)
            return false
        }
        if gestureRecognizer === timingPan {
            pendingTimingHit = enabled && !pinching ? canvas.timingHit(at: touch.location(in: canvas)) : nil
            return pendingTimingHit != nil
        }
        if gestureRecognizer === timingHold {
            pendingHoldCue = enabled && !pinching ? canvas.captionHit(at: touch.location(in: canvas)) : nil
            return pendingHoldCue != nil
        }
        return timingGesture == nil && clipGesture == nil
    }
    @objc private func clipPanned(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            guard let (id, edge) = pendingClipHit, clipGesture == nil, timingGesture == nil else { return }
            stopUserScrolling(); onInteraction?()
            guard let plan = onClipTrimBegin?(id, edge) else { return }
            let point = pan.location(in: self)
            clipGesture = ActiveClipTrim(plan: plan, initialX: Double(point.x - pan.translation(in: self).x),
                initialOffset: Double(scroll.contentOffset.x), touchX: Double(point.x), proposed: plan.original)
            scroll.isScrollEnabled = false; pinchRecognizer?.isEnabled = false
            canvas.timingMessage = nil
            let target = TimelineTimingDisplayTarget(viewport: self)
            let link = CADisplayLink(target: target, selector: #selector(TimelineTimingDisplayTarget.tick(_:)))
            timingLink = link; timingTick = 0; link.add(to: .main, forMode: .common)
            updateClipTrim(touchX: Double(point.x))
        case .changed: updateClipTrim(touchX: Double(pan.location(in: self).x))
        case .ended:
            updateClipTrim(touchX: Double(pan.location(in: self).x)); finishClipTrim(commit: true)
        case .cancelled, .failed: finishClipTrim(commit: false)
        default: break
        }
    }
    private func updateClipTrim(touchX: Double) {
        guard var edit = clipGesture else { return }
        edit.touchX = touchX
        let delta = (touchX - edit.initialX + Double(scroll.contentOffset.x) - edit.initialOffset) / scale + edit.extraDelta
        guard let range = try? edit.plan.proposal(delta: delta) else { return }
        edit.proposed = range; clipGesture = edit
        let left = EditorTime.seconds(range.start) - EditorTime.seconds(edit.plan.original.start)
        let right = EditorTime.seconds(range.end) - EditorTime.seconds(edit.plan.original.end)
        canvas.clipTrimPreview = TimelineClipTrimDrawing(clipID: edit.plan.clip.id,
            start: edit.plan.outputStart + left, end: edit.plan.outputEnd + right, range: range)
        onClipTrimPreview?(edit.plan, range)
        canvas.setNeedsDisplay()
    }
    private func clipDisplayTick(_ link: CADisplayLink) {
        guard var edit = clipGesture, enabled, window != nil else { return }
        let elapsed = timingTick == 0 ? 0 : min(1.0 / 15, link.timestamp - timingTick)
        timingTick = link.timestamp
        let margin = 40.0, width = Double(bounds.width)
        let edge = edit.touchX < margin ? max(-1, (edit.touchX - margin) / margin) :
            edit.touchX > width - margin ? min(1, (edit.touchX - width + margin) / margin) : 0
        guard edge != 0, elapsed > 0 else { return }
        let delta = (edit.touchX - edit.initialX + Double(scroll.contentOffset.x) - edit.initialOffset) / scale + edit.extraDelta
        guard let farther = try? edit.plan.proposal(delta: delta + edge * max(1 / scale, 1 / edit.plan.frameRate)), farther != edit.proposed else { return }
        let before = Double(scroll.contentOffset.x), desired = edge * 160 * elapsed
        setOffset(before + desired)
        edit.extraDelta += (desired - (Double(scroll.contentOffset.x) - before)) / scale
        clipGesture = edit
        refreshViewport(); updateClipTrim(touchX: edit.touchX)
    }
    private func finishClipTrim(commit: Bool) {
        guard let edit = clipGesture else { return }
        clipGesture = nil; pendingClipHit = nil; canvas.clipTrimPreview = nil
        timingLink?.invalidate(); timingLink = nil; timingTick = 0
        scroll.isScrollEnabled = true; pinchRecognizer?.isEnabled = true
        cancelPendingSeek()
        onClipTrimEnd?(edit.plan, commit && enabled ? edit.proposed : nil)
        accessibilityDirty = true; refreshViewport()
    }
    private func accessibleClipTrim(id: UUID, edge: ClipTrimEdge, delta: Double) -> Bool {
        guard enabled, timingGesture == nil, clipGesture == nil else { return false }
        stopUserScrolling(); onInteraction?()
        guard let plan = onClipTrimBegin?(id, edge) else { return false }
        guard let range = try? plan.proposal(delta: delta), range != plan.original else {
            onClipTrimEnd?(plan, nil); return false
        }
        onClipTrimEnd?(plan, range); return true
    }

    @objc private func timingPanned(_ pan: UIPanGestureRecognizer) {
        guard pan.state == .began || timingOwner === pan else { return }
        switch pan.state {
        case .began:
            guard let (id, operation) = pendingTimingHit else { return }
            let point = pan.location(in: self)
            beginTiming(cueID: id, operation: operation, owner: pan,
                initialX: Double(point.x - pan.translation(in: self).x), currentX: Double(point.x))
        case .changed: updateTiming(touchX: Double(pan.location(in: self).x))
        case .ended:
            updateTiming(touchX: Double(pan.location(in: self).x)); finishTiming(commit: true)
        case .cancelled, .failed: finishTiming(commit: false, restorePlayhead: true)
        default: break
        }
    }
    @objc private func timingHeld(_ hold: UILongPressGestureRecognizer) {
        guard hold.state == .began || timingOwner === hold else { return }
        if hold.numberOfTouches > 1 { finishTiming(commit: false, restorePlayhead: true); return }
        switch hold.state {
        case .began:
            guard let id = pendingHoldCue else { return }
            let x = Double(hold.location(in: self).x)
            beginTiming(cueID: id, operation: .move, owner: hold, initialX: x, currentX: x)
        case .changed: updateTiming(touchX: Double(hold.location(in: self).x))
        case .ended:
            updateTiming(touchX: Double(hold.location(in: self).x)); finishTiming(commit: true)
        case .cancelled, .failed: finishTiming(commit: false, restorePlayhead: true)
        default: break
        }
    }
    private func beginTiming(cueID: UUID, operation: TimelineTimingOperation, owner: UIGestureRecognizer, initialX: Double, currentX: Double) {
        guard enabled, timingGesture == nil, clipGesture == nil,
              let caption = snapshot?.captions.first(where: { $0.id == cueID }) else { return }
        stopUserScrolling(); onInteraction?()
        guard let plan = onTimingBegin?(cueID, operation) else { return }
        timingOwner = owner
        timingGesture = ActiveTimelineTiming(plan: plan, caption: caption, initialX: initialX,
            initialOffset: Double(scroll.contentOffset.x), originalSeconds: centerTime, touchX: currentX, proposed: plan.original)
        scroll.isScrollEnabled = false
        pinchRecognizer?.isEnabled = false
        canvas.selectedCaptionID = cueID; canvas.timingMessage = nil
        let target = TimelineTimingDisplayTarget(viewport: self)
        let link = CADisplayLink(target: target, selector: #selector(TimelineTimingDisplayTarget.tick(_:)))
        timingLink = link; timingTick = 0
        link.add(to: .main, forMode: .common)
        updateTiming(touchX: currentX)
    }
    private func updateTiming(touchX: Double) {
        guard var edit = timingGesture else { return }
        edit.touchX = touchX
        let delta = (touchX - edit.initialX + Double(scroll.contentOffset.x) - edit.initialOffset) / scale
        guard let proposed = try? edit.plan.proposal(delta: delta), let output = edit.plan.outputInterval(proposed) else { return }
        edit.proposed = proposed; timingGesture = edit
        canvas.timingPreview = TimelineTimingPreview(caption: edit.caption, interval: output, valid: edit.plan.allows(proposed))
        seek(to: auditionTime(output, operation: edit.plan.operation), final: false)
        canvas.setNeedsDisplay()
    }
    private func auditionTime(_ interval: MediaInterval, operation: TimelineTimingOperation) -> Double {
        let start = EditorTime.seconds(interval.start), end = EditorTime.seconds(interval.end)
        return operation == .end ? max(start, end - min(0.001, (end - start) / 2)) : start + min(0.001, (end - start) / 2)
    }
    fileprivate func timingDisplayTick(_ link: CADisplayLink) {
        if clipGesture != nil { clipDisplayTick(link); return }
        guard let edit = timingGesture, enabled, window != nil else { return }
        let elapsed = timingTick == 0 ? 0 : min(1.0 / 15, link.timestamp - timingTick)
        timingTick = link.timestamp
        let margin = 40.0, width = Double(bounds.width)
        let edge = edit.touchX < margin ? max(-1, (edit.touchX - margin) / margin) :
            edit.touchX > width - margin ? min(1, (edit.touchX - width + margin) / margin) : 0
        guard edge != 0, elapsed > 0 else { return }
        // Stop edge scrolling when the gesture has already reached its clip bound.
        let delta = (edit.touchX - edit.initialX + Double(scroll.contentOffset.x) - edit.initialOffset) / scale
        if let farther = try? edit.plan.proposal(delta: delta + edge / scale), farther == edit.proposed { return }
        setOffset(Double(scroll.contentOffset.x) + edge * 160 * elapsed)
        refreshViewport(); updateTiming(touchX: edit.touchX)
    }
    private func finishTiming(commit: Bool, restorePlayhead: Bool = false) {
        guard let edit = timingGesture else { return }
        timingLink?.invalidate(); timingLink = nil; timingTick = 0
        timingGesture = nil; timingOwner = nil; canvas.timingPreview = nil
        scroll.isScrollEnabled = true; pinchRecognizer?.isEnabled = true
        cancelPendingSeek()
        if commit, enabled {
            let accepted = onTimingCommit?(edit.plan, edit.proposed) == true
            canvas.timingMessage = accepted ? nil : "Timing was not changed"
            if accepted, let output = edit.plan.outputInterval(edit.proposed) {
                seek(to: auditionTime(output, operation: edit.plan.operation), final: true)
            } else if !accepted {
                setOffset(edit.originalSeconds * scale)
                seek(to: edit.originalSeconds, final: true)
            }
        } else if restorePlayhead && enabled {
            setOffset(edit.originalSeconds * scale)
            seek(to: edit.originalSeconds, final: true)
        }
        accessibilityDirty = true; refreshViewport()
    }
    private func accessibleTiming(cueID: UUID, operation: TimelineTimingOperation, delta: Double) -> Bool {
        guard enabled, timingGesture == nil, clipGesture == nil else { return false }
        stopUserScrolling(); onInteraction?()
        guard let edit = onTimingBegin?(cueID, operation), let interval = try? edit.proposal(delta: delta),
              onTimingCommit?(edit, interval) == true else { return false }
        if let output = edit.outputInterval(interval) { seek(to: auditionTime(output, operation: operation), final: true) }
        return true
    }
}

@MainActor
private final class TimelineTimingDisplayTarget: NSObject {
    weak var viewport: TimelineViewport?
    init(viewport: TimelineViewport) { self.viewport = viewport; super.init() }
    @objc func tick(_ link: CADisplayLink) {
        guard let viewport else { link.invalidate(); return }
        viewport.timingDisplayTick(link)
    }
}
