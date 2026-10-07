import Foundation

nonisolated struct ProjectRuntimePersistenceBridge: Sendable {
    let projectID: UUID
    let store: ProjectStore

    func load() async throws -> LoadedProject {
        try await store.loadProject(projectID: projectID)
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
