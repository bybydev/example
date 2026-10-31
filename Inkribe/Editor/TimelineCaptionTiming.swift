import CoreMedia
import Foundation

enum TimelineTimingOperation: Equatable, Sendable { case move, start, end }

enum TimelineTimingError: LocalizedError {
    case changed, overlap, clippedEdge
    var errorDescription: String? {
        switch self {
        case .changed: "This caption changed while you were adjusting it. Try again."
        case .overlap: "This timing would overlap another manual caption or replace additional recognized captions. Use Add caption to review replacements."
        case .clippedEdge: "This edge is outside the retained video. Adjust its original timing in the Timing sheet."
        }
    }
}

/// A small expected-state transaction. Dragging never mutates the document;
/// release compares the captured caption/words/clip/trim and commits one patch.
struct TimelineCaptionTiming: Sendable {
    let cueID: UUID
    let operation: TimelineTimingOperation
    let clip: ProjectClip
    let original: MediaInterval
    let outputStart: MediaTime
    let outputEnd: MediaTime
    private let outputMap: OutputTimeline
    let retainedClip: MediaInterval
    let nativeCue: CaptionCue?
    let words: [CaptionWord]
    let manual: ManualCaption?
    let minimumDuration: CMTime
    private let blockers: [MediaInterval]
    private let replacements: [UUID: CaptionCue]

    init(cueID: UUID, operation: TimelineTimingOperation, project: ProjectDocument) throws {
        self.cueID = cueID; self.operation = operation
        manual = project.manualCaptions?.first { $0.id == cueID }
        nativeCue = manual == nil ? project.recognition?.cues.first { $0.id == cueID } : nil
        let ids = Set(nativeCue?.wordIDs ?? [])
        words = project.recognition?.words.filter { ids.contains($0.id) } ?? []
        guard let interval = manual?.interval ?? nativeCue?.interval,
              let clipID = manual?.clipID ?? words.first?.clipID,
              let clip = project.clips.first(where: { $0.id == clipID }) else { throw CaptionEditError.missingCaption }
        original = interval; self.clip = clip
        let timeline = OutputTimeline(project)
        outputStart = timeline.start; outputEnd = timeline.end; outputMap = timeline
        guard let retained = timeline.retained(clip.timelineInterval), timeline.outputInterval(interval) != nil else {
            throw CaptionEditError.invalidTiming
        }
        retainedClip = retained
        if operation == .start, interval.start < retained.start { throw TimelineTimingError.clippedEdge }
        if operation == .end, interval.end > retained.end { throw TimelineTimingError.clippedEdge }
        let duration = CMTimeGetSeconds(interval.duration)
        let shortestWord = words.map { CMTimeGetSeconds($0.projectInterval.duration) }.min() ?? duration
        // Leave at least two rational ticks per scaled word. Final native/project
        // validation remains authoritative if an unusual source time cannot scale.
        let precisionFloor = duration * (2.0 / 60_000) / max(1.0 / 60_000, shortestWord)
        minimumDuration = CMTimeMinimum(interval.duration, CMTimeMaximum(CMTime(value: 1, timescale: 60_000),
            CMTime(seconds: max(0.05, precisionFloor), preferredTimescale: 60_000)))
        let isManual = manual != nil
        let index = Dictionary(uniqueKeysWithValues: (project.recognition?.words ?? []).map { ($0.id, $0) })
        replacements = Dictionary(uniqueKeysWithValues: (project.recognition?.cues ?? []).filter { cue in
            isManual && ManualCaption.overlaps(cue.interval, interval) && cue.wordIDs.contains {
                index[$0].map { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
            }
        }.map { ($0.id, $0) })
        blockers = Self.blockers(project: project, cueID: cueID, clipID: clipID,
            replacements: replacements, isManual: manual != nil, hidden: Self.hidden(manual: manual, words: words))
    }

    func matches(_ project: ProjectDocument) -> Bool {
        let timeline = OutputTimeline(project)
        guard project.clips.first(where: { $0.id == clip.id }) == clip,
              timeline == outputMap else { return false }
        if let manual { return project.manualCaptions?.first { $0.id == cueID } == manual }
        guard let nativeCue, project.recognition?.cues.first(where: { $0.id == cueID }) == nativeCue else { return false }
        let ids = Set(nativeCue.wordIDs)
        return project.recognition?.words.filter { ids.contains($0.id) } == words
    }

    func proposal(delta seconds: Double) throws -> MediaInterval {
        guard seconds.isFinite else { throw CaptionEditError.invalidTiming }
        let delta = CMTime(seconds: seconds, preferredTimescale: 60_000)
        switch operation {
        case .move:
            // Preserve portions already outside project trim, without moving
            // farther out of the visible clip or crossing into another clip.
            let lower = min(original.start, retainedClip.start)
            let upper = max(original.end, retainedClip.end)
            let shift = CMTimeMaximum(CMTimeSubtract(lower.cmTime, original.start.cmTime),
                CMTimeMinimum(CMTimeSubtract(upper.cmTime, original.end.cmTime), delta))
            return try MediaInterval(start: MediaTime(validating: CMTimeAdd(original.start.cmTime, shift)),
                end: MediaTime(validating: CMTimeAdd(original.end.cmTime, shift)))
        case .start:
            let upper = CMTimeMinimum(CMTimeSubtract(original.end.cmTime, minimumDuration),
                CMTimeSubtract(retainedClip.end.cmTime, minimumDuration))
            let start = CMTimeMaximum(retainedClip.start.cmTime,
                CMTimeMinimum(upper, CMTimeAdd(original.start.cmTime, delta)))
            return try MediaInterval(start: MediaTime(validating: start), end: original.end)
        case .end:
            let lower = CMTimeMaximum(CMTimeAdd(original.start.cmTime, minimumDuration),
                CMTimeAdd(retainedClip.start.cmTime, minimumDuration))
            let end = CMTimeMinimum(retainedClip.end.cmTime,
                CMTimeMaximum(lower, CMTimeAdd(original.end.cmTime, delta)))
            return try MediaInterval(start: original.start, end: MediaTime(validating: end))
        }
    }
    func outputInterval(_ interval: MediaInterval) -> MediaInterval? {
        outputMap.outputInterval(interval)
    }
    func allows(_ interval: MediaInterval) -> Bool {
        !blockers.contains { ManualCaption.overlaps($0, interval) }
    }
    func validate(_ interval: MediaInterval, in project: ProjectDocument) throws {
        guard matches(project) else { throw TimelineTimingError.changed }
        guard interval.start >= clip.timelineInterval.start, interval.end <= clip.timelineInterval.end,
              outputInterval(interval) != nil else { throw CaptionEditError.invalidTiming }
        switch operation {
        case .move:
            guard CMTimeCompare(interval.duration, original.duration) == 0,
                  interval.start >= min(original.start, retainedClip.start),
                  interval.end <= max(original.end, retainedClip.end) else { throw CaptionEditError.invalidTiming }
        case .start:
            guard interval.end == original.end, interval.start >= retainedClip.start,
                  CMTimeCompare(interval.duration, minimumDuration) >= 0 else { throw CaptionEditError.invalidTiming }
        case .end:
            guard interval.start == original.start, interval.end <= retainedClip.end,
                  CMTimeCompare(interval.duration, minimumDuration) >= 0 else { throw CaptionEditError.invalidTiming }
        }
        let current = Self.blockers(project: project, cueID: cueID, clipID: clip.id,
            replacements: replacements, isManual: manual != nil, hidden: Self.hidden(manual: manual, words: words))
        guard !current.contains(where: { ManualCaption.overlaps($0, interval) }) else { throw TimelineTimingError.overlap }
    }
    private static func hidden(manual: ManualCaption?, words: [CaptionWord]) -> Bool {
        if let manual { return manual.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return words.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    private static func blockers(project: ProjectDocument, cueID: UUID, clipID: UUID,
                                 replacements: [UUID: CaptionCue], isManual: Bool, hidden: Bool) -> [MediaInterval] {
        guard !hidden else { return [] }
        var result = (project.manualCaptions ?? []).filter {
            $0.id != cueID && $0.clipID == clipID && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.map(\.interval)
        if isManual, let recognition = project.recognition {
            let words = Dictionary(uniqueKeysWithValues: recognition.words.map { ($0.id, $0) })
            // Existing explicitly reviewed replacements remain valid. A drag
            // cannot silently suppress a new recognized cue elsewhere.
            result += recognition.cues.filter { cue in
                guard replacements[cue.id] != cue else { return false }
                return cue.wordIDs.contains { id in
                    words[id].map { $0.clipID == clipID && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
                }
            }.map(\.interval)
        }
        return result
    }
}
