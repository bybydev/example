import Foundation
import JobQueue
import Observation

enum ProcessingKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case transcription, export
    var id: Self { self }
    var title: String { self == .transcription ? "Transcription" : "Export" }
    var icon: String { self == .transcription ? "waveform" : "square.and.arrow.up" }
}

struct ProcessingJobKey: Hashable, Identifiable, Sendable {
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
    var pending: Bool { record.status == .pending }
    var processing: Bool { record.status.isExecuting }
    var failed: Bool { record.status == .failed || record.status == .unrecoverable }
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
        guard record.status == .processing,
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
/// JobQueue admits one transcription and up to three independent exports.
@MainActor
@Observable
final class ProcessingCoordinator {
    let lifecycle: ProcessingLifecycle
    let transcription: TranscriptionController
    let exports: ExportController
    let continuedProcessing = ContinuedProcessing()
    private(set) var acting: Set<ProcessingJobKey> = []

    init(access: ProAccess) {
        let lifecycle = ProcessingLifecycle()
        self.lifecycle = lifecycle
        ProcessingRuntime.shared.configure(lifecycle)
        transcription = TranscriptionController(access: access, lifecycle: lifecycle)
        exports = ExportController(access: access, lifecycle: lifecycle)
        continuedProcessing.configure(self)
        transcription.onQueueEvent = { [weak self] in self?.continuedProcessing.handle($0, kind: .transcription) }
        exports.onQueueEvent = { [weak self] in self?.continuedProcessing.handle($0, kind: .export) }
        transcription.onUserRequestedWork = { [weak self] in self?.userRequestedWork(.transcription) }
        exports.onUserRequestedWork = { [weak self] in self?.userRequestedWork(.export) }
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
    func setForeground(_ value: Bool, recoveringFromBackground: Bool = false) {
        // A temporary inactive/active cycle (system UI, alerts) must not undo
        // cancellation/expiration. Resume automatically only on a real return.
        if value && recoveringFromBackground {
            lifecycle.resumeInterrupted()
            continuedProcessing.didReturnToForeground()
        }
        lifecycle.foreground = value
        applyLifecycle()
    }
    func setPaused(_ value: Bool) throws {
        do { try lifecycle.setUserPaused(value) }
        catch { continuedProcessing.stopAll(); applyLifecycle(); throw error }
        if value {
            continuedProcessing.stopAll()
        } else {
            lifecycle.resumeInterrupted()
            // Explicit Resume is user intent; ordinary foreground recovery is not.
            for kind in ProcessingKind.allCases { continuedProcessing.beginOrExtend(kind) }
        }
        applyLifecycle()
    }
    func retryControlStorage() {
        lifecycle.reload()
        applyLifecycle()
    }
    private func applyLifecycle() {
        if !lifecycle.canTranscribe { ProcessingRuntime.shared.cancelTranscription() }
        if !lifecycle.canExport { ProcessingRuntime.shared.cancelExports() }
        transcription.applyLifecycle()
        exports.applyLifecycle()
    }

    private func userRequestedWork(_ kind: ProcessingKind) {
        lifecycle.resumeInterrupted(kind)
        continuedProcessing.beginOrExtend(kind)
        applyLifecycle()
    }

    func setBackgroundAccess(_ granted: Bool, for kind: ProcessingKind) {
        lifecycle.setBackground(granted, for: kind)
        applyLifecycle()
    }

    func interruptFromSystem(_ kind: ProcessingKind) {
        lifecycle.interrupt(kind)
        applyLifecycle()
    }

    /// A model switch cancels transcription only. Exports keep running
    /// independently; accepted captions and edits are retained.
    func switchSpeechModel(to id: String) async throws {
        guard id != SpeechEngine.shared.activeModelID else { return }
        guard !transcription.models.isRemoving else { throw SpeechError.busy }
        try lifecycle.beginModelSwitch()
        continuedProcessing.stop(.transcription)
        ProcessingRuntime.shared.cancelTranscription()
        transcription.applyLifecycle()
        defer { lifecycle.endModelSwitch(); transcription.applyLifecycle() }
        transcription.start()
        await transcription.waitForAuthorization()
        await transcription.models.cancelDownloadAndWait()
        var cancellationError: Error?
        for entry in entries where entry.id.kind == .transcription &&
            !entry.record.status.isTerminal && entry.record.status != .cancelling {
            do { try transcription.cancel(entry.id.jobID) }
            catch { if cancellationError == nil { cancellationError = error } }
        }
        ProcessingRuntime.shared.cancelTranscription()
        await ProcessingRuntime.shared.waitForTranscriptionIdle()
        if let cancellationError { throw cancellationError }
        guard transcription.persistenceError == nil else {
            throw ProjectStoreError.unavailableRoot
        }
        try await SpeechEngine.shared.activate(id)
        await transcription.models.refresh()
        await transcription.refreshAllowance()
    }

    func can(_ action: ProcessingAction, _ key: ProcessingJobKey) -> Bool {
        guard (key.kind != .transcription || !lifecycle.isSwitchingModel),
              let entry = entry(key), !acting.contains(key),
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
