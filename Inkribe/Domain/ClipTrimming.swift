import CoreMedia
import Foundation

/// Endpoints use the immutable imported source clock. An empty range preserves
/// a clip wholly hidden by an older project trim without deleting its footage.
struct ClipSourceTrim: Codable, Equatable, Sendable {
    var start: MediaTime
    var end: MediaTime
    init(_ interval: MediaInterval) { start = interval.start; end = interval.end }
    init(start: MediaTime, end: MediaTime) { self.start = start; self.end = end }
    var interval: MediaInterval? { try? MediaInterval(start: start, end: end) }
    func validate(in source: MediaInterval) throws {
        guard source.start <= start, start <= end, end <= source.end else { throw ClipTrimError.invalid }
    }
}

enum ClipTrimEdge: Equatable, Sendable { case start, end }
enum ClipTrimError: LocalizedError {
    case changed, invalid, busy
    var errorDescription: String? {
        switch self {
        case .changed: "The clip or its trim changed. Try trimming again."
        case .invalid: "Keep a positive clip length within the original footage."
        case .busy: "Finish the current edit before trimming this clip."
        }
    }
}

/// Separate from full settings history: caption/style/name edits are never
/// replaced by clip trim Undo. The immutable graph is an expected-state guard.
struct ClipTrimState: Equatable, Sendable {
    let clips: [ProjectClip]
    let projectTrim: MediaInterval?
    let trims: [UUID: ClipSourceTrim]
    init(_ document: ProjectDocument) {
        clips = document.clips; projectTrim = document.mediaEdits?.trim
        trims = Dictionary(uniqueKeysWithValues: (document.clipSettings ?? []).compactMap { value in
            value.sourceTrim.map { (value.id, $0) }
        })
    }
    func applying(to document: ProjectDocument) -> ProjectDocument {
        var next = document
        var media = next.effectiveMediaEdits; media.trim = projectTrim
        next.mediaEdits = media == .standard ? nil : media
        let settings = Dictionary(uniqueKeysWithValues: (document.clipSettings ?? []).map { ($0.id, $0) })
        let values = document.clips.compactMap { clip -> ClipSettings? in
            var value = settings[clip.id] ?? ClipSettings(id: clip.id)
            value.sourceTrim = trims[clip.id]
            return value.isEmpty ? nil : value
        }
        next.clipSettings = values.isEmpty ? nil : values.sorted { $0.id.uuidString < $1.id.uuidString }
        return next
    }
}

struct TimelineClipTrim: Sendable {
    let id = UUID()
    let clip: ProjectClip
    let edge: ClipTrimEdge
    let original: ClipSourceTrim
    let state: ClipTrimState
    let frameRate: Double
    let outputStart: Double
    let outputEnd: Double
    let minimum: CMTime

    init(clipID: UUID, edge: ClipTrimEdge, document: ProjectDocument) throws {
        guard let clip = document.clips.first(where: { $0.id == clipID }) else { throw ClipTrimError.changed }
        self.clip = clip; self.edge = edge; state = ClipTrimState(document)
        let timeline = OutputTimeline(document)
        original = Self.visibleSource(clip, in: document, timeline: timeline)
        let output = timeline.outputInterval(clip.timelineInterval)
        let anchor = try timeline.outputTime(clampingOriginal: clip.timelineInterval.start)
        outputStart = EditorTime.seconds(output?.start ?? anchor)
        outputEnd = EditorTime.seconds(output?.end ?? anchor)
        let rate = document.assets.first { $0.id == clip.sourceAssetID }?.metadata.nominalFrameRate ?? 30
        frameRate = rate.isFinite && rate > 0 ? rate : 30
        minimum = CMTimeMinimum(original.interval?.duration ?? clip.sourceInterval.duration, CMTime(seconds: 1 / frameRate, preferredTimescale: 60_000))
    }
    static func visibleSource(_ clip: ProjectClip, in document: ProjectDocument, timeline: OutputTimeline) -> ClipSourceTrim {
        if let kept = timeline.retained(clip.timelineInterval),
           let start = try? MediaTime(validating: CMTimeAdd(clip.sourceInterval.start.cmTime,
                CMTimeSubtract(kept.start.cmTime, clip.timelineInterval.start.cmTime))),
           let end = try? MediaTime(validating: CMTimeAdd(start.cmTime, kept.duration)) {
            return ClipSourceTrim(start: start, end: end)
        }
        let point = document.settings(for: clip.id).sourceTrim?.start ??
            (clip.timelineInterval.end <= timeline.start ? clip.sourceInterval.end : clip.sourceInterval.start)
        return ClipSourceTrim(start: point, end: point)
    }
    func matches(_ document: ProjectDocument) -> Bool { ClipTrimState(document) == state }
    func proposal(delta seconds: Double) throws -> ClipSourceTrim {
        guard seconds.isFinite else { throw ClipTrimError.invalid }
        let frames = (seconds * frameRate).rounded()
        guard frames.isFinite else { throw ClipTrimError.invalid }
        if frames == 0 { return original }
        let delta = CMTime(seconds: frames / frameRate, preferredTimescale: 60_000)
        switch edge {
        case .start:
            let upper = CMTimeSubtract(original.end.cmTime, minimum)
            let point = CMTimeMaximum(clip.sourceInterval.start.cmTime,
                CMTimeMinimum(upper, CMTimeAdd(original.start.cmTime, delta)))
            return ClipSourceTrim(start: try MediaTime(validating: point), end: original.end)
        case .end:
            let lower = CMTimeAdd(original.start.cmTime, minimum)
            let point = CMTimeMinimum(clip.sourceInterval.end.cmTime,
                CMTimeMaximum(lower, CMTimeAdd(original.end.cmTime, delta)))
            return ClipSourceTrim(start: original.start, end: try MediaTime(validating: point))
        }
    }
    func projectPoint(_ range: ClipSourceTrim) throws -> MediaTime {
        let point = edge == .start ? range.start : range.end
        return try MediaTime(validating: CMTimeAdd(clip.timelineInterval.start.cmTime,
            CMTimeSubtract(point.cmTime, clip.sourceInterval.start.cmTime)))
    }
    func applying(_ range: ClipSourceTrim, to document: ProjectDocument) throws -> ProjectDocument {
        guard matches(document) else { throw ClipTrimError.changed }
        if range == original { return document }
        try range.validate(in: clip.sourceInterval)
        guard let interval = range.interval, CMTimeCompare(interval.duration, minimum) >= 0 else { throw ClipTrimError.invalid }
        switch edge {
        case .start: guard range.end == original.end else { throw ClipTrimError.invalid }
        case .end: guard range.start == original.start else { throw ClipTrimError.invalid }
        }
        var next = document
        // Freeze all old window exclusions before expanding that compatibility
        // window. Restoring one clip must never reveal other hidden clips.
        let timeline = OutputTimeline(document)
        var settings = Dictionary(uniqueKeysWithValues: (document.clipSettings ?? []).map { ($0.id, $0) })
        if document.mediaEdits?.trim != nil {
            for item in document.clips {
                var value = settings[item.id] ?? ClipSettings(id: item.id)
                value.sourceTrim = Self.visibleSource(item, in: document, timeline: timeline)
                settings[item.id] = value
            }
        }
        var value = settings[clip.id] ?? ClipSettings(id: clip.id)
        value.sourceTrim = range == ClipSourceTrim(clip.sourceInterval) ? nil : range
        settings[clip.id] = value
        next.clipSettings = settings.values.filter { !$0.isEmpty }.sorted { $0.id.uuidString < $1.id.uuidString }
        if let old = document.mediaEdits?.trim {
            var cursor = MediaTime.zero
            var contiguous = true
            for item in document.orderedClips {
                if item.timelineInterval.start != cursor { contiguous = false }
                cursor = item.timelineInterval.end
            }
            if contiguous {
                // Imported projects have no genuine gaps. Their old window is
                // now represented entirely by the source trims above, so it must
                // not re-trim different footage after a later clip reorder.
                next.mediaEdits?.trim = nil
                if next.mediaEdits == .standard { next.mediaEdits = nil }
            } else {
                // Preserve the exact black-gap boundaries of an older gapped
                // timeline, expanding only to reach the edited source clip.
                let a = try MediaTime(validating: CMTimeAdd(clip.timelineInterval.start.cmTime,
                    CMTimeSubtract(range.start.cmTime, clip.sourceInterval.start.cmTime)))
                let b = try MediaTime(validating: CMTimeAdd(clip.timelineInterval.start.cmTime,
                    CMTimeSubtract(range.end.cmTime, clip.sourceInterval.start.cmTime)))
                next.mediaEdits?.trim = try MediaInterval(start: min(old.start, a), end: max(old.end, b))
            }
        }
        next.schemaVersion = ProjectSchema.current
        try next.validate()
        return next
    }
}
