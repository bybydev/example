import Foundation
import JobQueue

nonisolated struct ReadAloudGenerationJob: Job {
    nonisolated struct Payload: Codable, Sendable {
        let projectID: UUID
        let itemID: UUID
        let generationKey: String
    }

    static let maxConcurrentExecutions = 1

    let id: UUID
    let payload: Payload

    var title: String? {
        "Generate Offline Audio"
    }

    var detail: String? {
        payload.itemID.uuidString.lowercased()
    }

    var priority: JobPriority {
        .utility
    }

    func execute(
        progress: JobProgressReporter
    ) async throws {
        try await ProjectGenerationExecutionRegistry
            .shared
            .execute(
                jobID: id,
                payload: payload,
                progress: progress
            )
    }
}

@MainActor
final class ProjectGenerationExecutionRegistry {
    static let shared =
        ProjectGenerationExecutionRegistry()

    private final class WeakRuntime {
        weak var value: ProjectRuntime?

        init(_ value: ProjectRuntime) {
            self.value = value
        }
    }

    private var runtimes:
        [UUID: WeakRuntime] = [:]

    func register(
        _ runtime: ProjectRuntime
    ) {
        runtimes[runtime.id] =
            WeakRuntime(runtime)
    }

    func unregister(
        _ runtime: ProjectRuntime
    ) {
        guard runtimes[runtime.id]?
            .value === runtime
        else {
            return
        }
        runtimes.removeValue(
            forKey: runtime.id
        )
    }

    func execute(
        jobID: UUID,
        payload:
            ReadAloudGenerationJob.Payload,
        progress: JobProgressReporter
    ) async throws {
        guard let runtime =
                runtimes[payload.projectID]?
                    .value
        else {
            throw ProjectStoreError
                .projectNotFound(
                    payload.projectID
                )
        }

        try await runtime
            .executeQueuedGeneration(
                jobID: jobID,
                itemID: payload.itemID,
                generationKey:
                    payload.generationKey,
                progress: progress
            )
    }
}
