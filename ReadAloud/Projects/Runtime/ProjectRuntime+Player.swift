import Foundation

/// Normalized chapter positions that have finished, reusable audio.
nonisolated struct PlayerBufferedRange: Equatable, Sendable {
    let start: Double
    let end: Double
}

/// Shared presentation rules keep hero controls tied to the playback owner.
nonisolated struct ListeningHeroPresentation {
    enum Action: Equatable { case start, continueListening, pause, resume, cancel, retry }
    let action: Action
    let heading: String
    let error: String?

    init(state: ProjectRuntimePlaybackState?, active: Bool, paused: Bool,
         preparing: Bool, hasHistory: Bool) {
        heading = active && !paused ? "NOW LISTENING" : ((active || hasHistory) ? "CONTINUE LISTENING" : "READY TO LISTEN")
        if case .failed(let message)? = state {
            error = message.localizedCaseInsensitiveContains("memory")
                ? "Audio stopped because the device is low on memory. Try again when memory is available."
                : "Audio couldn’t play. Try again."
            action = .retry
        } else {
            error = nil
            if preparing { action = .cancel }
            else if active { action = paused ? .resume : .pause }
            else { action = hasHistory ? .continueListening : .start }
        }
    }

    var label: String {
        switch action {
        case .start: "Start Listening"
        case .continueListening: "Continue Listening"
        case .pause: "Pause"
        case .resume: "Resume"
        case .cancel: "Cancel"
        case .retry: "Try Again"
        }
    }

    var symbol: String {
        switch action {
        case .pause: "pause.fill"
        case .cancel: "xmark"
        case .retry: "arrow.clockwise"
        default: "play.fill"
        }
    }
}

@MainActor
extension ProjectRuntime {
    func clearSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerDeadline = nil
        stopsAtChapterEnd = false
    }

    func setSleepTimer(minutes: Int) {
        guard [5, 15, 30, 45, 60].contains(minutes) else { return }
        clearSleepTimer()
        let deadline = Date.now.addingTimeInterval(Double(minutes * 60))
        sleepTimerDeadline = deadline
        sleepTimerTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(minutes * 60)) }
            catch { return }
            guard let self, !Task.isCancelled, self.sleepTimerDeadline == deadline else { return }
            self.pausePlayback()
            self.clearSleepTimer()
        }
    }

    func stopAtChapterEnd() {
        clearSleepTimer()
        stopsAtChapterEnd = true
    }

    func changePlayerChapter(to itemID: UUID) throws {
        let wasPaused = isPlaybackPaused
        try play(itemID: itemID, fromOffsetUTF16: 0)
        if wasPaused { pausePlayback() }
    }

    func playerControlItemID(fallback: UUID? = nil) -> UUID? {
        activity.activeItemID ?? playerItemID ?? fallback
    }

    var isPlayerPreparing: Bool {
        guard !isPlaybackPaused else { return false }
        if activity.playbackState == .buffering { return true }
        guard activity.queuedAudioBuffers == 0 else { return false }
        switch activity.playbackState {
        case .loading, .buffering, .warmingUp, .synthesizing, .playing: return true
        default: return false
        }
    }

    var isPlaybackAudible: Bool {
        !isPlaybackPaused && activity.hasAudiblePlayback
    }

    var canSkipPlayback: Bool {
        isPlaybackActive && !isPlayerPreparing
            && (finalAudioAsset != nil || activity.currentChunkRange != nil)
    }

    func playerDuration(for itemID: UUID) -> Double? {
        guard isPlaybackActive, activity.activeItemID == itemID,
              let asset = finalAudioAsset, asset.metadata.itemID == itemID,
              asset.metadata.durationSeconds.isFinite,
              asset.metadata.durationSeconds > 0 else { return nil }
        return asset.metadata.durationSeconds
    }

    func playerProgress(for itemID: UUID) -> Double {
        if let duration = playerDuration(for: itemID) {
            return min(1, max(0, currentFinalAudioPositionSeconds / duration))
        }
        if activity.activeItemID == itemID {
            return min(1, max(0, activity.itemProgress))
        }
        guard let state = itemState(itemID),
              let playback = project?.playback,
              playback.currentItemID == itemID,
              let bookmark = playback.contentBookmark,
              bookmark.contentRevision == state.item.contentRevision else { return 0 }
        return min(1, max(0, Double(bookmark.textOffsetUTF16)
            / Double(max(1, playerTextLength(for: state.item)))))
    }

    /// One identity shared by compact and expanded views. A narration or
    /// pronunciation change invalidates previously generated chunk keys.
    func playerBufferIdentity(for itemID: UUID) -> String {
        "\(id.uuidString)/\(itemID.uuidString)/"
            + (itemState(itemID)?.generationKey ?? "unloaded")
    }

    /// The live scrubber is on a source-text axis, not a guessed audio-time
    /// axis. Each finished chunk occupies exactly its original UTF-16 range.
    /// A validated fully generated chapter fills the entire track instead.
    func playerBufferedRanges(for itemID: UUID) async -> [PlayerBufferedRange] {
        guard let state = itemState(itemID) else { return [] }
        let key = state.generationKey
        if let asset = finalAudioAsset,
           asset.metadata.itemID == itemID,
           asset.metadata.generationKey == key {
            return [PlayerBufferedRange(start: 0, end: 1)]
        }
        // .readyOffline is issued only for matching, checksum-validated final
        // audio in ProjectStore's generation status reconciliation.
        if state.generationStatus.state == .readyOffline {
            return [PlayerBufferedRange(start: 0, end: 1)]
        }

        let length = playerTextLength(for: state.item)
        guard length > 0,
              let runtimeRevision = try? ReadAloudSynthesisContract.runtimeRevision()
        else { return [] }
        let chunks = SpeechChunkScheduler().chunks(
            for: state.item.text, speed: Float(state.resolved.speed)
        )
        guard !chunks.isEmpty else { return [] }
        let requests = chunks.enumerated().map { index, chunk in
            ChunkAudioRequest(
                itemID: itemID, index: index, chunk: chunk,
                generationKey: key, resolved: state.resolved,
                runtimeRevision: runtimeRevision,
                synthesisConfigVersion: ReadAloudNarrationCatalog.synthesisConfigVersion
            )
        }
        let ready = await chunkCache.cachedSourceRanges(for: requests)
        // Settings may refresh the runtime while the cache actor is queried.
        guard !Task.isCancelled,
              itemState(itemID)?.generationKey == key else { return [] }

        var ranges: [PlayerBufferedRange] = []
        ranges.reserveCapacity(ready.count)
        for source in ready.sorted(by: { $0.startUTF16 < $1.startUTF16 }) {
            let start = min(1, max(0, Double(source.startUTF16) / Double(length)))
            let end = min(1, max(0, Double(source.endUTF16) / Double(length)))
            guard end > start else { continue }
            if let last = ranges.last, start <= last.end {
                ranges[ranges.count - 1] = PlayerBufferedRange(
                    start: last.start, end: max(last.end, end)
                )
            } else {
                ranges.append(PlayerBufferedRange(start: start, end: end))
            }
        }
        return ranges
    }

    var playerStatus: String {
        switch activity.playbackState {
        case .idle: return "Ready to listen"
        case .loading, .warmingUp: return "Preparing audio…"
        case .buffering: return "Preparing audio…"
        case .synthesizing: return isPlayerPreparing ? "Preparing audio…" : "Playing"
        case .playing: return isPlayerPreparing ? "Preparing audio…" : "Playing"
        case .paused: return "Paused"
        case .finished: return "Chapter finished"
        case .failed(let message): return message
        }
    }

    var playerActionLabel: String {
        if isPlaybackActive { return isPlaybackPaused ? "Resume" : "Pause" }
        switch activity.playbackState {
        case .failed: return "Retry"
        case .finished: return "Replay chapter"
        default: return "Listen"
        }
    }

    func togglePlayer(itemID: UUID) throws {
        if isPlaybackActive, activity.activeItemID == itemID {
            if isPlaybackPaused { resumePlayback() } else { pausePlayback() }
        } else if case .finished = activity.playbackState, playerItemID == itemID {
            try play(itemID: itemID, fromOffsetUTF16: 0)
        } else {
            try play(itemID: itemID)
        }
    }

    func adjacentPlayerItem(to itemID: UUID, delta: Int) -> UUID? {
        guard let index = itemStates.firstIndex(where: { $0.id == itemID }) else { return nil }
        let target = index + delta
        guard itemStates.indices.contains(target) else { return nil }
        return itemStates[target].id
    }

    // Saved audio seeks in seconds. Live speech seeks to a source passage;
    // its duration is unknown until synthesis completes.
    func seekPlayer(toProgress progress: Double, itemID: UUID) throws {
        guard progress.isFinite, let state = itemState(itemID) else { return }
        try prepareExplicitWork()
        let fraction = min(1, max(0, progress))
        if let duration = playerDuration(for: itemID) {
            try seekPlayback(to: fraction * duration)
            return
        }
        let chunks = SpeechChunkScheduler().chunks(
            for: state.item.text, speed: Float(state.resolved.speed)
        )
        guard !chunks.isEmpty else { return }
        let offset = Int(fraction * Double(playerTextLength(for: state.item)))
        let index = chunks.firstIndex(where: {
            offset < $0.sourceRange.endUTF16
        }) ?? (chunks.count - 1)
        let wasPaused = isPlaybackActive && isPlaybackPaused
        try play(itemID: itemID, fromOffsetUTF16: chunks[index].sourceRange.startUTF16)
        if wasPaused { pausePlayback() }
    }
}

