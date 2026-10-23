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
    private let logger = Logger(subsystem: "com.hoangbkit.inkribe", category: "LocalTranscriber")

    init(repository: ProjectRepository) {
        self.repository = repository
    }

    func execute(id: UUID, payload: SpeechJob.Payload, progress: JobProgressReporter) async throws {
        try Task.checkCancellation()
        let project = try await repository.open(payload.projectID)
        // Do not erase a committed result if the process died before queue completion.
        if let saved = project.recognition, saved.id == id {
            guard !saved.words.isEmpty else { throw SpeechError.noRecognizedWords }
            if payload.requiresAllowance == true { try await repository.finishSpeechAllowance(id) }
            return
        }
        guard project.recognition == nil else { throw SpeechError.alreadyTranscribed }
        guard project.contentRevision == payload.expectedRevision else {
            throw ProjectStoreError.staleRevision(expected: payload.expectedRevision,
                                                      actual: project.contentRevision)
        }
        guard project.assets.contains(where: { $0.metadata.audioTrackCount > 0 }) else { throw SpeechError.noAudio }
        if payload.requiresAllowance == true {
            try await repository.requireSpeechAllowance(jobID: id, projectID: project.id, revision: payload.expectedRevision)
        }
        let tracker = SpeechProgress(reporter: progress)
        await tracker.stage("Loading speech model…", fraction: 0)
        let lease = UUID()
        let model = try await SpeechModelStore.shared.acquire(payload.resolvedModelID, lease: lease)
        let runtime = NativeWhisperRuntime(modelURL: model.url,
            configuration: .init(threadCount: Int32(max(1, min(4, ProcessInfo.processInfo.processorCount - 1))),
                                 useGPU: false, flashAttention: false),
            captureTokenBytes: true, modelDescriptor: model.descriptor)
        do {
            try Task.checkCancellation()
            try await runtime.loadModel()
            try Task.checkCancellation()
            let result = try await recognize(project, id: id, language: payload.languageCode,
                                             runtime: runtime, model: model.descriptor, tracker: tracker)
            await tracker.stage("Saving captions…", fraction: 0.98)
            try Task.checkCancellation()
            try await repository.saveRecognition(result, projectID: project.id,
                                                  expectedRevision: payload.expectedRevision,
                                                  chargeAllowance: payload.requiresAllowance == true)
            // Publication precedes queue success, with no cancellation check in between.
            await runtime.unloadModel()
            await SpeechModelStore.shared.release(lease)
            await tracker.stage("Captions saved", fraction: 1)
        } catch {
            await runtime.unloadModel()
            await SpeechModelStore.shared.release(lease)
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private func recognize(_ project: ProjectDocument, id: UUID, language: String?,
                           runtime: NativeWhisperRuntime, model: ModelAssetDescriptor,
                           tracker: SpeechProgress) async throws -> Recognition {
        var windows: [RecognitionWindow] = []
        var words: [CaptionWord] = []
        let assets = Dictionary(uniqueKeysWithValues: project.assets.map { ($0.id, $0) })
        let clips = project.clips.sorted { $0.timelineInterval.start < $1.timelineInterval.start }
        let total = clips.filter { assets[$0.sourceAssetID]?.metadata.audioTrackCount ?? 0 > 0 }
            .reduce(0.0) { $0 + CMTimeGetSeconds($1.sourceInterval.duration) }
        guard total.isFinite, total > 0 else { throw SpeechError.noAudio }
        var completed = 0.0
        var index = 0
        var copiedSampleCount = 0
        var peak: Float = 0
        for clip in clips {
            guard assets[clip.sourceAssetID]?.metadata.audioTrackCount ?? 0 > 0 else { continue }
            let url = try await repository.sourceURL(projectID: project.id, assetID: clip.sourceAssetID)
            var cursor = clip.sourceInterval.start
            while cursor < clip.sourceInterval.end {
                try Task.checkCancellation()
                let end = min(clip.sourceInterval.end, try MediaTime(validating:
                    CMTimeAdd(cursor.cmTime, CMTime(seconds: 24, preferredTimescale: 1))))
                let core = try MediaInterval(start: cursor, end: end)
                let leading = CMTimeSubtract(cursor.cmTime, CMTime(seconds: 2, preferredTimescale: 1))
                let trailing = CMTimeAdd(end.cmTime, CMTime(seconds: 2, preferredTimescale: 1))
                let readRange = try MediaInterval(
                    start: MediaTime(validating: CMTimeMaximum(clip.sourceInterval.start.cmTime, leading)),
                    end: MediaTime(validating: CMTimeMinimum(clip.sourceInterval.end.cmTime, trailing)))
                let windowIndex = index
                let base = completed / total
                let duration = CMTimeGetSeconds(core.duration)
                let share = duration / total
                await tracker.begin(window: windowIndex, base: base, share: share)
                let decoded = try await decoder.read(url: url, interval: readRange)
                copiedSampleCount += decoded.copiedSampleCount
                peak = max(peak, decoded.peak)
                // Skip digital silence and intentional track gaps without asking
                // the model to hallucinate text. Quiet nonzero audio still runs.
                if decoded.peak == 0 {
                    completed += duration; index += 1; cursor = end
                    continue
                }
                try Task.checkCancellation()
                let relay = NativeProgressRelay(window: windowIndex, tracker: tracker)
                let raw = try await runtime.transcribe(buffer: WhisperAudioBuffer(samples: decoded.samples),
                    requestedLanguageCode: language, progress: { value in relay.report(value) })
                try Task.checkCancellation()
                let window = WordMapper.rawWindow(raw, clipID: clip.id, interval: readRange)
                logger.info("Speech inference window=\(windowIndex) segments=\(raw.segments.count) tokens=\(raw.tokens.count)")
                let mapped = try WordMapper.words(in: window, clip: clip, core: core)
                logger.info("Speech mapping window=\(windowIndex) words=\(mapped.count)")
                WordMapper.append(mapped, to: &words)
                windows.append(window)
                completed += duration
                index += 1
                cursor = end
            }
        }
        guard copiedSampleCount > 0 else { throw SpeechError.emptyAudio }
        guard peak > 0 else { throw SpeechError.silentAudio }
        guard !words.isEmpty else {
            let hasText = windows.contains { window in
                window.segments.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ||
                window.tokens.contains { !$0.utf8.isEmpty }
            }
            throw hasText ? SpeechError.wordTimingUnavailable : SpeechError.noRecognizedWords
        }
        // Stable ordering when a native token covers more than one lexical word.
        words = words.enumerated().sorted {
            $0.element.projectInterval.start == $1.element.projectInterval.start
                ? $0.offset < $1.offset : $0.element.projectInterval.start < $1.element.projectInterval.start
        }.map(\.element)
        let result = Recognition(id: id, modelID: model.id, modelSHA256: model.sha256,
            requestedLanguageCode: language, completedAt: Date(), rawWindows: windows,
            words: words, cues: try WordMapper.cues(for: words))
        try result.validate(clips: clips, assets: project.assets)
        return result
    }
}

/// Ignore callbacks from an already-finished window and keep progress monotonic.
private actor SpeechProgress {
    let reporter: JobProgressReporter
    private var activeWindow = -1
    private var base = 0.0
    private var share = 0.0
    private var fraction = 0.0
    init(reporter: JobProgressReporter) { self.reporter = reporter }
    func begin(window: Int, base: Double, share: Double) async {
        activeWindow = window
        self.base = base
        self.share = share
        await stage("Decoding audio…", fraction: base * 0.95)
    }
    func native(window: Int, value: Double) async {
        guard window == activeWindow, value.isFinite else { return }
        await stage("Transcribing…", fraction: (base + share * min(1, max(0, value))) * 0.95)
    }
    func stage(_ message: String, fraction value: Double) async {
        if value >= 0.98 { activeWindow = -1 }
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
    init(window: Int, tracker: SpeechProgress) { self.window = window; self.tracker = tracker }
    func report(_ value: Double) {
        guard value.isFinite else { return }
        let percent = Int((min(1, max(0, value)) * 100).rounded(.down))
        let shouldReport = lock.withLock {
            guard percent > highest else { return false }
            highest = percent
            return true
        }
        if shouldReport { Task { await tracker.native(window: window, value: Double(percent) / 100) } }
    }
}
