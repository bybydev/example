import CoreMedia
import Foundation

struct CaptionPresentation: Sendable {
    let cueID: UUID
    let words: [CaptionWord]
    let activeWordIDs: Set<UUID>
    var text: String {
        words.map(\.text).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct CaptionGap: Sendable, Identifiable {
    let id: Int
    let clipNumber: Int
    let interval: MediaInterval
}

enum CaptionTranscriptItem: Sendable, Identifiable {
    case cue(CaptionCue), gap(CaptionGap)
    var id: String {
        switch self {
        case .cue(let cue): "cue-" + cue.id.uuidString
        case .gap(let gap): "gap-\(gap.id)"
        }
    }
    var start: MediaTime {
        switch self {
        case .cue(let cue): cue.interval.start
        case .gap(let gap): gap.interval.start
        }
    }
}

/// Immutable, revision-tagged edited input for preview and the later style/export phases.
/// Time lookup is independent of selection, playback rate, UI focus and wall-clock time.
struct CaptionSnapshot: Sendable {
    private(set) var id = UUID()
    let revision: ProjectRevision
    let canvas: ProjectCanvas
    private(set) var style: CaptionStyle
    let wordsByID: [UUID: CaptionWord]
    let cues: [CaptionCue]
    let timeline: OutputTimeline
    let gaps: [CaptionGap]
    let transcriptItems: [CaptionTranscriptItem]
    private let originalWordsByID: [UUID: CaptionWord]
    private let ordered: [CaptionCue]
    private let prefixEnd: [MediaTime]

    init(_ document: ProjectDocument) {
        revision = ProjectRevision(projectID: document.id, contentRevision: document.contentRevision)
        canvas = document.canvas
        style = document.effectiveCaptionStyle
        let timeline = OutputTimeline(document)
        self.timeline = timeline
        let originalWords = document.recognition?.words ?? []
        originalWordsByID = Dictionary(uniqueKeysWithValues: originalWords.map { ($0.id, $0) })
        let mappedWords = originalWords.compactMap { word -> CaptionWord? in
            guard let interval = timeline.outputInterval(word.projectInterval) else { return nil }
            var copy = word
            copy.projectInterval = interval
            return copy
        }
        let mappedIndex = Dictionary(uniqueKeysWithValues: mappedWords.map { ($0.id, $0) })
        wordsByID = mappedIndex
        cues = (document.recognition?.cues ?? []).compactMap { cue in
            guard let interval = timeline.outputInterval(cue.interval) else { return nil }
            let ids = cue.wordIDs.filter { mappedIndex[$0] != nil }
            guard !ids.isEmpty else { return nil }
            return CaptionCue(id: cue.id, wordIDs: ids, interval: interval)
        }
        let originalStarts = Dictionary(uniqueKeysWithValues: (document.recognition?.cues ?? []).map { ($0.id, $0.interval.start) })
        var missing: [CaptionGap] = []
        if let progress = document.recognition?.progress, progress.isIncomplete,
           let plan = try? SpeechCheckpoint.plan(clips: document.clips, assets: document.assets) {
            let resolved = Set(progress.resolved.map(\.index))
            for window in plan where !resolved.contains(window.index) {
                let offset = CMTimeSubtract(window.core.start.cmTime, window.clip.sourceInterval.start.cmTime)
                let start = CMTimeAdd(window.clip.timelineInterval.start.cmTime, offset)
                if let interval = try? MediaInterval(start: MediaTime(validating: start),
                    end: MediaTime(validating: CMTimeAdd(start, window.core.duration))),
                   let output = timeline.outputInterval(interval) {
                    missing.append(CaptionGap(id: window.index,
                        clipNumber: (document.clips.firstIndex { $0.id == window.clip.id } ?? 0) + 1,
                        interval: output))
                }
            }
        }
        gaps = missing
        // Keep caption order consistent with Merge next. Insert gap rows without
        // reordering existing captions after manual timing corrections.
        var items = cues.map(CaptionTranscriptItem.cue)
        for gap in missing {
            let index = items.firstIndex { $0.start > gap.interval.start } ?? items.endIndex
            items.insert(.gap(gap), at: index)
        }
        transcriptItems = items
        ordered = cues.sorted {
            if $0.interval.start != $1.interval.start { return $0.interval.start < $1.interval.start }
            let a = originalStarts[$0.id] ?? .zero
            let b = originalStarts[$1.id] ?? .zero
            return a == b ? $0.id.uuidString < $1.id.uuidString : a < b
        }
        var maximum = MediaTime.zero
        prefixEnd = ordered.map { cue in maximum = max(maximum, cue.interval.end); return maximum }
    }

    /// Share immutable indexes/timing for bounded preset comparisons. No recognition
    /// mapping, native timing, selection or saved document is changed by browsing.
    func styled(_ style: CaptionStyle) -> Self {
        var copy = self
        copy.id = UUID()
        copy.style = style
        return copy
    }

    var chronologicalCues: [CaptionCue] { ordered }

    func text(for cue: CaptionCue) -> String {
        cue.wordIDs.compactMap { wordsByID[$0]?.text }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Clip only the output view. Effects still use full original edited word
    /// intervals, so trimming into a word doesn't restart karaoke/pop/fade.
    func motionPresentation(_ visible: CaptionPresentation) -> CaptionPresentation {
        CaptionPresentation(cueID: visible.cueID,
            words: visible.words.compactMap { originalWordsByID[$0.id] }, activeWordIDs: visible.activeWordIDs)
    }

    func evaluate(at time: MediaTime) -> CaptionPresentation? {
        // Find the latest started cue, then walk only possibly overlapping cues.
        // Native intervals can overlap; latest start wins, with a stable ID tie-break.
        var low = 0
        var high = ordered.count
        while low < high {
            let middle = (low + high) / 2
            if ordered[middle].interval.start <= time { low = middle + 1 } else { high = middle }
        }
        var index = low - 1
        while index >= 0 {
            if prefixEnd[index] <= time { break }
            let cue = ordered[index]
            if cue.interval.contains(time) {
                let words = cue.wordIDs.compactMap { wordsByID[$0] }
                if words.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    return CaptionPresentation(cueID: cue.id, words: words,
                        activeWordIDs: Set(words.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.projectInterval.contains(time) }.map(\.id)))
                }
            }
            index -= 1
        }
        return nil
    }
}

enum EditorTime {
    static func seconds(_ time: MediaTime) -> Double { CMTimeGetSeconds(time.cmTime) }
    static func stamp(_ seconds: Double) throws -> MediaTime {
        guard seconds.isFinite, seconds >= 0 else { throw CaptionEditError.invalidTiming }
        return try MediaTime(validating: CMTime(seconds: seconds, preferredTimescale: 60_000))
    }
    static func display(_ time: MediaTime) -> String {
        let seconds = self.seconds(time)
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max / 1_000) else { return "—" }
        let milliseconds = Int((seconds * 1_000).rounded())
        return String(format: "%02d:%02d.%03d", milliseconds / 60_000, (milliseconds / 1_000) % 60, milliseconds % 1_000)
    }
    static func field(_ time: MediaTime) -> String { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), seconds(time)) }
    static func interval(start: String, end: String, preserving original: MediaInterval? = nil) throws -> MediaInterval {
        func parse(_ field: String, original: MediaTime?) throws -> MediaTime {
            if let original, field == EditorTime.field(original) { return original }
            guard let seconds = Double(field.replacingOccurrences(of: ",", with: ".")) else { throw CaptionEditError.invalidTiming }
            return try stamp(seconds)
        }
        return try MediaInterval(start: parse(start, original: original?.start), end: parse(end, original: original?.end))
    }
}

