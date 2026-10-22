import Foundation
import JobQueue
import Observation

struct IOSExportJob: Job {
    struct Payload: Codable, Sendable {
        let projectID: UUID
        let profile: IOSExportProfile
    }
    static let maxConcurrentExecutions = 1
    let id: UUID
    let payload: Payload
    var title: String? { payload.profile.format == .mp4 ? "Captioned video export" : "Edited subtitle export" }
    var priority: JobPriority { .userInitiated }

    func execute(progress: JobProgressReporter) async throws {
        let repository = IOSProjectRepository.shared
        do {
            let request = try await repository.frozenExport(id)
            guard request.manifest.document.id == payload.projectID,
                  request.manifest.profile == payload.profile else { throw IOSExportError.invalidRequest }
            try await repository.removeExportPartial(id)
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: request.outputURL.path) {
                // A crash may occur after atomic publication but before the queue
                // records success. Validate and acknowledge that same artifact.
                if payload.profile.format == .mp4 {
                    let canvas = try payload.profile.resolution.canvas(for: request.manifest.document.canvas)
                    // Source pins may already have been released. The original
                    // write verified actual intersecting audio, not just counts.
                    try await IOSMP4Exporter.validate(url: request.outputURL, document: request.manifest.document,
                                                     canvas: canvas, expectAudio: nil)
                } else {
                    let size = try request.outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size > 0 else { throw IOSExportError.invalidOutput }
                }
            } else if payload.profile.format == .mp4 {
                try await IOSMP4Exporter.write(request, progress: progress)
            } else {
                try await IOSSRTExporter.write(IOSCaptionSnapshot(request.manifest.document),
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

/// One app-wide, durable export. Keeping one request bounds retained originals
/// and artifacts without adding batch rendering or an export-history product.
@MainActor
@Observable
final class IOSExportController {
    private let access: IOSProAccess
    init(access: IOSProAccess) { self.access = access }
    private(set) var queue: JobQueue?
    private(set) var startupError: String?
    private(set) var isPreparing = false
    private(set) var completedURL: URL?
    private(set) var frozenTitle: String?
    private(set) var frozenRevision: UInt64?
    private(set) var deliveryTokens: Set<UUID> = []
    private let registry = JobRegistry()
    private let repository = IOSProjectRepository.shared
    private var startup: Task<Void, Never>?
    private var ready = false
    private var registered = false
    private var queueStarted = false
    private var foreground = true

    var record: JobRecord? { queue?.sortedRecords.first }
    var isActive: Bool { record.map { !$0.status.isTerminal } ?? false }
    var isDelivering: Bool { !deliveryTokens.isEmpty }
    var persistenceError: String? { startupError ?? queue?.persistenceIssue?.errorDescription }

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
            if !registered { try registry.register(IOSExportJob.self); registered = true }
            if queue == nil {
                let root = try FileManager.default.url(for: .applicationSupportDirectory,
                    in: .userDomainMask, appropriateFor: nil, create: true)
                    .appendingPathComponent("InkribeIOSProcessing", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let value = JobQueue(fileURL: root.appendingPathComponent("export-jobs.json"),
                    policy: JobQueuePolicy(maxConcurrentExecutions: 1), registry: registry,
                    maxRecords: 1, autoCleanupEnabled: false)
                value.eventHandler = { [weak self] event in
                    if case .jobCompleted = event { Task { await self?.refreshArtifact() } }
                }
                queue = value
            }
            try queue?.start()
            queueStarted = true
            if !foreground { try queue?.pause() }
            let ids = Set(queue?.records.keys.map { $0 } ?? [])
            try await repository.removeOrphanedExports(keeping: ids)
            ready = true
            startupError = nil
            await refreshArtifact()
        } catch { startupError = error.localizedDescription }
    }

    func retryStorage() async {
        do {
            // A failed initial rewrite has not published loaded records into
            // memory. Retry start/load rather than saving an empty record set.
            if let queue, queueStarted { try queue.perform(.retryPersistence) }
            ready = false
            await start()
        } catch { startupError = error.localizedDescription }
    }

    func setForeground(_ value: Bool) {
        foreground = value
        guard ready, let queue else { return }
        do {
            if value { try queue.resume() }
            else { try queue.pause() }
        } catch { startupError = error.localizedDescription }
    }

    func enqueue(document: IOSProjectDocument, profile: IOSExportProfile) async throws {
        guard !isPreparing, !isDelivering else { throw IOSExportError.busy }
        isPreparing = true
        defer { isPreparing = false }
        await start()
        await access.refreshForRequest()
        if profile.format == .mp4 && profile.resolution == .fullHD { try access.require(.fullHD) }
        guard ready, persistenceError == nil, let queue else { throw IOSExportError.invalidRequest }
        guard !isActive, !queue.isProcessing else { throw IOSExportError.busy }
        if let old = record {
            try queue.remove(id: old.id)
            completedURL = nil
            try await repository.discardExport(old.id)
        }
        let id = UUID()
        try await repository.prepareExport(document: document, profile: profile, id: id)
        do {
            try Task.checkCancellation()
            try queue.enqueue(IOSExportJob(id: id, payload: .init(projectID: document.id, profile: profile)))
            frozenTitle = document.title
            frozenRevision = document.contentRevision
        } catch {
            try? await repository.discardExport(id)
            throw error
        }
    }

    func cancel() throws {
        if let id = record?.id { try queue?.cancel(id: id) }
    }

    func retry() throws {
        guard !isPreparing, !isDelivering, let record, record.status.isRetryable else { throw IOSExportError.busy }
        try queue?.retry(id: record.id)
    }

    func discard() async throws {
        guard !isPreparing, !isDelivering, !isActive, queue?.isProcessing != true else { throw IOSExportError.busy }
        isPreparing = true
        defer { isPreparing = false }
        if let record {
            try queue?.remove(id: record.id)
            completedURL = nil
            frozenTitle = nil
            frozenRevision = nil
            try await repository.discardExport(record.id)
        }
    }

    func refreshArtifact() async {
        guard let record else { completedURL = nil; return }
        let id = record.id
        do {
            let request = try await repository.frozenExport(id)
            guard self.record?.id == id else { return }
            frozenTitle = request.manifest.document.title
            frozenRevision = request.manifest.document.contentRevision
            completedURL = self.record?.status == .completed
                && FileManager.default.fileExists(atPath: request.outputURL.path) ? request.outputURL : nil
        } catch {
            guard self.record?.id == id else { return }
            completedURL = nil
        }
    }

    /// A document picker/share service/Photos write may read after presentation.
    /// Block replacement and cleanup until the destination has finished with it.
    func beginDelivery() throws -> (token: UUID, url: URL) {
        guard !isPreparing, !isDelivering, record?.status == .completed, let completedURL,
              FileManager.default.fileExists(atPath: completedURL.path) else { throw IOSExportError.invalidOutput }
        let token = UUID()
        deliveryTokens.insert(token)
        return (token, completedURL)
    }
    func endDelivery(_ token: UUID) { deliveryTokens.remove(token) }
}
