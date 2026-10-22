import Foundation
import JobQueue
import Observation

struct SpeechJob: Job {
    struct Payload: Codable, Sendable {
        let projectID: UUID
        let expectedRevision: UInt64
        let languageCode: String?
        /// Nil in pre-picker durable jobs: keep their original Small variant.
        var modelID: String? = nil
        /// Nil means accepted before the allowance policy; false is Pro-granted.
        var requiresAllowance: Bool? = nil
        var resolvedModelID: String { modelID ?? SpeechModelCatalog.smallID }
    }
    static let maxConcurrentExecutions = 1
    let id: UUID
    let payload: Payload
    var title: String? { "Transcription" }
    var priority: JobPriority { .userInitiated }

    func execute(progress: JobProgressReporter) async throws {
        guard let executor = SpeechEnvironment.shared.executor else { throw SpeechError.missingModel }
        try await executor.execute(id: id, payload: payload, progress: progress)
    }
}

/// Separate from the Mac job environment: never replace its executor or records.
private final class SpeechEnvironment: @unchecked Sendable {
    static let shared = SpeechEnvironment()
    private let lock = NSLock()
    private var stored: LocalTranscriber?
    var executor: LocalTranscriber? { lock.withLock { stored } }
    func install(_ executor: LocalTranscriber) { lock.withLock { stored = executor } }
}

@MainActor
@Observable
final class TranscriptionController {
    private(set) var queue: JobQueue?
    private(set) var startupError: String?
    private(set) var resultGeneration = 0
    private(set) var allowance: CaptionAllowance?
    private(set) var allowanceError: String?
    private(set) var isAuthorizing = false
    private var needsAllowanceRefresh = false
    let access: ProAccess
    private let registry = JobRegistry()
    private let repository = ProjectRepository.shared
    private var registered = false
    private var queueStarted = false
    private var foreground = true
    let models = SpeechModels()
    var modelAvailable: Bool { models.available }
    var protectedModelIDs: Set<String> {
        Set((queue?.sortedRecords ?? []).filter { !$0.status.isTerminal }.compactMap {
            (try? $0.decode(SpeechJob.self))?.payload.resolvedModelID
        })
    }
    var persistenceError: String? { startupError ?? queue?.persistenceIssue?.errorDescription }

    init(access: ProAccess) { self.access = access }

    private var activeJobIDs: Set<UUID> {
        Set((queue?.sortedRecords ?? []).filter { !$0.status.isTerminal }.map(\.id))
    }

    private func endAuthorization() {
        isAuthorizing = false
        if needsAllowanceRefresh {
            needsAllowanceRefresh = false
            Task { await refreshAllowance() }
        }
    }

    func refreshAllowance() async {
        guard queueStarted, persistenceError == nil else { return }
        guard !isAuthorizing else { needsAllowanceRefresh = true; return }
        isAuthorizing = true
        defer { endAuthorization() }
        do {
            allowance = try await repository.reconcileSpeechAllowance(activeJobIDs: activeJobIDs)
            allowanceError = nil
        } catch { allowanceError = error.localizedDescription }
    }

    func start() {
        models.start()
        guard !queueStarted else { return }
        do {
            if queue == nil {
                let root = try FileManager.default.url(for: .applicationSupportDirectory,
                    in: .userDomainMask, appropriateFor: nil, create: true)
                    .appendingPathComponent("InkribeIOSProcessing", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                if !registered {
                    try registry.register(SpeechJob.self)
                    try registry.register(IOSSpeechJob.self)
                    registered = true
                }
                SpeechEnvironment.shared.install(LocalTranscriber(repository: repository))
                let value = JobQueue(fileURL: root.appendingPathComponent("speech-jobs.json"),
                    policy: JobQueuePolicy(maxConcurrentExecutions: 1), registry: registry,
                    maxRecords: 100, autoCleanupEnabled: true)
                value.eventHandler = { [weak self] event in
                    switch event {
                    case .jobCompleted, .jobFailed, .jobCancelled:
                        self?.resultGeneration += 1
                        Task { await self?.refreshAllowance() }
                    default: break
                    }
                }
                queue = value
            }
            try queue?.start()
            queueStarted = true
            if !foreground { try queue?.pause() }
            startupError = nil
            Task { await refreshAllowance() }
        } catch { startupError = error.localizedDescription }
    }

    func retryStorage() {
        if let queue, queueStarted {
            do {
                try queue.perform(.retryPersistence)
                if foreground { try queue.resume() } else { try queue.pause() }
                startupError = nil
                Task { await refreshAllowance() }
            }
            catch { startupError = error.localizedDescription }
        } else { start() }
    }

    func setForeground(_ value: Bool) {
        foreground = value
        guard queueStarted, let queue else { return }
        do {
            if value { try queue.resume() } else { try queue.pause() }
        } catch { startupError = error.localizedDescription }
    }

    func record(for projectID: UUID) -> JobRecord? {
        // An older active operation must win over a newer terminal record.
        let matching = queue?.sortedRecords.filter {
            (try? $0.decode(SpeechJob.self).payload.projectID) == projectID
        } ?? []
        return matching.first(where: { !$0.status.isTerminal }) ?? matching.first
    }

    func isActive(_ projectID: UUID) -> Bool {
        guard let record = record(for: projectID) else { return false }
        return !record.status.isTerminal
    }

    func enqueue(projectID: UUID, language: String) async throws {
        start()
        guard queueStarted, persistenceError == nil, let queue else { throw ProjectStoreError.unavailableRoot }
        guard !isAuthorizing else { throw SpeechError.busy }
        isAuthorizing = true
        defer { needsAllowanceRefresh = true; endAuthorization() }
        let chosenModelID = models.selectedID
        await access.refreshForRequest()
        await models.refresh()
        guard !models.isRemoving, models.isAvailable(chosenModelID) else { throw SpeechError.missingModel }
        guard !isActive(projectID) else { throw SpeechError.busy }
        let project = try await repository.open(projectID)
        // Recheck after suspension so rapid double taps cannot enqueue duplicates.
        guard !isActive(projectID) else { throw SpeechError.busy }
        guard !models.isRemoving, models.isAvailable(chosenModelID) else { throw SpeechError.missingModel }
        guard project.recognition == nil else { throw SpeechError.alreadyTranscribed }
        let code = SpeechLanguage.codes.contains(language) && language != "auto" ? language : nil
        let id = UUID()
        let free = !access.hasPro
        if free {
            allowance = try await repository.reconcileSpeechAllowance(activeJobIDs: activeJobIDs)
            try await repository.reserveSpeechAllowance(jobID: id, projectID: projectID, revision: project.contentRevision)
        }
        try Task.checkCancellation()
        guard persistenceError == nil else { throw ProjectStoreError.unavailableRoot }
        guard !models.isRemoving, models.isAvailable(chosenModelID) else { throw SpeechError.missingModel }
        try queue.enqueue(SpeechJob(id: id, payload: .init(projectID: projectID,
            expectedRevision: project.contentRevision, languageCode: code, modelID: chosenModelID,
            requiresAllowance: free)))
    }

    func cancel(_ id: UUID) throws { try queue?.cancel(id: id) }

    func retry(_ record: JobRecord, language: String) async throws {
        guard queueStarted, persistenceError == nil, let queue else { throw ProjectStoreError.unavailableRoot }
        guard !isAuthorizing else { throw SpeechError.busy }
        isAuthorizing = true
        defer { needsAllowanceRefresh = true; endAuthorization() }
        let chosenModelID = models.selectedID
        await access.refreshForRequest()
        let previous = try record.decode(SpeechJob.self)
        guard !isActive(previous.payload.projectID) else { throw SpeechError.busy }
        let project = try await repository.open(previous.payload.projectID)
        guard !isActive(project.id) else { throw SpeechError.busy }
        if project.recognition?.id == record.id {
            // Job completion may have failed to persist after document publication.
            try queue.retry(id: record.id)
            return
        }
        guard project.recognition == nil else { throw SpeechError.alreadyTranscribed }
        guard !models.isRemoving, models.isAvailable(chosenModelID) else { throw SpeechError.missingModel }
        let free = !access.hasPro
        if free {
            allowance = try await repository.reconcileSpeechAllowance(activeJobIDs: activeJobIDs)
            try await repository.reserveSpeechAllowance(jobID: record.id, projectID: project.id, revision: project.contentRevision)
        } else {
            try await repository.releaseSpeechAllowance(record.id)
        }
        try Task.checkCancellation()
        guard persistenceError == nil else { throw ProjectStoreError.unavailableRoot }
        guard !models.isRemoving, models.isAvailable(chosenModelID) else { throw SpeechError.missingModel }
        // Explicit retry takes a new document revision only while there are no
        // saved captions to overwrite. Reuse the durable operation identity.
        try queue.replace(id: record.id, with: SpeechJob(id: record.id, payload: .init(
            projectID: project.id, expectedRevision: project.contentRevision,
            languageCode: SpeechLanguage.codes.contains(language) && language != "auto" ? language : nil,
            modelID: chosenModelID, requiresAllowance: free)))
    }
}

enum SpeechLanguage {
    // The same initial language set as the existing Mac catalog, without linking
    // its diarization/persistence pipeline into the iOS target.
    static let codes = ["auto", "en", "vi", "zh", "ja", "ko", "es", "fr", "de", "it", "pt"]
    static func name(_ code: String) -> String {
        code == "auto" ? "Automatic" : (Locale.current.localizedString(forLanguageCode: code) ?? code)
    }
}
