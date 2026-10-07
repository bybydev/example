import Foundation
import KokoroTTS

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

        if playbackTask != nil {
            activity.playbackState =
                .playing
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
        guard seconds != 0,
              let currentItemID =
                activity.activeItemID
        else {
            return
        }

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

        guard let currentRange =
                activity
                    .currentParagraphRange
        else {
            return
        }

        let timeline =
            readerTimeline()
        guard !timeline.isEmpty,
              let currentIndex =
                timeline.firstIndex(
                    where: {
                        $0.itemID
                            == currentItemID
                            && $0.paragraph
                                .sourceRange
                                == currentRange
                    }
                )
        else {
            return
        }

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
                target.paragraph
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
        guard let currentItemID =
                activity.activeItemID,
              let asset =
                finalAudioAsset,
              asset.metadata.itemID
                == currentItemID
        else {
            return
        }

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
            let paragraphs =
                ReaderTextLayout
                    .paragraphs(
                        in:
                            state.item.text
                    )
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

        try play(
            itemID:
                itemStates[
                    nextIndex
                ].id,
            fromOffsetUTF16: 0
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

        try play(
            itemID:
                itemStates[
                    previousIndex
                ].id,
            fromOffsetUTF16: 0
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

        return ReaderTextLayout
            .paragraphs(
                in: state.item.text
            )
    }

    private func startReaderPlayback(
        itemID: UUID,
        offsetUTF16: Int,
        exactStartSeconds: Double?,
        allowsExactAudioResume: Bool
    ) {
        playbackOperationID = nil
        readerPauseRequested = false
        playbackTask?.cancel()
        playbackTask = nil
        pipeline.stop()
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

            for itemIndex
                in initialIndex
                    ..< itemStates.count {
                try requirePlaybackOperation(
                    operationID
                )

                guard let state =
                        itemState(
                            itemStates[
                                itemIndex
                            ].id
                        )
                else {
                    continue
                }

                let paragraphs =
                    ReaderTextLayout
                        .paragraphs(
                            in:
                                state.item.text
                        )
                guard !paragraphs.isEmpty
                else {
                    continue
                }

                let requestedOffset =
                    itemIndex
                        == initialIndex
                    ? initialOffsetUTF16
                    : 0

                await schedulePrefetch(
                    after: state.id
                )

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
                            try await refresh()
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

            try requirePlaybackOperation(
                operationID
            )
            pipeline
                .finishContinuousPlayback()
            finalAudioAsset = nil
            finalAudioPositionSeconds = 0
            finalAudioPlaybackOriginSeconds = 0
            activity.itemProgress = 1
            activity.projectProgress = 1

            if var playback =
                project?.playback {
                playback.projectProgress =
                    1
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
        itemState:
            ProjectRuntimeItemState,
        paragraphs:
            [ReaderParagraph],
        startOffsetUTF16: Int,
        runtimeRevision: String,
        operationID: UUID
    ) async throws {
        finalAudioAsset = nil
        finalAudioPositionSeconds = 0
        finalAudioPlaybackOriginSeconds = 0
        queueController.setPlaybackActive(
            true
        )

        let startParagraphIndex =
            ReaderTextLayout
                .paragraphIndex(
                    forUTF16Offset:
                        startOffsetUTF16,
                    in: paragraphs
                )

        guard let voice =
            KokoroEngine.Voice.all
                .first(
                    where: {
                        $0.id
                            == itemState
                                .resolved
                                .voiceID
                    }
                )
        else {
            throw KokoroEngine
                .EngineError
                .unsupportedVoice(
                    itemState
                        .resolved
                        .voiceID
                )
        }

        for paragraphIndex
            in startParagraphIndex
                ..< paragraphs.count {
            try requirePlaybackOperation(
                operationID
            )

            let paragraph =
                paragraphs[
                    paragraphIndex
                ]

            try await waitWhileReaderPaused(
                operationID
            )
            try await publishReaderPosition(
                itemState:
                    itemState,
                paragraph:
                    paragraph,
                paragraphIndex:
                    paragraphIndex,
                paragraphCount:
                    paragraphs.count,
                operationID:
                    operationID
            )

            try requirePlaybackOperation(
                operationID
            )
            try await waitWhileReaderPaused(
                operationID
            )

            let cacheKey =
                try ParagraphCacheIdentity
                    .key(
                        itemID:
                            itemState.id,
                        paragraphIndex:
                            paragraphIndex,
                        paragraphText:
                            paragraph.text,
                        resolved:
                            itemState.resolved,
                        runtimeRevision:
                            runtimeRevision,
                        synthesisConfigVersion:
                            ReadAloudNarrationCatalog
                                .synthesisConfigVersion
                    )

            if let cached =
                try await cacheCoordinator
                    .loadParagraph(
                        cacheKey:
                            cacheKey,
                        itemID:
                            itemState.id,
                        paragraphIndex:
                            paragraphIndex,
                        paragraphText:
                            paragraph.text,
                        generationKey:
                            itemState
                                .generationKey,
                        resolved:
                            itemState.resolved,
                        runtimeRevision:
                            runtimeRevision,
                        synthesisConfigVersion:
                            ReadAloudNarrationCatalog
                                .synthesisConfigVersion,
                        sourceRange:
                            paragraph
                                .sourceRange
                    )
            {
                do {
                    try await pipeline.play(
                        audio:
                            cached.audio,
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
                continue
            }

            var capturedSamples:
                [Float] = []
            var capturedSampleRate:
                Int?
            var incompatibleRate =
                false

            do {
                try await pipeline.read(
                    text:
                        paragraph.text,
                    voice: voice,
                    speed:
                        Float(
                            itemState
                                .resolved
                                .speed
                        ),
                    continuous: true,
                    onAudio: {
                        audio in
                        if let current =
                            capturedSampleRate,
                           current
                            != audio.sampleRate
                        {
                            incompatibleRate =
                                true
                        } else {
                            capturedSampleRate =
                                audio.sampleRate
                        }

                        capturedSamples
                            .append(
                                contentsOf:
                                    audio.samples
                            )
                    }
                )
            } catch ReadAloudPipeline
                .PipelineError
                .cancelled {
                try requirePlaybackOperation(
                    operationID
                )
                throw CancellationError()
            }

            guard !incompatibleRate,
                  let sampleRate =
                    capturedSampleRate,
                  sampleRate
                    == ProjectWAVCodec
                        .requiredSampleRate,
                  !capturedSamples
                    .isEmpty
            else {
                throw ProjectStoreError
                    .invalidData(
                        "Kokoro paragraph output was not consistent 24 kHz audio."
                    )
            }

            try requirePlaybackOperation(
                operationID
            )

            do {
                _ = try await cacheCoordinator
                    .storeParagraph(
                        cacheKey:
                            cacheKey,
                        itemID:
                            itemState.id,
                        paragraphIndex:
                            paragraphIndex,
                        paragraphText:
                            paragraph.text,
                        generationKey:
                            itemState
                                .generationKey,
                        resolved:
                            itemState.resolved,
                        runtimeRevision:
                            runtimeRevision,
                        synthesisConfigVersion:
                            ReadAloudNarrationCatalog
                                .synthesisConfigVersion,
                        sourceRange:
                            paragraph
                                .sourceRange,
                        audio:
                            KokoroAudio(
                                samples:
                                    capturedSamples,
                                sampleRate:
                                    sampleRate
                            )
                    )
            } catch {
                lastErrorMessage =
                    Self.message(
                        for: error
                    )
            }
        }
    }

    func finalizeItemIfComplete(
        itemState:
            ProjectRuntimeItemState,
        paragraphs:
            [ReaderParagraph],
        runtimeRevision: String
    ) async throws -> Bool {
        var samples: [Float] = []
        var segments:
            [AudioSegmentMetadata] = []

        for (
            paragraphIndex,
            paragraph
        ) in paragraphs.enumerated() {
            let cacheKey =
                try ParagraphCacheIdentity
                    .key(
                        itemID:
                            itemState.id,
                        paragraphIndex:
                            paragraphIndex,
                        paragraphText:
                            paragraph.text,
                        resolved:
                            itemState.resolved,
                        runtimeRevision:
                            runtimeRevision,
                        synthesisConfigVersion:
                            ReadAloudNarrationCatalog
                                .synthesisConfigVersion
                    )

            guard let cached =
                try await cacheCoordinator
                    .loadParagraph(
                        cacheKey:
                            cacheKey,
                        itemID:
                            itemState.id,
                        paragraphIndex:
                            paragraphIndex,
                        paragraphText:
                            paragraph.text,
                        generationKey:
                            itemState
                                .generationKey,
                        resolved:
                            itemState.resolved,
                        runtimeRevision:
                            runtimeRevision,
                        synthesisConfigVersion:
                            ReadAloudNarrationCatalog
                                .synthesisConfigVersion,
                        sourceRange:
                            paragraph
                                .sourceRange
                    )
            else {
                return false
            }

            let startSample =
                samples.count
            samples.append(
                contentsOf:
                    cached.audio.samples
            )
            let endSample =
                samples.count

            segments.append(
                AudioSegmentMetadata(
                    sourceRange:
                        paragraph
                            .sourceRange,
                    startSeconds:
                        Double(
                            startSample
                        )
                        / Double(
                            ProjectWAVCodec
                                .requiredSampleRate
                        ),
                    endSeconds:
                        Double(
                            endSample
                        )
                        / Double(
                            ProjectWAVCodec
                                .requiredSampleRate
                        )
                )
            )
        }

        guard !samples.isEmpty,
              !segments.isEmpty
        else {
            return false
        }

        let wavData =
            try ProjectWAVCodec
                .encode(
                    samples: samples,
                    sampleRate:
                        ProjectWAVCodec
                            .requiredSampleRate
                )
        let audioRevision =
            ProjectDigest
                .sha256(wavData)
        let duration =
            Double(samples.count)
            / Double(
                ProjectWAVCodec
                    .requiredSampleRate
            )

        let metadata =
            GeneratedAudioMetadata(
                itemID:
                    itemState.id,
                generationKey:
                    itemState
                        .generationKey,
                audioRevision:
                    audioRevision,
                contentRevision:
                    itemState.item
                        .contentRevision,
                voiceID:
                    itemState.resolved
                        .voiceID,
                speed:
                    itemState.resolved
                        .speed,
                runtimeRevision:
                    runtimeRevision,
                synthesisConfigVersion:
                    ReadAloudNarrationCatalog
                        .synthesisConfigVersion,
                durationSeconds:
                    duration,
                segments:
                    segments
            )

        try await persistence
            .commitGeneratedAudio(
                wavData: wavData,
                metadata: metadata
            )

        return true
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
        let audio =
            try ProjectWAVCodec
                .decode(
                    asset.wavData
                )
        let duration =
            asset.metadata
                .durationSeconds
        let clampedStart =
            min(
                duration,
                max(
                    0,
                    startSeconds
                )
            )

        if clampedStart
            >= duration {
            return
        }

        let startSample =
            min(
                audio.samples.count,
                max(
                    0,
                    Int(
                        (
                            clampedStart
                            * Double(
                                audio.sampleRate
                            )
                        )
                        .rounded(.down)
                    )
                )
            )

        guard startSample
            < audio.samples.count
        else {
            return
        }

        let actualStart =
            Double(startSample)
            / Double(
                audio.sampleRate
            )
        let sliced =
            KokoroAudio(
                samples:
                    Array(
                        audio.samples[
                            startSample...
                        ]
                    ),
                sampleRate:
                    audio.sampleRate
            )

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
            try await pipeline.play(
                audio: sliced,
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
        activity.activeItemID =
            itemState.id
        activity.currentParagraphRange =
            segment.sourceRange
        activity.currentParagraphIndex =
            paragraphIndex
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
        operationID: UUID
    ) async throws {
        let itemLength =
            max(
                1,
                itemState.item
                    .text.utf16.count
            )
        let itemProgress =
            min(
                1,
                max(
                    0,
                    Double(
                        paragraph
                            .sourceRange
                            .startUTF16
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
                    paragraph
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
                            paragraph
                                .sourceRange
                                .startUTF16
                    ),
                audioPosition: nil,
                projectProgress:
                    projectProgress,
                lastPlayedAt: .now
            )

        try await persistence
            .updatePlayback(
                playback
            )
        try requirePlaybackOperation(
            operationID
        )

        project?.playback =
            playback
        activity.activeItemID =
            itemState.id
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
        ProjectSystemMediaController
            .shared
            .publish(self)
    }

    private func projectProgress(
        itemID: UUID,
        offsetUTF16: Int
    ) -> Double {
        let totalLength =
            itemStates.reduce(0) {
                $0 + max(
                    1,
                    $1.item
                        .text.utf16.count
                )
            }
        guard totalLength > 0
        else {
            return 0
        }

        var consumed = 0
        for state in itemStates {
            let length =
                max(
                    1,
                    state.item
                        .text.utf16.count
                )

            if state.id == itemID {
                consumed += min(
                    max(
                        offsetUTF16,
                        0
                    ),
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
                Double(consumed)
                    / Double(
                        totalLength
                    )
            )
        )
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

    private func readerTimeline()
        -> [ReaderTimedPlaybackPosition]
    {
        var timeline:
            [ReaderTimedPlaybackPosition] =
                []

        for state in itemStates {
            for paragraph
                in ReaderTextLayout
                    .paragraphs(
                        in:
                            state.item.text
                    )
            {
                timeline.append(
                    ReaderTimedPlaybackPosition(
                        itemID:
                            state.id,
                        paragraph:
                            paragraph,
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

        guard playbackOperationID
                == operationID
        else {
            throw CancellationError()
        }
    }
}

private nonisolated struct ReaderTimedPlaybackPosition {
    let itemID: UUID
    let paragraph: ReaderParagraph
    let durationSeconds: Double
}
