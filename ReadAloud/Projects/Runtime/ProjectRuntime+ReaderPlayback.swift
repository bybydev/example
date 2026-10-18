import Foundation

@MainActor
extension ProjectRuntime {
    var isPlaybackActive: Bool {
        if playbackTask != nil {
            return true
        }

        switch activity.playbackState {
        case .loading,
             .buffering,
             .warmingUp,
             .synthesizing,
             .playing,
             .paused:
            return true
        case .idle,
             .finished,
             .failed:
            return false
        }
    }

    var currentFinalAudioPositionSeconds: Double {
        guard let asset =
                finalAudioAsset
        else {
            return finalAudioPositionSeconds
        }

        let live =
            finalAudioPlaybackOriginSeconds
            + pipeline
                .playbackPositionSeconds

        return min(
            asset.metadata
                .durationSeconds,
            max(
                0,
                max(
                    finalAudioPositionSeconds,
                    live
                )
            )
        )
    }

    var isPlaybackPaused: Bool {
        readerPauseRequested
            || activity.playbackState
                == .paused
    }

    func play(
        itemID: UUID,
        fromOffsetUTF16 explicitOffset: Int? = nil
    ) throws {
        // Low-level playback never offers preparation UI (including automatic
        // resume paths). Explicit controls use listen/playFromUser instead.
        try prepareExplicitWork()
        guard let state =
                itemState(itemID)
        else {
            throw ProjectStoreError
                .invalidData(
                    "Reader item is unavailable."
                )
        }

        let offset: Int
        if let explicitOffset {
            offset = explicitOffset
        } else if project?.playback?
            .currentItemID == itemID,
            project?.playback?
                .contentBookmark?
                .contentRevision
                == state.item
                    .contentRevision {
            offset =
                project?.playback?
                    .contentBookmark?
                    .textOffsetUTF16
                ?? 0
        } else {
            offset = 0
        }

        startReaderPlayback(
            itemID: itemID,
            offsetUTF16: offset,
            exactStartSeconds: nil,
            allowsExactAudioResume:
                explicitOffset == nil
        )
    }

    /// Explicit listening is idempotent for the same chapter. Transport buttons
    /// use togglePlayer instead; opening/continuing must never pause or restart.
    @discardableResult
    func listen(itemID: UUID) throws -> Bool {
        if !isPDFReadingReady {
            try offerParsedPreparationForUserAction { [self] in _ = try listen(itemID: itemID) }
            return false
        }
        if activity.activeItemID == itemID, playbackOperationID != nil {
            switch activity.playbackState {
            case .paused:
                resumePlayback()
                return true
            case .loading, .buffering, .warmingUp, .synthesizing, .playing:
                return true
            case .idle, .finished, .failed:
                break
            }
        }
        if case .finished = activity.playbackState, playerItemID == itemID {
            try play(itemID: itemID, fromOffsetUTF16: 0)
        } else {
            try play(itemID: itemID)
        }
        return true
    }

    func playFromUser(itemID: UUID, fromOffsetUTF16: Int) throws {
        if !isPDFReadingReady {
            try offerParsedPreparationForUserAction { [self] in
                try playFromUser(itemID: itemID, fromOffsetUTF16: fromOffsetUTF16)
            }
            return
        }
        try play(itemID: itemID, fromOffsetUTF16: fromOffsetUTF16)
    }

    func pausePlayback() {
        interruptedPlaybackOperationID = nil
        guard isPlaybackActive,
              !readerPauseRequested
        else {
            return
        }

        readerPauseRequested = true
        pipeline.pause()
        activity.playbackState = .paused
        queueController.reconcileScheduling()
        ProjectSystemMediaController
            .shared
            .publish(self)
    }

    func resumePlayback() {
        guard readerPauseRequested, playbackOperationID != nil else {
            return
        }
        if let playbackCoordinator, playbackCoordinator.playerRuntime !== self { return }
        guard playbackCoordinator?.authorizeListening() != false else { return }

        playbackCoordinator?.voicePreviews.stop()
        interruptedPlaybackOperationID = nil
        readerPauseRequested = false
        pipeline.resume()
        // A failed session restart must stay failed. Pipeline events publish
        // the audible state; preparation can still be in progress here.
        if case .failed = pipeline.state {
            let failure = activity.playbackState
            let itemID = playerItemID
            stopPlayback()
            playerItemID = itemID
            activity.playbackState = failure
        }

        queueController.reconcileScheduling()
        ProjectSystemMediaController
            .shared
            .publish(self)
    }

    func togglePlayback(
        itemID: UUID
    ) throws {
        try togglePlayer(itemID: itemID)
    }

    func seekPlayback(
        by seconds: Double
    ) throws {
        guard seconds.isFinite, seconds != 0,
              let currentItemID =
                activity.activeItemID
        else {
            return
        }

        try prepareExplicitWork()

        if let asset = finalAudioAsset,
           asset.metadata.itemID
                == currentItemID {
            let shouldRemainPaused =
                isPlaybackPaused
            let targetSeconds = min(
                asset.metadata
                    .durationSeconds,
                max(
                    0,
                    currentFinalAudioPositionSeconds
                        + seconds
                )
            )
            let range =
                finalAudioSegment(
                    in: asset.metadata,
                    at: targetSeconds
                )?.sourceRange
                ?? activity
                    .currentParagraphRange
                ?? AudioSourceRange(
                    startUTF16: 0,
                    endUTF16: 1
                )

            startReaderPlayback(
                itemID: currentItemID,
                offsetUTF16:
                    range.startUTF16,
                exactStartSeconds:
                    targetSeconds,
                allowsExactAudioResume:
                    false
            )

            if shouldRemainPaused {
                pausePlayback()
            }
            return
        }

        guard let currentRange = activity.currentChunkRange else { return }
        let timeline = readerTimeline(itemID: currentItemID)
        guard !timeline.isEmpty,
              let currentIndex = timeline.firstIndex(where: {
                  $0.itemID == currentItemID
                      && $0.chunk.sourceRange == currentRange
              }) else { return }

        var remaining =
            abs(seconds)
        var targetIndex =
            currentIndex

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

        let target =
            timeline[targetIndex]
        let shouldRemainPaused =
            isPlaybackPaused

        startReaderPlayback(
            itemID: target.itemID,
            offsetUTF16:
                target.chunk
                    .sourceRange
                    .startUTF16,
            exactStartSeconds: nil,
            allowsExactAudioResume:
                false
        )

        if shouldRemainPaused {
            pausePlayback()
        }
    }

    func seekPlayback(
        to positionSeconds: Double
    ) throws {
        guard positionSeconds.isFinite,
              let currentItemID = activity.activeItemID,
              let asset =
                finalAudioAsset,
              asset.metadata.itemID
                == currentItemID
        else {
            return
        }

        try prepareExplicitWork()

        let shouldRemainPaused =
            isPlaybackPaused
        let targetSeconds =
            min(
                asset.metadata
                    .durationSeconds,
                max(
                    0,
                    positionSeconds
                )
            )
        let range =
            finalAudioSegment(
                in: asset.metadata,
                at: targetSeconds
            )?.sourceRange
            ?? activity
                .currentParagraphRange
            ?? AudioSourceRange(
                startUTF16: 0,
                endUTF16: 1
            )

        startReaderPlayback(
            itemID: currentItemID,
            offsetUTF16:
                range.startUTF16,
            exactStartSeconds:
                targetSeconds,
            allowsExactAudioResume:
                false
        )

        if shouldRemainPaused {
            pausePlayback()
        }
    }

    func persistPlaybackCheckpoint()
        async
    {
        guard let playback =
                project?.playback
        else {
            return
        }

        if let operationID =
                playbackOperationID,
           let asset =
                finalAudioAsset,
           let itemID =
                activity.activeItemID,
           asset.metadata.itemID
                == itemID,
           let state =
                itemState(itemID)
        {
            let paragraphs = cachedReaderParagraphs(for: state.item)
            let position =
                min(
                    asset.metadata
                        .durationSeconds,
                    max(
                        0,
                        currentFinalAudioPositionSeconds
                    )
                )

            do {
                try await
                    publishFinalAudioPosition(
                        asset: asset,
                        itemState: state,
                        paragraphs:
                            paragraphs,
                        positionSeconds:
                            position,
                        persist: true,
                        operationID:
                            operationID
                    )
            } catch is CancellationError {
                return
            } catch {
                lastErrorMessage =
                    Self.message(
                        for: error
                    )
            }
            return
        }

        do {
            var checkpoint = playback
            checkpoint.lastPlayedAt = .now
            try await persistence
                .updatePlayback(
                    checkpoint
                )
            project?.playback =
                checkpoint
            revision &+= 1
            ProjectSystemMediaController
                .shared
                .publish(self)
        } catch {
            lastErrorMessage =
                Self.message(
                    for: error
                )
        }
    }

    func playNextItem(
        after itemID: UUID
    ) throws {
        guard let index =
                itemStates.firstIndex(
                    where: {
                        $0.id == itemID
                    }
                )
        else {
            return
        }

        let nextIndex =
            index + 1
        guard itemStates.indices
            .contains(nextIndex)
        else {
            return
        }

        try changePlayerChapter(
            to:
                itemStates[
                    nextIndex
                ].id
        )
    }

    func playPreviousItem(
        before itemID: UUID
    ) throws {
        guard let index =
                itemStates.firstIndex(
                    where: {
                        $0.id == itemID
                    }
                )
        else {
            return
        }

        let previousIndex =
            index - 1
        guard itemStates.indices
            .contains(previousIndex)
        else {
            return
        }

        try changePlayerChapter(
            to:
                itemStates[
                    previousIndex
                ].id
        )
    }

    func readerParagraphs(
        itemID: UUID
    ) -> [ReaderParagraph] {
        guard let state =
                itemState(itemID)
        else {
            return []
        }

        return cachedReaderParagraphs(for: state.item)
    }

    private func startReaderPlayback(
        itemID: UUID,
        offsetUTF16: Int,
        exactStartSeconds: Double?,
        allowsExactAudioResume: Bool
    ) {
        guard playbackCoordinator?.authorizeListening() != false else { return }
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchTaskID = nil
        playbackOperationID = nil
        interruptedPlaybackOperationID = nil
        readerPauseRequested = false
        chunkBookmarkTask?.cancel()
        chunkBookmarkTask = nil
        activity.currentChunkRange = nil
        activity.currentChunkIndex = nil
        // Do not keep highlighting the old passage while the new one loads.
        activity.currentParagraphRange = nil
        activity.currentParagraphIndex = nil
        retirePlayback(playbackTask)
        playbackTask = nil
        pipeline.stop()
        playerItemID = itemID
        isPlayerDismissed = false
        finalAudioAsset = nil
        finalAudioPlaybackOriginSeconds = 0
        finalAudioPositionSeconds = 0

        let operationID = UUID()
        playbackOperationID =
            operationID
        activity.activeItemID =
            itemID
        activity.playbackState = .loading
        // Ownership is transferred before file/cache reads or generation drains
        // can suspend. System media only mirrors the coordinator's decision.
        playbackCoordinator?.claimPlayback(self)
        queueController.reconcileScheduling()

        playbackTask =
            Task {
                @MainActor [weak self] in
                guard let self else {
                    return
                }

                await self.runReaderPlayback(
                    initialItemID:
                        itemID,
                    initialOffsetUTF16:
                        offsetUTF16,
                    explicitExactStartSeconds:
                        exactStartSeconds,
                    allowsExactAudioResume:
                        allowsExactAudioResume,
                    operationID:
                        operationID
                )
            }
    }

    private func runReaderPlayback(
        initialItemID: UUID,
        initialOffsetUTF16: Int,
        explicitExactStartSeconds: Double?,
        allowsExactAudioResume: Bool,
        operationID: UUID
    ) async {
        guard playbackOperationID == operationID, !Task.isCancelled else { return }
        guard let initialIndex =
                itemStates.firstIndex(
                    where: {
                        $0.id
                            == initialItemID
                    }
                )
        else {
            playbackTask = nil
            playbackOperationID = nil
            activity.playbackState =
                .failed(
                    "Reader item is unavailable."
                )
            queueController.reconcileScheduling()
            return
        }

        do {
            guard isPDFReadingReady else { throw ParsedOutputPreparationError.unavailable }
            let runtimeRevision =
                try ReadAloudSynthesisContract
                    .runtimeRevision()

            let playbackEndIndex =
                ReadAloudPreferences
                    .continueToNextChapter
                ? itemStates.count
                : min(
                    itemStates.count,
                    initialIndex + 1
                )

            let playbackItemIDs = itemStates.map(\.id)
            var reachedProjectEnd = false
            for itemIndex
                in initialIndex
                    ..< playbackEndIndex {
                try requirePlaybackOperation(
                    operationID
                )
                // In particular, do not transition past the last audible
                // chapter while the weekly limit has paused the session.
                try await waitWhileReaderPaused(operationID)

                guard let state =
                        itemState(
                            playbackItemIDs[itemIndex]
                        )
                else {
                    continue
                }

                let paragraphs = cachedReaderParagraphs(for: state.item)
                guard !paragraphs.isEmpty
                else {
                    continue
                }

                let requestedOffset =
                    itemIndex
                        == initialIndex
                    ? initialOffsetUTF16
                    : 0

                let request =
                    generationStatusRequest(
                        for: state
                    )

                if let asset =
                    try await persistence
                        .loadCompatibleFinalAudio(
                            request: request
                        )
                {
                    let requestedExact =
                        itemIndex
                                == initialIndex
                        ? explicitExactStartSeconds
                        : nil
                    let startSeconds =
                        finalAudioStartSeconds(
                            asset: asset,
                            itemState: state,
                            requestedOffset:
                                requestedOffset,
                            explicitExact:
                                requestedExact,
                            allowsSavedExact:
                                itemIndex
                                    == initialIndex
                                    && allowsExactAudioResume
                        )

                    try requirePlaybackOperation(operationID)
                    await scheduleChunkReclamation(
                        itemState: state, runtimeRevision: runtimeRevision,
                        metadata: asset.metadata
                    )
                    try requirePlaybackOperation(operationID)
                    try await playFinalAudio(
                        asset: asset,
                        itemState: state,
                        paragraphs:
                            paragraphs,
                        startSeconds:
                            startSeconds,
                        operationID:
                            operationID
                    )
                } else {
                    try await chunkCache.withUsage(itemID: state.id) { @MainActor [self] in
                        try await streamItem(
                            itemState: state,
                            paragraphs:
                                paragraphs,
                            startOffsetUTF16:
                                requestedOffset,
                            runtimeRevision:
                                runtimeRevision,
                            operationID:
                                operationID
                        )

                        do {
                            if try await
                                finalizeItemIfComplete(
                                    itemState:
                                        state,
                                    paragraphs:
                                        paragraphs,
                                    runtimeRevision:
                                        runtimeRevision
                                )
                            {
                                try requirePlaybackOperation(
                                    operationID
                                )
                                try await refreshGenerationState()
                                try requirePlaybackOperation(
                                    operationID
                                )
                            }
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            lastErrorMessage =
                                Self.message(
                                    for: error
                                )
                        }
                    }
                }
                reachedProjectEnd = itemIndex == playbackItemIDs.count - 1
                if stopsAtChapterEnd { break }
            }

            try requirePlaybackOperation(
                operationID
            )
            try await waitWhileReaderPaused(operationID)
            pipeline
                .finishContinuousPlayback()
            finalAudioAsset = nil
            finalAudioPositionSeconds = 0
            finalAudioPlaybackOriginSeconds = 0
            activity.itemProgress = 1
            clearSleepTimer()

            if reachedProjectEnd {
                activity.projectProgress = 1
            }

            if var playback =
                project?.playback {
                if reachedProjectEnd {
                    playback.projectProgress =
                        1
                }
                playback.lastPlayedAt =
                    .now

                try await persistence
                    .updatePlayback(
                        playback
                    )
                try requirePlaybackOperation(
                    operationID
                )

                project?.playback =
                    playback
                revision &+= 1
            }

            playbackTask = nil
            playbackOperationID = nil
        } catch is CancellationError {
            if playbackOperationID
                == operationID {
                playbackTask = nil
                playbackOperationID =
                    nil
            }
        } catch {
            guard playbackOperationID
                    == operationID
            else {
                return
            }

            // Keep the bookmark at the last audible chunk even when the
            // next chunk fails. Never checkpoint the read-ahead frontier.
            await chunkBookmarkTask?.value
            guard playbackOperationID == operationID else { return }
            await persistPlaybackCheckpoint()
            guard playbackOperationID == operationID else { return }
            clearSleepTimer()
            playbackTask = nil
            playbackOperationID = nil
            readerPauseRequested = false
            finalAudioAsset = nil
            finalAudioPositionSeconds = 0
            pipeline.stop()
            activity.playbackState =
                .failed(
                    Self.message(
                        for: error
                    )
                )
        }
    }

    private func streamItem(
        itemState: ProjectRuntimeItemState,
        paragraphs: [ReaderParagraph],
        startOffsetUTF16: Int,
        runtimeRevision: String,
        operationID: UUID
    ) async throws {
        finalAudioAsset = nil
        finalAudioPositionSeconds = 0
        finalAudioPlaybackOriginSeconds = 0
        queueController.reconcileScheduling()
        await ProjectGenerationExecutionRegistry.shared.drainForPlayback()
        try Task.checkCancellation()

        let chunks = SpeechChunkScheduler().chunks(
            for: itemState.item.text, speed: Float(itemState.resolved.speed)
        )
        guard !chunks.isEmpty else { return }
        let startIndex = chunks.firstIndex {
            startOffsetUTF16 < $0.sourceRange.endUTF16
        } ?? (chunks.count - 1)
        guard let voice = SpeechVoice.all.first(where: {
            $0.id == itemState.resolved.voiceID
        }) else {
            throw SpeechEngineError.unsupportedVoice(itemState.resolved.voiceID)
        }

        SpeechPlaybackDiagnostics.chapterStarted(finalized: false)
        let lookahead = ChunkReadAhead(startIndex: startIndex)
        let requests: [ChunkAudioRequest] = chunks.enumerated().map { index, chunk in
            ChunkAudioRequest(
                itemID: itemState.id,
                index: index, chunk: chunk,
                generationKey: itemState.generationKey,
                resolved: itemState.resolved,
                runtimeRevision: runtimeRevision,
                synthesisConfigVersion: ReadAloudNarrationCatalog.synthesisConfigVersion
            )
        }
        let engine = pipeline.engine

        // Prepare at most 20 chunks ahead on disk without retaining them as
        // PCM. Pausing sound keeps filling this same window in any scene;
        // audible progress is the only event that frees more capacity.
        let producer = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for index in startIndex..<requests.count {
                    try self.requirePlaybackOperation(operationID)
                    let request = requests[index]
                    _ = try await lookahead.loadAudio(for: index) { [cache = self.chunkCache] in
                        try await cache.audio(for: request) {
                            try await engine.load()
                            let result = try await engine.synthesize(
                                text: request.chunk.text, voice: voice,
                                speed: Float(itemState.resolved.speed),
                                maxChunkSeconds: request.chunk.maxChunkSeconds,
                                pronunciationMode: itemState.pronunciationMode
                            )
                            return result.audio
                        }
                    }
                    try self.requirePlaybackOperation(operationID)
                    await lookahead.markReady(index)
                }
            } catch {
                await lookahead.fail(error)
            }
        }
        do {
            try await pipeline.playChunkStream(
                count: requests.count - startIndex,
                loadAudio: { [cache = chunkCache] offset in
                    let index = startIndex + offset
                    try await lookahead.awaitReady(index)
                    guard let audio = try await cache.load(requests[index]) else {
                        throw ProjectStoreError.invalidData(
                            "Prepared chunk audio is unavailable. Restart playback to retry."
                        )
                    }
                    return audio
                },
                onChunkStarted: { [weak self] offset in
                    guard let self, self.playbackOperationID == operationID else { return }
                    let index = startIndex + offset
                    let chunk = chunks[index]
                    let paragraphIndex = ReaderTextLayout.paragraphIndex(
                        forUTF16Offset: chunk.sourceRange.startUTF16, in: paragraphs
                    )
                    // Highlight immediately when audio actually starts, not when
                    // the producer has synthesized it.
                    self.activity.currentChunkRange = chunk.sourceRange
                    self.activity.currentChunkIndex = index
                    self.activity.currentParagraphRange = paragraphs[paragraphIndex].sourceRange
                    self.activity.currentParagraphIndex = paragraphIndex
                    self.activity.paragraphCount = paragraphs.count
                    self.activity.activeItemID = itemState.id
                    self.activity.itemProgress = Double(chunk.sourceRange.startUTF16)
                        / Double(max(1, self.playerTextLength(for: itemState.item)))
                    let projectProgress = self.readingProgressIndex.progress(
                        itemID: itemState.id,
                        offsetUTF16: chunk.sourceRange.startUTF16
                    )
                    self.activity.projectProgress = projectProgress
                    // Keep the in-memory resume bookmark equal to the audible
                    // chunk even before the serialized disk write completes.
                    self.project?.playback = ProjectPlaybackState(
                        currentItemID: itemState.id,
                        contentBookmark: ProjectContentBookmark(
                            contentRevision: itemState.item.contentRevision,
                            textOffsetUTF16: chunk.sourceRange.startUTF16
                        ),
                        audioPosition: nil,
                        projectProgress: projectProgress,
                        lastPlayedAt: .now
                    )
                    self.revision &+= 1
                    let previous = self.chunkBookmarkTask
                    self.chunkBookmarkTask = Task { @MainActor [weak self] in
                        await lookahead.markAudible(index)
                        await previous?.value
                        guard let self, self.playbackOperationID == operationID,
                              self.activity.activeItemID == itemState.id,
                              self.activity.currentChunkIndex == index else { return }
                        try? await self.publishReaderPosition(
                            itemState: itemState,
                            paragraph: paragraphs[paragraphIndex],
                            paragraphIndex: paragraphIndex,
                            paragraphCount: paragraphs.count,
                            operationID: operationID,
                            sourceRange: chunk.sourceRange
                        )
                    }
                }
            )
            // Flush the last audible bookmark before transitioning chapters.
            await chunkBookmarkTask?.value
            try requirePlaybackOperation(operationID)
        } catch {
            producer.cancel()
            await producer.value
            throw error
        }
        producer.cancel()
        await producer.value
    }

    func finalizeItemIfComplete(
        itemState: ProjectRuntimeItemState,
        paragraphs: [ReaderParagraph],
        runtimeRevision: String
    ) async throws -> Bool {
        try await chunkCache.withUsage(itemID: itemState.id) { @MainActor [self] in
            try await assembleItemIfComplete(
                itemState: itemState, paragraphs: paragraphs, runtimeRevision: runtimeRevision
            )
        }
    }

    private func assembleItemIfComplete(
        itemState: ProjectRuntimeItemState,
        paragraphs: [ReaderParagraph], runtimeRevision: String
    ) async throws -> Bool {
        try Task.checkCancellation()
        guard ProjectGenerationExecutionRegistry.shared.canPerformGeneration else { return false }
        let chunks = SpeechChunkScheduler().chunks(
            for: itemState.item.text, speed: Float(itemState.resolved.speed)
        )
        guard !chunks.isEmpty else { return false }

        let writer = try ProjectWAVFileWriter(directory: cacheCoordinator.temporaryDirectory)
        do {
            var segments: [AudioSegmentMetadata] = []
            for (index, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                guard !synthesisSuspendedForMemoryPressure else {
                    throw CancellationError()
                }
                guard ProjectGenerationExecutionRegistry.shared.canPerformGeneration else {
                    await writer.discard()
                    return false
                }
                let request = ChunkAudioRequest(
                    itemID: itemState.id, index: index, chunk: chunk,
                    generationKey: itemState.generationKey,
                    resolved: itemState.resolved,
                    runtimeRevision: runtimeRevision,
                    synthesisConfigVersion: ReadAloudNarrationCatalog.synthesisConfigVersion
                )
                guard let cached = try await chunkCache.load(request) else {
                    await writer.discard()
                    return false
                }
                let span = try await writer.append(samples: cached.samples)
                segments.append(AudioSegmentMetadata(
                    sourceRange: chunk.sourceRange,
                    startSeconds: Double(span.start) / Double(ProjectWAVCodec.requiredSampleRate),
                    endSeconds: Double(span.end) / Double(ProjectWAVCodec.requiredSampleRate)
                ))
            }
            guard ProjectGenerationExecutionRegistry.shared.canPerformGeneration else {
                await writer.discard()
                return false
            }
            let file = try await writer.finish()
            let metadata = GeneratedAudioMetadata(
                itemID: itemState.id,
                generationKey: itemState.generationKey,
                audioRevision: file.revision,
                contentRevision: itemState.item.contentRevision,
                voiceID: itemState.resolved.voiceID,
                speed: itemState.resolved.speed,
                runtimeRevision: ReadAloudSynthesisContract.generationRuntimeRevision(
                    base: runtimeRevision, pronunciationMode: itemState.pronunciationMode
                ),
                synthesisConfigVersion: ReadAloudNarrationCatalog.synthesisConfigVersion,
                durationSeconds: Double(file.samples) / Double(ProjectWAVCodec.requiredSampleRate),
                segments: segments
            )
            try await persistence.commitGeneratedAudio(
                wavURL: file.url, metadata: metadata
            )
            await writer.discard()
            await scheduleChunkReclamation(
                itemState: itemState, runtimeRevision: runtimeRevision, metadata: metadata
            )
            return true
        } catch {
            await writer.discard()
            throw error
        }
    }

    private func scheduleChunkReclamation(
        itemState: ProjectRuntimeItemState, runtimeRevision: String,
        metadata: GeneratedAudioMetadata
    ) async {
        let request = generationStatusRequest(for: itemState)
        let chunks = SpeechChunkScheduler().chunks(
            for: itemState.item.text, speed: Float(itemState.resolved.speed)
        ).enumerated().map { index, chunk in
            ChunkAudioRequest(
                itemID: itemState.id, index: index, chunk: chunk,
                generationKey: itemState.generationKey, resolved: itemState.resolved,
                runtimeRevision: runtimeRevision,
                synthesisConfigVersion: ReadAloudNarrationCatalog.synthesisConfigVersion
            )
        }
        await chunkCache.requestReclamation(
            itemID: itemState.id, audioRevision: metadata.audioRevision
        ) { [persistence] in
            try await persistence.reclaimFinalizedChunks(
                request: request, expectedAudioRevision: metadata.audioRevision, chunks: chunks
            )
        }
    }

    private func playFinalAudio(
        asset: ProjectFinalAudioAsset,
        itemState:
            ProjectRuntimeItemState,
        paragraphs:
            [ReaderParagraph],
        startSeconds: Double,
        operationID: UUID
    ) async throws {
        SpeechPlaybackDiagnostics.chapterStarted(finalized: true)
        let duration = asset.metadata.durationSeconds
        guard startSeconds.isFinite, duration.isFinite, duration > 0 else {
            throw ProjectStoreError.invalidData("Saved playback position is invalid.")
        }
        let clampedStart = min(duration, max(0, startSeconds))
        if clampedStart >= duration { return }
        let actualStart = clampedStart

        finalAudioAsset = asset
        finalAudioPositionSeconds =
            actualStart
        finalAudioPlaybackOriginSeconds =
            actualStart
        queueController.reconcileScheduling()

        try await publishFinalAudioPosition(
            asset: asset,
            itemState:
                itemState,
            paragraphs:
                paragraphs,
            positionSeconds:
                actualStart,
            persist: true,
            operationID:
                operationID
        )

        try await waitWhileReaderPaused(
            operationID
        )

        let monitor =
            Task {
                @MainActor [weak self] in
                guard let self else {
                    return
                }

                var lastPersisted =
                    actualStart

                while !Task.isCancelled {
                    do {
                        try await Task.sleep(
                            for:
                                .milliseconds(
                                    500
                                )
                        )
                        try self
                            .requirePlaybackOperation(
                                operationID
                            )

                        let position =
                            min(
                                duration,
                                actualStart
                                    + self
                                        .pipeline
                                        .playbackPositionSeconds
                            )
                        let segment =
                            self
                                .finalAudioSegment(
                                    in:
                                        asset
                                            .metadata,
                                    at:
                                        position
                                )
                        let changedSegment =
                            segment?
                                .sourceRange
                            != self.activity
                                .currentParagraphRange
                        let shouldPersist =
                            changedSegment
                            || position
                                - lastPersisted
                                >= 2

                        do {
                            try await self
                                .publishFinalAudioPosition(
                                    asset:
                                        asset,
                                    itemState:
                                        itemState,
                                    paragraphs:
                                        paragraphs,
                                    positionSeconds:
                                        position,
                                    persist:
                                        shouldPersist,
                                    operationID:
                                        operationID
                                )

                            if shouldPersist {
                                lastPersisted =
                                    position
                            }
                        } catch is CancellationError {
                            return
                        } catch {
                            self.lastErrorMessage =
                                Self.message(
                                    for: error
                                )

                            try? await self
                                .publishFinalAudioPosition(
                                    asset:
                                        asset,
                                    itemState:
                                        itemState,
                                    paragraphs:
                                        paragraphs,
                                    positionSeconds:
                                        position,
                                    persist: false,
                                    operationID:
                                        operationID
                                )
                        }
                    } catch {
                        return
                    }
                }
            }

        defer {
            monitor.cancel()
        }

        do {
            try await pipeline.playFile(
                at: asset.wavURL,
                startSeconds: actualStart,
                continuous: true
            )
        } catch ReadAloudPipeline
            .PipelineError
            .cancelled {
            try requirePlaybackOperation(
                operationID
            )
            throw CancellationError()
        }

        try requirePlaybackOperation(
            operationID
        )

        finalAudioPositionSeconds =
            duration
        try await publishFinalAudioPosition(
            asset: asset,
            itemState:
                itemState,
            paragraphs:
                paragraphs,
            positionSeconds:
                duration,
            persist: true,
            operationID:
                operationID
        )
    }

    private func publishFinalAudioPosition(
        asset: ProjectFinalAudioAsset,
        itemState:
            ProjectRuntimeItemState,
        paragraphs:
            [ReaderParagraph],
        positionSeconds: Double,
        persist: Bool,
        operationID: UUID
    ) async throws {
        let duration =
            asset.metadata
                .durationSeconds
        let position =
            min(
                duration,
                max(
                    0,
                    positionSeconds
                )
            )

        guard let segment =
                finalAudioSegment(
                    in:
                        asset.metadata,
                    at: position
                )
        else {
            throw ProjectStoreError
                .invalidData(
                    "Final audio has no source segment for playback position."
                )
        }

        let paragraphIndex =
            ReaderTextLayout
                .paragraphIndex(
                    forUTF16Offset:
                        segment
                            .sourceRange
                            .startUTF16,
                    in: paragraphs
                )
        let projectProgress =
            projectProgress(
                itemID:
                    itemState.id,
                offsetUTF16:
                    segment
                        .sourceRange
                        .startUTF16
            )
        let playback =
            ProjectPlaybackState(
                currentItemID:
                    itemState.id,
                contentBookmark:
                    ProjectContentBookmark(
                        contentRevision:
                            itemState.item
                                .contentRevision,
                        textOffsetUTF16:
                            segment
                                .sourceRange
                                .startUTF16
                    ),
                audioPosition:
                    ProjectAudioPosition(
                        generationKey:
                            asset.metadata
                                .generationKey,
                        audioRevision:
                            asset.metadata
                                .audioRevision,
                        positionSeconds:
                            position
                    ),
                projectProgress:
                    projectProgress,
                lastPlayedAt: .now
            )

        if persist {
            try await persistence
                .updatePlayback(
                    playback
                )
            try requirePlaybackOperation(
                operationID
            )
        }

        project?.playback =
            playback
        playerItemID = itemState.id
        activity.activeItemID =
            itemState.id
        activity.currentParagraphRange = paragraphs[paragraphIndex].sourceRange
        activity.currentParagraphIndex = paragraphIndex
        activity.currentChunkRange = segment.sourceRange
        activity.currentChunkIndex = asset.metadata.segments.firstIndex(where: {
            $0.sourceRange == segment.sourceRange
        })
        activity.paragraphCount =
            paragraphs.count
        activity.itemProgress =
            duration > 0
            ? min(
                1,
                max(
                    0,
                    position
                        / duration
                )
            )
            : 0
        activity.projectProgress =
            projectProgress
        finalAudioPositionSeconds =
            position
        revision &+= 1
        ProjectSystemMediaController
            .shared
            .publish(self)
    }

    private func finalAudioStartSeconds(
        asset: ProjectFinalAudioAsset,
        itemState:
            ProjectRuntimeItemState,
        requestedOffset: Int,
        explicitExact: Double?,
        allowsSavedExact: Bool
    ) -> Double {
        let duration =
            asset.metadata
                .durationSeconds

        if let explicitExact {
            return min(
                duration,
                max(
                    0,
                    explicitExact
                )
            )
        }

        if allowsSavedExact,
           project?.playback?
                .currentItemID
                == itemState.id,
           let saved =
                project?.playback?
                    .audioPosition,
           saved.generationKey
                == asset.metadata
                    .generationKey,
           saved.audioRevision
                == asset.metadata
                    .audioRevision {
            return min(
                duration,
                max(
                    0,
                    saved.positionSeconds
                )
            )
        }

        if let segment =
            asset.metadata.segments
                .first(
                    where: {
                        requestedOffset
                            >= $0
                                .sourceRange
                                .startUTF16
                            && requestedOffset
                                < $0
                                    .sourceRange
                                    .endUTF16
                    }
                )
                ?? asset.metadata
                    .segments
                    .first(
                        where: {
                            $0.sourceRange
                                .startUTF16
                                >= requestedOffset
                        }
                    )
        {
            return segment
                .startSeconds
        }

        return asset.metadata
            .segments.last?
            .startSeconds
            ?? 0
    }

    private func finalAudioSegment(
        in metadata:
            GeneratedAudioMetadata,
        at positionSeconds: Double
    ) -> AudioSegmentMetadata? {
        guard !metadata
            .segments.isEmpty
        else {
            return nil
        }

        let position =
            min(
                metadata
                    .durationSeconds,
                max(
                    0,
                    positionSeconds
                )
            )

        if position
            >= metadata
                .durationSeconds {
            return metadata
                .segments.last
        }

        return metadata.segments
            .first(
                where: {
                    position
                        >= $0.startSeconds
                        && position
                            < $0.endSeconds
                }
            )
            ?? metadata.segments
                .last(
                    where: {
                        $0.startSeconds
                            <= position
                    }
                )
            ?? metadata
                .segments.first
    }

    private func generationStatusRequest(
        for state:
            ProjectRuntimeItemState
    ) -> ProjectGenerationStatusRequest {
        ProjectGenerationStatusRequest(
            itemID: state.id,
            generationKey:
                state.generationKey,
            contentRevision:
                state.item
                    .contentRevision,
            voiceID:
                state.resolved
                    .voiceID,
            speed:
                state.resolved
                    .speed
        )
    }

    private func publishReaderPosition(
        itemState:
            ProjectRuntimeItemState,
        paragraph:
            ReaderParagraph,
        paragraphIndex: Int,
        paragraphCount: Int,
        operationID: UUID,
        sourceRange: AudioSourceRange? = nil
    ) async throws {
        let audibleRange = sourceRange ?? paragraph.sourceRange
        let itemLength =
            max(
                1,
                playerTextLength(for: itemState.item)
            )
        let itemProgress =
            min(
                1,
                max(
                    0,
                    Double(
                        audibleRange.startUTF16
                    )
                    / Double(
                        itemLength
                    )
                )
            )
        let projectProgress =
            projectProgress(
                itemID:
                    itemState.id,
                offsetUTF16:
                    audibleRange.startUTF16
            )

        let playback =
            ProjectPlaybackState(
                currentItemID:
                    itemState.id,
                contentBookmark:
                    ProjectContentBookmark(
                        contentRevision:
                            itemState.item
                                .contentRevision,
                        textOffsetUTF16: audibleRange.startUTF16
                    ),
                audioPosition: nil,
                projectProgress:
                    projectProgress,
                lastPlayedAt: .now
            )

        try requirePlaybackOperation(operationID)
        guard activity.currentChunkRange == audibleRange else { return }
        try await persistence
            .updatePlayback(
                playback
            )
        try requirePlaybackOperation(
            operationID
        )

        guard activity.currentChunkRange == audibleRange else { return }
        project?.playback = playback
        playerItemID = itemState.id
        activity.activeItemID =
            itemState.id
        activity.currentParagraphRange = paragraph.sourceRange
        activity.currentChunkRange = audibleRange
        activity.currentParagraphIndex =
            paragraphIndex
        activity.paragraphCount =
            paragraphCount
        activity.itemProgress =
            itemProgress
        activity.projectProgress =
            projectProgress
        revision &+= 1
        ProjectSystemMediaController
            .shared
            .publish(self)
    }

    private func projectProgress(
        itemID: UUID,
        offsetUTF16: Int
    ) -> Double {
        readingProgressIndex.progress(itemID: itemID, offsetUTF16: offsetUTF16)
    }

    private func waitWhileReaderPaused(
        _ operationID: UUID
    ) async throws {
        while readerPauseRequested {
            try requirePlaybackOperation(
                operationID
            )
            try await Task.sleep(
                for:
                    .milliseconds(50)
            )
        }

        try requirePlaybackOperation(
            operationID
        )
    }

    private func readerTimeline(itemID: UUID) -> [ReaderTimedPlaybackPosition] {
        guard let state = itemState(itemID) else { return [] }
        return SpeechChunkScheduler().chunks(
            for: state.item.text, speed: Float(state.resolved.speed)
        ).map { chunk in
            ReaderTimedPlaybackPosition(
                itemID: state.id,
                chunk: chunk,
                durationSeconds: chunk.estimatedDurationSeconds
            )
        }
    }

    private func requirePlaybackOperation(
        _ operationID: UUID
    ) throws {
        try Task.checkCancellation()

        guard playbackOperationID
                == operationID
        else {
            throw CancellationError()
        }
        if let playbackCoordinator, playbackCoordinator.playerRuntime !== self {
            throw CancellationError()
        }
    }
}

private nonisolated struct ReaderTimedPlaybackPosition {
    let itemID: UUID
    let chunk: SpeechChunk
    let durationSeconds: Double
}





