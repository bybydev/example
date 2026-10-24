import Foundation

extension Recognition {
    /// A new inference publication adds units; the draft keeps every existing
    /// text/timing/group edit, including edits made while awaiting a disk write.
    func keepingEdits(from draft: Recognition?) throws -> Recognition {
        guard let draft else { return self }
        guard id == draft.id, modelID == draft.modelID, modelSHA256 == draft.modelSHA256,
              requestedLanguageCode == draft.requestedLanguageCode else {
            throw ProjectStoreError.invalidDocument("Different transcription publication")
        }
        let published = Dictionary(uniqueKeysWithValues: words.map { ($0.id, $0) })
        for word in draft.words {
            guard let saved = published[word.id], saved.clipID == word.clipID,
                  saved.rawWindowID == word.rawWindowID, saved.sourceInterval == word.sourceInterval,
                  saved.timingProvenance == word.timingProvenance else {
                throw ProjectStoreError.invalidDocument("Published native anchors changed")
            }
        }
        let known = Set(draft.words.map(\.id))
        let newCues = cues.filter { $0.wordIDs.allSatisfy { !known.contains($0) } }
        var result = self
        result.words = draft.words + words.filter { !known.contains($0.id) }
        result.cues = Self.inserting(newCues, into: draft.cues)
        return result
    }

    static func inserting(_ additions: [CaptionCue], into existing: [CaptionCue]) -> [CaptionCue] {
        var result = existing
        for cue in additions.sorted(by: { $0.interval.start < $1.interval.start }) {
            let index = result.firstIndex { $0.interval.start > cue.interval.start } ?? result.endIndex
            result.insert(cue, at: index)
        }
        return result
    }
}

extension ProjectDocument {
    /// A narrow rebase is permitted only across append-only speech publication.
    /// Any concurrent title/style/media/manual-caption edit still conflicts.
    func isSpeechPublication(since base: ProjectDocument) -> Bool {
        guard id == base.id, createdAt == base.createdAt, title == base.title,
              canvas == base.canvas, preset == base.preset, assets == base.assets,
              clips == base.clips, captionStyle == base.captionStyle, mediaEdits == base.mediaEdits,
              clipSettings == base.clipSettings,
              let current = recognition, current.progress != nil else { return false }
        guard let old = base.recognition else { return true }
        guard old.isIncomplete, current.id == old.id, current.modelID == old.modelID,
              current.modelSHA256 == old.modelSHA256,
              current.requestedLanguageCode == old.requestedLanguageCode,
              current.completedAt == old.completedAt else { return false }
        let raw = Dictionary(uniqueKeysWithValues: current.rawWindows.map { ($0.id, $0) })
        let words = Dictionary(uniqueKeysWithValues: current.words.map { ($0.id, $0) })
        let cues = Dictionary(uniqueKeysWithValues: current.cues.map { ($0.id, $0) })
        return old.rawWindows.allSatisfy { raw[$0.id] == $0 } &&
            old.words.allSatisfy { words[$0.id] == $0 } && old.cues.allSatisfy { cues[$0.id] == $0 }
    }
}
