import BackgroundTasks
import Dispatch
import Foundation
import JobQueue
import Observation

/// System execution leases only. JobQueue still owns jobs, recovery and 1/3
/// concurrency; speech and export grants must never authorize each other.
@MainActor
@Observable
final class ContinuedProcessing {
    enum Notice: Equatable {
        case waiting, unavailable, foregroundRequired, interrupted
        var message: String {
            switch self {
            case .waiting: "Waiting for iOS background access. Keep Inkribe open until it’s ready."
            case .unavailable: "Background processing is unavailable. Keep Inkribe open to finish; saved work is kept."
            case .foregroundRequired: "Video exports need Inkribe open on this device. Export work pauses outside the app and continues when you return."
            case .interrupted: "iOS stopped background processing. Resume in Queue to continue."
            }
        }
    }

    @MainActor private final class Session {
        let identifier: String
        let kind: ProcessingKind
        let usesGPU: Bool
        var task: BGContinuedProcessingTask?
        var jobIDs: Set<UUID> = []
        var finished: Set<UUID> = []
        var failed: Set<UUID> = []
        init(identifier: String, kind: ProcessingKind, usesGPU: Bool) {
            self.identifier = identifier
            self.kind = kind
            self.usesGPU = usesGPU
        }
    }

    @ObservationIgnored private weak var coordinator: ProcessingCoordinator?
    private let scheduler = BGTaskScheduler.shared
    private var sessions: [ProcessingKind: Session] = [:]
    private(set) var notices: [ProcessingKind: Notice] = [:]

    func configure(_ coordinator: ProcessingCoordinator) { self.coordinator = coordinator }

    /// Called only after successful user enqueue/retry/recovery, or explicit
    /// Resume. Never called by launch, scene recovery or a background handler.
    func beginOrExtend(_ kind: ProcessingKind) {
        guard let coordinator, coordinator.lifecycle.foreground,
              !coordinator.lifecycle.userPaused, coordinator.lifecycle.error == nil,
              kind != .transcription || !coordinator.lifecycle.isSwitchingModel,
              let queue = coordinator.queue(for: kind), queue.activeCount > 0,
              queue.persistenceIssue == nil else { return }
        let needsGPU = requiresGPU(kind)
        if let session = sessions[kind] {
            if !needsGPU || session.usesGPU {
                synchronize(session)
                return
            }
            // A new explicit video request upgrades an existing CPU-only export
            // lease. Foreground jobs keep their JobQueue slots and frozen inputs.
            finish(session, success: false, title: "Updating export work")
        }
        guard !needsGPU || BGTaskScheduler.supportedResources.contains(.gpu) else {
            notices[kind] = .foregroundRequired
            return
        }
        guard let bundleID = Bundle.main.bundleIdentifier else {
            notices[kind] = .unavailable
            return
        }
        let identifier = "\(bundleID).queue.\(kind.rawValue)_\(UUID().uuidString)"
        let session = Session(identifier: identifier, kind: kind, usesGPU: needsGPU)
        sessions[kind] = session
        let registered = scheduler.register(forTaskWithIdentifier: identifier, using: DispatchQueue.main) { [weak self] rawTask in
            // BGContinuedProcessingTask is not Sendable. Keep its delivery and
            // lifetime on MainActor instead of passing it through a Task boundary.
            MainActor.assumeIsolated {
                guard let task = rawTask as? BGContinuedProcessingTask, let self else {
                    rawTask.setTaskCompleted(success: false)
                    return
                }
                self.activate(task, kind: kind, identifier: identifier)
            }
        }
        guard registered else {
            sessions[kind] = nil
            notices[kind] = .unavailable
            return
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier,
            title: title(kind), subtitle: "Preparing saved work")
        request.strategy = .queue
        if needsGPU { request.requiredResources = .gpu }
        do {
            try scheduler.submit(request)
            if session.task == nil { notices[kind] = .waiting }
            // The handler, not successful submission, grants background execution.
            // Fast CPU jobs can finish before iOS delivers the handler.
            synchronize(session)
        } catch {
            sessions[kind] = nil
            notices[kind] = .unavailable
            coordinator.setBackgroundAccess(false, for: kind)
        }
    }

    func handle(_ event: JobQueueEvent, kind: ProcessingKind) {
        guard let coordinator else { return }
        guard let session = sessions[kind] else {
            if coordinator.queue(for: kind)?.activeCount == 0 {
                notices[kind] = nil
                coordinator.lifecycle.resumeInterrupted(kind)
            }
            return
        }
        if coordinator.lifecycle.userPaused {
            stop(kind)
            return
        }
        if case .persistenceFailed = event {
            expire(kind, identifier: session.identifier)
            return
        }
        // Never let an existing CPU export lease cover a newly admitted video,
        // even between queue admission and its explicit beginOrExtend callback.
        if !session.usesGPU && requiresGPU(kind) {
            finish(session, success: false, title: "Updating export work")
            return
        }
        synchronize(session)
    }

    func stop(_ kind: ProcessingKind) {
        notices[kind] = nil
        guard let session = sessions[kind] else { return }
        finish(session, success: false, title: "Processing paused")
    }
    func stopAll() { for kind in ProcessingKind.allCases { stop(kind) } }

    func didReturnToForeground() {
        for kind in ProcessingKind.allCases where notices[kind] == .interrupted { notices[kind] = nil }
        // Resume durable work in the foreground without submitting a new lease.
    }

    func explanation(for kind: ProcessingKind) -> String {
        if coordinator?.lifecycle.userPaused == true { return "Processing is paused. Resume in Queue when you’re ready." }
        if let notice = notices[kind] { return notice.message }
        if coordinator?.lifecycle.backgroundKinds.contains(kind) == true {
            return "You can leave Inkribe while this work finishes. If iOS stops processing, reopen the app to continue."
        }
        return "You can leave this sheet. Background processing is requested when you start or resume work; iOS decides whether it can continue outside Inkribe."
    }

    private func requiresGPU(_ kind: ProcessingKind) -> Bool {
        guard kind == .export, let queue = coordinator?.queue(for: kind) else { return false }
        return queue.records.values.contains { record in
            guard !record.status.isTerminal else { return false }
            // Unknown/unreadable export input cannot be assumed CPU-only.
            return (try? record.decode(ExportJob.self).payload.profile.format) != .srt
        }
    }

    private func activate(_ task: BGContinuedProcessingTask, kind: ProcessingKind, identifier: String) {
        guard let session = sessions[kind], session.identifier == identifier else {
            task.setTaskCompleted(success: false)
            return
        }
        guard let coordinator, !coordinator.lifecycle.userPaused,
              coordinator.lifecycle.error == nil,
              coordinator.queue(for: kind)?.persistenceIssue == nil,
              !coordinator.lifecycle.systemPausedKinds.contains(kind),
              kind != .transcription || !coordinator.lifecycle.isSwitchingModel else {
            sessions[kind] = nil
            notices[kind] = .unavailable
            coordinator?.setBackgroundAccess(false, for: kind)
            task.setTaskCompleted(success: false)
            return
        }
        session.task = task
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.expire(kind, identifier: identifier) }
        }
        notices[kind] = nil
        coordinator.setBackgroundAccess(true, for: kind)
        synchronize(session)
    }

    private func synchronize(_ session: Session) {
        guard sessions[session.kind] === session, let queue = coordinator?.queue(for: session.kind) else { return }
        session.jobIDs.formUnion(queue.records.values.filter { !$0.status.isTerminal }.map(\.id))
        for id in session.jobIDs {
            guard let record = queue.records[id] else {
                session.finished.insert(id)
                session.failed.remove(id)
                continue
            }
            if record.status.isTerminal {
                session.finished.insert(id)
                if record.status == .completed { session.failed.remove(id) }
                else { session.failed.insert(id) }
            } else {
                session.finished.remove(id)
                session.failed.remove(id)
            }
        }
        if let task = session.task {
            let total = max(1, Int64(session.jobIDs.count) * 1_000)
            let finished = Int64(session.finished.count) * 1_000
            let active = queue.executingJobIDs.intersection(session.jobIDs).subtracting(session.finished)
            let live = active.reduce(Int64(0)) { sum, id in
                guard let fraction = queue.liveProgress[id]?.fractionCompleted, fraction.isFinite else { return sum }
                return sum + Int64((min(1, max(0, fraction)) * 1_000).rounded())
            }
            task.progress.totalUnitCount = total
            task.progress.completedUnitCount = min(total, max(task.progress.completedUnitCount, finished + live))
            let current = active.compactMap { queue.records[$0] }.max { $0.updatedAt < $1.updatedAt }
            let subtitle = current.flatMap { queue.liveProgress[$0.id]?.message ?? $0.title } ?? "Waiting for saved work"
            task.updateTitle(title(session.kind), subtitle: subtitle)
        }
        if queue.activeCount == 0 {
            finish(session, success: session.failed.isEmpty,
                title: session.failed.isEmpty ? (session.kind == .export ? "Exports ready" : "Captions ready") : "Processing finished with issues")
        }
    }

    private func expire(_ kind: ProcessingKind, identifier: String) {
        guard let session = sessions[kind], session.identifier == identifier else { return }
        // Invalidate before queue.pause emits callbacks. Expiration is not a
        // durable user pause and affects only this system task's queue kind.
        sessions[kind] = nil
        coordinator?.interruptFromSystem(kind)
        notices[kind] = .interrupted
        finish(session, success: false, title: "Processing paused by iOS")
    }

    private func finish(_ session: Session, success: Bool, title: String) {
        if sessions[session.kind] === session { sessions[session.kind] = nil }
        coordinator?.setBackgroundAccess(false, for: session.kind)
        if notices[session.kind] == .waiting { notices[session.kind] = nil }
        guard let task = session.task else {
            scheduler.cancel(taskRequestWithIdentifier: session.identifier)
            return
        }
        task.expirationHandler = nil
        task.updateTitle(title, subtitle: success ? "Saved on this device" : "Open Inkribe to review saved work")
        if success { task.progress.completedUnitCount = task.progress.totalUnitCount }
        let teardown = ProcessingRuntime.shared.teardownBarrier(for: session.kind)
        Task { @MainActor in
            await teardown.value
            session.task?.setTaskCompleted(success: success)
            session.task = nil
        }
    }

    private func title(_ kind: ProcessingKind) -> String {
        kind == .transcription ? "Transcribing captions" : "Creating exports"
    }
}
