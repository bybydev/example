import Foundation

@MainActor
extension ProjectRuntime {
    var isPlaybackActive: Bool {
        if playbackTask != nil {
            return true
        }

        switch activity.playbackState {
        case .loading, .warmingUp, .synthesizing, .playing, .paused:
            return true
        case .idle, .finished, .failed:
            return false
        }
    }

    var isPlaybackPaused: Bool {
        readerPauseRequested
            || activity.playbackState == .paused
    }

    func play(
        itemID: UUID,
        fromOffsetUTF16 explicitOffset: Int? = nil
    ) throws {
        guard let state = itemState(itemID) else {
            throw ProjectStoreError.invalidData(
                "Reader item is unavailable."
            )
        }

        let offset: Int
        if let explicitOffset {
            offset = explicitOffset
        } else if project?.playback?.currentItemID == itemID,
                  project?.playback?.contentBookmark?.contentRevision
                    == state.item.contentRevision {
            offset =
                project?.playback?.contentBookmark?.textOffsetUTF16
                ?? 0
        } else {
            offset = 0
        }

        startReaderPlayback(
            itemID: itemID,
            offsetUTF16: offset
        )
    }

    func pausePlayback() {
        guard isPlaybackActive,
              !readerPauseRequested
        else {
            return
        }

        readerPauseRequested = true
        pipeline.pause()
        activity.playbackState = .paused
    }

    func resumePlayback() {
        guard readerPauseRequested else {
            return
        }

        readerPauseRequested = false
        pipeline.resume()

        if playbackTask != nil {
            activity.playbackState = .playing
        }
    }

    func togglePlayback(
        itemID: UUID
    ) throws {
        if activity.activeItemID == itemID {
            switch activity.playbackState {
            case .paused:
                resumePlayback()
                return
            case .loading, .warmingUp, .synthesizing, .playing:
                pausePlayback()
                return
            case .idle, .finished, .failed:
                break
            }
        }

        try play(itemID: itemID)
    }

    func seekPlayback(
        by seconds: Double
    ) throws {
        guard seconds != 0,
              let currentItemID =
                activity.activeItemID,
              let currentRange =
                activity.currentParagraphRange
        else {
            return
        }

        let timeline = readerTimeline()
        guard !timeline.isEmpty,
              let currentIndex =
                timeline.firstIndex(where: {
                    $0.itemID == currentItemID
                        && $0.paragraph
                            .sourceRange
                            == currentRange
                })
        else {
            return
        }

        var remaining = abs(seconds)
        var targetIndex = currentIndex

        if seconds < 0 {
            while targetIndex > 0 {
                targetIndex -= 1
                remaining -=
                    timeline[targetIndex]
                        .durationSeconds
                if remaining <= 0 {
                    break
                }
            }
        } else {
            while targetIndex
                < timeline.count - 1 {
                targetIndex += 1
                remaining -=
                    timeline[targetIndex]
                        .durationSeconds
                if remaining <= 0 {
                    break
                }
            }
        }

        let target = timeline[targetIndex]
        let shouldRemainPaused =
            isPlaybackPaused

        try play(
            itemID: target.itemID,
            fromOffsetUTF16:
                target.paragraph
                    .sourceRange.startUTF16
        )

        if shouldRemainPaused {
            pausePlayback()
        }
    }

    func playNextItem(
        after itemID: UUID
    ) throws {
        guard let index = itemStates.firstIndex(where: {
            $0.id == itemID
        }) else {
            return
        }
        let nextIndex = index + 1
        guard itemStates.indices.contains(nextIndex) else {
            return
        }
        try play(
            itemID: itemStates[nextIndex].id,
            fromOffsetUTF16: 0
        )
    }

    func playPreviousItem(
        before itemID: UUID
    ) throws {
        guard let index = itemStates.firstIndex(where: {
            $0.id == itemID
        }) else {
            return
        }
        let previousIndex = index - 1
        guard itemStates.indices.contains(previousIndex) else {
            return
        }
        try play(
            itemID: itemStates[previousIndex].id,
            fromOffsetUTF16: 0
        )
    }

    func readerParagraphs(
        itemID: UUID
    ) -> [ReaderParagraph] {
        guard let state = itemState(itemID) else {
            return []
        }
        return ReaderTextLayout.paragraphs(
            in: state.item.text
        )
    }

    private func startReaderPlayback(
        itemID: UUID,
        offsetUTF16: Int
    ) {
        playbackOperationID = nil
        readerPauseRequested = false
        playbackTask?.cancel()
        playbackTask = nil
        pipeline.stop()

        let operationID = UUID()
        playbackOperationID = operationID
        activity.activeItemID = itemID

        playbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runReaderPlayback(
                initialItemID: itemID,
                initialOffsetUTF16: offsetUTF16,
                operationID: operationID
            )
        }
    }

    private func runReaderPlayback(
        initialItemID: UUID,
        initialOffsetUTF16: Int,
        operationID: UUID
    ) async {
        guard let initialIndex = itemStates.firstIndex(where: {
            $0.id == initialItemID
        }) else {
            activity.playbackState = .failed(
                "Reader item is unavailable."
            )
            return
        }

        do {
            for itemIndex in initialIndex..<itemStates.count {
                try requirePlaybackOperation(operationID)

                guard let state = itemState(
                    itemStates[itemIndex].id
                ) else {
                    continue
                }

                let paragraphs =
                    ReaderTextLayout.paragraphs(
                        in: state.item.text
                    )
                guard !paragraphs.isEmpty else {
                    continue
                }

                let startParagraphIndex =
                    itemIndex == initialIndex
                    ? ReaderTextLayout.paragraphIndex(
                        forUTF16Offset: initialOffsetUTF16,
                        in: paragraphs
                    )
                    : 0

                guard let voice = KokoroEngine.Voice.all.first(
                    where: { $0.id == state.resolved.voiceID }
                ) else {
                    throw KokoroEngine.EngineError.unsupportedVoice(
                        state.resolved.voiceID
                    )
                }

                for paragraphIndex
                    in startParagraphIndex..<paragraphs.count {
                    try requirePlaybackOperation(operationID)

                    let paragraph = paragraphs[paragraphIndex]
                    try await waitWhileReaderPaused(
                        operationID
                    )
                    try await publishReaderPosition(
                        itemState: state,
                        paragraph: paragraph,
                        paragraphIndex: paragraphIndex,
                        paragraphCount: paragraphs.count,
                        operationID: operationID
                    )

                    try requirePlaybackOperation(operationID)
                    try await waitWhileReaderPaused(
                        operationID
                    )

                    do {
                        try await pipeline.read(
                            text: paragraph.text,
                            voice: voice,
                            speed: Float(state.resolved.speed),
                            continuous: true
                        )
                    } catch ReadAloudPipeline.PipelineError.cancelled {
                        try requirePlaybackOperation(operationID)
                        throw CancellationError()
                    }
                }
            }

            try requirePlaybackOperation(operationID)
            pipeline.finishContinuousPlayback()
            activity.itemProgress = 1
            activity.projectProgress = 1
            if var playback = project?.playback {
                playback.projectProgress = 1
                playback.lastPlayedAt = .now
                try await persistence.updatePlayback(playback)
                try requirePlaybackOperation(operationID)
                project?.playback = playback
                revision &+= 1
            }
            playbackTask = nil
            playbackOperationID = nil
        } catch is CancellationError {
            if playbackOperationID == operationID {
                playbackTask = nil
                playbackOperationID = nil
            }
        } catch {
            guard playbackOperationID == operationID else {
                return
            }
            playbackTask = nil
            playbackOperationID = nil
            readerPauseRequested = false
            pipeline.stop()
            activity.playbackState = .failed(
                Self.message(for: error)
            )
        }
    }

    private func publishReaderPosition(
        itemState: ProjectRuntimeItemState,
        paragraph: ReaderParagraph,
        paragraphIndex: Int,
        paragraphCount: Int,
        operationID: UUID
    ) async throws {
        let itemLength = max(
            1,
            itemState.item.text.utf16.count
        )
        let itemProgress = min(
            1,
            max(
                0,
                Double(paragraph.sourceRange.startUTF16)
                    / Double(itemLength)
            )
        )
        let projectProgress = projectProgress(
            itemID: itemState.id,
            offsetUTF16:
                paragraph.sourceRange.startUTF16
        )

        let playback = ProjectPlaybackState(
            currentItemID: itemState.id,
            contentBookmark: ProjectContentBookmark(
                contentRevision:
                    itemState.item.contentRevision,
                textOffsetUTF16:
                    paragraph.sourceRange.startUTF16
            ),
            audioPosition: nil,
            projectProgress: projectProgress,
            lastPlayedAt: .now
        )

        try await persistence.updatePlayback(playback)
        try requirePlaybackOperation(operationID)

        project?.playback = playback
        activity.activeItemID = itemState.id
        activity.currentParagraphRange =
            paragraph.sourceRange
        activity.currentParagraphIndex =
            paragraphIndex
        activity.paragraphCount =
            paragraphCount
        activity.itemProgress =
            itemProgress
        activity.projectProgress =
            projectProgress
        revision &+= 1
    }

    private func projectProgress(
        itemID: UUID,
        offsetUTF16: Int
    ) -> Double {
        let totalLength = itemStates.reduce(0) {
            $0 + max(1, $1.item.text.utf16.count)
        }
        guard totalLength > 0 else { return 0 }

        var consumed = 0
        for state in itemStates {
            let length = max(
                1,
                state.item.text.utf16.count
            )
            if state.id == itemID {
                consumed += min(
                    max(offsetUTF16, 0),
                    length
                )
                break
            }
            consumed += length
        }

        return min(
            1,
            max(
                0,
                Double(consumed) / Double(totalLength)
            )
        )
    }

    private func waitWhileReaderPaused(
        _ operationID: UUID
    ) async throws {
        while readerPauseRequested {
            try requirePlaybackOperation(operationID)
            try await Task.sleep(
                for: .milliseconds(50)
            )
        }
        try requirePlaybackOperation(operationID)
    }

    private func readerTimeline()
        -> [ReaderTimedPlaybackPosition]
    {
        var timeline:
            [ReaderTimedPlaybackPosition] = []

        for state in itemStates {
            for paragraph in
                ReaderTextLayout.paragraphs(
                    in: state.item.text
                )
            {
                timeline.append(
                    ReaderTimedPlaybackPosition(
                        itemID: state.id,
                        paragraph: paragraph,
                        durationSeconds:
                            paragraph
                                .estimatedDurationSeconds(
                                    speed:
                                        state.resolved
                                            .speed
                                )
                    )
                )
            }
        }

        return timeline
    }

    private func requirePlaybackOperation(
        _ operationID: UUID
    ) throws {
        try Task.checkCancellation()
        guard playbackOperationID == operationID else {
            throw CancellationError()
        }
    }
}

private nonisolated struct ReaderTimedPlaybackPosition {
    let itemID: UUID
    let paragraph: ReaderParagraph
    let durationSeconds: Double
}
