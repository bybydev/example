import Foundation
import JobQueue
import KokoroTTS

@MainActor
extension ProjectRuntime {
    func executeQueuedGeneration(
        jobID: UUID,
        itemID: UUID,
        generationKey: String,
        progress: JobProgressReporter
    ) async throws {
        try requireGenerationCanRun()

        guard let state =
                itemState(itemID)
        else {
            throw ProjectStoreError
                .invalidData(
                    "Queued generation item is unavailable."
                )
        }

        guard state.generationKey
                == generationKey
        else {
            throw ProjectStoreError
                .invalidData(
                    "Queued generation is stale because narration settings changed."
                )
        }

        let paragraphs =
            ReaderTextLayout.paragraphs(
                in: state.item.text
            )
        guard !paragraphs.isEmpty else {
            throw ProjectStoreError
                .invalidData(
                    "Queued generation item has no readable text."
                )
        }

        guard let voice =
                KokoroEngine.Voice.all
                    .first(where: {
                        $0.id
                            == state.resolved
                                .voiceID
                    })
        else {
            throw KokoroEngine
                .EngineError
                .unsupportedVoice(
                    state.resolved.voiceID
                )
        }

        let runtimeRevision =
            try ReadAloudSynthesisContract
                .runtimeRevision()
        let scheduler =
            SpeechChunkScheduler()

        do {
            try await pipeline.engine.load()

            for (
                paragraphIndex,
                paragraph
            ) in paragraphs.enumerated() {
                try requireGenerationCanRun()

                let cacheKey =
                    try ParagraphCacheIdentity
                        .key(
                            itemID: itemID,
                            paragraphIndex:
                                paragraphIndex,
                            paragraphText:
                                paragraph.text,
                            resolved:
                                state.resolved,
                            runtimeRevision:
                                runtimeRevision,
                            synthesisConfigVersion:
                                ReadAloudNarrationCatalog
                                    .synthesisConfigVersion
                        )

                if try await cacheCoordinator
                    .loadParagraph(
                        cacheKey: cacheKey,
                        itemID: itemID,
                        paragraphIndex:
                            paragraphIndex,
                        paragraphText:
                            paragraph.text,
                        generationKey:
                            generationKey,
                        resolved:
                            state.resolved,
                        runtimeRevision:
                            runtimeRevision,
                        synthesisConfigVersion:
                            ReadAloudNarrationCatalog
                                .synthesisConfigVersion,
                        sourceRange:
                            paragraph.sourceRange
                    ) == nil
                {
                    let chunks =
                        scheduler.chunks(
                            for:
                                paragraph.text,
                            speed:
                                Float(
                                    state.resolved
                                        .speed
                                )
                        )

                    guard !chunks.isEmpty else {
                        throw ProjectStoreError
                            .invalidData(
                                "Paragraph generation produced no speech chunks."
                            )
                    }

                    var samples: [Float] = []
                    var sampleRate: Int?

                    for chunk in chunks {
                        try requireGenerationCanRun()

                        let result =
                            try await pipeline
                                .engine
                                .synthesize(
                                    text:
                                        chunk.text,
                                    voice: voice,
                                    speed:
                                        Float(
                                            state.resolved
                                                .speed
                                        ),
                                    maxChunkSeconds:
                                        chunk
                                            .maxChunkSeconds
                                )

                        if let current =
                            sampleRate,
                           current
                            != result.audio
                                .sampleRate
                        {
                            throw ProjectStoreError
                                .invalidData(
                                    "Queued generation produced inconsistent sample rates."
                                )
                        }

                        sampleRate =
                            result.audio.sampleRate
                        samples.append(
                            contentsOf:
                                result.audio.samples
                        )
                    }

                    guard let sampleRate,
                          sampleRate
                            == ProjectWAVCodec
                                .requiredSampleRate,
                          !samples.isEmpty
                    else {
                        throw ProjectStoreError
                            .invalidData(
                                "Queued generation did not produce valid 24 kHz audio."
                            )
                    }

                    _ = try await cacheCoordinator
                        .storeParagraph(
                            cacheKey:
                                cacheKey,
                            itemID:
                                itemID,
                            paragraphIndex:
                                paragraphIndex,
                            paragraphText:
                                paragraph.text,
                            generationKey:
                                generationKey,
                            resolved:
                                state.resolved,
                            runtimeRevision:
                                runtimeRevision,
                            synthesisConfigVersion:
                                ReadAloudNarrationCatalog
                                    .synthesisConfigVersion,
                            sourceRange:
                                paragraph.sourceRange,
                            audio:
                                KokoroAudio(
                                    samples:
                                        samples,
                                    sampleRate:
                                        sampleRate
                                )
                        )
                }

                await progress.report(
                    fractionCompleted:
                        Double(
                            paragraphIndex + 1
                        )
                        / Double(
                            paragraphs.count
                        ),
                    message:
                        "Preparing \(paragraphIndex + 1) of \(paragraphs.count)"
                )
            }

            try requireGenerationCanRun()

            guard try await
                finalizeItemIfComplete(
                    itemState: state,
                    paragraphs:
                        paragraphs,
                    runtimeRevision:
                        runtimeRevision
                )
            else {
                throw ProjectStoreError
                    .invalidData(
                        "Queued generation could not finalize the complete item."
                    )
            }

            await progress.report(
                fractionCompleted: 1,
                message: "Ready Offline"
            )
        } catch KokoroEngine
            .EngineError.cancelled
        {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        }
    }

    func generationJobStarted(
        _ jobID: UUID
    ) async {
        do {
            _ = try await persistence
                .updateGenerationJob(
                    jobID: jobID,
                    state: .generating,
                    incrementAttempt: true
                )
            try await refresh()
        } catch {
            lastErrorMessage =
                Self.message(for: error)
        }
    }

    func generationJobYielded(
        _ jobID: UUID
    ) async {
        do {
            _ = try await persistence
                .updateGenerationJob(
                    jobID: jobID,
                    state: .queued
                )
            try await refresh()
        } catch {
            lastErrorMessage =
                Self.message(for: error)
        }
    }

    func generationJobCompleted(
        _ jobID: UUID
    ) async {
        do {
            _ = try await persistence
                .updateGenerationJob(
                    jobID: jobID,
                    state: .completed
                )
            try await refresh()
        } catch {
            lastErrorMessage =
                Self.message(for: error)
        }
    }

    func generationJobFailed(
        _ jobID: UUID,
        message: String
    ) async {
        do {
            _ = try await persistence
                .updateGenerationJob(
                    jobID: jobID,
                    state: .failed,
                    errorMessage: message
                )
            try await refresh()
        } catch {
            lastErrorMessage =
                Self.message(for: error)
        }
    }

    func enqueueSelectedGeneration(
        itemIDs: Set<UUID>,
        regenerate: Bool
    ) async throws {
        let requests =
            itemStates.compactMap {
                state
                -> ProjectGenerationRequest?
                in
                guard itemIDs.contains(
                    state.id
                ) else {
                    return nil
                }

                if !regenerate,
                   state.generationStatus
                    .state
                    == .readyOffline
                {
                    return nil
                }

                return ProjectGenerationRequest(
                    itemID: state.id,
                    generationKey:
                        state.generationKey
                )
            }

        guard !requests.isEmpty else {
            return
        }

        try await persistence
            .enqueueGeneration(
                requests,
                replaceExisting:
                    regenerate
            )
        try await refresh()
    }

    func enqueueAllGeneration()
        async throws
    {
        try await enqueueSelectedGeneration(
            itemIDs:
                Set(itemStates.map(\.id)),
            regenerate: false
        )
    }

    func cancelGeneration(
        itemIDs: Set<UUID>
    ) async throws {
        _ = try await persistence
            .removeGenerationJobs(
                itemIDs: itemIDs,
                states: [
                    .queued,
                    .generating,
                ]
            )
        try await refresh()
    }

    func retryGeneration(
        itemIDs: Set<UUID>
    ) async throws {
        _ = try await persistence
            .removeGenerationJobs(
                itemIDs: itemIDs,
                states: [
                    .failed,
                    .queued,
                    .generating,
                ]
            )

        let requests =
            itemStates.compactMap {
                state
                -> ProjectGenerationRequest?
                in
                guard itemIDs.contains(
                    state.id
                ) else {
                    return nil
                }

                return ProjectGenerationRequest(
                    itemID: state.id,
                    generationKey:
                        state.generationKey
                )
            }

        try await persistence
            .enqueueGeneration(
                requests,
                replaceExisting: false
            )
        try await refresh()
    }

    func clearCacheAndRegenerate(
        itemIDs: Set<UUID>
    ) async throws {
        guard !itemIDs.isEmpty else {
            return
        }

        queueController
            .setPlaybackActive(true)

        defer {
            queueController
                .setPlaybackActive(
                    blocksQueuedGeneration
                )
        }

        if let activeItemID =
                activity.activeItemID,
           itemIDs.contains(
                activeItemID
           )
        {
            await persistPlaybackCheckpoint()
            stopPlayback()
            queueController
                .setPlaybackActive(true)
        }

        let requests =
            itemStates.compactMap {
                state
                -> ProjectGenerationRequest?
                in
                guard itemIDs.contains(
                    state.id
                ) else {
                    return nil
                }
                return ProjectGenerationRequest(
                    itemID: state.id,
                    generationKey:
                        state.generationKey
                )
            }

        try await persistence
            .clearGeneratedAudio(
                itemIDs: itemIDs
            )
        try await cacheCoordinator
            .clearParagraphCache(
                itemIDs: itemIDs
            )
        try await persistence
            .enqueueGeneration(
                requests,
                replaceExisting: true
            )
        try await refresh()
    }

    func schedulePrefetch(
        after itemID: UUID
    ) async {
        guard !prefetchScheduledItemIDs
            .contains(itemID),
              let currentIndex =
                itemStates.firstIndex(
                    where: {
                        $0.id == itemID
                    }
                )
        else {
            return
        }

        prefetchScheduledItemIDs.insert(
            itemID
        )

        let upperBound =
            min(
                itemStates.count,
                currentIndex + 3
            )
        guard currentIndex + 1
                < upperBound
        else {
            return
        }

        let requests =
            itemStates[
                (currentIndex + 1)
                    ..< upperBound
            ]
            .compactMap {
                state
                -> ProjectGenerationRequest?
                in
                switch state
                    .generationStatus.state
                {
                case .readyOffline,
                     .generating,
                     .waiting:
                    return nil
                case .notGenerated,
                     .needsAttention:
                    return ProjectGenerationRequest(
                        itemID:
                            state.id,
                        generationKey:
                            state.generationKey
                    )
                }
            }

        guard !requests.isEmpty else {
            return
        }

        do {
            try await persistence
                .enqueueGeneration(
                    requests,
                    replaceExisting:
                        false
                )
            try await refresh()
        } catch {
            lastErrorMessage =
                Self.message(for: error)
        }
    }

    private func requireGenerationCanRun()
        throws
    {
        try Task.checkCancellation()

        guard !blocksQueuedGeneration
        else {
            throw CancellationError()
        }
    }
}
