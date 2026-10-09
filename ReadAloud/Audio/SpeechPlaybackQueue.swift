import AVFoundation
import Foundation

@MainActor
final class SpeechPlaybackQueue {
    enum SessionEvent: Equatable, Sendable {
        case interruptionBegan
        case interruptionEnded(
            shouldResume: Bool
        )
        case routeBecameUnavailable
        case mediaServicesWereReset
    }

    struct Snapshot: Equatable, Sendable {
        let queuedBuffers: Int
        let queuedDurationSeconds: Double
        let isPlaying: Bool
    }

    enum PlaybackError: LocalizedError {
        case invalidBuffer
        case inconsistentFormat

        var errorDescription: String? {
            switch self {
            case .invalidBuffer:
                return "Kokoro produced an invalid PCM buffer."
            case .inconsistentFormat:
                return "Kokoro produced PCM with an unexpected playback format."
            }
        }
    }

    private struct DepthWaiter {
        let limit: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var audioEngine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()

    private var pendingDurations: [UUID: Double] = [:]
    private var pendingFiles: [UUID: AVAudioFile] = [:]
    private var depthWaiters: [DepthWaiter] = []
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var generation = 0
    private var queuedDurationSeconds = 0.0
    private var connectedSampleRate: Double?
    private var connectedChannelCount: AVAudioChannelCount?
    private var isPaused = false
    private var notificationObservers:
        [NSObjectProtocol] = []

    var onSnapshotChange: ((Snapshot) -> Void)?
    var onSessionEvent:
        ((SessionEvent) -> Void)?

    init() {
        audioEngine.attach(playerNode)
        installAudioSessionObservers()
    }

    var playedSeconds: Double {
        guard let nodeTime =
                playerNode.lastRenderTime,
              let playerTime =
                playerNode.playerTime(
                    forNodeTime: nodeTime
                ),
              playerTime.sampleRate > 0
        else {
            return 0
        }

        return max(
            0,
            Double(playerTime.sampleTime)
                / playerTime.sampleRate
        )
    }

    var snapshot: Snapshot {
        Snapshot(
            queuedBuffers: pendingDurations.count,
            queuedDurationSeconds: queuedDurationSeconds,
            isPlaying: playerNode.isPlaying && !pendingDurations.isEmpty
        )
    }

    func prepare() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playback,
            mode: .spokenAudio,
            options: []
        )
        try session.setActive(true)
        #endif
    }

    func enqueue(_ audio: KokoroAudio) throws {
        try ReadAloudSafety.validate(audio, maximumSamples: ReadAloudSafety.maximumParagraphSamples)
        let buffer = try audio.makePCMBuffer()
        try ensureEngineReady(for: buffer.format)

        let itemID = UUID()
        let itemGeneration = generation

        pendingDurations[itemID] = audio.durationSeconds
        queuedDurationSeconds += audio.durationSeconds

        playerNode.scheduleBuffer(
            buffer,
            completionCallbackType: .dataPlayedBack,
            completionHandler: Self.makeCompletionHandler(
                queue: self, itemID: itemID, generation: itemGeneration
            )
        )

        if !isPaused && !playerNode.isPlaying {
            playerNode.play()
        }

        notifySnapshotChange()
    }

    func enqueueFile(at url: URL, startSeconds: Double) throws {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        guard startSeconds.isFinite, startSeconds >= 0,
              rate == Double(ProjectWAVCodec.requiredSampleRate),
              file.processingFormat.channelCount == 1,
              file.length > 0,
              file.length <= AVAudioFramePosition(UInt32.max) else {
            throw PlaybackError.invalidBuffer
        }
        let framePosition = min(Double(file.length), startSeconds * rate)
        guard framePosition.isFinite, framePosition < Double(file.length) else {
            throw PlaybackError.invalidBuffer
        }
        let start = AVAudioFramePosition(framePosition.rounded(.down))
        let remaining = file.length - start
        guard remaining > 0, remaining <= AVAudioFramePosition(UInt32.max) else {
            throw PlaybackError.invalidBuffer
        }
        try ensureEngineReady(for: file.processingFormat)
        let itemID = UUID()
        let itemGeneration = generation
        let duration = Double(remaining) / rate
        pendingFiles[itemID] = file
        pendingDurations[itemID] = duration
        queuedDurationSeconds += duration
        playerNode.scheduleSegment(
            file, startingFrame: start, frameCount: AVAudioFrameCount(remaining),
            at: nil, completionCallbackType: .dataPlayedBack,
            completionHandler: Self.makeCompletionHandler(
                queue: self, itemID: itemID, generation: itemGeneration
            )
        )
        if !isPaused && !playerNode.isPlaying { playerNode.play() }
        notifySnapshotChange()
    }

    func waitUntilQueueDepthBelow(_ limit: Int) async {
        guard pendingDurations.count >= limit else {
            return
        }

        await withCheckedContinuation { continuation in
            depthWaiters.append(
                DepthWaiter(
                    limit: limit,
                    continuation: continuation
                )
            )
        }
    }

    // AVAudioPlayerNode invokes completions on its own queue, not MainActor.
    // Hop only after entering a nonisolated callback; retain generation checks
    // in didFinish so stopped/replaced playback cannot consume current buffers.
    private nonisolated static func makeCompletionHandler(
        queue: SpeechPlaybackQueue, itemID: UUID, generation: Int
    ) -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        { [weak queue] _ in
            Task { @MainActor [weak queue] in
                queue?.didFinish(itemID: itemID, generation: generation)
            }
        }
    }

    func waitUntilDrained() async {
        guard !pendingDurations.isEmpty else {
            return
        }

        await withCheckedContinuation { continuation in
            drainWaiters.append(continuation)
        }
    }

    func pause() {
        guard !isPaused else { return }
        isPaused = true
        if playerNode.isPlaying {
            playerNode.pause()
        }
        notifySnapshotChange()
    }

    func resume() throws {
        guard isPaused else { return }

        #if os(iOS)
        try AVAudioSession.sharedInstance().setActive(true)
        #endif

        if !pendingDurations.isEmpty && !audioEngine.isRunning {
            try audioEngine.start()
        }
        isPaused = false
        if !pendingDurations.isEmpty
            && !playerNode.isPlaying
        {
            playerNode.play()
        }
        notifySnapshotChange()
    }

    func stop() {
        generation += 1
        isPaused = false
        playerNode.stop()

        pendingDurations.removeAll()
        pendingFiles.removeAll()
        queuedDurationSeconds = 0

        resumeDepthWaiters()
        resumeDrainWaiters()

        if audioEngine.isRunning {
            audioEngine.stop()
        }

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        #endif

        notifySnapshotChange()
    }

    func shutdown() {
        stop()

        for observer in notificationObservers {
            NotificationCenter.default
                .removeObserver(observer)
        }
        notificationObservers.removeAll()
        onSnapshotChange = nil
        onSessionEvent = nil
    }

    private func installAudioSessionObservers() {
        #if os(iOS)
        let center = NotificationCenter.default

        notificationObservers.append(
            center.addObserver(
                forName:
                    AVAudioSession
                        .interruptionNotification,
                object:
                    AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                let rawType =
                    notification.userInfo?[
                        AVAudioSessionInterruptionTypeKey
                    ] as? UInt
                let rawOptions =
                    notification.userInfo?[
                        AVAudioSessionInterruptionOptionKey
                    ] as? UInt
                    ?? 0

                Task { @MainActor [weak self] in
                    self?.handleInterruption(
                        rawType: rawType,
                        rawOptions:
                            rawOptions
                    )
                }
            }
        )

        notificationObservers.append(
            center.addObserver(
                forName:
                    AVAudioSession
                        .routeChangeNotification,
                object:
                    AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                let rawReason =
                    notification.userInfo?[
                        AVAudioSessionRouteChangeReasonKey
                    ] as? UInt

                Task { @MainActor [weak self] in
                    self?.handleRouteChange(
                        rawReason:
                            rawReason
                    )
                }
            }
        )

        notificationObservers.append(
            center.addObserver(
                forName:
                    AVAudioSession
                        .mediaServicesWereResetNotification,
                object:
                    AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleMediaServicesReset()
                }
            }
        )
        #endif
    }

    private func handleMediaServicesReset() {
        generation += 1
        playerNode.stop()

        pendingDurations.removeAll()
        pendingFiles.removeAll()
        queuedDurationSeconds = 0
        resumeDepthWaiters()
        resumeDrainWaiters()

        if audioEngine.isRunning {
            audioEngine.stop()
        }

        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        audioEngine.attach(playerNode)
        connectedSampleRate = nil
        connectedChannelCount = nil
        isPaused = false

        notifySnapshotChange()
        onSessionEvent?(
            .mediaServicesWereReset
        )
    }

    #if os(iOS)
    private func handleInterruption(
        rawType: UInt?,
        rawOptions: UInt
    ) {
        guard let rawType,
              let type =
                AVAudioSession
                    .InterruptionType(
                        rawValue: rawType
                    )
        else {
            return
        }

        switch type {
        case .began:
            onSessionEvent?(
                .interruptionBegan
            )

        case .ended:
            let options =
                AVAudioSession
                    .InterruptionOptions(
                        rawValue: rawOptions
                    )
            onSessionEvent?(
                .interruptionEnded(
                    shouldResume:
                        options.contains(
                            .shouldResume
                        )
                )
            )

        @unknown default:
            break
        }
    }

    private func handleRouteChange(
        rawReason: UInt?
    ) {
        guard let rawReason,
              let reason =
                AVAudioSession
                    .RouteChangeReason(
                        rawValue: rawReason
                    )
        else {
            return
        }

        if reason == .oldDeviceUnavailable {
            onSessionEvent?(
                .routeBecameUnavailable
            )
        }
    }
    #endif

    private func ensureEngineReady(for format: AVAudioFormat) throws {
        if let connectedSampleRate,
           let connectedChannelCount
        {
            guard connectedSampleRate == format.sampleRate,
                  connectedChannelCount == format.channelCount
            else {
                throw PlaybackError.inconsistentFormat
            }
        } else {
            audioEngine.connect(
                playerNode,
                to: audioEngine.mainMixerNode,
                format: format
            )
            connectedSampleRate = format.sampleRate
            connectedChannelCount = format.channelCount
        }

        guard !audioEngine.isRunning else {
            return
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func didFinish(
        itemID: UUID,
        generation itemGeneration: Int
    ) {
        guard itemGeneration == generation,
              let duration = pendingDurations.removeValue(forKey: itemID)
        else {
            return
        }

        pendingFiles.removeValue(forKey: itemID)
        queuedDurationSeconds = max(
            0,
            queuedDurationSeconds - duration
        )

        notifySnapshotChange()
        resumeDepthWaiters()

        if pendingDurations.isEmpty {
            resumeDrainWaiters()
        }
    }

    private func notifySnapshotChange() {
        onSnapshotChange?(snapshot)
    }

    private func resumeDepthWaiters() {
        guard !depthWaiters.isEmpty else {
            return
        }

        var remaining: [DepthWaiter] = []

        for waiter in depthWaiters {
            if pendingDurations.count < waiter.limit {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }

        depthWaiters = remaining
    }

    private func resumeDrainWaiters() {
        let waiters = drainWaiters
        drainWaiters.removeAll()

        for waiter in waiters {
            waiter.resume()
        }
    }
}

