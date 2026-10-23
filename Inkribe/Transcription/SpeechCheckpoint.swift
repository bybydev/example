import CoreMedia
import Foundation
import WhisperRuntime

/// Durable inference state. Accepted units publish incrementally into Recognition;
/// unresolved attempts stay here. Queue payload additions remain optional.
struct SpeechCheckpoint: Codable, Sendable {
    static let currentVersion = 1
    static let currentPolicy = 1 // 24s cores, 2s context; one recovery using <=12s cores.
    static let maximumBytes = 64 * 1024 * 1024
    static let maximumWindows = 20_000

    let version: Int
    let policy: Int
    let jobID: UUID
    let projectID: UUID
    var revision: UInt64
    let modelID: String
    let modelSHA256: String
    let runtimeRevision: String
    let language: String?
    let assets: [SourceAsset]
    let clips: [ProjectClip]
    var entries: [Entry]

    struct Window: Equatable, Sendable {
        let index: Int
        let clip: ProjectClip
        let core: MediaInterval
    }

    struct Entry: Codable, Equatable, Sendable {
        let index: Int
        let attempts: Int
        var recoveryReason: Failure? = nil
        let windows: [RecognitionWindow]
        let words: [CaptionWord]
        let copiedSamples: Int
        let peak: Float
        let failure: Failure?
        /// Absent in existing checkpoints; mapping 1 remains reproducible.
        var mappingVersion: Int? = nil
    }

    enum Failure: String, Codable, Sendable {
        case timing, text, decode, inference

        var description: String {
            switch self {
            case .timing: "Unusable word timing"
            case .text: "Incomplete model text"
            case .decode: "Audio window could not be decoded"
            case .inference: "Speech inference failed"
            }
        }

        /// Only these explicit failures can be isolated. Model/source/storage,
        /// revision, arbitrary AVFoundation errors and cancellation remain fatal.
        static func classify(_ error: Error) -> Self? {
            if let error = error as? SpeechError {
                switch error {
                case .wordTimingUnavailable: return .timing
                case .invalidUTF8: return .text
                case .emptyAudio, .invalidAudio: return .decode
                default: return nil
                }
            }
            if let error = error as? WhisperRuntimeError,
               case .transcriptionFailed = error { return .inference }
            return nil
        }
    }

    init(jobID: UUID, project: ProjectDocument, modelID: String,
         modelSHA256: String, language: String?) {
        version = Self.currentVersion; policy = Self.currentPolicy
        self.jobID = jobID; projectID = project.id; revision = project.contentRevision
        self.modelID = modelID; self.modelSHA256 = modelSHA256; self.language = language
        runtimeRevision = WhisperRuntimeRelease.revision
        assets = project.assets; clips = project.clips; entries = []
    }

    func matches(_ other: Self) -> Bool {
        revision == other.revision && matchesInputs(other)
    }

    func matchesInputs(_ other: Self) -> Bool {
        version == other.version && policy == other.policy && jobID == other.jobID &&
            projectID == other.projectID &&
            modelID == other.modelID && modelSHA256 == other.modelSHA256 && runtimeRevision == other.runtimeRevision &&
            language == other.language && assets == other.assets && clips == other.clips
    }

    /// Canonical coverage can rebuild resume state after sidecar loss/discard or
    /// duplication. Raw text recreates native values; edited text is never inferred again.
    func seeded(from recognition: Recognition?) throws -> Self {
        guard let recognition else { return self }
        guard recognition.id == jobID, recognition.modelID == modelID,
              recognition.modelSHA256 == modelSHA256, recognition.requestedLanguageCode == language,
              let progress = recognition.progress, progress.policy == policy,
              progress.runtimeRevision == runtimeRevision else { throw SpeechRecoveryError.incompatible }
        let plan = try Self.plan(clips: clips, assets: assets)
        let rawIndex = Dictionary(uniqueKeysWithValues: recognition.rawWindows.map { ($0.id, $0) })
        var result = self
        for saved in progress.resolved {
            guard plan.indices.contains(saved.index) else { throw SpeechRecoveryError.corrupt }
            let planned = plan[saved.index]
            let cores: [MediaInterval]
            if saved.attempts == 1 { cores = [planned.core] }
            else { cores = try Self.recoveryCores(planned.core) }
            let ranges = try cores.map { try Self.context(for: $0, clip: planned.clip, recovering: saved.attempts == 2) }
            let windows = saved.rawWindowIDs.compactMap { rawIndex[$0] }
            guard windows.count == saved.rawWindowIDs.count else { throw SpeechRecoveryError.corrupt }
            var words: [CaptionWord] = []
            for raw in windows {
                guard let part = ranges.firstIndex(of: raw.sourceInterval) else { throw SpeechRecoveryError.corrupt }
                WordMapper.append(try WordMapper.words(in: raw, clip: planned.clip, core: cores[part],
                    mappingVersion: saved.mappingVersion ?? 1), to: &words)
            }
            guard words.count == saved.nativeWordIDs.count else { throw SpeechRecoveryError.corrupt }
            let identified = zip(words, saved.nativeWordIDs).map { pair in
                let (word, id) = pair
                return CaptionWord(id: id, clipID: word.clipID, rawWindowID: word.rawWindowID,
                    text: word.text, sourceInterval: word.sourceInterval, projectInterval: word.projectInterval,
                    timingProvenance: word.timingProvenance)
            }
            result.entries.append(.init(index: saved.index, attempts: saved.attempts,
                recoveryReason: saved.recoveryReason.flatMap(Failure.init(rawValue:)),
                windows: windows, words: identified, copiedSamples: saved.copiedSamples,
                peak: saved.peak, failure: nil, mappingVersion: saved.mappingVersion))
        }
        result.entries.sort { $0.index < $1.index }
        try result.validate(recheckingMapping: true)
        return result
    }

    func publication(merging existing: Recognition?) throws -> Recognition? {
        let accepted = entries.filter { $0.failure == nil }
        let raw = accepted.flatMap(\.windows)
        let native = accepted.flatMap(\.words)
        if native.isEmpty && existing == nil { return nil }
        let existingIDs = Set(existing?.words.map(\.id) ?? [])
        let nativeIndex = Dictionary(uniqueKeysWithValues: native.map { ($0.id, $0) })
        guard existingIDs.isSubset(of: Set(nativeIndex.keys)) else { throw SpeechRecoveryError.corrupt }
        if let existing {
            guard existing.id == jobID, existing.modelID == modelID, existing.modelSHA256 == modelSHA256,
                  existing.requestedLanguageCode == language else { throw SpeechError.alreadyTranscribed }
            let rawIndex = Dictionary(uniqueKeysWithValues: raw.map { ($0.id, $0) })
            guard existing.rawWindows.allSatisfy({ rawIndex[$0.id] == $0 }) else { throw SpeechRecoveryError.corrupt }
        }
        // Compare native text/anchors for deduplication, even when the visible
        // existing word has been corrected, hidden or retimed by the user.
        let oldNative = existingIDs.compactMap { nativeIndex[$0] }
        let oldByText = Dictionary(grouping: oldNative, by: WordMapper.duplicateKey)
        var additions: [CaptionWord] = []
        let orderedNative = native.enumerated().sorted {
            $0.element.projectInterval.start == $1.element.projectInterval.start
                ? $0.offset < $1.offset : $0.element.projectInterval.start < $1.element.projectInterval.start
        }.map(\.element)
        for word in orderedNative
            where !existingIDs.contains(word.id) {
            if oldByText[WordMapper.duplicateKey(word)]?.contains(where: { WordMapper.duplicates(word, $0) }) == true { continue }
            WordMapper.append([word], to: &additions)
        }
        let progress = RecognitionProgress(version: 1, policy: policy, runtimeRevision: runtimeRevision,
            totalWindows: try Self.plan(clips: clips, assets: assets).count,
            resolved: accepted.map {
                .init(index: $0.index, attempts: $0.attempts, recoveryReason: $0.recoveryReason?.rawValue,
                      rawWindowIDs: $0.windows.map(\.id), nativeWordIDs: $0.words.map(\.id),
                      copiedSamples: $0.copiedSamples, peak: $0.peak, mappingVersion: $0.mappingVersion)
            })
        let currentRawIDs = Set(existing?.rawWindows.map(\.id) ?? [])
        return Recognition(id: jobID, modelID: modelID, modelSHA256: modelSHA256,
            requestedLanguageCode: language, completedAt: existing?.completedAt ?? Date(),
            rawWindows: (existing?.rawWindows ?? []) + raw.filter { !currentRawIDs.contains($0.id) },
            words: (existing?.words ?? []) + additions,
            cues: Recognition.inserting(try WordMapper.cues(for: additions), into: existing?.cues ?? []),
            progress: progress)
    }

    static func plan(clips: [ProjectClip], assets: [SourceAsset]) throws -> [Window] {
        let audio = Set(assets.filter { $0.metadata.audioTrackCount > 0 }.map(\.id))
        var result: [Window] = []
        for clip in clips.sorted(by: { $0.timelineInterval.start < $1.timelineInterval.start })
            where audio.contains(clip.sourceAssetID) {
            var start = clip.sourceInterval.start
            while start < clip.sourceInterval.end {
                guard result.count < maximumWindows else { throw SpeechRecoveryError.tooLarge }
                let end = min(clip.sourceInterval.end, try MediaTime(validating:
                    CMTimeAdd(start.cmTime, CMTime(seconds: 24, preferredTimescale: 1))))
                let core = try MediaInterval(start: start, end: end)
                result.append(Window(index: result.count, clip: clip, core: core))
                start = end
            }
        }
        return result
    }

    static func context(for core: MediaInterval, clip: ProjectClip,
                        recovering: Bool = false) throws -> MediaInterval {
        let padding = recovering ? CMTimeMinimum(CMTime(seconds: 2, preferredTimescale: 1),
            CMTimeMultiplyByRatio(core.duration, multiplier: 1, divisor: 4)) : CMTime(seconds: 2, preferredTimescale: 1)
        return try MediaInterval(start: max(clip.sourceInterval.start, MediaTime(validating:
            CMTimeMaximum(.zero, CMTimeSubtract(core.start.cmTime, padding)))),
            end: min(clip.sourceInterval.end, MediaTime(validating:
                CMTimeAdd(core.end.cmTime, padding))))
    }

    static func recoveryCores(_ core: MediaInterval) throws -> [MediaInterval] {
        let midpoint = try MediaTime(validating: CMTimeAdd(core.start.cmTime,
            CMTimeMultiplyByRatio(core.duration, multiplier: 1, divisor: 2)))
        guard midpoint > core.start, midpoint < core.end else { return [core] }
        return try [MediaInterval(start: core.start, end: midpoint),
                    MediaInterval(start: midpoint, end: core.end)]
    }

    func validate(recheckingMapping: Bool = false) throws {
        guard version == Self.currentVersion, policy == Self.currentPolicy else { throw SpeechRecoveryError.incompatible }
        guard revision > 0, !modelID.isEmpty, modelSHA256.count == 64,
              runtimeRevision.count == 40, runtimeRevision.allSatisfy(\.isHexDigit),
              modelSHA256.allSatisfy(\.isHexDigit), !assets.isEmpty, !clips.isEmpty,
              Set(assets.map(\.id)).count == assets.count,
              Set(clips.map(\.id)).count == clips.count,
              Set(entries.map(\.index)).count == entries.count,
              entries.map(\.index) == entries.map(\.index).sorted() else { throw SpeechRecoveryError.corrupt }
        for asset in assets { try asset.validate() }
        let assetIndex = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        for clip in clips { try clip.validate(assets: assetIndex) }
        let plan = try Self.plan(clips: clips, assets: assets)
        guard entries.count <= plan.count else { throw SpeechRecoveryError.corrupt }
        for entry in entries {
            guard plan.indices.contains(entry.index), (1...2).contains(entry.attempts),
                  (entry.attempts == 1 ? entry.recoveryReason == nil : entry.recoveryReason != nil),
                  entry.copiedSamples >= 0, entry.peak.isFinite, entry.peak >= 0,
                  (1...WordMapper.currentMappingVersion).contains(entry.mappingVersion ?? 1) else {
                throw SpeechRecoveryError.corrupt
            }
            if entry.failure != nil {
                guard entry.attempts == 2, entry.windows.isEmpty, entry.words.isEmpty,
                      entry.copiedSamples == 0, entry.peak == 0 else { throw SpeechRecoveryError.corrupt }
                continue
            }
            let planned = plan[entry.index]
            let cores: [MediaInterval]
            if entry.attempts == 1 { cores = [planned.core] }
            else { cores = try Self.recoveryCores(planned.core) }
            let ranges = try cores.map { try Self.context(for: $0, clip: planned.clip, recovering: entry.attempts == 2) }
            guard entry.windows.count <= cores.count,
                  (entry.peak == 0 ? entry.windows.isEmpty && entry.words.isEmpty : !entry.windows.isEmpty),
                  entry.peak == 0 || entry.copiedSamples > 0 else { throw SpeechRecoveryError.corrupt }
            var seenRanges: [MediaInterval] = []
            for raw in entry.windows {
                guard raw.clipID == planned.clip.id, ranges.contains(raw.sourceInterval) else {
                    throw SpeechRecoveryError.corrupt
                }
                guard !seenRanges.contains(raw.sourceInterval) else { throw SpeechRecoveryError.corrupt }
                seenRanges.append(raw.sourceInterval)
            }
            for word in entry.words {
                guard word.clipID == planned.clip.id,
                      let raw = entry.windows.first(where: { $0.id == word.rawWindowID }),
                      let part = ranges.firstIndex(of: raw.sourceInterval),
                      word.adjustedSourceInterval == nil,
                      word.timingProvenance == "whisper-token-union" ||
                        (entry.mappingVersion == 2 && word.timingProvenance == "whisper-segment") else {
                    throw SpeechRecoveryError.corrupt
                }
                let midpoint = CMTimeAdd(word.sourceInterval.start.cmTime,
                    CMTimeMultiplyByFloat64(word.sourceInterval.duration, multiplier: 0.5))
                guard CMTimeCompare(midpoint, cores[part].start.cmTime) >= 0,
                      CMTimeCompare(midpoint, cores[part].end.cmTime) < 0 else { throw SpeechRecoveryError.corrupt }
            }
            if recheckingMapping {
                // Validate raw-to-word provenance once before reuse, without
                // re-tokenizing every preceding window on each incremental save.
                var mapped: [CaptionWord] = []
                for raw in entry.windows {
                    guard let part = ranges.firstIndex(of: raw.sourceInterval) else { throw SpeechRecoveryError.corrupt }
                    WordMapper.append(try WordMapper.words(in: raw, clip: planned.clip, core: cores[part],
                        mappingVersion: entry.mappingVersion ?? 1), to: &mapped)
                }
                guard mapped.count == entry.words.count,
                      zip(mapped, entry.words).allSatisfy({ pair in
                          let (expected, stored) = pair
                          return expected.rawWindowID == stored.rawWindowID && expected.text == stored.text &&
                              expected.sourceInterval == stored.sourceInterval &&
                              expected.projectInterval == stored.projectInterval &&
                              expected.timingProvenance == stored.timingProvenance
                      }) else { throw SpeechRecoveryError.corrupt }
            }
        }
        // Check cross-entry identities and all canonical source/project links too.
        let words = entries.flatMap(\.words).enumerated().sorted {
            $0.element.projectInterval.start == $1.element.projectInterval.start
                ? $0.offset < $1.offset : $0.element.projectInterval.start < $1.element.projectInterval.start
        }.map(\.element)
        try Recognition(id: jobID, modelID: modelID, modelSHA256: modelSHA256,
            requestedLanguageCode: language, completedAt: .distantPast,
            rawWindows: entries.flatMap(\.windows), words: words, cues: WordMapper.cues(for: words))
            .validate(clips: clips, assets: assets)
    }

    var wordCount: Int { entries.reduce(0) { $0 + $1.words.count } }
    var usesCurrentModelAndRuntime: Bool {
        Self.usesCurrentModelAndRuntime(modelID: modelID, hash: modelSHA256, revision: runtimeRevision)
    }

    static func usesCurrentModelAndRuntime(modelID: String, hash: String, revision: String) -> Bool {
        revision == WhisperRuntimeRelease.revision &&
            (try? SpeechModelCatalog.descriptor(modelID).sha256) == hash
    }

    /// A fully empty run must infer again on retry; its empty responses are not
    /// permanent evidence that the source contains no speech. Digital silence is reusable.
    mutating func prepareForResume() {
        if wordCount == 0 { entries.removeAll { $0.failure == nil && $0.peak > 0 } }
    }
}

struct SpeechRecoverySummary: Sendable {
    struct Unresolved: Identifiable, Sendable {
        let id: Int
        let clipNumber: Int
        let source: MediaInterval
        let reason: String
    }
    let jobID: UUID
    let reusableRevision: Bool
    let compatibleRuntime: Bool
    let resolved: Int
    let total: Int
    let words: Int
    let modelID: String
    let language: String?
    let unresolved: [Unresolved] // UI displays a bounded prefix.
}

enum SpeechRecoveryError: LocalizedError {
    case corrupt, incompatible, tooLarge
    case incomplete(resolved: Int, total: Int, detail: String)

    var errorDescription: String? {
        switch self {
        case .corrupt: "Saved transcription progress could not be read safely. Discard saved progress to start again. Your project and original media are preserved."
        case .incompatible: "Saved transcription progress uses another model, runtime or recovery policy. Existing captions remain usable. Resume requires the original compatible setup."
        case .tooLarge: "This transcription exceeds the saved-progress limit. Use a shorter source project."
        case let .incomplete(resolved, total, detail): "Transcription resolved \(resolved) of \(total) windows. \(detail) Retry the missing ranges. Incomplete work has not used your allowance."
        }
    }
}
