import CoreGraphics
import CoreMedia
import Foundation

enum MediaFit: String, Codable, CaseIterable, Sendable {
    case fit, fill
    var title: String { self == .fit ? "Fit" : "Fill / crop" }
}

/// Project-wide, non-destructive presentation. Trim uses the original project
/// clock; persisted clips, recognition and manual caption timing never move.
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

/// One rational source-project/output map for media, captions, SRT and seeking.
struct OutputTimeline: Sendable {
    let start: MediaTime
    let end: MediaTime
    var duration: MediaTime { (try? MediaTime(validating: CMTimeSubtract(end.cmTime, start.cmTime))) ?? .zero }

    init(_ document: ProjectDocument) {
        start = document.mediaEdits?.trim?.start ?? .zero
        end = document.mediaEdits?.trim?.end ?? document.sourceDuration
    }

    func retained(_ interval: MediaInterval) -> MediaInterval? {
        let a = max(start, interval.start)
        let b = min(end, interval.end)
        guard a < b else { return nil }
        return try? MediaInterval(start: a, end: b)
    }

    func outputInterval(_ original: MediaInterval) -> MediaInterval? {
        guard let kept = retained(original) else { return nil }
        return try? MediaInterval(start: MediaTime(validating: CMTimeSubtract(kept.start.cmTime, start.cmTime)),
                                 end: MediaTime(validating: CMTimeSubtract(kept.end.cmTime, start.cmTime)))
    }

    func originalTime(forOutput time: MediaTime) throws -> MediaTime {
        guard time <= duration else { throw MediaEditError.invalidSettings }
        return try MediaTime(validating: CMTimeAdd(start.cmTime, time.cmTime))
    }
    func outputTime(clampingOriginal time: MediaTime) throws -> MediaTime {
        try MediaTime(validating: CMTimeSubtract(min(end, max(start, time)).cmTime, start.cmTime))
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
