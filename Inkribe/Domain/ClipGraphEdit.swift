import CoreMedia
import Foundation
import WhisperRuntime

/// Structural undo stores project values only. Original files stay owned by the
/// project, including after removing a clip or undoing an append.
struct ClipGraphState: Equatable, Sendable {
    let assets: [SourceAsset]
    let clips: [ProjectClip]
    let recognition: Recognition?
    let manualCaptions: [ManualCaption]?
    let clipSettings: [ClipSettings]?
    let mediaEdits: MediaEdits?

    init(_ project: ProjectDocument) {
        assets = project.assets; clips = project.clips; recognition = project.recognition
        manualCaptions = project.manualCaptions; clipSettings = project.clipSettings
        mediaEdits = project.mediaEdits
    }
    func applying(to project: ProjectDocument) -> ProjectDocument {
        var copy = project
        copy.assets = assets; copy.clips = clips; copy.recognition = recognition
        copy.manualCaptions = manualCaptions; copy.clipSettings = clipSettings
        copy.mediaEdits = mediaEdits
        return copy
    }
    var estimatedBytes: Int {
        // Keep each arithmetic step small so Swift can resolve Int operators
        // without inferring one nested optional/reduce expression.
        var total: Int = clips.count * 256
        if let recognition {
            total += recognition.words.count * 512
            for window in recognition.rawWindows {
                total += 256
                for token in window.tokens {
                    total += 64
                    total += token.utf8.count
                }
                for segment in window.segments {
                    total += 64
                    total += segment.text.utf8.count
                }
            }
        }
        let manualCount: Int = manualCaptions?.count ?? 0
        let settingsCount: Int = clipSettings?.count ?? 0
        total += manualCount * 4_608
        total += settingsCount * 2_048
        return total
    }
}

enum ClipGraphError: LocalizedError {
    case lastClip, busy, stale, invalidImport
    var errorDescription: String? {
        switch self {
        case .lastClip: "Keep at least one clip in the project."
        case .busy: "Finish or cancel this project’s transcription before changing clips."
        case .stale: "The project changed. Your clips were not changed. Try again."
        case .invalidImport: "These clips could not be added safely. Select the media again."
        }
    }
}

/// Source intervals, raw windows and native identities remain unchanged. Removing
/// a clip closes its gap and translates retained project-clock values exactly.
enum ClipGraphEdit {
    static func appending(_ imported: PreparedClipImport, to project: ProjectDocument) throws -> ProjectDocument {
        guard !imported.clips.isEmpty, !imported.assets.isEmpty,
              Set(project.assets.map(\.id)).isDisjoint(with: imported.assets.map(\.id)),
              Set(project.clips.map(\.id)).isDisjoint(with: imported.clips.map(\.id)) else { throw ClipGraphError.invalidImport }
        var copy = project
        copy.assets += imported.assets
        copy.clips += try imported.clips.map { clip in
            ProjectClip(id: clip.id, sourceAssetID: clip.sourceAssetID, sourceInterval: clip.sourceInterval,
                timelineInterval: try translated(clip.timelineInterval, by: project.sourceDuration.cmTime))
        }
        // An explicit end trim expands, rather than silently hiding newly added clips.
        if let trim = copy.mediaEdits?.trim {
            let expandedTrim = try MediaInterval(start: trim.start, end: copy.sourceDuration)
            copy.mediaEdits?.trim = expandedTrim
        }
        return try projecting(project, onto: copy)
    }

    static func removing(_ clipID: UUID, from project: ProjectDocument) throws -> ProjectDocument {
        guard project.clips.count > 1 else { throw ClipGraphError.lastClip }
        guard let removed = project.clips.first(where: { $0.id == clipID }) else { throw ClipGraphError.stale }
        var copy = project
        let delta = CMTimeSubtract(.zero, removed.timelineInterval.duration)
        copy.clips = try project.orderedClips.filter { $0.id != clipID }.map { clip in
            var interval = clip.timelineInterval
            if interval.start >= removed.timelineInterval.end { interval = try translated(interval, by: delta) }
            return ProjectClip(id: clip.id, sourceAssetID: clip.sourceAssetID,
                sourceInterval: clip.sourceInterval, timelineInterval: interval)
        }
        let usedAssets = Set(copy.clips.map(\.sourceAssetID))
        copy.assets = project.assets.filter { usedAssets.contains($0.id) }
        copy.clipSettings = project.clipSettings?.filter { $0.id != clipID }
        if let trim = project.mediaEdits?.trim {
            let start = try collapsed(trim.start, removing: removed.timelineInterval)
            let end = min(copy.sourceDuration, try collapsed(trim.end, removing: removed.timelineInterval))
            if start < end { copy.mediaEdits?.trim = try MediaInterval(start: start, end: end) }
            else { copy.mediaEdits?.trim = nil }
        }
        return try projecting(project, onto: copy)
    }

    /// One validated permutation of the existing identities. Trim is a global
    /// output window, so its clock positions remain fixed while content moves.
    static func reordering(_ ids: [UUID], in project: ProjectDocument) throws -> ProjectDocument {
        guard ids.count == project.clips.count, Set(ids).count == ids.count,
              Set(ids) == Set(project.clips.map(\.id)) else { throw ClipGraphError.stale }
        guard ids != project.orderedClips.map(\.id) else { return project }
        let clips = Dictionary(uniqueKeysWithValues: project.clips.map { ($0.id, $0) })
        var copy = project
        var cursor = MediaTime.zero
        copy.clips = try ids.map { id in
            guard let clip = clips[id] else { throw ClipGraphError.stale }
            let end = try MediaTime(validating: CMTimeAdd(cursor.cmTime, clip.sourceInterval.duration))
            let interval = try MediaInterval(start: cursor, end: end)
            cursor = end
            return ProjectClip(id: clip.id, sourceAssetID: clip.sourceAssetID,
                sourceInterval: clip.sourceInterval, timelineInterval: interval)
        }
        // Imported projects are contiguous. Clamp an older graph with gaps if
        // compacting it shortened the available duration, without invalid ranges.
        if let trim = project.mediaEdits?.trim {
            let end = min(trim.end, copy.sourceDuration)
            if trim.start < end { copy.mediaEdits?.trim = try MediaInterval(start: trim.start, end: end) }
            else { copy.mediaEdits?.trim = nil }
        }
        return try projecting(project, onto: copy)
    }

    private static func projecting(_ original: ProjectDocument, onto proposed: ProjectDocument) throws -> ProjectDocument {
        var copy = proposed
        let oldClips = Dictionary(uniqueKeysWithValues: original.clips.map { ($0.id, $0) })
        let offsets = Dictionary(uniqueKeysWithValues: copy.clips.compactMap { clip -> (UUID, CMTime)? in
            guard let previous = oldClips[clip.id] else { return nil }
            return (clip.id, CMTimeSubtract(clip.timelineInterval.start.cmTime, previous.timelineInterval.start.cmTime))
        })
        copy.manualCaptions = try original.manualCaptions?.compactMap { caption -> ManualCaption? in
            guard let delta = offsets[caption.clipID] else { return nil }
            var value = caption
            value.interval = try translated(caption.interval, by: delta)
            return value
        }.sorted {
            $0.interval.start == $1.interval.start ? $0.id.uuidString < $1.id.uuidString : $0.interval.start < $1.interval.start
        }
        copy.recognition = try recognition(from: original, in: copy)
        copy.schemaVersion = ProjectSchema.current
        try copy.validate()
        return copy
    }

    static func playhead(_ time: MediaTime, from before: ProjectDocument, to after: ProjectDocument) -> MediaTime {
        guard let original = try? OutputTimeline(before).originalTime(forOutput: min(time, before.outputDuration)) else { return .zero }
        let old = before.orderedClips.first { $0.timelineInterval.contains(original) } ?? before.orderedClips.last
        let projected: MediaTime
        if let old, let next = after.clips.first(where: { $0.id == old.id }),
           let value = try? MediaTime(validating: CMTimeAdd(original.cmTime,
                CMTimeSubtract(next.timelineInterval.start.cmTime, old.timelineInterval.start.cmTime))) {
            projected = value
        } else if let old,
                  let following = before.orderedClips.first(where: { clip in
                      clip.timelineInterval.start >= old.timelineInterval.end && after.clips.contains { $0.id == clip.id }
                  }), let next = after.clips.first(where: { $0.id == following.id }) {
            projected = next.timelineInterval.start
        } else { projected = after.sourceDuration }
        return (try? OutputTimeline(after).outputTime(clampingOriginal: projected)) ?? .zero
    }

    private static func recognition(from before: ProjectDocument, in after: ProjectDocument) throws -> Recognition? {
        guard let old = before.recognition else { return nil }
        if old.progress == nil && old.words.isEmpty && old.cues.isEmpty { return nil }
        let active = Set(after.clips.map(\.id))
        let oldPlan = try SpeechCheckpoint.plan(clips: before.clips, assets: before.assets)
        let plan = try SpeechCheckpoint.plan(clips: after.clips, assets: after.assets)
        let grouped = Dictionary(grouping: oldPlan, by: { $0.clip.id })
        var positions: [UUID: Int] = [:]
        var indices: [Int: Int] = [:]
        for window in plan {
            let position = positions[window.clip.id, default: 0]
            positions[window.clip.id] = position + 1
            if let prior = grouped[window.clip.id], prior.indices.contains(position) {
                guard prior[position].core == window.core else { throw ClipGraphError.stale }
                indices[prior[position].index] = window.index
            }
        }
        let retained = (old.progress?.retainedClipIDs ?? (old.progress == nil ? before.clips.map(\.id) : []))
            .filter { active.contains($0) }
        let retainedIDs = Set(retained)
        let resolved = (old.progress?.resolved ?? []).compactMap { value -> RecognitionProgress.Resolved? in
            guard let index = indices[value.index] else { return nil }
            return .init(index: index, attempts: value.attempts, recoveryReason: value.recoveryReason,
                rawWindowIDs: value.rawWindowIDs, nativeWordIDs: value.nativeWordIDs,
                copiedSamples: value.copiedSamples, peak: value.peak, mappingVersion: value.mappingVersion)
        }.sorted { $0.index < $1.index }
        let oldClips = Dictionary(uniqueKeysWithValues: before.clips.map { ($0.id, $0) })
        let offsets = Dictionary(uniqueKeysWithValues: after.clips.compactMap { clip -> (UUID, CMTime)? in
            guard let previous = oldClips[clip.id] else { return nil }
            return (clip.id, CMTimeSubtract(clip.timelineInterval.start.cmTime, previous.timelineInterval.start.cmTime))
        })
        let projectedWords = try old.words.filter { active.contains($0.clipID) }.map { word in
            var copy = word
            guard let delta = offsets[word.clipID] else { throw ClipGraphError.stale }
            copy.projectInterval = try translated(word.projectInterval, by: delta)
            return copy
        }
        let words = projectedWords.enumerated().sorted {
            $0.element.projectInterval.start == $1.element.projectInterval.start
                ? $0.offset < $1.offset : $0.element.projectInterval.start < $1.element.projectInterval.start
        }.map(\.element)
        let originalWords = Dictionary(uniqueKeysWithValues: old.words.map { ($0.id, $0) })
        let projectedCues = try old.cues.compactMap { cue -> CaptionCue? in
            guard let clipID = cue.wordIDs.first.flatMap({ originalWords[$0]?.clipID }), active.contains(clipID) else { return nil }
            guard let delta = offsets[clipID] else { throw ClipGraphError.stale }
            return CaptionCue(id: cue.id, wordIDs: cue.wordIDs, interval: try translated(cue.interval, by: delta))
        }
        let cues = projectedCues.enumerated().sorted {
            $0.element.interval.start == $1.element.interval.start
                ? $0.offset < $1.offset : $0.element.interval.start < $1.element.interval.start
        }.map(\.element)
        if plan.isEmpty && words.isEmpty { return nil }
        // Every structural edit gets a new operation identity. Old terminal jobs
        // and charged reservations cannot be revived for different project inputs.
        return Recognition(id: UUID(), modelID: old.modelID, modelSHA256: old.modelSHA256,
            requestedLanguageCode: old.requestedLanguageCode, completedAt: old.completedAt,
            rawWindows: old.rawWindows.filter { active.contains($0.clipID) }, words: words, cues: cues,
            progress: .init(version: 1, policy: old.progress?.policy ?? SpeechCheckpoint.currentPolicy,
                runtimeRevision: old.progress?.runtimeRevision ?? WhisperRuntimeRelease.revision,
                totalWindows: plan.count, resolved: resolved,
                retainedClipIDs: retained.isEmpty ? nil : retained,
                retainedWindowCount: retained.isEmpty ? nil : plan.filter { retainedIDs.contains($0.clip.id) }.count))
    }

    private static func translated(_ interval: MediaInterval, by delta: CMTime) throws -> MediaInterval {
        try MediaInterval(start: MediaTime(validating: CMTimeAdd(interval.start.cmTime, delta)),
            end: MediaTime(validating: CMTimeAdd(interval.end.cmTime, delta)))
    }
    private static func collapsed(_ time: MediaTime, removing interval: MediaInterval) throws -> MediaTime {
        if time <= interval.start { return time }
        if time < interval.end { return interval.start }
        return try MediaTime(validating: CMTimeSubtract(time.cmTime, interval.duration))
    }
}
