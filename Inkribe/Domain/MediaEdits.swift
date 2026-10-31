import CoreGraphics
import CoreMedia
import Foundation

enum MediaFit: String, Codable, CaseIterable, Sendable {
    case fit, fill
    var title: String { self == .fit ? "Fit" : "Fill / crop" }
}

/// Project-wide, non-destructive presentation. Trim uses the original project
/// clock. Trim changes do not move captions; structural clip edits explicitly
/// reproject project-clock values while preserving native source anchors.
struct MediaEdits: Codable, Equatable, Sendable {
    var trim: MediaInterval? = nil
    var fit: MediaFit = .fit
    var zoom: Double = 1
    var positionX: Double = 0.5
    var positionY: Double = 0.5
    var volume: Double = 1
    static let standard = Self()

    func validate(sourceDuration: MediaTime) throws {
        guard zoom.isFinite, (1...3).contains(zoom), positionX.isFinite, positionY.isFinite,
              (0...1).contains(positionX), (0...1).contains(positionY),
              volume.isFinite, (0...1).contains(volume),
              trim.map({ $0.end <= sourceDuration }) ?? true else { throw MediaEditError.invalidSettings }
    }

    /// Both AVPlayer and MP4 use this transform after source orientation.
    /// Positions run left-to-right/top-to-bottom in the oriented image.
    func placement(orientedBounds: CGRect, target: CGRect) throws -> CGAffineTransform {
        guard orientedBounds.width.isFinite, orientedBounds.height.isFinite,
              orientedBounds.width > 0, orientedBounds.height > 0,
              target.width.isFinite, target.height.isFinite, target.width > 0, target.height > 0 else {
            throw MediaEditError.invalidSettings
        }
        let sx = target.width / orientedBounds.width
        let sy = target.height / orientedBounds.height
        let scale = (fit == .fit ? min(sx, sy) : max(sx, sy)) * CGFloat(zoom)
        let width = orientedBounds.width * scale
        let height = orientedBounds.height * scale
        let x = width > target.width ? target.minX - (width - target.width) * CGFloat(positionX) : target.midX - width / 2
        let y = height > target.height ? target.minY - (height - target.height) * CGFloat(positionY) : target.midY - height / 2
        return CGAffineTransform(translationX: -orientedBounds.minX, y: -orientedBounds.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: x, y: y))
    }
}

enum MediaEditError: LocalizedError {
    case invalidSettings
    var errorDescription: String? { "Use a positive trim range inside the original project, a supported crop, and volume from 0 to 100%." }
}

/// One piecewise rational map for preview, captions, SRT, frames and seeking.
/// Remove trimmed clip portions, closing their gaps while retaining any genuine
/// pre-existing timeline gaps and the old project's output window.
struct OutputTimeline: Sendable, Equatable {
    struct Segment: Sendable, Equatable {
        let original: MediaInterval
        let output: MediaInterval
    }
    let start: MediaTime
    let end: MediaTime
    let segments: [Segment]
    let duration: MediaTime

    init(_ document: ProjectDocument) {
        start = document.mediaEdits?.trim?.start ?? .zero
        end = document.mediaEdits?.trim?.end ?? document.sourceDuration
        let settings = Dictionary((document.clipSettings ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var removed: [MediaInterval] = []
        for clip in document.orderedClips {
            guard let trim = settings[clip.id]?.sourceTrim else { continue }
            let a = CMTimeAdd(clip.timelineInterval.start.cmTime, CMTimeSubtract(trim.start.cmTime, clip.sourceInterval.start.cmTime))
            let b = CMTimeAdd(clip.timelineInterval.start.cmTime, CMTimeSubtract(trim.end.cmTime, clip.sourceInterval.start.cmTime))
            if let range = try? MediaInterval(start: clip.timelineInterval.start, end: MediaTime(validating: a)) { removed.append(range) }
            if let range = try? MediaInterval(start: MediaTime(validating: b), end: clip.timelineInterval.end) { removed.append(range) }
        }
        var cursor = start, output = MediaTime.zero
        var result: [Segment] = []
        var invalid = false
        func append(_ a: MediaTime, _ b: MediaTime) {
            guard let original = try? MediaInterval(start: a, end: b),
                  let next = try? MediaTime(validating: CMTimeAdd(output.cmTime, original.duration)),
                  let mapped = try? MediaInterval(start: output, end: next) else { invalid = true; return }
            result.append(Segment(original: original, output: mapped)); output = next
        }
        for range in removed.sorted(by: { $0.start < $1.start }) where range.end > start && range.start < end {
            let a = max(start, range.start), b = min(end, range.end)
            if cursor < a { append(cursor, a) }
            cursor = max(cursor, b)
        }
        if cursor < end { append(cursor, end) }
        segments = invalid ? [] : result; duration = invalid ? .zero : output
    }

    private func firstEnding(after value: MediaTime, output: Bool = false) -> Int {
        var low = 0, high = segments.count
        while low < high {
            let mid = (low + high) / 2
            let end = output ? segments[mid].output.end : segments[mid].original.end
            if end <= value { low = mid + 1 } else { high = mid }
        }
        return low
    }
    /// Clip/caption intervals are contiguous within one retained clip. A larger
    /// interval returns the bounding retained source range; output mapping removes
    /// any excluded portions between those bounds.
    func retained(_ interval: MediaInterval) -> MediaInterval? {
        let first = firstEnding(after: interval.start)
        guard first < segments.count, segments[first].original.start < interval.end else { return nil }
        var low = first, high = segments.count
        while low < high {
            let mid = (low + high) / 2
            if segments[mid].original.start < interval.end { low = mid + 1 } else { high = mid }
        }
        return try? MediaInterval(start: max(interval.start, segments[first].original.start),
            end: min(interval.end, segments[low - 1].original.end))
    }
    func outputInterval(_ original: MediaInterval) -> MediaInterval? {
        guard let kept = retained(original) else { return nil }
        return try? MediaInterval(start: outputTime(clampingOriginal: kept.start), end: outputTime(clampingOriginal: kept.end))
    }
    func originalTime(forOutput time: MediaTime, precedingBoundary: Bool = false) throws -> MediaTime {
        guard time <= duration, !segments.isEmpty else { throw MediaEditError.invalidSettings }
        var i = firstEnding(after: time, output: true)
        if precedingBoundary, i > 0, segments[i - 1].output.end == time { return segments[i - 1].original.end }
        if i == segments.count { i -= 1 }
        let segment = segments[i]
        return try MediaTime(validating: CMTimeAdd(segment.original.start.cmTime,
            CMTimeSubtract(min(time, segment.output.end).cmTime, segment.output.start.cmTime)))
    }
    func outputTime(clampingOriginal time: MediaTime) throws -> MediaTime {
        let i = firstEnding(after: time)
        guard i < segments.count else { return duration }
        let segment = segments[i]
        return try MediaTime(validating: CMTimeAdd(segment.output.start.cmTime,
            CMTimeSubtract(max(time, segment.original.start).cmTime, segment.original.start.cmTime)))
    }
}

/// Small atomic undo payload; never retains an additional recognition array.
struct MediaEditState: Equatable, Sendable {
    let edits: MediaEdits?
    let canvas: ProjectCanvas
    let preset: CanvasPreset
    init(_ document: ProjectDocument) { edits = document.mediaEdits; canvas = document.canvas; preset = document.preset }
    func applying(to document: ProjectDocument) -> ProjectDocument {
        var copy = document
        copy.mediaEdits = edits
        copy.canvas = canvas
        copy.preset = preset
        return copy
    }
}

enum MediaControl: Equatable { case zoom, x, y, volume }
