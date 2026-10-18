import Foundation
import PDFKitAudio

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

    func loadParsedOutput() async throws -> ParsedImportCache? {
        try await store.loadParsedOutput(projectID: projectID)
    }

    func parsedOutputSource() async throws -> ParsedOutputSource {
        try await store.parsedOutputSource(projectID: projectID)
    }

    func saveParsedOutput(_ cache: ParsedImportCache) async throws {
        try await store.saveParsedOutput(projectID: projectID, cache: cache)
    }

    func retainedPDFSourceURL() async throws -> URL {
        try await store.retainedPDFSourceURL(projectID: projectID)
    }

    func updatePDFReadingPolicy(
        _ policy: PdfReadingPolicy,
        parsedCache: ParsedImportCache? = nil
    ) async throws -> ProjectDocument {
        try await store.updatePDFReadingPolicy(
            projectID: projectID,
            policy: policy,
            parsedCache: parsedCache
        )
    }

    func loadCompatibleFinalAudio(
        request: ProjectGenerationStatusRequest
    ) async throws -> ProjectFinalAudioAsset? {
        try await store.loadCompatibleFinalAudio(
            projectID: projectID,
            request: request
        )
    }

    func reclaimFinalizedChunks(
        request: ProjectGenerationStatusRequest, expectedAudioRevision: String,
        chunks: [ChunkAudioRequest]
    ) async throws {
        _ = try await store.reclaimFinalizedChunks(
            projectID: projectID, request: request,
            expectedAudioRevision: expectedAudioRevision, chunks: chunks
        )
    }

    func commitGeneratedAudio(
        wavURL: URL,
        metadata: GeneratedAudioMetadata
    ) async throws {
        try await store.commitGeneratedAudio(
            projectID: projectID,
            wavURL: wavURL,
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

    func recoverGenerationQueue(
        generationKeys: [UUID: String]? = nil,
        readyOfflineItemIDs: Set<UUID> = []
    ) async throws -> ProjectQueueDocument
    {
        try await store
            .recoverGenerationQueue(
                projectID: projectID,
                generationKeys: generationKeys,
                readyOfflineItemIDs: readyOfflineItemIDs
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

    func generationState(
        requests: [ProjectGenerationStatusRequest]
    ) async throws -> (queue: ProjectQueueDocument, statuses: [UUID: ProjectItemGenerationStatus]) {
        try await store.generationState(projectID: projectID, requests: requests)
    }
}


