import Foundation
import JobQueue
import Observation

enum ProcessingKind: String, CaseIterable, Identifiable, Hashable {
    case transcription, export
    var id: Self { self }
    var title: String { self == .transcription ? "Transcription" : "Export" }
    var icon: String { self == .transcription ? "waveform" : "square.and.arrow.up" }
}

struct ProcessingJobKey: Hashable, Identifiable {
    let kind: ProcessingKind
    let jobID: UUID
    var id: Self { self }
}

struct ProcessingEntry: Identifiable {
    let id: ProcessingJobKey
    let record: JobRecord
    let progress: JobProgress?
    var projectID: UUID? {
        switch id.kind {
        case .transcription: (try? record.decode(SpeechJob.self))?.payload.projectID
        case .export: (try? record.decode(ExportJob.self))?.payload.projectID
        }
    }
    var waitingForCapacity: Bool {
        record.status == .processing && progress?.message == "Waiting for processing capacity…"
    }
    var pending: Bool { record.status == .pending || waitingForCapacity }
    var processing: Bool { record.status.isExecuting && !waitingForCapacity }
    var statusTitle: String {
        switch record.status {
        case .pending: "Pending"
        case .processing: progress?.message ?? "Starting…"
        case .pausing: "Pausing…"
        case .cancelling: "Cancelling…"
        case .completed: "Completed"
        case .failed: "Needs retry"
        case .cancelled: "Cancelled"
        case .unrecoverable: "Cannot restore this job"
        }
    }
    var fraction: Double? {
        guard record.status == .processing, !waitingForCapacity,
              let value = progress?.fractionCompleted, value.isFinite else { return nil }
        return min(1, max(0, value))
    }
}

enum ProcessingAction: Equatable { case cancel, retry, removeRecord, discardExport }

enum ProcessingError: LocalizedError {
    case staleAction, retentionFull
    var errorDescription: String? {
        switch self {
        case .staleAction: "This job changed. Review its current status and try again."
        case .retentionFull: "Local export retention is full (100 requests and results). Save the files you need, then delete older local exports in Queue to make room. No saved result was replaced."
        }
    }
}

/// One composition/lifecycle/action owner, preserving both existing queue files.
/// Each queue admits one job; the shared core gate admits one native operation.
@MainActor
@Observable
final class ProcessingCoordinator {
    let lifecycle: ProcessingLifecycle
    let transcription: TranscriptionController
    let exports: ExportController
    private(set) var acting: Set<ProcessingJobKey> = []

    init(access: ProAccess) {
        let lifecycle = ProcessingLifecycle()
        self.lifecycle = lifecycle
        ProcessingRuntime.shared.configure(lifecycle)
        transcription = TranscriptionController(access: access, lifecycle: lifecycle)
        exports = ExportController(access: access, lifecycle: lifecycle)
    }

    var entries: [ProcessingEntry] {
        ProcessingKind.allCases.flatMap { kind in
            let queue = queue(for: kind)
            return (queue?.sortedRecords ?? []).map {
                ProcessingEntry(id: .init(kind: kind, jobID: $0.id), record: $0, progress: queue?.liveProgress[$0.id])
            }
        }.sorted {
            if $0.record.createdAt != $1.record.createdAt { return $0.record.createdAt > $1.record.createdAt }
            return $0.record.id.uuidString < $1.record.id.uuidString
        }
    }
    var activeCount: Int { entries.filter { !$0.record.status.isTerminal }.count }
    var pendingCount: Int { entries.filter(\.pending).count }
    var processingCount: Int { entries.filter(\.processing).count }

    func queue(for kind: ProcessingKind) -> JobQueue? {
        kind == .transcription ? transcription.queue : exports.queue
    }
    func entry(_ key: ProcessingJobKey) -> ProcessingEntry? {
        guard let queue = queue(for: key.kind), let record = queue.records[key.jobID] else { return nil }
        return ProcessingEntry(id: key, record: record, progress: queue.liveProgress[key.jobID])
    }
    func start() async {
        transcription.start()
        await exports.start()
    }
    func setForeground(_ value: Bool) {
        lifecycle.foreground = value
        applyLifecycle()
    }
    func setPaused(_ value: Bool) throws {
        do { try lifecycle.setUserPaused(value) }
        catch { applyLifecycle(); throw error }
        applyLifecycle()
    }
    func retryControlStorage() {
        lifecycle.reload()
        applyLifecycle()
    }
    private func applyLifecycle() {
        if !lifecycle.canRun { ProcessingRuntime.shared.cancelForInterruption() }
        transcription.applyLifecycle()
        exports.applyLifecycle()
    }

    func can(_ action: ProcessingAction, _ key: ProcessingJobKey) -> Bool {
        guard let entry = entry(key), !acting.contains(key),
              queue(for: key.kind)?.persistenceIssue == nil else { return false }
        let executing = queue(for: key.kind)?.executingJobIDs.contains(key.jobID) == true
        switch action {
        case .cancel: return entry.record.status == .pending || entry.record.status == .processing || entry.record.status == .pausing
        case .retry:
            return lifecycle.error == nil && entry.record.status.isRetryable && !executing &&
                (key.kind == .transcription ? !transcription.isAuthorizing : !exports.isDelivering(key.jobID))
        case .removeRecord: return entry.record.status.isTerminal && !executing &&
            (key.kind != .transcription || !transcription.isAuthorizing)
        case .discardExport: return key.kind == .export && entry.record.status.isTerminal && !executing && !exports.isDelivering(key.jobID)
        }
    }

    func perform(_ action: ProcessingAction, _ key: ProcessingJobKey) async throws {
        guard can(action, key), let entry = entry(key) else { throw ProcessingError.staleAction }
        acting.insert(key)
        defer { acting.remove(key) }
        switch (key.kind, action) {
        case (.transcription, .cancel): try transcription.cancel(key.jobID)
        case (.transcription, .retry):
            let request = try entry.record.decode(SpeechJob.self).payload
            try await transcription.retry(entry.record, language: request.languageCode ?? "auto", windowIndices: request.windowIndices)
        case (.transcription, .removeRecord): try await transcription.remove(key.jobID)
        case (.export, .cancel): try exports.cancel(key.jobID)
        case (.export, .retry): try exports.retry(key.jobID)
        case (.export, .removeRecord): try exports.removeRecord(key.jobID)
        case (.export, .discardExport): try await exports.discard(key.jobID)
        default: throw ProcessingError.staleAction
        }
    }

    /// Bulk actions use captured IDs but resolve eligibility again for every job.
    /// Speech retry always passes through model/revision/allowance authorization.
    func performBulk(_ action: ProcessingAction, keys: [ProcessingJobKey]) async -> [String] {
        var failures: [String] = []
        for key in keys {
            if key.kind == .transcription && (action == .retry || action == .removeRecord) {
                await transcription.waitForAuthorization()
            }
            guard can(action, key) else { continue }
            do { try await perform(action, key) }
            catch { failures.append("\(key.kind.title) \(key.jobID.uuidString.prefix(8)): \(error.localizedDescription)") }
        }
        return failures
    }
}
