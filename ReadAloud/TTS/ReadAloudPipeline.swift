import Foundation
import OSLog

/// Audio hardware is replaceable in continuity tests; production still uses
/// the same AVAudioEngine/player-node implementation and buffer limits.
@MainActor
protocol SpeechPlaybackOutput: AnyObject {
    var onSnapshotChange: ((SpeechPlaybackQueue.Snapshot) -> Void)? { get set }
    var onSessionEvent: ((SpeechPlaybackQueue.SessionEvent) -> Void)? { get set }
    var snapshot: SpeechPlaybackQueue.Snapshot { get }
    var playedSeconds: Double { get }
    func prepare() throws
    func enqueue(_ audio: KokoroAudio, onPlaybackStart: (@MainActor () -> Void)?) throws
    func enqueueFile(at url: URL, startSeconds: Double) throws
    func waitUntilQueueDepthBelow(_ limit: Int) async
    func waitUntilDrained() async
    func pause()
    func resume() throws
    func stop()
    func shutdown()
}

nonisolated enum SpeechPlaybackDiagnostic: Equatable, Sendable {
    nonisolated enum EndReason: String, Sendable { case resumed, paused, drained, stopped, failed }
    case starvationStarted
    case starvationEnded(seconds: Double, reason: EndReason)
}

/// Classify queue snapshots independently from synthesis progress. In
/// particular, the expected final drain and a user pause are not underruns.
nonisolated struct SpeechStreamContinuity {
    nonisolated enum Phase: Equatable, Sendable { case loading, playing, buffering, paused, drained }
    nonisolated struct Update: Sendable {
        let phase: Phase
        let diagnostic: SpeechPlaybackDiagnostic?
    }

    private var hasPlayed = false
    private var starvationStart: TimeInterval?

    mutating func update(
        queuedBuffers: Int, outputIsPlaying: Bool,
        expectingMore: Bool, paused: Bool, now: TimeInterval
    ) -> Update {
        let phase: Phase
        if paused {
            phase = .paused
        } else if queuedBuffers > 0, outputIsPlaying {
            phase = .playing
            hasPlayed = true
        } else if queuedBuffers > 0 || expectingMore {
            phase = hasPlayed ? .buffering : .loading
        } else {
            phase = .drained
        }
        var diagnostic: SpeechPlaybackDiagnostic?
        if phase == .buffering {
            if starvationStart == nil {
                starvationStart = now
                diagnostic = .starvationStarted
            }
        } else {
            let reason: SpeechPlaybackDiagnostic.EndReason = phase == .playing
                ? .resumed : (phase == .paused ? .paused : .drained)
            diagnostic = endStarvation(at: now, reason: reason)
        }
        return Update(phase: phase, diagnostic: diagnostic)
    }

    mutating func endStarvation(
        at now: TimeInterval, reason: SpeechPlaybackDiagnostic.EndReason
    ) -> SpeechPlaybackDiagnostic? {
        guard let start = starvationStart else { return nil }
        starvationStart = nil
        return .starvationEnded(seconds: max(0, now - start), reason: reason)
    }
}

@MainActor
enum SpeechPlaybackDiagnostics {
    // Local metadata only: never send text, project identity or these events
    // through analytics. No service connection or telemetry is introduced.
    private static let logger = Logger(subsystem: "com.hoangbkit.readaloud", category: "Playback")

    static func record(_ event: SpeechPlaybackDiagnostic) {
        switch event {
        case .starvationStarted:
            logger.debug("Live audio starved; waiting for a chunk")
        case .starvationEnded(let seconds, let reason):
            logger.debug("Live audio wait ended: \(reason.rawValue, privacy: .public), seconds: \(seconds, privacy: .public)")
        }
    }

    static func chapterStarted(finalized: Bool) {
        logger.debug("Chapter preparation began; finalized audio: \(finalized, privacy: .public)")
    }

    static func firstAudio(after seconds: Double) {
        logger.debug("Time to first audible chunk, seconds: \(seconds, privacy: .public)")
    }

    static func applicationState(_ state: String) {
        logger.debug("Application state: \(state, privacy: .public)")
    }
}

@MainActor
final class ReadAloudPipeline {
    enum State: Equatable, Sendable {
        case idle
        case loading
        case warmingUp
        case synthesizing(current: Int, total: Int)
        case buffering
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
    private let playback: any SpeechPlaybackOutput
    private let scheduler: SpeechChunkScheduler
    private let maxQueuedBuffers = 2

    private var readingTask: Task<Void, Error>?
    private var activeOperationID: UUID?
    private var isPaused = false
    private var playbackPositionOriginSeconds = 0.0
    private var streamContinuity: SpeechStreamContinuity?
    private var streamExpectsMore = false
    private var streamStartedAt: TimeInterval?
    private let now: @MainActor () -> TimeInterval

    private(set) var state: State = .idle
    var onEvent: ((Event) -> Void)?
    var onDiagnostic: ((SpeechPlaybackDiagnostic) -> Void)?
    var onAudioSessionEvent:
        ((SpeechPlaybackQueue.SessionEvent) -> Void)?

    var playbackPositionSeconds: Double {
        max(
            0,
            playback.playedSeconds
                - playbackPositionOriginSeconds
        )
    }

    init(
        playback: (any SpeechPlaybackOutput)? = nil,
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        let playback = playback ?? SpeechPlaybackQueue()

        let kind = ReadAloudPreferences.speechEngine
        self.engineKind = kind
        self.engine = SpeechEngineFactory.make(kind)
        self.playback = playback
        self.scheduler = SpeechChunkScheduler()
        self.now = now

        playback.onSnapshotChange = { [weak self] snapshot in
            self?.onEvent?(
                .queueChanged(
                    queuedBuffers: snapshot.queuedBuffers,
                    queuedDurationSeconds: snapshot.queuedDurationSeconds
                )
            )
            self?.updateStreamState(snapshot)
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

    /// Playback consumes already-synthesized shared-cache chunks. Synthesis
    /// runs independently with disk-backed read-ahead; the player still
    /// schedules only two decoded buffers at a time.
    func playChunkStream(
        count: Int,
        continuous: Bool = true,
        loadAudio: @escaping @MainActor (Int) async throws -> KokoroAudio,
        onChunkStarted: @escaping @MainActor (Int) -> Void
    ) async throws {
        guard count > 0 else { throw PipelineError.emptyText }
        resetActiveOperation(stopPlayback: !continuous)
        let operationID = UUID()
        activeOperationID = operationID
        streamContinuity = SpeechStreamContinuity()
        streamExpectsMore = true
        streamStartedAt = now()
        setState(isPaused ? .paused : .loading)
        do {
            try playback.prepare()
            try await withTaskCancellationHandler {
                for index in 0..<count {
                    try requireActiveOperation(operationID)
                    await playback.waitUntilQueueDepthBelow(maxQueuedBuffers)
                    try requireActiveOperation(operationID)
                    let audio = try await loadAudio(index)
                    try requireActiveOperation(operationID)
                    try ReadAloudSafety.validate(
                        audio, maximumSamples: ReadAloudSafety.maximumBufferSamples
                    )
                    // Set this before enqueue's synchronous snapshot callback.
                    // A last-buffer completion is expected, not starvation.
                    streamExpectsMore = index + 1 < count
                    try playback.enqueue(audio, onPlaybackStart: { [weak self] in
                        guard self?.activeOperationID == operationID else { return }
                        onChunkStarted(index)
                    })
                }
                await playback.waitUntilDrained()
                try requireActiveOperation(operationID)
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard self?.activeOperationID == operationID else { return }
                    self?.stop()
                }
            }
            endStream(reason: .drained)
            activeOperationID = nil
            if !continuous {
                playback.stop()
                setState(.finished)
            } else {
                setState(isPaused ? .paused : .loading)
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
                endStream(reason: .failed)
                activeOperationID = nil
                playback.stop()
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
            try self.playback.enqueue(audio, onPlaybackStart: nil)
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
        endStream(reason: .drained)
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
            if streamContinuity != nil {
                updateStreamState(playback.snapshot)
            } else {
                setState(playback.snapshot.isPlaying ? .playing : .loading)
            }
        } catch {
            resetActiveOperation()
            setState(.failed(Self.message(for: error)))
        }
    }

    func shutdown() {
        endStream(reason: .stopped)
        onDiagnostic = nil
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

            try playback.enqueue(result.audio, onPlaybackStart: nil)

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
        endStream(reason: .stopped)
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

        endStream(reason: .stopped)
        activeOperationID = nil
        playback.stop()
        readingTask = nil
        setState(.idle)
    }

    private func requireActiveOperation(_ operationID: UUID) throws {
        try Task.checkCancellation()

        guard activeOperationID == operationID else {
            throw PipelineError.cancelled
        }
    }

    private func updateStreamState(_ snapshot: SpeechPlaybackQueue.Snapshot) {
        guard activeOperationID != nil, var continuity = streamContinuity else { return }
        let update = continuity.update(
            queuedBuffers: snapshot.queuedBuffers, outputIsPlaying: snapshot.isPlaying,
            expectingMore: streamExpectsMore, paused: isPaused, now: now()
        )
        streamContinuity = continuity
        if let diagnostic = update.diagnostic { record(diagnostic) }
        switch update.phase {
        case .loading, .drained: setState(.loading)
        case .buffering: setState(.buffering)
        case .playing:
            if let started = streamStartedAt {
                SpeechPlaybackDiagnostics.firstAudio(after: max(0, now() - started))
                streamStartedAt = nil
            }
            setState(.playing)
        case .paused: setState(.paused)
        }
    }

    private func endStream(reason: SpeechPlaybackDiagnostic.EndReason) {
        let diagnostic = streamContinuity?.endStarvation(at: now(), reason: reason)
        streamContinuity = nil
        streamExpectsMore = false
        streamStartedAt = nil
        if let diagnostic { record(diagnostic) }
    }

    private func record(_ event: SpeechPlaybackDiagnostic) {
        SpeechPlaybackDiagnostics.record(event)
        onDiagnostic?(event)
    }

    private func setState(_ newState: State) {
        guard state != newState else { return }
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


