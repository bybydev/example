import CoreMedia
import Foundation

/// Display-only timed text. Native words retain their own strict persisted model;
/// a manually authored phrase needs no fabricated native window or word anchors.
struct CaptionUnit: Sendable {
    let id: UUID
    let clipID: UUID
    let text: String
    var projectInterval: MediaInterval
    let timingProvenance: String
}

struct CaptionPresentation: Sendable {
    let cueID: UUID
    let words: [CaptionUnit]
    let activeWordIDs: Set<UUID>
    var text: String {
        words.map(\.text).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct CaptionGap: Sendable, Identifiable {
    let id: Int
    let clipNumber: Int
    let clipID: UUID
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
    let requireWordTiming: Bool
    let canvas: ProjectCanvas
    private(set) var style: CaptionStyle
    private var clipStyles: [UUID: CaptionStyle]
    private let clipOverrides: [UUID: CaptionStyleOverrides]
    let manualCaptionIDs: Set<UUID>
    let manualConflicts: [ManualCaptionConflict]
    let wordsByID: [UUID: CaptionUnit]
    let cues: [CaptionCue]
    let timeline: OutputTimeline
    let gaps: [CaptionGap]
    let transcriptItems: [CaptionTranscriptItem]
    let transcriptItemsByClip: [UUID: [CaptionTranscriptItem]]
    private let originalWordsByID: [UUID: CaptionUnit]
    private let ordered: [CaptionCue]
    private let prefixEnd: [MediaTime]

    init(_ document: ProjectDocument, usesClipStyles: Bool = false, requireWordTiming: Bool = true) {
        self.requireWordTiming = requireWordTiming
        revision = ProjectRevision(projectID: document.id, contentRevision: document.contentRevision)
        canvas = document.canvas
        style = document.effectiveCaptionStyle
        clipStyles = Dictionary(uniqueKeysWithValues: document.clips.map {
            ($0.id, usesClipStyles ? document.captionStyle(for: $0.id) : document.effectiveCaptionStyle)
        })
        clipOverrides = usesClipStyles ? Dictionary(uniqueKeysWithValues: (document.clipSettings ?? []).map { ($0.id, $0.captions) }) : [:]
        let timeline = OutputTimeline(document)
        self.timeline = timeline
        let manuals = document.manualCaptions ?? []
        manualCaptionIDs = Set(manuals.map(\.id))
        let nativeWords = document.recognition?.words ?? []
        let retainedManuals = manuals.compactMap { value -> ManualCaption? in
            guard let interval = timeline.retained(value.interval) else { return nil }
            var copy = value; copy.interval = interval; return copy
        }
        let manualIndex = ManualCaptionIndex(retainedManuals)
        var conflicts: [ManualCaptionConflict] = []
        if !manualIndex.captions.isEmpty {
            let nativeIndex = Dictionary(uniqueKeysWithValues: nativeWords.map { ($0.id, $0) })
            for cue in document.recognition?.cues ?? [] {
                guard let retained = timeline.retained(cue.interval) else { continue }
                let overlaps = manualIndex.overlapping(retained)
                guard !overlaps.isEmpty else { continue }
                let text = cue.wordIDs.compactMap { nativeIndex[$0]?.text }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { conflicts.append(ManualCaptionConflict(cue: cue, text: text, manuals: overlaps)) }
            }
        }
        manualConflicts = conflicts
        let suppressed = Set(conflicts.map(\.id))
        let originalWords = nativeWords.map {
            CaptionUnit(id: $0.id, clipID: $0.clipID, text: $0.text,
                projectInterval: $0.projectInterval, timingProvenance: $0.timingProvenance)
        } + manuals.map {
            CaptionUnit(id: $0.id, clipID: $0.clipID, text: $0.text,
                projectInterval: $0.interval, timingProvenance: "manual-phrase")
        }
        originalWordsByID = Dictionary(uniqueKeysWithValues: originalWords.map { ($0.id, $0) })
        let mappedWords = originalWords.compactMap { word -> CaptionUnit? in
            guard let interval = timeline.outputInterval(word.projectInterval) else { return nil }
            var copy = word
            copy.projectInterval = interval
            return copy
        }
        let mappedIndex = Dictionary(uniqueKeysWithValues: mappedWords.map { ($0.id, $0) })
        wordsByID = mappedIndex
        // A manual phrase replaces the whole overlapping recognized cue. Keep
        // native anchors intact and expose every replacement in the editor/export
        // review, including overlaps introduced by a later gap retry.
        let nativeCues = (document.recognition?.cues ?? []).filter { !suppressed.contains($0.id) }
        let manualCues = manuals.map { CaptionCue(id: $0.id, wordIDs: [$0.id], interval: $0.interval) }
        let additions = manualCues.sorted {
            $0.interval.start == $1.interval.start ? $0.id.uuidString < $1.id.uuidString : $0.interval.start < $1.interval.start
        }
        var originalCues: [CaptionCue] = []
        originalCues.reserveCapacity(nativeCues.count + additions.count)
        var addition = 0
        for cue in nativeCues {
            while addition < additions.count, additions[addition].interval.start < cue.interval.start {
                originalCues.append(additions[addition]); addition += 1
            }
            originalCues.append(cue)
        }
        originalCues.append(contentsOf: additions.dropFirst(addition))
        cues = originalCues.compactMap { cue in
            guard let interval = timeline.outputInterval(cue.interval) else { return nil }
            let ids = cue.wordIDs.filter { mappedIndex[$0] != nil }
            guard !ids.isEmpty else { return nil }
            return CaptionCue(id: cue.id, wordIDs: ids, interval: interval)
        }
        let originalStarts = Dictionary(uniqueKeysWithValues: originalCues.map { ($0.id, $0.interval.start) })
        var missing: [CaptionGap] = []
        if let progress = document.recognition?.progress, progress.isIncomplete,
           let plan = try? SpeechCheckpoint.plan(clips: document.clips, assets: document.assets) {
            let resolved = Set(progress.resolved.map(\.index))
            for window in plan where !resolved.contains(window.index) && progress.retainedClipIDs?.contains(window.clip.id) != true {
                let offset = CMTimeSubtract(window.core.start.cmTime, window.clip.sourceInterval.start.cmTime)
                let start = CMTimeAdd(window.clip.timelineInterval.start.cmTime, offset)
                if let interval = try? MediaInterval(start: MediaTime(validating: start),
                    end: MediaTime(validating: CMTimeAdd(start, window.core.duration))),
                   let output = timeline.outputInterval(interval) {
                    missing.append(CaptionGap(id: window.index,
                        clipNumber: (document.orderedClips.firstIndex { $0.id == window.clip.id } ?? 0) + 1,
                        clipID: window.clip.id,
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
        var grouped: [UUID: [CaptionTranscriptItem]] = [:]
        for item in items {
            let clipID: UUID?
            switch item {
            case .cue(let cue): clipID = cue.wordIDs.first.flatMap { mappedIndex[$0]?.clipID }
            case .gap(let gap): clipID = gap.clipID
            }
            if let clipID { grouped[clipID, default: []].append(item) }
        }
        transcriptItemsByClip = grouped
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
    func styled(_ style: CaptionStyle, scope: EditorSettingsScope = .project) -> Self {
        var copy = self
        copy.id = UUID()
        switch scope {
        case .project:
            copy.style = style
            copy.clipStyles = clipStyles.mapValues { _ in style }
            for (id, overrides) in clipOverrides { copy.clipStyles[id] = overrides.resolved(over: style) }
        case .clip(let id): copy.clipStyles[id] = style
        }
        return copy
    }

    func style(for presentation: CaptionPresentation) -> CaptionStyle {
        presentation.words.first.flatMap { clipStyles[$0.clipID] } ?? style
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


