import Foundation

@MainActor
extension ProjectRuntime {
    var isPlaybackActive: Bool {
        if playbackTask != nil {
            return true
        }

        switch activity.playbackState {
        case .loading,
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

    func pausePlayback() {
        guard isPlaybackActive,
              !readerPauseRequested
        else {
            return
        }

        readerPauseRequested = true
        pipeline.pause()
        activity.playbackState = .paused
        ProjectSystemMediaController
            .shared
            .publish(self)
    }

    func resumePlayback() {
        guard readerPauseRequested else {
            return
        }

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

        ProjectSystemMediaController
            .shared
            .publish(self)
    }

    func togglePlayback(
        itemID: UUID
    ) throws {
        if activity.activeItemID
            == itemID {
            switch activity.playbackState {
            case .paused:
                resumePlayback()
                return
            case .loading,
                 .warmingUp,
                 .synthesizing,
                 .playing:
                pausePlayback()
                return
            case .idle,
                 .finished,
                 .failed:
                break
            }
        }

        try play(itemID: itemID)
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
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchTaskID = nil
        playbackOperationID = nil
        readerPauseRequested = false
        chunkBookmarkTask?.cancel()
        chunkBookmarkTask = nil
        activity.currentChunkRange = nil
        activity.currentChunkIndex = nil
        // Do not keep highlighting the old passage while the new one loads.
        activity.currentParagraphRange = nil
        activity.currentParagraphIndex = nil
        playbackTask?.cancel()
        playbackTask = nil
        pipeline.stop()
        playerItemID = itemID
        finalAudioAsset = nil
        finalAudioPlaybackOriginSeconds = 0
        queueController.setPlaybackActive(
            true
        )
        finalAudioPositionSeconds = 0

        let operationID = UUID()
        playbackOperationID =
            operationID
        activity.activeItemID =
            itemID
        activity.playbackState = .loading

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
            queueController.setPlaybackActive(false)
            activity.playbackState =
                .failed(
                    "Reader item is unavailable."
                )
            return
        }

        do {
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
                reachedProjectEnd = itemIndex == playbackItemIDs.count - 1
                if stopsAtChapterEnd { break }
            }

            try requirePlaybackOperation(
                operationID
            )
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
        queueController.setPlaybackActive(true)

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

        let lookahead = ChunkReadAhead(startIndex: startIndex, maxAhead: 20)
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

        // Producer: fill the bounded, disk-backed window without waiting for
        // paragraph playback to drain. Playback does not own ONNX inference.
        let producer = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for index in startIndex..<requests.count {
                    try self.requirePlaybackOperation(operationID)
                    try await lookahead.awaitCapacity(for: index)
                    try self.requirePlaybackOperation(operationID)
                    let request = requests[index]
                    _ = try await self.chunkCache.audio(for: request) {
                        try await engine.load()
                        let result = try await engine.synthesize(
                            text: request.chunk.text, voice: voice,
                            speed: Float(itemState.resolved.speed),
                            maxChunkSeconds: request.chunk.maxChunkSeconds
                        )
                        return result.audio
                    }
                    try self.requirePlaybackOperation(operationID)
                    await lookahead.markReady(index)
                }
            } catch {
                await lookahead.fail(error)
            }
        }
        defer { producer.cancel() }

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
    }

    func finalizeItemIfComplete(
        itemState: ProjectRuntimeItemState,
        paragraphs: [ReaderParagraph],
        runtimeRevision: String
    ) async throws -> Bool {
        try Task.checkCancellation()
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
            let file = try await writer.finish()
            let metadata = GeneratedAudioMetadata(
                itemID: itemState.id,
                generationKey: itemState.generationKey,
                audioRevision: file.revision,
                contentRevision: itemState.item.contentRevision,
                voiceID: itemState.resolved.voiceID,
                speed: itemState.resolved.speed,
                runtimeRevision: runtimeRevision,
                synthesisConfigVersion: ReadAloudNarrationCatalog.synthesisConfigVersion,
                durationSeconds: Double(file.samples) / Double(ProjectWAVCodec.requiredSampleRate),
                segments: segments
            )
            try await persistence.commitGeneratedAudio(
                wavURL: file.url, metadata: metadata
            )
            await writer.discard()
            return true
        } catch {
            await writer.discard()
            throw error
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
        queueController.setPlaybackActive(
            false
        )

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
    }
}

private nonisolated struct ReaderTimedPlaybackPosition {
    let itemID: UUID
    let chunk: SpeechChunk
    let durationSeconds: Double
}

