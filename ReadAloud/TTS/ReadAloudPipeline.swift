import Foundation

@MainActor
final class ReadAloudPipeline {
    enum State: Equatable, Sendable {
        case idle
        case loading
        case warmingUp
        case synthesizing(current: Int, total: Int)
        case playing
        case paused
        case finished
        case failed(String)
    }

    enum Event: Sendable {
        case state(State)
        case modelLoaded(seconds: Double)
        case chunkStarted(
            index: Int,
            total: Int,
            bucketSeconds: Int
        )
        case chunkReady(
            index: Int,
            total: Int,
            bucketSeconds: Int,
            synthesisSeconds: Double,
            audioDurationSeconds: Double,
            realTimeFactor: Double,
            firstAudioLatencySeconds: Double?,
            underrun: Bool
        )
        case queueChanged(
            queuedBuffers: Int,
            queuedDurationSeconds: Double
        )
        case warmUpFinished(seconds: Double)
        case stopped
    }

    enum PipelineError: LocalizedError {
        case emptyText
        case cancelled

        var errorDescription: String? {
            switch self {
            case .emptyText:
                return "Enter text to read aloud."
            case .cancelled:
                return "Read-aloud playback was cancelled."
            }
        }
    }

    private(set) var engine: any SpeechSynthesisEngine
    private(set) var engineKind: SpeechEngineKind
    private let playback: SpeechPlaybackQueue
    private let scheduler: SpeechChunkScheduler
    private let maxQueuedBuffers = 2

    private var readingTask: Task<Void, Error>?
    private var activeOperationID: UUID?
    private var isPaused = false
    private var playbackPositionOriginSeconds = 0.0

    private(set) var state: State = .idle
    var onEvent: ((Event) -> Void)?
    var onAudioSessionEvent:
        ((SpeechPlaybackQueue.SessionEvent) -> Void)?

    var playbackPositionSeconds: Double {
        max(
            0,
            playback.playedSeconds
                - playbackPositionOriginSeconds
        )
    }

    init() {
        let playback = SpeechPlaybackQueue()

        let kind = ReadAloudPreferences.speechEngine
        self.engineKind = kind
        self.engine = SpeechEngineFactory.make(kind)
        self.playback = playback
        self.scheduler = SpeechChunkScheduler()

        playback.onSnapshotChange = { [weak self] snapshot in
            self?.onEvent?(
                .queueChanged(
                    queuedBuffers: snapshot.queuedBuffers,
                    queuedDurationSeconds: snapshot.queuedDurationSeconds
                )
            )
        }

        playback.onSessionEvent = { [weak self] event in
            self?.onAudioSessionEvent?(event)
        }
    }

    /// Only replace engines while playback is stopped. Never retain the old
    /// model alongside the new one on memory-constrained devices.
    func selectEngine(_ kind: SpeechEngineKind) async {
        guard engineKind != kind else { return }
        let activeTask = readingTask
        stop()
        // Cancellation must complete before unloading the old inference
        // runtime, otherwise both models can briefly occupy RAM.
        _ = await activeTask?.result
        await engine.unload()
        engine = SpeechEngineFactory.make(kind)
        engineKind = kind
    }

    func read(
        text: String,
        voice: SpeechVoice = .heart,
        speed: Float = 1.0,
        continuous: Bool = false,
        onAudio:
            ((KokoroAudio) throws -> Void)? = nil
    ) async throws {
        resetActiveOperation(
            stopPlayback: !continuous
        )

        let chunks = scheduler.chunks(
            for: text,
            speed: speed
        )

        guard !chunks.isEmpty else {
            throw PipelineError.emptyText
        }

        let operationID = UUID()
        let readStart = ContinuousClock().now

        activeOperationID = operationID
        setState(.loading)

        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            try await self.run(
                chunks: chunks,
                voice: voice,
                speed: speed,
                readStart: readStart,
                operationID: operationID,
                stopPlaybackOnCompletion:
                    !continuous,
                onAudio: onAudio
            )
        }

        readingTask = task

        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard self?.activeOperationID == operationID else { return }
                    self?.stop()
                }
            }

            try requireActiveOperation(operationID)

            readingTask = nil
            activeOperationID = nil
            if !continuous {
                setState(.finished)
            }
        } catch is CancellationError {
            finishCancellation(operationID)
            throw PipelineError.cancelled
        } catch PipelineError.cancelled {
            finishCancellation(operationID)
            throw PipelineError.cancelled
        } catch SpeechEngineError.cancelled {
            finishCancellation(operationID)
            throw PipelineError.cancelled
        } catch {
            if activeOperationID == operationID {
                playback.stop()
                readingTask = nil
                activeOperationID = nil
                setState(.failed(Self.message(for: error)))
            }

            throw error
        }
    }

    func play(
        audio: KokoroAudio,
        continuous: Bool = false
    ) async throws {
        try ReadAloudSafety.validate(audio, maximumSamples: ReadAloudSafety.maximumParagraphSamples)
        try await playScheduled(continuous: continuous) {
            try self.playback.enqueue(audio)
        }
    }

    func playFile(at url: URL, startSeconds: Double, continuous: Bool = false) async throws {
        try await playScheduled(continuous: continuous) {
            try self.playback.enqueueFile(at: url, startSeconds: startSeconds)
        }
    }

    private func playScheduled(continuous: Bool, schedule: () throws -> Void) async throws {
        resetActiveOperation(
            stopPlayback: !continuous
        )

        let operationID = UUID()
        activeOperationID = operationID
        setState(.loading)

        do {
            try playback.prepare()
            try requireActiveOperation(
                operationID
            )
            playbackPositionOriginSeconds =
                playback.playedSeconds
            try schedule()
            setState(
                isPaused
                    ? .paused
                    : .playing
            )

            await withTaskCancellationHandler {
                await playback
                    .waitUntilDrained()
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard self?.activeOperationID == operationID else { return }
                    self?.stop()
                }
            }

            try requireActiveOperation(
                operationID
            )
            activeOperationID = nil

            if !continuous {
                playback.stop()
                setState(.finished)
            }
        } catch is CancellationError {
            finishCancellation(
                operationID
            )
            throw PipelineError.cancelled
        } catch PipelineError.cancelled {
            finishCancellation(
                operationID
            )
            throw PipelineError.cancelled
        } catch {
            if activeOperationID
                == operationID {
                playback.stop()
                activeOperationID = nil
                setState(
                    .failed(
                        Self.message(
                            for: error
                        )
                    )
                )
            }
            throw error
        }
    }

    func warmUp(
        voice: SpeechVoice = .heart,
        speed: Float = 1.0
    ) async throws -> Double {
        resetActiveOperation()

        let operationID = UUID()
        activeOperationID = operationID
        setState(.loading)

        let clock = ContinuousClock()
        let loadStart = clock.now

        do {
            try requireActiveOperation(operationID)
            try await engine.load()
            try requireActiveOperation(operationID)

            onEvent?(
                .modelLoaded(
                    seconds: Self.seconds(loadStart.duration(to: clock.now))
                )
            )

            setState(.warmingUp)

            let result = try await engine.warmUp(
                text: "Hello world.",
                voice: voice,
                speed: speed
            )

            try requireActiveOperation(operationID)

            onEvent?(.warmUpFinished(seconds: result.elapsedSeconds))
            activeOperationID = nil
            setState(.idle)
            return result.elapsedSeconds
        } catch is CancellationError {
            finishCancellation(operationID)
            throw PipelineError.cancelled
        } catch PipelineError.cancelled {
            finishCancellation(operationID)
            throw PipelineError.cancelled
        } catch SpeechEngineError.cancelled {
            finishCancellation(operationID)
            throw PipelineError.cancelled
        } catch {
            if activeOperationID == operationID {
                activeOperationID = nil
                setState(.failed(Self.message(for: error)))
            }

            throw error
        }
    }

    func finishContinuousPlayback() {
        activeOperationID = nil
        readingTask?.cancel()
        readingTask = nil
        isPaused = false
        playback.stop()
        playbackPositionOriginSeconds = 0
        setState(.finished)
    }

    func pause() {
        guard !isPaused else { return }
        isPaused = true
        playback.pause()
        setState(.paused)
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        do {
            try playback.resume()
            setState(playback.snapshot.queuedBuffers > 0 ? .playing : .loading)
        } catch {
            resetActiveOperation()
            setState(.failed(Self.message(for: error)))
        }
    }

    func shutdown() {
        onEvent = nil
        onAudioSessionEvent = nil
        readingTask?.cancel()
        readingTask = nil
        activeOperationID = nil
        isPaused = false
        playbackPositionOriginSeconds = 0
        playback.shutdown()
        state = .idle
    }

    func stop() {
        resetActiveOperation()
        setState(.idle)
        onEvent?(.stopped)
    }

    func unload() async {
        stop()
        await engine.unload()
    }

    private func run(
        chunks: [SpeechChunk],
        voice: SpeechVoice,
        speed: Float,
        readStart: ContinuousClock.Instant,
        operationID: UUID,
        stopPlaybackOnCompletion: Bool,
        onAudio:
            ((KokoroAudio) throws -> Void)?
    ) async throws {
        try requireActiveOperation(operationID)

        let clock = ContinuousClock()
        let loadStart = clock.now

        try await engine.load()
        try requireActiveOperation(operationID)

        onEvent?(
            .modelLoaded(
                seconds: Self.seconds(loadStart.duration(to: clock.now))
            )
        )

        try playback.prepare()

        for (offset, chunk) in chunks.enumerated() {
            try requireActiveOperation(operationID)

            await playback.waitUntilQueueDepthBelow(
                maxQueuedBuffers
            )

            try requireActiveOperation(operationID)

            let chunkNumber = offset + 1

            setState(
                isPaused
                    ? .paused
                    : .synthesizing(
                        current: chunkNumber,
                        total: chunks.count
                    )
            )

            onEvent?(
                .chunkStarted(
                    index: chunkNumber,
                    total: chunks.count,
                    bucketSeconds: chunk.targetBucketSeconds
                )
            )

            let result = try await engine.synthesize(
                text: chunk.text,
                voice: voice,
                speed: speed,
                maxChunkSeconds: chunk.maxChunkSeconds
            )

            try requireActiveOperation(operationID)

            try onAudio?(result.audio)

            let underrun = offset > 0 && playback.snapshot.queuedBuffers == 0

            try playback.enqueue(result.audio)

            let firstAudioLatency = offset == 0
                ? Self.seconds(readStart.duration(to: clock.now))
                : nil

            onEvent?(
                .chunkReady(
                    index: chunkNumber,
                    total: chunks.count,
                    bucketSeconds: chunk.targetBucketSeconds,
                    synthesisSeconds: result.elapsedSeconds,
                    audioDurationSeconds: result.durationSeconds,
                    realTimeFactor: result.realTimeFactor,
                    firstAudioLatencySeconds: firstAudioLatency,
                    underrun: underrun
                )
            )

            if offset == 0 {
                setState(isPaused ? .paused : .playing)
            }
        }

        setState(isPaused ? .paused : .playing)
        await playback.waitUntilDrained()
        try requireActiveOperation(operationID)

        if stopPlaybackOnCompletion {
            playback.stop()
        }
    }

    private func resetActiveOperation(
        stopPlayback: Bool = true
    ) {
        activeOperationID = nil
        if stopPlayback {
            isPaused = false
            playbackPositionOriginSeconds = 0
        }

        readingTask?.cancel()
        readingTask = nil

        if stopPlayback {
            playback.stop()
        }
    }

    private func finishCancellation(_ operationID: UUID) {
        guard activeOperationID == operationID else {
            return
        }

        playback.stop()
        readingTask = nil
        activeOperationID = nil
        setState(.idle)
    }

    private func requireActiveOperation(_ operationID: UUID) throws {
        try Task.checkCancellation()

        guard activeOperationID == operationID else {
            throw PipelineError.cancelled
        }
    }

    private func setState(_ newState: State) {
        state = newState
        onEvent?(.state(newState))
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }

        return String(describing: error)
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

