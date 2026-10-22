import CoreMedia
import Foundation

struct IOSCaptionPresentation: Sendable {
    let cueID: UUID
    let words: [IOSCaptionWord]
    let activeWordIDs: Set<UUID>
    var text: String {
        words.map(\.text).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Immutable, revision-tagged edited input for preview and the later style/export phases.
/// Time lookup is independent of selection, playback rate, UI focus and wall-clock time.
struct IOSCaptionSnapshot: Sendable {
    let id = UUID()
    let revision: ProjectRevision
    let canvas: IOSCanvas
    let style: IOSCaptionStyle
    let wordsByID: [UUID: IOSCaptionWord]
    let cues: [IOSCaptionCue]
    private let ordered: [IOSCaptionCue]
    private let prefixEnd: [MediaTime]

    init(_ document: IOSProjectDocument) {
        revision = ProjectRevision(projectID: document.id, contentRevision: document.contentRevision)
        canvas = document.canvas
        style = document.effectiveCaptionStyle
        wordsByID = Dictionary(uniqueKeysWithValues: (document.recognition?.words ?? []).map { ($0.id, $0) })
        cues = document.recognition?.cues ?? []
        ordered = cues.sorted {
            $0.interval.start == $1.interval.start ? $0.id.uuidString < $1.id.uuidString : $0.interval.start < $1.interval.start
        }
        var maximum = MediaTime.zero
        prefixEnd = ordered.map { cue in maximum = max(maximum, cue.interval.end); return maximum }
    }

    func text(for cue: IOSCaptionCue) -> String {
        cue.wordIDs.compactMap { wordsByID[$0]?.text }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func evaluate(at time: MediaTime) -> IOSCaptionPresentation? {
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
                    return IOSCaptionPresentation(cueID: cue.id, words: words,
                        activeWordIDs: Set(words.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.projectInterval.contains(time) }.map(\.id)))
                }
            }
            index -= 1
        }
        return nil
    }
}

enum IOSEditorTime {
    static func seconds(_ time: MediaTime) -> Double { CMTimeGetSeconds(time.cmTime) }
    static func stamp(_ seconds: Double) throws -> MediaTime {
        guard seconds.isFinite, seconds >= 0 else { throw IOSCaptionEditError.invalidTiming }
        return try MediaTime(validating: CMTime(seconds: seconds, preferredTimescale: 60_000))
    }
    static func display(_ time: MediaTime) -> String {
        let seconds = self.seconds(time)
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max / 1_000) else { return "—" }
        let milliseconds = Int((seconds * 1_000).rounded())
        return String(format: "%02d:%02d.%03d", milliseconds / 60_000, (milliseconds / 1_000) % 60, milliseconds % 1_000)
    }
    static func field(_ time: MediaTime) -> String { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), seconds(time)) }
    static func interval(start: String, end: String) throws -> MediaInterval {
        let a = start.replacingOccurrences(of: ",", with: ".")
        let b = end.replacingOccurrences(of: ",", with: ".")
        guard let start = Double(a), let end = Double(b) else { throw IOSCaptionEditError.invalidTiming }
        return try MediaInterval(start: stamp(start), end: stamp(end))
    }
}
