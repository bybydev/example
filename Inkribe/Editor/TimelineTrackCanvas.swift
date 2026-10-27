import UIKit

struct TimelineTimingPreview {
    let caption: ProjectTimelineSnapshot.Caption
    let interval: MediaInterval
    let valid: Bool
}

/// One viewport-sized drawing surface. It never allocates a project-wide bitmap
/// or a view/player for every thumbnail or caption.
@MainActor
final class TimelineTrackCanvas: UIView {
    var snapshot: ProjectTimelineSnapshot?
    var sourceURLs: [UUID: URL] = [:]
    var pointsPerSecond = 48.0
    var contentOffsetX = 0.0
    var selectedCaptionID: UUID?
    var selectedClipID: UUID?
    var accent = UIColor.systemOrange
    var thumbnails: TimelineThumbnailLoader?
    var onCaption: ((UUID) -> Void)?
    var onClip: ((UUID) -> Void)?
    var onSeek: ((Double) -> Void)?
    var onZoom: ((Double) -> Void)?
    var onTimingAction: ((UUID, TimelineTimingOperation, Double) -> Bool)?
    var timingPreview: TimelineTimingPreview?
    var timingMessage: String?
    private var tapRecognizer: UITapGestureRecognizer?
    func requireTapFailure(of gesture: UIGestureRecognizer) { tapRecognizer?.require(toFail: gesture) }
    private var accessibleItems: [String: TimelineAccessibilityElement] = [:]
    private func accessibleItem(_ key: String) -> TimelineAccessibilityElement {
        if let item = accessibleItems[key] { return item }
        let item = TimelineAccessibilityElement(accessibilityContainer: self)
        accessibleItems[key] = item
        return item
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        isOpaque = true
        contentMode = .redraw
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        addGestureRecognizer(tap)
        tapRecognizer = tap
        isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func x(_ seconds: Double) -> CGFloat { bounds.width / 2 + CGFloat(seconds * pointsPerSecond - contentOffsetX) }
    func time(at x: CGFloat) -> Double {
        min(snapshot?.duration ?? 0, max(0, (Double(x - bounds.width / 2) + contentOffsetX) / pointsPerSecond))
    }
    func visibleRange(padding: Double = 0) -> ClosedRange<Double> {
        let duration = snapshot?.duration ?? 0
        let lower = max(0, (contentOffsetX - Double(bounds.width / 2) - padding) / pointsPerSecond)
        let upper = min(duration, (contentOffsetX + Double(bounds.width / 2) + padding) / pointsPerSecond)
        return min(lower, duration)...max(min(lower, duration), upper)
    }
    private func rect(start: Double, end: Double, y: Double, height: Double) -> CGRect {
        CGRect(x: x(start), y: y, width: max(1, CGFloat((end - start) * pointsPerSecond)), height: height)
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let snapshot else { return }
        UIColor.secondarySystemBackground.setFill(); context.fill(bounds)
        drawRuler(context, duration: snapshot.duration)
        let range = visibleRange()
        for clip in snapshot.visibleClips(range) where clip.end > range.lowerBound {
            draw(clip, snapshot: snapshot, range: range, context: context)
        }
        for gap in snapshot.visibleGaps(range) where gap.end > range.lowerBound {
            let frame = self.rect(start: gap.start, end: gap.end, y: TimelineGeometry.captionTop, height: TimelineGeometry.captionHeight)
            context.saveGState()
            context.setFillColor(UIColor.systemOrange.withAlphaComponent(0.10).cgColor); context.fill(frame)
            context.setStrokeColor(UIColor.systemOrange.cgColor); context.setLineDash(phase: 0, lengths: [3, 3])
            context.stroke(frame.insetBy(dx: 1, dy: 1)); context.restoreGState()
        }
        let visibleCaptions = snapshot.visibleCaptions(range)
        for cue in visibleCaptions where cue.end > range.lowerBound && cue.id != selectedCaptionID && cue.id != timingPreview?.caption.id {
            drawCaption(cue)
        }
        if let preview = timingPreview {
            let cue = preview.caption
            drawCaption(ProjectTimelineSnapshot.Caption(id: cue.id, clipID: cue.clipID,
                start: EditorTime.seconds(preview.interval.start), end: EditorTime.seconds(preview.interval.end),
                text: cue.text, canResizeStart: cue.canResizeStart, canResizeEnd: cue.canResizeEnd))
        } else if let selected = visibleCaptions.first(where: { $0.id == selectedCaptionID && $0.end > range.lowerBound }) {
            drawCaption(selected)
        }
        if let preview = timingPreview {
            let text = preview.valid ? EditorTime.display(preview.interval.start) +
                " – " + EditorTime.display(preview.interval.end) : "Overlaps another caption"
            drawText(text, in: CGRect(x: 12, y: 145, width: max(0, bounds.width - 24), height: 15),
                font: .monospacedDigitSystemFont(ofSize: 11, weight: .medium), color: preview.valid ? .secondaryLabel : .systemRed)
        } else if let timingMessage {
            drawText(timingMessage, in: CGRect(x: 12, y: 145, width: max(0, bounds.width - 24), height: 15),
                font: .systemFont(ofSize: 11), color: .systemRed)
        }
        if snapshot.captions.isEmpty && snapshot.gaps.isEmpty {
            drawText("No captions yet", in: CGRect(x: 12, y: TimelineGeometry.captionTop + 12,
                width: max(0, bounds.width - 24), height: 22), font: .systemFont(ofSize: 13), color: .secondaryLabel)
        }
    }
    private func drawCaption(_ cue: ProjectTimelineSnapshot.Caption) {
        let frame = rect(start: cue.start, end: cue.end, y: TimelineGeometry.captionTop, height: TimelineGeometry.captionHeight)
        let selected = selectedCaptionID == cue.id
        let shape = UIBezierPath(roundedRect: frame.insetBy(dx: min(0.5, frame.width / 4), dy: 0), cornerRadius: 5)
        let fill = timingPreview?.caption.id == cue.id && timingPreview?.valid == false ? UIColor.systemRed : accent
        fill.withAlphaComponent(selected ? 1 : 0.65).setFill(); shape.fill()
        if selected {
            UIColor.label.setStroke(); shape.lineWidth = 2; shape.stroke()
            for edge in [cue.canResizeStart ? frame.minX : nil, cue.canResizeEnd ? frame.maxX : nil].compactMap({ $0 }) {
                let handle = UIBezierPath(roundedRect: CGRect(x: edge - 3, y: frame.minY + 7, width: 6, height: 28), cornerRadius: 3)
                UIColor.label.setFill(); handle.fill()
            }
        }
        drawText(cue.text.isEmpty ? "Hidden caption" : cue.text,
            in: frame.insetBy(dx: 8, dy: 12), font: .systemFont(ofSize: 12, weight: .medium), color: captionTextColor)
    }
    private func draw(_ clip: ProjectTimelineSnapshot.Clip, snapshot: ProjectTimelineSnapshot,
                      range: ClosedRange<Double>, context: CGContext) {
        let frame = rect(start: clip.start, end: clip.end, y: TimelineGeometry.videoTop, height: TimelineGeometry.videoHeight)
        context.saveGState()
        context.clip(to: frame)
        UIColor.tertiarySystemFill.setFill(); context.fill(frame)
        for tile in TimelineGeometry.tiles(clip: clip, range: range, scale: pointsPerSecond,
            projectID: snapshot.projectID, urls: sourceURLs) {
            let box = rect(start: tile.start, end: tile.end, y: TimelineGeometry.videoTop, height: TimelineGeometry.videoHeight)
            if let request = tile.request, let image = thumbnails?.image(for: request) {
                // Aspect-fit real frames over a neutral backing; clip geometry
                // and the ruler determine the tile's exact displayed duration.
                let factor = min(box.width / image.size.width, box.height / image.size.height)
                let size = CGSize(width: image.size.width * factor, height: image.size.height * factor)
                image.draw(in: CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2,
                    width: size.width, height: size.height))
            } else if box.width >= 18 {
                let unavailable = tile.request.map { thumbnails?.unavailable($0) == true } ?? (clip.kind == .video)
                let name = clip.kind == .audio ? "waveform" : unavailable ? "exclamationmark.triangle" : "film"
                let icon = UIImage(systemName: name)?.withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)
                icon?.draw(in: CGRect(x: box.midX - 8, y: box.midY - 8, width: 16, height: 16))
            }
        }
        if frame.width >= 44 {
            let titleFrame = CGRect(x: max(0, frame.minX) + 4, y: frame.minY + 3,
                width: min(frame.maxX, bounds.width) - max(0, frame.minX) - 8, height: 17)
            if titleFrame.width > 4 {
                UIColor.black.withAlphaComponent(0.55).setFill(); context.fill(titleFrame.insetBy(dx: -2, dy: -1))
                drawText(clip.title, in: titleFrame, font: .systemFont(ofSize: 10, weight: .medium), color: .white)
            }
        }
        context.restoreGState()
        let selected = selectedClipID == clip.id
        (selected ? accent : UIColor.separator).setStroke()
        let path = UIBezierPath(rect: frame.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = selected ? 2 : 1; path.stroke()
    }
    private func drawRuler(_ context: CGContext, duration: Double) {
        let step = TimelineGeometry.rulerStep(scale: pointsPerSecond)
        let range = visibleRange()
        let start = max(0, floor(range.lowerBound / step) * step)
        let end = min(duration, range.upperBound + step)
        var tick = start
        while tick <= end {
            let position = x(tick)
            UIColor.tertiaryLabel.setStroke()
            context.move(to: CGPoint(x: position, y: 20)); context.addLine(to: CGPoint(x: position, y: 25)); context.strokePath()
            drawText(TimelineGeometry.label(tick, fractional: step < 1),
                in: CGRect(x: position + 3, y: 3, width: 84, height: 17),
                font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular), color: .secondaryLabel)
            for part in 1...3 {
                let time = tick + Double(part) * step / 4
                if time <= duration {
                    context.setFillColor(UIColor.tertiaryLabel.cgColor)
                    context.fillEllipse(in: CGRect(x: x(time) - 1, y: 20, width: 2, height: 2))
                }
            }
            tick += step
        }
    }
    private var captionTextColor: UIColor {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        accent.resolvedColor(with: traitCollection).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return red * 0.2126 + green * 0.7152 + blue * 0.0722 > 0.58 ? .black : .white
    }
    private func drawText(_ value: String, in rect: CGRect, font: UIFont, color: UIColor) {
        guard rect.width > 4, rect.height > 0 else { return }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        (value as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }
    func captionHit(at point: CGPoint) -> UUID? {
        guard let snapshot, point.y >= TimelineGeometry.captionTop - 8,
              point.y <= TimelineGeometry.captionTop + TimelineGeometry.captionHeight + 8 else { return nil }
        let raw = (Double(point.x - bounds.width / 2) + contentOffsetX) / pointsPerSecond
        guard raw >= 0, raw <= snapshot.duration else { return nil }
        let time = self.time(at: point.x)
        let candidates = snapshot.visibleCaptions(max(0, time - 22 / pointsPerSecond)...min(snapshot.duration, time + 22 / pointsPerSecond))
        return (candidates.first(where: { $0.id == selectedCaptionID && $0.start <= time && $0.end > time }) ??
            candidates.last(where: { $0.start <= time && $0.end > time }) ??
            candidates.filter { $0.end > time - 22 / pointsPerSecond }
                .min { distance(to: point.x, start: $0.start, end: $0.end) < distance(to: point.x, start: $1.start, end: $1.end) })?.id
    }
    func timingHit(at point: CGPoint) -> (UUID, TimelineTimingOperation)? {
        guard let cue = snapshot?.captions.first(where: { $0.id == selectedCaptionID }),
              point.y >= TimelineGeometry.captionTop - 8,
              point.y <= TimelineGeometry.captionTop + TimelineGeometry.captionHeight + 8 else { return nil }
        let left = x(cue.start), right = x(cue.end)
        let leftDistance = abs(point.x - left), rightDistance = abs(point.x - right)
        let startHit = cue.canResizeStart && left >= 0 && left <= bounds.width && leftDistance <= 22
        let endHit = cue.canResizeEnd && right >= 0 && right <= bounds.width && rightDistance <= 22
        if startHit && (!endHit || leftDistance <= rightDistance) { return (cue.id, .start) }
        if endHit { return (cue.id, .end) }
        return point.x >= left && point.x <= right ? (cue.id, .move) : nil
    }
    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard let snapshot else { return }
        let point = recognizer.location(in: self)
        let time = self.time(at: point.x)
        let rawTime = (Double(point.x - bounds.width / 2) + contentOffsetX) / pointsPerSecond
        guard rawTime >= 0, rawTime <= snapshot.duration else { onSeek?(time); return }
        if point.y >= TimelineGeometry.captionTop && point.y <= TimelineGeometry.captionTop + TimelineGeometry.captionHeight + 8 {
            if let id = captionHit(at: point) { onCaption?(id); return }
        } else if point.y >= TimelineGeometry.videoTop && point.y <= TimelineGeometry.videoTop + TimelineGeometry.videoHeight {
            if let clip = snapshot.visibleClips(time...time).first(where: { $0.start <= time && $0.end > time }) {
                onClip?(clip.id); return
            }
        }
        onSeek?(time)
    }
    private func distance(to point: CGFloat, start: Double, end: Double) -> CGFloat {
        let low = x(start), high = x(end)
        return point < low ? low - point : point > high ? point - high : 0
    }

    func updateAccessibility() {
        guard let snapshot else { accessibilityElements = []; return }
        var elements: [UIAccessibilityElement] = []
        let playhead = accessibleItem("playhead")
        let seconds = min(snapshot.duration, max(0, contentOffsetX / pointsPerSecond))
        playhead.accessibilityLabel = "Project playhead"
        playhead.accessibilityValue = TimelineGeometry.label(seconds, fractional: true) + " of " + TimelineGeometry.label(snapshot.duration)
        playhead.accessibilityTraits = [.adjustable]
        playhead.accessibilityFrameInContainerSpace = CGRect(x: bounds.midX - 22, y: 0, width: 44, height: bounds.height)
        let increment = max(0.1, min(5, 20 / pointsPerSecond))
        playhead.increment = { [weak self] in
            guard let self else { return }
            self.onSeek?(min(snapshot.duration, max(0, self.contentOffsetX / self.pointsPerSecond) + increment))
        }
        playhead.decrement = { [weak self] in
            guard let self else { return }
            self.onSeek?(max(0, self.contentOffsetX / self.pointsPerSecond - increment))
        }
        playhead.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Zoom in") { [weak self] _ in self?.onZoom?(2); return true },
            UIAccessibilityCustomAction(name: "Zoom out") { [weak self] _ in self?.onZoom?(0.5); return true }
        ]
        elements.append(playhead)
        var retainedKeys: Set<String> = ["playhead"]
        let range = visibleRange()
        for clip in snapshot.visibleClips(range).prefix(32) where clip.end > range.lowerBound {
            let key = "clip-" + clip.id.uuidString
            let element = accessibleItem(key); retainedKeys.insert(key)
            element.accessibilityLabel = "Clip, " + clip.title
            element.accessibilityValue = TimelineGeometry.label(clip.start) + " to " + TimelineGeometry.label(clip.end)
            element.accessibilityTraits = selectedClipID == clip.id ? [.button, .selected] : [.button]
            element.accessibilityFrameInContainerSpace = rect(start: clip.start, end: clip.end,
                y: TimelineGeometry.videoTop, height: TimelineGeometry.videoHeight).intersection(bounds)
            element.activate = { [weak self] in self?.onClip?(clip.id); return true }
            elements.append(element)
        }
        for cue in snapshot.visibleCaptions(range).prefix(64) where cue.end > range.lowerBound {
            let key = "caption-" + cue.id.uuidString
            let element = accessibleItem(key); retainedKeys.insert(key)
            element.accessibilityLabel = cue.text.isEmpty ? "Hidden caption" : cue.text
            element.accessibilityValue = TimelineGeometry.label(cue.start, fractional: true) + " to " + TimelineGeometry.label(cue.end, fractional: true)
            element.accessibilityHint = selectedCaptionID == cue.id ? "Activate to edit text and timing" : "Activate to select caption"
            element.accessibilityTraits = selectedCaptionID == cue.id ? [.button, .selected] : [.button]
            element.accessibilityFrameInContainerSpace = rect(start: cue.start, end: cue.end,
                y: TimelineGeometry.captionTop, height: TimelineGeometry.captionHeight).intersection(bounds)
            element.activate = { [weak self] in self?.onCaption?(cue.id); return true }
            if selectedCaptionID == cue.id {
                var actions: [UIAccessibilityCustomAction] = []
                let operations: [(String, TimelineTimingOperation)] = [("Move", .move)] +
                    (cue.canResizeStart ? [("Start", .start)] : []) + (cue.canResizeEnd ? [("End", .end)] : [])
                for (label, operation) in operations {
                    for (direction, delta) in [("earlier", -0.1), ("later", 0.1)] {
                        actions.append(UIAccessibilityCustomAction(name: label + " " + direction + " by 0.1 seconds") { [weak self] _ in
                            self?.onTimingAction?(cue.id, operation, delta) ?? false
                        })
                    }
                }
                element.accessibilityCustomActions = actions
                element.accessibilityHint = "Drag to move, drag edge handles to resize, or activate to edit text and timing"
            } else { element.accessibilityCustomActions = nil }
            elements.append(element)
        }
        accessibleItems = accessibleItems.filter { retainedKeys.contains($0.key) }
        accessibilityElements = elements
    }
}

@MainActor
private final class TimelineAccessibilityElement: UIAccessibilityElement {
    var activate: (() -> Bool)?
    var increment: (() -> Void)?
    var decrement: (() -> Void)?
    override func accessibilityActivate() -> Bool { activate?() ?? false }
    override func accessibilityIncrement() { increment?() }
    override func accessibilityDecrement() { decrement?() }
}
