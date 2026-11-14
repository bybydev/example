import CoreMedia
import Foundation
import OSLog
import InkribeModelAssets
import JobQueue
import WhisperRuntime

/// Isolated native/decode owner; JobQueue supplies the sole durable work state.
actor LocalTranscriber {
    private let repository: ProjectRepository
    private let decoder = SpeechDecoder()
    private let didPublish: @Sendable () async -> Void
    private let logger = Logger(subsystem: "com.hoangbkit.inkribe", category: "LocalTranscriber")

    init(repository: ProjectRepository, didPublish: @escaping @Sendable () async -> Void = {}) {
        self.repository = repository
        self.didPublish = didPublish
    }

    func execute(id: UUID, payload: SpeechJob.Payload, progress: JobProgressReporter) async throws {
        try Task.checkCancellation()
        let project = try await repository.open(payload.projectID)
        let replacingRecognitionID = payload.replacingRecognitionID
        // Do not erase a committed result if the process died before queue completion.
        if let saved = project.recognition, saved.id == id, !saved.isIncomplete {
            guard !saved.words.isEmpty else { throw SpeechError.noRecognizedWords }
            if payload.requiresAllowance == true { try await repository.finishSpeechAllowance(id) }
            try? await repository.removePublishedSpeechCheckpoint(projectID: project.id, recognitionID: id)
            return
        }
        if let replacingRecognitionID {
            guard project.recognition?.id == replacingRecognitionID,
                  project.recognition?.isIncomplete == false,
                  project.recognition?.words.isEmpty == false else {
                throw SpeechError.alreadyTranscribed
            }
        } else {
            guard project.recognition == nil || (project.recognition?.id == id && project.recognition?.isIncomplete == true) else { throw SpeechError.alreadyTranscribed }
            guard project.recognition?.isIncomplete == true || project.contentRevision == payload.expectedRevision else {
                throw ProjectStoreError.staleRevision(expected: payload.expectedRevision,
                                                          actual: project.contentRevision)
            }
        }
        guard project.assets.contains(where: { $0.metadata.audioTrackCount > 0 }) else { throw SpeechError.noAudio }
        if payload.requiresAllowance == true {
            try await repository.requireSpeechAllowance(jobID: id, projectID: project.id, revision: payload.expectedRevision)
        }
        let tracker = SpeechProgress(reporter: progress)
        await tracker.stage("Loading speech model…", fraction: 0)
        try await SpeechEngine.shared.withModel { runtime, model in
            try await self.recognize(project, id: id, language: payload.languageCode,
                runtime: runtime, model: model, tracker: tracker,
                chargeAllowance: payload.requiresAllowance == true,
                windowIndices: replacingRecognitionID == nil ? payload.windowIndices : nil,
                replacingRecognitionID: replacingRecognitionID)
            // Publication precedes queue success. Saved work survives cancellation.
            try? await self.repository.removePublishedSpeechCheckpoint(projectID: project.id, recognitionID: id)
            await tracker.stage("Captions saved", fraction: 1)
        }
    }

    private func recognize(_ project: ProjectDocument, id: UUID, language: String?,
                           runtime: NativeWhisperRuntime, model: ModelAssetDescriptor,
                           tracker: SpeechProgress, chargeAllowance: Bool, windowIndices: [Int]?,
                           replacingRecognitionID: UUID?) async throws {
        let current = try await repository.open(project.id)
        guard current.assets == project.assets, current.clips == project.clips else {
            throw ProjectStoreError.invalidDocument("Transcription source graph changed")
        }
        let fresh = SpeechCheckpoint(jobID: id, project: current, modelID: model.id,
                                     modelSHA256: model.sha256, language: language,
                                     retainingExistingCoverage: replacingRecognitionID == nil)
        var checkpoint = try await repository.loadSpeechCheckpoint(matching: fresh,
            replacingRecognitionID: replacingRecognitionID)
        checkpoint.prepareForResume(preservingSavedWords: checkpoint.retainedClipIDs?.isEmpty == false && current.recognition?.words.isEmpty == false)
        let plan = try SpeechCheckpoint.plan(clips: project.clips, assets: project.assets)
        guard !plan.isEmpty else { throw SpeechError.noAudio }
        if let windowIndices {
            guard !windowIndices.isEmpty, windowIndices.allSatisfy({ plan.indices.contains($0) }) else {
                throw ProjectStoreError.invalidDocument("Invalid transcription retry range")
            }
        }
        // Persist the binding before inference. A changed model/language/revision
        // starts fresh only after the new checkpoint is durably written.
        checkpoint = try await repository.saveSpeechCheckpoint(checkpoint,
            replacingRecognitionID: replacingRecognitionID)
        checkpoint = try await publish(checkpoint, chargeAllowance: chargeAllowance,
            replacingRecognitionID: replacingRecognitionID)
        if checkpoint.wordCount > 0, checkpoint.entries.filter({ $0.failure == nil }).count + checkpoint.retainedWindowCount(in: plan) == plan.count { return }
        var entries = Dictionary(uniqueKeysWithValues: checkpoint.entries.map { ($0.index, $0) })
        let total = plan.reduce(0.0) { $0 + CMTimeGetSeconds($1.core.duration) }
        var completed = 0.0
        for window in plan {
            try Task.checkCancellation()
            let base = completed / total
            let duration = CMTimeGetSeconds(window.core.duration)
            let share = duration / total
            await tracker.begin(window: window.index, base: base, share: share)
            if checkpoint.retains(window.clip.id) {
                completed += duration
                await tracker.stage("Keeping saved captions…", fraction: completed / total * 0.95)
                continue
            }
            if let saved = entries[window.index], saved.failure == nil {
                completed += duration
                await tracker.stage("Reusing saved transcription…", fraction: completed / total * 0.95)
                continue
            }
            if let windowIndices, !windowIndices.contains(window.index) {
                completed += duration
                continue
            }
            // Missing source/model/storage and cancellation never become window failures.
            let url = try await repository.sourceURL(projectID: project.id, assetID: window.clip.sourceAssetID)
            var entry: SpeechCheckpoint.Entry
            do {
                entry = try await recognizeWindow(window, url: url, language: language,
                    runtime: runtime, tracker: tracker,
                    recovering: false)
            } catch {
                try Task.checkCancellation()
                guard let failure = SpeechCheckpoint.Failure.classify(error) else { throw error }
                logger.info("Speech recovery window=\(window.index) reason=\(failure.rawValue) attempt=2 sourceStart=\(CMTimeGetSeconds(window.core.start.cmTime)) sourceEnd=\(CMTimeGetSeconds(window.core.end.cmTime))")
                await tracker.stage("Retrying an audio window…", fraction: base * 0.95)
                do {
                    // One bounded recovery, with changed acoustic context: split
                    // the ownership core in half, keeping real token timestamps.
                    let recovered = try await recognizeWindow(window, url: url, language: language,
                        runtime: runtime, tracker: tracker,
                        recovering: true)
                    // An empty retry cannot establish that malformed recognized
                    // text was silence. Keep that core explicitly unresolved.
                    guard !recovered.words.isEmpty || recovered.peak == 0 else { throw error }
                    entry = recovered
                } catch {
                    try Task.checkCancellation()
                    guard let lastFailure = SpeechCheckpoint.Failure.classify(error) else { throw error }
                    logger.info("Speech unresolved window=\(window.index) reason=\(lastFailure.rawValue) attempt=2")
                    entry = .init(index: window.index, attempts: 2, windows: [], words: [],
                                  copiedSamples: 0, peak: 0, failure: lastFailure)
                }
                entry.recoveryReason = failure
            }
            entries[window.index] = entry
            checkpoint.entries = entries.values.sorted { $0.index < $1.index }
            // Saving is outside the recovery catch. A failed/unsafe write stops
            // the job; the preceding atomic checkpoint remains available.
            checkpoint = try await repository.saveSpeechCheckpoint(checkpoint,
                replacingRecognitionID: replacingRecognitionID)
            checkpoint = try await publish(checkpoint, chargeAllowance: chargeAllowance,
                replacingRecognitionID: replacingRecognitionID)
            completed += duration
            await tracker.stage(entry.failure == nil ? "Audio window saved" : "Window needs retry; continuing…",
                                fraction: completed / total * 0.95)
        }
        let resolved = checkpoint.entries.filter { $0.failure == nil }.count + checkpoint.retainedWindowCount(in: plan)
        guard resolved == plan.count else {
            let failures = Dictionary(grouping: checkpoint.entries.compactMap { $0.failure?.description }, by: { $0 })
            let reasons = failures.keys.sorted().map { "\($0): \(failures[$0]?.count ?? 0) ranges" }.joined(separator: "; ")
            let captions = checkpoint.wordCount == 0 ? "No captions have been created yet." : "Available captions and edits remain usable."
            throw SpeechRecoveryError.incomplete(resolved: resolved, total: plan.count,
                detail: captions + (reasons.isEmpty ? "" : " " + reasons + "."))
        }
        // A carried legacy transcript already supplies genuine saved words;
        // newly appended silent cores must not erase that completed publication.
        if checkpoint.retainedClipIDs?.isEmpty == false, current.recognition?.words.isEmpty == false { return }
        guard checkpoint.entries.contains(where: { $0.copiedSamples > 0 }) else { throw SpeechError.emptyAudio }
        guard checkpoint.entries.contains(where: { $0.peak > 0 }) else { throw SpeechError.silentAudio }
        guard checkpoint.wordCount > 0 else { throw SpeechError.noRecognizedWords }
    }

    private func publish(_ checkpoint: SpeechCheckpoint, chargeAllowance: Bool,
                         replacingRecognitionID: UUID?) async throws -> SpeechCheckpoint {
        let document = try await repository.publishSpeechProgress(checkpoint,
            chargeOnCompletion: chargeAllowance, replacingRecognitionID: replacingRecognitionID)
        var updated = checkpoint
        updated.revision = document.contentRevision
        if document.contentRevision != checkpoint.revision { await didPublish() }
        return updated
    }

    private func recognizeWindow(_ window: SpeechCheckpoint.Window, url: URL, language: String?,
                                 runtime: NativeWhisperRuntime, tracker: SpeechProgress,
                                 recovering: Bool) async throws -> SpeechCheckpoint.Entry {
        let cores: [MediaInterval]
        if recovering { cores = try SpeechCheckpoint.recoveryCores(window.core) }
        else { cores = [window.core] }
        var windows: [RecognitionWindow] = []
        var words: [CaptionWord] = []
        var copied = 0
        var peak: Float = 0
        for (part, core) in cores.enumerated() {
            try Task.checkCancellation()
            let readRange = try SpeechCheckpoint.context(for: core, clip: window.clip, recovering: recovering)
            let decoded = try await decoder.read(url: url, interval: readRange)
            copied += decoded.copiedSampleCount
            peak = max(peak, decoded.peak)
            // Digital silence/gaps never ask Whisper to hallucinate speech.
            if decoded.peak == 0 { continue }
            let inferenceID = UUID()
            await tracker.beginInference(window: window.index, id: inferenceID)
            let relay = NativeProgressRelay(window: window.index, tracker: tracker,
                inferenceID: inferenceID,
                offset: Double(part) / Double(cores.count), scale: 1 / Double(cores.count))
            let raw: WhisperTranscriptionResult
            do {
                raw = try await runtime.transcribe(buffer: WhisperAudioBuffer(samples: decoded.samples),
                    requestedLanguageCode: language, progress: { value in relay.report(value) })
            } catch {
                await tracker.endInference(id: inferenceID)
                throw error
            }
            await tracker.endInference(id: inferenceID)
            try Task.checkCancellation()
            let value = WordMapper.rawWindow(raw, clipID: window.clip.id, interval: readRange)
            logger.info("Speech inference window=\(window.index) part=\(part) recovery=\(recovering) segments=\(raw.segments.count) tokens=\(raw.tokens.count)")
            // Reject malformed native times before conversion/JSON persistence.
            guard value.tokens.allSatisfy({ $0.startSeconds.isFinite && $0.endSeconds.isFinite }),
                  value.segments.allSatisfy({ $0.startSeconds.isFinite && $0.endSeconds.isFinite }) else {
                throw SpeechError.wordTimingUnavailable
            }
            let mapped: [CaptionWord]
            do { mapped = try WordMapper.words(in: value, clip: window.clip, core: core,
                mappingVersion: WordMapper.currentMappingVersion) }
            catch is MediaTimeError { throw SpeechError.wordTimingUnavailable }
            // Numeric diagnostics only; no source paths, raw audio or recognized text.
            let phrases = mapped.filter { $0.timingProvenance == "whisper-segment" }.count
            logger.info("Speech mapping window=\(window.index) part=\(part) recovery=\(recovering) units=\(mapped.count) segmentTimed=\(phrases)")
            WordMapper.append(mapped, to: &words)
            windows.append(value)
        }
        return .init(index: window.index, attempts: recovering ? 2 : 1,
                     windows: windows, words: words, copiedSamples: copied, peak: peak, failure: nil,
                     mappingVersion: WordMapper.currentMappingVersion)
    }
}

/// Ignore callbacks from an already-finished window and keep progress monotonic.
private actor SpeechProgress {
    let reporter: JobProgressReporter
    private var activeWindow = -1
    private var activeInference: UUID?
    private var base = 0.0
    private var share = 0.0
    private var fraction = 0.0
    init(reporter: JobProgressReporter) { self.reporter = reporter }
    func begin(window: Int, base: Double, share: Double) async {
        activeWindow = window
        activeInference = nil
        self.base = base
        self.share = share
        await stage("Decoding audio…", fraction: base * 0.95)
    }
    func beginInference(window: Int, id: UUID) {
        guard window == activeWindow else { return }
        activeInference = id
    }
    func endInference(id: UUID) {
        if activeInference == id { activeInference = nil }
    }
    func native(window: Int, inferenceID: UUID, value: Double) async {
        guard window == activeWindow, inferenceID == activeInference, value.isFinite else { return }
        await stage("Transcribing…", fraction: (base + share * min(1, max(0, value))) * 0.95)
    }
    func stage(_ message: String, fraction value: Double) async {
        if value >= 0.98 { activeWindow = -1; activeInference = nil }
        fraction = max(fraction, value)
        await reporter.report(fractionCompleted: fraction, message: message)
    }
}

/// Bound cross-thread progress tasks to at most 101 per inference window.
private final class NativeProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var highest = -1
    private let window: Int
    private let tracker: SpeechProgress
    private let inferenceID: UUID
    private let offset: Double
    private let scale: Double
    init(window: Int, tracker: SpeechProgress, inferenceID: UUID, offset: Double = 0, scale: Double = 1) {
        self.window = window; self.tracker = tracker; self.offset = offset; self.scale = scale
        self.inferenceID = inferenceID
    }
    func report(_ value: Double) {
        guard value.isFinite else { return }
        let percent = Int((min(1, max(0, value)) * 100).rounded(.down))
        let shouldReport = lock.withLock {
            guard percent > highest else { return false }
            highest = percent
            return true
        }
        if shouldReport {
            let fraction = offset + scale * Double(percent) / 100
            Task { await tracker.native(window: window, inferenceID: inferenceID, value: fraction) }
        }
    }
}
