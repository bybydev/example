import Foundation
import InkribeCore
import JobQueue
import Observation

struct ExportJob: Job {
    typealias Payload = InkribeCore.ExportRequest
    static let maxConcurrentExecutions = 1
    let id: UUID
    let payload: Payload
    var title: String? { payload.profile.format == .mp4 ? "Captioned video export" : "Edited subtitle export" }
    var priority: JobPriority { .userInitiated }

    func execute(progress: JobProgressReporter) async throws {
        await progress.report(message: "Waiting for processing capacity…")
        try await ProcessingRuntime.shared.run {
            try await render(progress: progress)
        }
    }

    private func render(progress: JobProgressReporter) async throws {
        let repository = ProjectRepository.shared
        do {
            let request = try await repository.frozenExport(id)
            guard request.manifest.document.id == payload.projectID,
                  request.manifest.profile == payload.profile else { throw ExportError.invalidRequest }
            try await repository.removeExportPartial(id)
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: request.outputURL.path) {
                // A crash may occur after atomic publication but before the queue
                // records success. Validate and acknowledge that same artifact.
                if payload.profile.format == .mp4 {
                    let canvas = try payload.profile.resolution.canvas(for: request.manifest.document.canvas)
                    // Source pins may already have been released. The original
                    // write verified actual intersecting audio, not just counts.
                    try await MP4Exporter.validate(url: request.outputURL, document: request.manifest.document,
                                                     canvas: canvas, expectAudio: nil)
                } else {
                    let size = try request.outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size > 0 else { throw ExportError.invalidOutput }
                }
            } else if payload.profile.format == .mp4 {
                try await MP4Exporter.write(request, progress: progress)
            } else {
                try await SRTExporter.write(CaptionSnapshot(request.manifest.document),
                                               to: request.partialURL, progress: progress)
            }
            try Task.checkCancellation()
            await progress.report(fractionCompleted: 0.99, message: "Publishing export…")
            try await repository.publishExport(id)
            await progress.report(fractionCompleted: 1, message: "Ready to save or share")
        } catch {
            try? await repository.removeExportPartial(id)
            // Pause/cancel wins over an AVFoundation error caused by shutdown.
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }
}

struct ExportArtifact: Identifiable, Sendable {
    let id: UUID
    let projectID: UUID?
    let title: String
    let revision: UInt64?
    let profile: ExportProfile?
    let outputURL: URL?
    let bytes: Int64
    let issue: String?
    let createdAt: Date?
    let duration: MediaTime?
    let outputBytes: Int64?
}

/// Stable per-job requests/results. Nothing is evicted to admit a newer export.
@MainActor
@Observable
final class ExportController {
    nonisolated static let retainedRecordLimit = 100
    private let access: ProAccess
    private let lifecycle: ProcessingLifecycle
    private let registry = JobRegistry()
    private let repository = ProjectRepository.shared
    private var startup: Task<Void, Never>?
    private var ready = false
    private var registered = false
    private var queueStarted = false
    private(set) var queue: JobQueue?
    private(set) var startupError: String?
    private(set) var isPreparing = false
    private(set) var artifacts: [UUID: ExportArtifact] = [:]
    private(set) var inventoryError: String?
    private(set) var deliveryTokens: [UUID: UUID] = [:]
    private(set) var mutatingIDs: Set<UUID> = []
    private var inventoryGeneration = 0

    init(access: ProAccess, lifecycle: ProcessingLifecycle) {
        self.access = access
        self.lifecycle = lifecycle
    }

    var persistenceError: String? { startupError ?? queue?.persistenceIssue?.errorDescription }
    var isDelivering: Bool { !deliveryTokens.isEmpty }
    var orphanedArtifacts: [ExportArtifact] {
        artifacts.values.filter { queue?.records[$0.id] == nil }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    func isDelivering(_ id: UUID) -> Bool { deliveryTokens.values.contains(id) }

    func start() async {
        if let startup { await startup.value; return }
        guard !ready else { return }
        let task = Task { await initialize() }
        startup = task
        await task.value
        startup = nil
    }

    private func initialize() async {
        do {
            if !registered {
                try registry.register(ExportJob.self)
                try registry.register(IOSExportJob.self)
                registered = true
            }
            if queue == nil {
                let root = try FileManager.default.url(for: .applicationSupportDirectory,
                    in: .userDomainMask, appropriateFor: nil, create: true)
                    .appendingPathComponent("InkribeIOSProcessing", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let value = JobQueue(fileURL: root.appendingPathComponent("export-jobs.json"),
                    policy: JobQueuePolicy(maxConcurrentExecutions: 1), registry: registry,
                    maxRecords: Self.retainedRecordLimit, autoCleanupEnabled: false)
                value.eventHandler = { [weak self] event in
                    switch event {
                    case .jobCompleted, .jobFailed, .jobCancelled:
                        Task { await self?.refreshArtifacts() }
                    default: break
                    }
                }
                queue = value
            }
            try queue?.start()
            queueStarted = true
            if !lifecycle.canRun { try queue?.pause() }
            ready = true
            startupError = nil
            // Never delete orphaned requests/results on startup. They may be the
            // only surviving publication after a crash or queue-file recovery.
            await refreshArtifacts()
        } catch {
            startupError = error.localizedDescription
            await refreshArtifacts()
        }
    }

    func retryStorage() async {
        do {
            if let queue, queueStarted { try queue.perform(.retryPersistence) }
            ready = false
            await start()
            applyLifecycle()
        } catch { startupError = error.localizedDescription }
    }

    func applyLifecycle() {
        guard ready, let queue else { return }
        do {
            if lifecycle.canRun { try queue.resume() } else { try queue.pause() }
        } catch { startupError = error.localizedDescription }
    }

    @discardableResult
    func enqueue(document: ProjectDocument, profile: ExportProfile) async throws -> UUID {
        guard !isPreparing else { throw ExportError.busy }
        isPreparing = true
        defer { isPreparing = false }
        await start()
        await access.refreshForRequest()
        if profile.format == .mp4 && profile.resolution == .fullHD { try access.require(.fullHD) }
        guard lifecycle.error == nil, ready, persistenceError == nil, let queue else { throw ExportError.invalidRequest }
        // This is a bounded local retention store, not a purchase/active-job quota.
        guard queue.records.count < Self.retainedRecordLimit else { throw ProcessingError.retentionFull }
        let id = UUID()
        try await repository.prepareExport(document: document, profile: profile, id: id)
        do {
            try Task.checkCancellation()
            guard lifecycle.error == nil, persistenceError == nil else { throw ExportError.invalidRequest }
            try queue.enqueue(ExportJob(id: id, payload: .init(projectID: document.id, profile: profile)))
        } catch {
            // A failed cleanup stays discoverable in retained requests on refresh.
            try? await repository.discardExport(id)
            await refreshArtifacts()
            throw error
        }
        await refreshArtifacts()
        return id
    }

    func cancel(_ id: UUID) throws { try queue?.cancel(id: id) }

    func retry(_ id: UUID) throws {
        guard lifecycle.error == nil, persistenceError == nil, let queue,
              let record = queue.records[id], record.status.isRetryable,
              !mutatingIDs.contains(id), !isDelivering(id) else { throw ExportError.busy }
        // Accepted frozen input is reused, including after an entitlement change.
        try queue.retry(id: id)
    }

    func recover(_ id: UUID) async throws {
        guard ready, lifecycle.error == nil, persistenceError == nil, let queue,
              queue.records[id] == nil, !mutatingIDs.contains(id), !isDelivering(id) else { throw ExportError.busy }
        guard queue.records.count < Self.retainedRecordLimit else { throw ProcessingError.retentionFull }
        mutatingIDs.insert(id)
        defer { mutatingIDs.remove(id) }
        let request = try await repository.frozenExport(id)
        guard persistenceError == nil, queue.records[id] == nil else { throw ExportError.busy }
        try queue.enqueue(ExportJob(id: id, payload: .init(
            projectID: request.manifest.document.id, profile: request.manifest.profile)))
        await refreshArtifacts()
    }

    /// Record removal preserves the frozen request/result, visible in Retained files.
    func removeRecord(_ id: UUID) throws {
        guard let queue, let record = queue.records[id], record.status.isTerminal,
              !queue.executingJobIDs.contains(id), !mutatingIDs.contains(id) else { throw ExportError.busy }
        try queue.remove(id: id)
    }

    /// Explicit file deletion removes just this job's inputs/result and its record.
    func discard(_ id: UUID) async throws {
        guard ready, persistenceError == nil, let queue, !mutatingIDs.contains(id), !isDelivering(id),
              !queue.executingJobIDs.contains(id), queue.records[id]?.status.isTerminal != false else { throw ExportError.busy }
        mutatingIDs.insert(id)
        defer { mutatingIDs.remove(id) }
        // Persist removal first. If deletion fails, the intact orphan remains
        // visible and removable; no active request can begin using its sources.
        try queue.remove(id: id)
        do { try await repository.discardExport(id) }
        catch { await refreshArtifacts(); throw error }
        await refreshArtifacts()
    }

    func refreshArtifacts() async {
        inventoryGeneration += 1
        let generation = inventoryGeneration
        do {
            let values = try await repository.exportArtifacts()
            guard generation == inventoryGeneration else { return }
            artifacts = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
            inventoryError = nil
        } catch {
            guard generation == inventoryGeneration else { return }
            inventoryError = error.localizedDescription
        }
    }

    /// A lease pins this exact immutable URL through native completion/cancel.
    func beginDelivery(_ id: UUID) throws -> (token: UUID, url: URL) {
        guard !mutatingIDs.contains(id),
              (queue?.records[id] == nil || queue?.records[id]?.status == .completed),
              let url = artifacts[id]?.outputURL else { throw ExportError.invalidOutput }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? 0) > 0 else { throw ExportError.invalidOutput }
        let token = UUID()
        deliveryTokens[token] = id
        return (token, url)
    }
    func endDelivery(_ token: UUID) { deliveryTokens.removeValue(forKey: token) }
}
