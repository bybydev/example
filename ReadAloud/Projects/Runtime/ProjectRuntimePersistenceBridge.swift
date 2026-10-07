import Foundation

nonisolated struct ProjectRuntimePersistenceBridge: Sendable {
    let projectID: UUID
    let store: ProjectStore

    func storageBreakdown()
        async throws -> ProjectStorageBreakdown
    {
        try await store
            .storageBreakdown(
                projectID: projectID
            )
    }

    func clearTemporaryCache()
        async throws
    {
        _ = try await store
            .clearTemporaryCache(
                projectID: projectID
            )
    }

    func load() async throws -> LoadedProject {
        try await store.loadProject(projectID: projectID)
    }

    func loadCompatibleFinalAudio(
        request: ProjectGenerationStatusRequest
    ) async throws -> ProjectFinalAudioAsset? {
        try await store.loadCompatibleFinalAudio(
            projectID: projectID,
            request: request
        )
    }

    func commitGeneratedAudio(
        wavData: Data,
        metadata: GeneratedAudioMetadata
    ) async throws {
        try await store.commitGeneratedAudio(
            projectID: projectID,
            wavData: wavData,
            metadata: metadata
        )
    }

    func updatePlayback(
        _ playback: ProjectPlaybackState?
    ) async throws {
        _ = try await store.updatePlayback(
            projectID: projectID,
            playback: playback
        )
    }

    func updateProjectSettings(
        _ settings: ProjectNarrationSettings
    ) async throws {
        _ = try await store.updateSettings(
            projectID: projectID,
            settings: settings
        )
    }

    func updateItemSettings(
        itemID: UUID,
        settings: ItemNarrationSettings
    ) async throws {
        _ = try await store.updateContentItemSettings(
            projectID: projectID,
            itemID: itemID,
            settings: settings
        )
    }

    func recoverGenerationQueue()
        async throws -> ProjectQueueDocument
    {
        try await store
            .recoverGenerationQueue(
                projectID: projectID
            )
    }

    func updateGenerationJob(
        jobID: UUID,
        state: GenerationJobState,
        incrementAttempt: Bool = false,
        errorMessage: String? = nil
    ) async throws -> ProjectQueueDocument {
        try await store.updateGenerationJob(
            projectID: projectID,
            jobID: jobID,
            state: state,
            incrementAttempt:
                incrementAttempt,
            errorMessage:
                errorMessage
        )
    }

    func removeGenerationJobs(
        itemIDs: Set<UUID>,
        states: Set<GenerationJobState>? = nil
    ) async throws -> ProjectQueueDocument {
        try await store.removeGenerationJobs(
            projectID: projectID,
            itemIDs: itemIDs,
            states: states
        )
    }

    func enqueueGeneration(
        _ requests: [ProjectGenerationRequest],
        replaceExisting: Bool
    ) async throws {
        try await store.enqueueGeneration(
            projectID: projectID,
            requests: requests,
            replaceExisting: replaceExisting
        )
    }

    func clearGeneratedAudio(
        itemIDs: Set<UUID>
    ) async throws {
        try await store.clearGeneratedAudio(
            projectID: projectID,
            itemIDs: itemIDs
        )
    }

    func rename(to title: String) async throws {
        _ = try await store.renameProject(
            projectID: projectID,
            to: title
        )
    }

    func deleteProject() async throws {
        try await store.deleteProject(projectID: projectID)
    }

    func generationStatuses(
        requests: [ProjectGenerationStatusRequest]
    ) async throws -> [UUID: ProjectItemGenerationStatus] {
        try await store.generationStatuses(
            projectID: projectID,
            requests: requests
        )
    }
}
