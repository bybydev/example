import Foundation

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
        guard !isPlaybackPaused, activity.queuedAudioBuffers == 0 else { return false }
        switch activity.playbackState {
        case .loading, .warmingUp, .synthesizing, .playing: return true
        default: return false
        }
    }

    var canSkipPlayback: Bool {
        isPlaybackActive && !isPlayerPreparing
            && (finalAudioAsset != nil || activity.currentParagraphRange != nil)
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

    var playerStatus: String {
        switch activity.playbackState {
        case .idle: return "Ready to listen"
        case .loading, .warmingUp: return "Preparing audio…"
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
        let paragraphs = cachedReaderParagraphs(for: state.item)
        guard !paragraphs.isEmpty else { return }
        let offset = Int(fraction * Double(playerTextLength(for: state.item)))
        let index = ReaderTextLayout.paragraphIndex(forUTF16Offset: offset, in: paragraphs)
        let wasPaused = isPlaybackActive && isPlaybackPaused
        try play(itemID: itemID, fromOffsetUTF16: paragraphs[index].sourceRange.startUTF16)
        if wasPaused { pausePlayback() }
    }
}
