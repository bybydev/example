import CoreMedia
import Foundation

/// Derived output-clock geometry only. No project/schema/native word data is moved.
struct ProjectTimelineSnapshot: Sendable {
    struct Clip: Identifiable, Sendable {
        let id: UUID
        let assetID: UUID
        let title: String
        let fingerprint: String
        let kind: MediaKind
        let start: Double
        let end: Double
        let sourceStart: Double
    }
    struct Caption: Identifiable, Sendable {
        let id: UUID
        let clipID: UUID
        let start: Double
        let end: Double
        let text: String
        let canResizeStart: Bool
        let canResizeEnd: Bool
    }
    struct Gap: Sendable {
        let start: Double
        let end: Double
    }
    let id: UUID
    let projectID: UUID
    let duration: Double
    let clips: [Clip]
    let captions: [Caption]
    let gaps: [Gap]
    private let captionEnds: [Double]
    private let clipEnds: [Double]
    private let gapEnds: [Double]

    init(document: ProjectDocument, captions snapshot: CaptionSnapshot) {
        id = snapshot.id
        projectID = document.id
        duration = EditorTime.seconds(document.outputDuration)
        let timeline = OutputTimeline(document)
        let assets = Dictionary(uniqueKeysWithValues: document.assets.map { ($0.id, $0) })
        clips = document.orderedClips.enumerated().compactMap { index, clip in
            guard let asset = assets[clip.sourceAssetID],
                  let kept = timeline.retained(clip.timelineInterval),
                  let output = timeline.outputInterval(clip.timelineInterval) else { return nil }
            return Clip(id: clip.id, assetID: asset.id, title: "Clip \(index + 1)",
                fingerprint: asset.sha256, kind: asset.kind,
                start: EditorTime.seconds(output.start), end: EditorTime.seconds(output.end),
                sourceStart: CMTimeGetSeconds(CMTimeAdd(clip.sourceInterval.start.cmTime,
                    CMTimeSubtract(kept.start.cmTime, clip.timelineInterval.start.cmTime))))
        }
        let nativeIntervals = Dictionary(uniqueKeysWithValues: (document.recognition?.cues ?? []).map { ($0.id, $0.interval) })
        let manualIntervals = Dictionary(uniqueKeysWithValues: (document.manualCaptions ?? []).map { ($0.id, $0.interval) })
        captions = snapshot.chronologicalCues.compactMap { cue in
            guard let clipID = cue.wordIDs.first.flatMap({ snapshot.wordsByID[$0]?.clipID }) else { return nil }
            return Caption(id: cue.id, clipID: clipID, start: EditorTime.seconds(cue.interval.start),
                end: EditorTime.seconds(cue.interval.end), text: snapshot.text(for: cue),
                canResizeStart: (manualIntervals[cue.id] ?? nativeIntervals[cue.id]).map { $0.start >= timeline.start } ?? false,
                canResizeEnd: (manualIntervals[cue.id] ?? nativeIntervals[cue.id]).map { $0.end <= timeline.end } ?? false)
        }
        gaps = snapshot.gaps.map { Gap(start: EditorTime.seconds($0.interval.start), end: EditorTime.seconds($0.interval.end)) }
            .sorted { $0.start < $1.start }
        captionEnds = Self.prefixEnds(captions.map(\.end))
        clipEnds = Self.prefixEnds(clips.map(\.end))
        gapEnds = Self.prefixEnds(gaps.map(\.end))
    }

    // Prefix maxima keep native overlapping captions visible at the left edge.
    func visibleClips(_ range: ClosedRange<Double>) -> ArraySlice<Clip> {
        let low = Self.firstEnd(after: range.lowerBound, ends: clipEnds)
        let high = Self.firstStart(after: range.upperBound, count: clips.count) { clips[$0].start }
        return clips[min(low, high)..<high]
    }
    func visibleCaptions(_ range: ClosedRange<Double>) -> ArraySlice<Caption> {
        let low = Self.firstEnd(after: range.lowerBound, ends: captionEnds)
        let high = Self.firstStart(after: range.upperBound, count: captions.count) { captions[$0].start }
        return captions[min(low, high)..<high]
    }
    func visibleGaps(_ range: ClosedRange<Double>) -> ArraySlice<Gap> {
        let low = Self.firstEnd(after: range.lowerBound, ends: gapEnds)
        let high = Self.firstStart(after: range.upperBound, count: gaps.count) { gaps[$0].start }
        return gaps[min(low, high)..<high]
    }
    private static func prefixEnds(_ values: [Double]) -> [Double] {
        var maximum = 0.0
        return values.map { maximum = max(maximum, $0); return maximum }
    }
    private static func firstEnd(after time: Double, ends: [Double]) -> Int {
        var low = 0, high = ends.count
        while low < high {
            let middle = (low + high) / 2
            if ends[middle] <= time { low = middle + 1 } else { high = middle }
        }
        return low
    }
    private static func firstStart(after time: Double, count: Int, start: (Int) -> Double) -> Int {
        var low = 0, high = count
        while low < high {
            let middle = (low + high) / 2
            if start(middle) <= time { low = middle + 1 } else { high = middle }
        }
        return low
    }
}

/// Tile identity includes exact source time and file identity; unrelated projects,
/// trimmed clips and relinked paths cannot display another frame's cache entry.
struct TimelineFrameRequest: Hashable, Sendable {
    let projectID: UUID
    let assetID: UUID
    let fingerprint: String
    let url: URL
    let tick: Int64
    let pixels: Int
    var key: String { "\(projectID)/\(assetID)/\(fingerprint)/\(url.absoluteString)/\(tick)/\(pixels)" }
}

struct TimelineFrameTile {
    let start: Double
    let end: Double
    let request: TimelineFrameRequest?
}

enum TimelineGeometry {
    static let tileWidth = 64.0
    static let videoTop = 28.0
    static let videoHeight = 60.0
    static let captionTop = 100.0
    static let captionHeight = 42.0
    static let trackHeight = 160.0

    static func tiles(clip: ProjectTimelineSnapshot.Clip, range: ClosedRange<Double>,
                      scale: Double, projectID: UUID, urls: [UUID: URL]) -> [TimelineFrameTile] {
        guard scale.isFinite, scale > 0 else { return [] }
        let step = tileWidth / scale
        let first = max(0, Int(floor((range.lowerBound - clip.start) / step)))
        let last = max(first, Int(ceil((min(clip.end, range.upperBound) - clip.start) / step)))
        // A viewport/prefetch range must never allocate frames for a whole video.
        return (first..<min(last, first + 96)).compactMap { index in
            let start = clip.start + Double(index) * step
            let end = min(clip.end, start + step)
            guard start < end else { return nil }
            let source = clip.sourceStart + (start + end) / 2 - clip.start
            let ticks = source * 60_000
            let validSample = ticks.isFinite && ticks >= 0 && ticks < Double(Int64.max)
            let request = clip.kind == .video && validSample ? urls[clip.assetID].map {
                TimelineFrameRequest(projectID: projectID, assetID: clip.assetID, fingerprint: clip.fingerprint,
                    url: $0, tick: Int64(ticks.rounded(.down)), pixels: 192)
            } : nil
            return TimelineFrameTile(start: start, end: end, request: request)
        }
    }
    static func rulerStep(scale: Double) -> Double {
        guard scale.isFinite, scale > 0 else { return 1 }
        let target = 80 / scale
        let exponent = pow(10, floor(log10(target)))
        for multiplier in [1.0, 2.0, 5.0, 10.0] where exponent * multiplier >= target { return exponent * multiplier }
        return exponent * 10
    }
    static func label(_ time: Double, fractional: Bool = false) -> String {
        guard time.isFinite, time >= 0, time < Double(Int.max / 1_000) else { return "—" }
        let tenths = Int((time * 10 + 0.0001).rounded(.down))
        let seconds = fractional ? tenths / 10 : Int((time + 0.0001).rounded(.down))
        let base = seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) :
            String(format: "%d:%02d", seconds / 60, seconds % 60)
        return fractional ? base + String(format: ".%01d", tenths % 10) : base
    }
}
