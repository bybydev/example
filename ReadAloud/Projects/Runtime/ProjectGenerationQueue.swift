import Foundation
import JobQueue

/// Transient presentation of durable chapter requests, overlaid with live
/// executor progress by the runtime manager. These are never persisted.
nonisolated struct OfflineGenerationQueueRow: Identifiable, Sendable {
    let job: GenerationJobRecord
    let title: String
    var isProcessing = false
    var progress: JobProgress?
    var waitingReason = "Waiting to restore queued work"

    var id: UUID { job.id }
    var statusMessage: String {
        isProcessing ? (progress?.message ?? "Preparing offline audio…") : waitingReason
    }
}

nonisolated struct OfflineGenerationQueueBook: Identifiable, Sendable {
    let project: ProjectSnapshot
    let artworkURL: URL?
    var rows: [OfflineGenerationQueueRow]

    var id: UUID { project.id }
}

nonisolated struct OfflineGenerationQueueSnapshot: Sendable {
    var books: [OfflineGenerationQueueBook] = []
    var issues: [String] = []
}

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

/// Admission for separate offline jobs, recovery and housekeeping. Live
/// read-ahead uses its own 20-chunk bound even while playback is paused.
/// Preparation/buffering count as listening intent; paused/stopped sessions do not.
nonisolated enum GenerationActivityPolicy {
    static func allowsWork(isApplicationActive: Bool, hasListeningIntent: Bool) -> Bool {
        isApplicationActive || hasListeningIntent
    }
}

/// Scheduling policy is independent of JobQueue's per-project concurrency.
/// A paused live stream still owns speech priority; compatible file playback
/// can share time with offline work when the user's preference permits it.
nonisolated struct GenerationAdmissionCandidate: Sendable {
    let projectID: UUID
    let oldestJob: Date?
    let isEligible: Bool
    let requiresPlaybackPriority: Bool
}

nonisolated enum GenerationAdmissionPolicy {
    static func nextProject(
        candidates: [GenerationAdmissionCandidate], paused: Bool
    ) -> UUID? {
        guard !paused, !candidates.contains(where: \.requiresPlaybackPriority) else { return nil }
        return candidates.filter { $0.isEligible && $0.oldestJob != nil }
            .min {
                if $0.oldestJob != $1.oldestJob { return $0.oldestJob! < $1.oldestJob! }
                return $0.projectID.uuidString < $1.projectID.uuidString
            }?.projectID
    }
}

@MainActor
final class ProjectGenerationExecutionRegistry {
    static let shared = ProjectGenerationExecutionRegistry()

    private final class WeakRuntime {
        weak var value: ProjectRuntime?
        init(_ value: ProjectRuntime) { self.value = value }
    }

    private var runtimes: [UUID: WeakRuntime] = [:]
    private var retiringControllers: [ProjectQueueController] = []
    private var reconciliationTask: Task<Void, Never>?
    private var revision: UInt64 = 0
    private(set) var isApplicationActive = true

    var canPerformGeneration: Bool {
        GenerationActivityPolicy.allowsWork(
            isApplicationActive: isApplicationActive,
            hasListeningIntent: liveRuntimes.contains { $0.hasListeningIntent }
        )
    }

    func setApplicationActive(_ active: Bool) {
        isApplicationActive = active
        reconcileAdmission()
    }

    func register(_ runtime: ProjectRuntime) {
        runtimes[runtime.id] = WeakRuntime(runtime)
        reconcileAdmission()
    }

    func unregister(_ runtime: ProjectRuntime) {
        guard runtimes[runtime.id]?.value === runtime else { return }
        runtime.queueController.setGlobalAdmission(false)
        // Retain the old controller until the entire cancelled job (including
        // finalization) drains, even when its runtime leaves the manager.
        retiringControllers.append(runtime.queueController)
        runtimes.removeValue(forKey: runtime.id)
        reconcileAdmission()
    }

    private var liveRuntimes: [ProjectRuntime] { runtimes.values.compactMap(\.value) }

    private func nextProject() -> UUID? {
        GenerationAdmissionPolicy.nextProject(
            candidates: liveRuntimes.map { runtime in
                GenerationAdmissionCandidate(
                    projectID: runtime.id,
                    oldestJob: runtime.queueController.queue.jobs
                        .filter { $0.state == .queued || $0.state == .generating }
                        .map(\.createdAt).min(),
                    isEligible: runtime.didLoad && !runtime.blocksQueuedGeneration,
                    requiresPlaybackPriority: runtime.requiresGlobalPlaybackPriority
                )
            },
            paused: ReadAloudPreferences.backgroundPrefetchPaused || !canPerformGeneration
        )
    }

    func reconcileAdmission() {
        revision &+= 1
        let selected = nextProject()
        // Revoke synchronously, before another foreground chunk is requested.
        let listening = liveRuntimes.contains { $0.requiresGlobalPlaybackPriority }
        let allowed = canPerformGeneration
        let activityRevision = revision
        for runtime in liveRuntimes {
            Task { await runtime.chunkCache.setReclamationAllowed(allowed, revision: activityRevision) }
            if !allowed {
                runtime.prefetchTask?.cancel()
                runtime.prefetchTask = nil
                runtime.prefetchTaskID = nil
            }
            let status: String
            if !allowed { status = "Paused while not listening in background" }
            else if ReadAloudPreferences.backgroundPrefetchPaused { status = "Background generation paused" }
            else if listening { status = "Waiting for listening" }
            else if runtime.blocksQueuedGeneration { status = "Waiting for speech resources" }
            else if runtime.id != selected { status = "Waiting for another project" }
            else { status = "Preparing offline audio" }
            runtime.queueController.publishSchedulingStatus(status)
            if runtime.id != selected { runtime.queueController.setGlobalAdmission(false) }
        }
        guard reconciliationTask == nil else { return }
        reconciliationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while true {
                let observedRevision = self.revision
                let selected = self.nextProject()
                let retiring = self.retiringControllers
                self.retiringControllers.removeAll()
                let others = self.liveRuntimes.filter { $0.id != selected }
                for runtime in others { runtime.queueController.setGlobalAdmission(false) }
                for controller in retiring { await controller.cancelAndDrain() }
                for runtime in others { await runtime.queueController.cancelAndDrain() }
                // Changes while draining must be considered before granting.
                if self.revision != observedRevision { continue }
                if let selected, let runtime = self.runtimes[selected]?.value {
                    runtime.queueController.setGlobalAdmission(true)
                }
                self.reconciliationTask = nil
                return
            }
        }
    }

    func drainForPlayback() async {
        // Include retired controllers already captured by the scheduler's
        // current drain, rather than overlooking them after unregister.
        await reconciliationTask?.value
        for runtime in liveRuntimes {
            runtime.queueController.setGlobalAdmission(false)
        }
        for runtime in liveRuntimes { await runtime.queueController.cancelAndDrain() }
        for controller in retiringControllers { await controller.cancelAndDrain() }
    }

    func execute(
        jobID: UUID, payload: ReadAloudGenerationJob.Payload,
        progress: JobProgressReporter
    ) async throws {
        guard let runtime = runtimes[payload.projectID]?.value else {
            throw ProjectStoreError.projectNotFound(payload.projectID)
        }
        try await runtime.executeQueuedGeneration(
            jobID: jobID, itemID: payload.itemID,
            generationKey: payload.generationKey, progress: progress
        )
    }
}

