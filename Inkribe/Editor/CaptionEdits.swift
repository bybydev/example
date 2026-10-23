import CoreMedia
import Foundation

/// Only editable state is retained in undo history; raw recognition is never copied/rewritten by commands.
struct CaptionEditState: Equatable, Sendable {
    var words: [CaptionWord]
    var cues: [CaptionCue]

    init(_ result: Recognition) { words = result.words; cues = result.cues }
    func applying(to result: Recognition) -> Recognition {
        var copy = result
        copy.words = words
        copy.cues = cues
        return copy
    }
}

enum CaptionEditError: LocalizedError {
    case missingCaption, invalidText, invalidTiming, splitBoundary, mergeBoundary, unsavedChanges
    var errorDescription: String? {
        switch self {
        case .missingCaption: "This caption is no longer available."
        case .unsavedChanges: "Save the current changes before continuing."
        case .invalidText: "Keep each timed text field within 4,096 characters."
        case .invalidTiming: "Use a positive interval inside this clip. Caption timing must contain its words."
        case .splitBoundary: "Choose a word after the first word to split before it."
        case .mergeBoundary: "Only the next caption in the same clip can be merged."
        }
    }
}

/// Atomic, value-only operations. The session validates the entire result before publishing a draft.
enum CaptionEdits {
    static func text(_ value: String, wordID: UUID, in state: inout CaptionEditState) throws {
        guard value.count <= 4_096 else { throw CaptionEditError.invalidText }
        guard let index = state.words.firstIndex(where: { $0.id == wordID }) else {
            throw CaptionEditError.missingCaption
        }
        // Empty text hides this timed unit without deleting its stable identity or native timing.
        // A corrected phrase can occupy one unit; correction never invents sub-word timestamps.
        let original = state.words[index].text
        let hidden = original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let leading = hidden ? "" : String(original.prefix(while: { $0.isWhitespace }))
        let trailing = hidden ? original : String(original.reversed().prefix(while: { $0.isWhitespace }).reversed())
        let corrected = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep the native separator (including no separator for CJK). TextField replacement
        // must not accidentally concatenate neighboring words after selecting all text.
        state.words[index].text = leading + corrected + trailing
    }

    static func wordTiming(_ interval: MediaInterval, wordID: UUID, project: ProjectDocument,
                           in state: inout CaptionEditState) throws {
        guard let index = state.words.firstIndex(where: { $0.id == wordID }),
              let cueIndex = state.cues.firstIndex(where: { $0.wordIDs.contains(wordID) }) else {
            throw CaptionEditError.missingCaption
        }
        guard interval != state.words[index].projectInterval else { return }
        try retime(&state.words[index], to: interval, project: project)
        let wordIndex = Dictionary(uniqueKeysWithValues: state.words.map { ($0.id, $0) })
        let linked = state.cues[cueIndex].wordIDs.compactMap { wordIndex[$0] }
        // Expand, never silently trim another word when a manual word extends past its cue.
        state.cues[cueIndex].interval = try MediaInterval(
            start: min(state.cues[cueIndex].interval.start, linked.map(\.projectInterval.start).min() ?? interval.start),
            end: max(state.cues[cueIndex].interval.end, linked.map(\.projectInterval.end).max() ?? interval.end))
    }

    static func cueTiming(_ interval: MediaInterval, cueID: UUID, project: ProjectDocument,
                          in state: inout CaptionEditState) throws {
        guard let index = state.cues.firstIndex(where: { $0.id == cueID }) else {
            throw CaptionEditError.missingCaption
        }
        let cue = state.cues[index]
        guard interval != cue.interval else { return }
        let oldDuration = CMTimeGetSeconds(cue.interval.duration)
        let newDuration = CMTimeGetSeconds(interval.duration)
        guard oldDuration.isFinite, oldDuration > 0, newDuration.isFinite, newDuration > 0 else {
            throw CaptionEditError.invalidTiming
        }
        let ids = Set(cue.wordIDs)
        for wordIndex in state.words.indices where ids.contains(state.words[wordIndex].id) {
            func mapped(_ time: MediaTime) throws -> MediaTime {
                let offset = CMTimeSubtract(time.cmTime, cue.interval.start.cmTime)
                let scaled = CMTimeMultiplyByFloat64(offset, multiplier: newDuration / oldDuration)
                let mapped = try MediaTime(validating: CMTimeAdd(interval.start.cmTime, scaled))
                return min(interval.end, max(interval.start, mapped))
            }
            let word = state.words[wordIndex]
            let adjusted = try MediaInterval(start: mapped(word.projectInterval.start), end: mapped(word.projectInterval.end))
            try retime(&state.words[wordIndex], to: adjusted, project: project)
        }
        // Scaling is an explicit user adjustment; native intervals remain immutable on each word.
        state.cues[index].interval = interval
    }

    static func split(cueID: UUID, before wordID: UUID, in state: inout CaptionEditState) throws -> UUID {
        guard let index = state.cues.firstIndex(where: { $0.id == cueID }),
              let boundary = state.cues[index].wordIDs.firstIndex(of: wordID), boundary > 0 else {
            throw CaptionEditError.splitBoundary
        }
        let cue = state.cues[index]
        let left = Array(cue.wordIDs[..<boundary])
        let right = Array(cue.wordIDs[boundary...])
        let wordIndex = Dictionary(uniqueKeysWithValues: state.words.map { ($0.id, $0) })
        func bounds(_ ids: [UUID]) throws -> MediaInterval {
            let words = ids.compactMap { wordIndex[$0] }
            guard let start = words.map(\.projectInterval.start).min(),
                  let end = words.map(\.projectInterval.end).max() else { throw CaptionEditError.missingCaption }
            return try MediaInterval(start: start, end: end)
        }
        let leftBounds = try bounds(left)
        let rightBounds = try bounds(right)
        let rightID = UUID()
        state.cues[index] = CaptionCue(id: cue.id, wordIDs: left,
            interval: try MediaInterval(start: cue.interval.start, end: leftBounds.end))
        state.cues.insert(CaptionCue(id: rightID, wordIDs: right,
            interval: try MediaInterval(start: rightBounds.start, end: cue.interval.end)), at: index + 1)
        return rightID
    }

    static func mergeNext(cueID: UUID, in state: inout CaptionEditState) throws {
        guard let index = state.cues.firstIndex(where: { $0.id == cueID }), index + 1 < state.cues.count else {
            throw CaptionEditError.mergeBoundary
        }
        let first = state.cues[index]
        let next = state.cues[index + 1]
        let ids = first.wordIDs + next.wordIDs
        let mergedIDs = Set(ids)
        let clips = Set(state.words.filter { mergedIDs.contains($0.id) }.map(\.clipID))
        guard clips.count == 1 else { throw CaptionEditError.mergeBoundary }
        state.cues[index] = CaptionCue(id: first.id, wordIDs: ids,
            interval: try MediaInterval(start: min(first.interval.start, next.interval.start),
                                        end: max(first.interval.end, next.interval.end)))
        state.cues.remove(at: index + 1)
    }

    private static func retime(_ word: inout CaptionWord, to interval: MediaInterval,
                               project: ProjectDocument) throws {
        guard let clip = project.clips.first(where: { $0.id == word.clipID }),
              interval.start >= clip.timelineInterval.start, interval.end <= clip.timelineInterval.end else {
            throw CaptionEditError.invalidTiming
        }
        let offset = CMTimeSubtract(interval.start.cmTime, clip.timelineInterval.start.cmTime)
        let sourceStart = try MediaTime(validating: CMTimeAdd(clip.sourceInterval.start.cmTime, offset))
        let sourceEnd = try MediaTime(validating: CMTimeAdd(sourceStart.cmTime, interval.duration))
        word.adjustedSourceInterval = try MediaInterval(start: sourceStart, end: sourceEnd)
        word.projectInterval = interval
    }
}

/// Undo retains changed values, not a complete transcript array per keystroke.
struct CaptionEditPatch: Sendable {
    struct WordChange: Sendable { let before: CaptionWord; var after: CaptionWord }
    struct CueChange: Sendable { let id: UUID; let before: CaptionCue?; let after: CaptionCue? }
    var words: [WordChange]
    let cues: [CueChange]
    let beforeOrder: [UUID]?
    let afterOrder: [UUID]?

    init(before: CaptionEditState, after: CaptionEditState) {
        let finalWords = Dictionary(uniqueKeysWithValues: after.words.map { ($0.id, $0) })
        words = before.words.compactMap { word in
            guard let final = finalWords[word.id], word != final else { return nil }
            return WordChange(before: word, after: final)
        }
        let oldCues = Dictionary(uniqueKeysWithValues: before.cues.map { ($0.id, $0) })
        let newCues = Dictionary(uniqueKeysWithValues: after.cues.map { ($0.id, $0) })
        cues = Set(oldCues.keys).union(newCues.keys).compactMap { id in
            guard oldCues[id] != newCues[id] else { return nil }
            return CueChange(id: id, before: oldCues[id], after: newCues[id])
        }
        let oldOrder = before.cues.map(\.id)
        let newOrder = after.cues.map(\.id)
        beforeOrder = oldOrder == newOrder ? nil : oldOrder
        afterOrder = oldOrder == newOrder ? nil : newOrder
    }

    func applying(to state: CaptionEditState, forward: Bool) throws -> CaptionEditState {
        var result = state
        let replacements = Dictionary(uniqueKeysWithValues: words.map { ($0.before.id, $0) })
        var appliedWords = 0
        for index in result.words.indices {
            guard let change = replacements[result.words[index].id] else { continue }
            guard result.words[index] == (forward ? change.before : change.after) else {
                throw CaptionEditError.missingCaption
            }
            result.words[index] = forward ? change.after : change.before
            appliedWords += 1
        }
        guard appliedWords == replacements.count else { throw CaptionEditError.missingCaption }
        var index = Dictionary(uniqueKeysWithValues: result.cues.map { ($0.id, $0) })
        if let expected = forward ? beforeOrder : afterOrder, expected != result.cues.map(\.id) {
            throw CaptionEditError.missingCaption
        }
        for change in cues {
            guard index[change.id] == (forward ? change.before : change.after) else {
                throw CaptionEditError.missingCaption
            }
            index[change.id] = forward ? change.after : change.before
        }
        let order = (forward ? afterOrder : beforeOrder) ?? result.cues.map(\.id)
        result.cues = order.compactMap { index[$0] }
        guard result.cues.count == index.count else { throw CaptionEditError.missingCaption }
        return result
    }

    mutating func coalesceText(_ next: Self) -> Bool {
        guard words.count == 1, next.words.count == 1, cues.isEmpty, next.cues.isEmpty,
              beforeOrder == nil, next.beforeOrder == nil,
              words[0].after == next.words[0].before else { return false }
        words[0].after = next.words[0].after
        return true
    }

    var estimatedBytes: Int {
        let wordStorageBytes = words.count * MemoryLayout<WordChange>.stride
        var wordTextBytes = 0
        for change in words {
            wordTextBytes += change.before.text.utf8.count
            wordTextBytes += change.after.text.utf8.count
        }

        let cueStorageBytes = cues.count * MemoryLayout<CueChange>.stride
        var cueWordIDBytes = 0
        for change in cues {
            let beforeCount = change.before?.wordIDs.count ?? 0
            let afterCount = change.after?.wordIDs.count ?? 0
            cueWordIDBytes += (beforeCount + afterCount) * MemoryLayout<UUID>.stride
        }

        let orderCount = (beforeOrder?.count ?? 0) + (afterOrder?.count ?? 0)
        let orderBytes = orderCount * MemoryLayout<UUID>.stride
        return wordStorageBytes + wordTextBytes + cueStorageBytes + cueWordIDBytes + orderBytes
    }
}
