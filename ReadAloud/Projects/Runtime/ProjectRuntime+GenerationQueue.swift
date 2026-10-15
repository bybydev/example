import Foundation
import JobQueue

@MainActor
extension ProjectRuntime {
    func executeQueuedGeneration(
        jobID: UUID,
        itemID: UUID,
        generationKey: String,
        progress: JobProgressReporter
    ) async throws {
        try await queueController.executeGeneration { [self] in
            try await chunkCache.withUsage(itemID: itemID) { @MainActor [self] in
                try await runQueuedGeneration(
                    jobID: jobID, itemID: itemID,
                    generationKey: generationKey, progress: progress
                )
            }
        }
    }

    private func runQueuedGeneration(
        jobID: UUID,
        itemID: UUID,
        generationKey: String,
        progress: JobProgressReporter
    ) async throws {
        try requireGenerationCanRun()
        guard let state = itemState(itemID) else {
            throw ProjectStoreError.invalidData("Queued generation item is unavailable.")
        }
        guard state.generationKey == generationKey else {
            throw ProjectStoreError.invalidData(
                "Queued generation is stale because narration settings changed."
            )
        }
        let chunks = SpeechChunkScheduler().chunks(
            for: state.item.text, speed: Float(state.resolved.speed)
        )
        guard !chunks.isEmpty else {
            throw ProjectStoreError.invalidData("Queued generation has no readable text.")
        }
        guard let voice = SpeechVoice.all.first(where: {
            $0.id == state.resolved.voiceID
        }) else {
            throw SpeechEngineError.unsupportedVoice(state.resolved.voiceID)
        }
        let selectedEngine = pipeline.engineKind
        guard selectedEngine == ReadAloudPreferences.speechEngine else {
            throw CancellationError()
        }
        let engine = pipeline.engine
        let runtimeRevision = try ReadAloudSynthesisContract.runtimeRevision()

        do {
            for (index, chunk) in chunks.enumerated() {
                try requireGenerationCanRun(expectedEngine: selectedEngine)
                let request = ChunkAudioRequest(
                    itemID: itemID, index: index, chunk: chunk,
                    generationKey: generationKey,
                    resolved: state.resolved,
                    runtimeRevision: runtimeRevision,
                    synthesisConfigVersion: ReadAloudNarrationCatalog.synthesisConfigVersion
                )
                // Foreground listening and offline generation share this
                // persistent cache and the same coalesced in-flight synthesis.
                _ = try await chunkCache.audio(for: request) {
                    try await engine.load()
                    let result = try await engine.synthesize(
                        text: chunk.text, voice: voice,
                        speed: Float(state.resolved.speed),
                        maxChunkSeconds: chunk.maxChunkSeconds,
                        pronunciationMode: state.pronunciationMode
                    )
                    return result.audio
                }
                try requireGenerationCanRun(expectedEngine: selectedEngine)
                await progress.report(
                    fractionCompleted: Double(index + 1) / Double(chunks.count),
                    message: "Preparing chunk \(index + 1) of \(chunks.count)"
                )
            }

            try requireGenerationCanRun(expectedEngine: selectedEngine)
            guard itemState(itemID)?.generationKey == generationKey,
                  !isApplyingPDFReadingPolicy else {
                throw CancellationError()
            }
            guard try await finalizeItemIfComplete(
                itemState: state,
                paragraphs: cachedReaderParagraphs(for: state.item),
                runtimeRevision: runtimeRevision
            ) else {
                throw ProjectStoreError.invalidData(
                    "Queued generation could not finalize the complete item."
                )
            }
            await progress.report(fractionCompleted: 1, message: "Ready Offline")
        } catch SpeechEngineError.cancelled {
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
            try await refreshGenerationState()
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
            try await refreshGenerationState()
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
            try await refreshGenerationState()
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
            try await refreshGenerationState()
        } catch {
            lastErrorMessage =
                Self.message(for: error)
        }
    }

    func enqueueSelectedGeneration(
        itemIDs: Set<UUID>,
        regenerate: Bool
    ) async throws {
        try prepareExplicitWork()
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
        try await refreshGenerationState()
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
        try prepareExplicitWork()
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

    func clearCacheAndRegenerate(itemIDs: Set<UUID>) async throws {
        try prepareExplicitWork()
        guard !itemIDs.isEmpty else { return }
        try await withAudioInvalidation(itemIDs: itemIDs) {
            let requests = itemStates.compactMap { state -> ProjectGenerationRequest? in
                guard itemIDs.contains(state.id) else { return nil }
                return ProjectGenerationRequest(
                    itemID: state.id, generationKey: state.generationKey
                )
            }
            try await persistence.clearGeneratedAudio(itemIDs: itemIDs)
            try await chunkCache.clear(itemIDs: itemIDs)
            try await cacheCoordinator.clearParagraphCache(itemIDs: itemIDs)
            try await persistence.enqueueGeneration(requests, replaceExisting: true)
            try await refresh()
        }
    }

    func schedulePlaybackPrefetch() {
        guard ProjectGenerationExecutionRegistry.shared.canPerformGeneration,
              ReadAloudPreferences.prefetchCount > 0,
              !isInvalidatingAudio,
              !ReadAloudPreferences.backgroundPrefetchPaused,
              !readerPauseRequested, !synthesisSuspendedForMemoryPressure,
              prefetchTask == nil, let operationID = playbackOperationID,
              let itemID = activity.activeItemID,
              !prefetchScheduledItemIDs.contains(itemID) else { return }
        let requestID = UUID()
        prefetchTaskID = requestID
        prefetchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.prefetchTaskID == requestID {
                    self.prefetchTask = nil
                    self.prefetchTaskID = nil
                }
            }
            guard !Task.isCancelled, self.playbackOperationID == operationID,
                  self.activity.activeItemID == itemID else { return }
            await self.schedulePrefetch(after: itemID)
        }
    }

    func schedulePrefetch(
        after itemID: UUID
    ) async {
        guard ProjectGenerationExecutionRegistry.shared.canPerformGeneration,
              !Task.isCancelled, !synthesisSuspendedForMemoryPressure,
              !ReadAloudPreferences.backgroundPrefetchPaused else { return }

        let prefetchCount =
            ReadAloudPreferences
                .prefetchCount
        guard prefetchCount > 0,
              !prefetchScheduledItemIDs
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

        let upperBound =
            min(
                itemStates.count,
                currentIndex
                    + 1
                    + prefetchCount
            )
        guard currentIndex + 1
                < upperBound
        else {
            prefetchScheduledItemIDs.insert(itemID)
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
            prefetchScheduledItemIDs.insert(itemID)
            return
        }

        do {
            try await persistence
                .enqueueGeneration(
                    requests,
                    replaceExisting:
                        false
                )
            prefetchScheduledItemIDs.insert(itemID)
            try await refreshGenerationState()
        } catch is CancellationError {
            return
        } catch {
            lastErrorMessage =
                Self.message(for: error)
        }
    }

    private func requireGenerationCanRun(
        expectedEngine: SpeechEngineKind? = nil
    ) throws {
        try Task.checkCancellation()
        guard queueController.hasGlobalAdmission,
              ProjectGenerationExecutionRegistry.shared.canPerformGeneration,
              !ReadAloudPreferences.backgroundPrefetchPaused else { throw CancellationError() }
        guard !isApplyingPDFReadingPolicy,
              !blocksQueuedGeneration,
              pipeline.engineKind == ReadAloudPreferences.speechEngine,
              expectedEngine == nil || pipeline.engineKind == expectedEngine else {
            throw CancellationError()
        }
    }
}



