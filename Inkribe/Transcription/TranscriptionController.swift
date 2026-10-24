import Foundation
import InkribeCore
import JobQueue
import Observation

struct SpeechJob: Job {
    typealias Payload = InkribeCore.TranscriptionRequest
    static let maxConcurrentExecutions = 1
    let id: UUID
    let payload: Payload
    var title: String? { payload.projectTitle ?? "Transcription" }
    var priority: JobPriority { .userInitiated }

    func execute(progress: JobProgressReporter) async throws {
        guard let executor = SpeechEnvironment.shared.executor else { throw SpeechError.missingModel }
        await progress.report(message: "Waiting for processing capacity…")
        try await ProcessingRuntime.shared.run {
            try await executor.execute(id: id, payload: payload, progress: progress)
        }
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
    private var authorizationWaiters: [CheckedContinuation<Void, Never>] = []
    let access: ProAccess
    private let registry = JobRegistry()
    private let repository = ProjectRepository.shared
    private var registered = false
    private var queueStarted = false
    private let lifecycle: ProcessingLifecycle
    let models = SpeechModels()
    var modelAvailable: Bool { models.available }
    var protectedModelIDs: Set<String> {
        Set((queue?.sortedRecords ?? []).filter { !$0.status.isTerminal }.compactMap {
            (try? $0.decode(SpeechJob.self))?.payload.resolvedModelID
        })
    }
    var persistenceError: String? { startupError ?? queue?.persistenceIssue?.errorDescription }

    init(access: ProAccess, lifecycle: ProcessingLifecycle) {
        self.access = access
        self.lifecycle = lifecycle
    }

    private var activeJobIDs: Set<UUID> {
        Set((queue?.sortedRecords ?? []).filter { !$0.status.isTerminal }.map(\.id))
    }

    func waitForAuthorization() async {
        while isAuthorizing {
            await withCheckedContinuation { authorizationWaiters.append($0) }
        }
    }

    private func endAuthorization() {
        isAuthorizing = false
        let waiters = authorizationWaiters
        authorizationWaiters.removeAll()
        waiters.forEach { $0.resume() }
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
                SpeechEnvironment.shared.install(LocalTranscriber(repository: repository, didPublish: { [weak self] in
                    await self?.publishedWindow()
                }))
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
            if !lifecycle.canRun { try queue?.pause() }
            startupError = nil
            Task { await refreshAllowance() }
        } catch { startupError = error.localizedDescription }
    }

    private func publishedWindow() { resultGeneration += 1 }

    func retryStorage() {
        if let queue, queueStarted {
            do {
                try queue.perform(.retryPersistence)
                if lifecycle.canRun { try queue.resume() } else { try queue.pause() }
                startupError = nil
                Task { await refreshAllowance() }
            }
            catch { startupError = error.localizedDescription }
        } else { start() }
    }

    func applyLifecycle() {
        guard queueStarted, let queue else { return }
        do {
            if lifecycle.canRun { try queue.resume() } else { try queue.pause() }
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

    func enqueue(projectID: UUID, language: String, replacingEmptyResultID: UUID? = nil,
                 windowIndices: [Int]? = nil) async throws {
        start()
        guard lifecycle.error == nil, queueStarted, persistenceError == nil, let queue else { throw ProjectStoreError.unavailableRoot }
        guard !isAuthorizing else { throw SpeechError.busy }
        isAuthorizing = true
        defer { needsAllowanceRefresh = true; endAuthorization() }
        var chosenModelID = models.selectedID
        await access.refreshForRequest()
        await models.refresh()
        guard !isActive(projectID) else { throw SpeechError.busy }
        var project = try await repository.open(projectID)
        // Recheck after suspension so rapid double taps cannot enqueue duplicates.
        guard !isActive(projectID) else { throw SpeechError.busy }
        if let replacingEmptyResultID {
            project = try await repository.recoverEmptyRecognition(projectID: projectID,
                recognitionID: replacingEmptyResultID, expectedRevision: project.contentRevision)
            // Refresh the open editor immediately, including when quota/model
            // authorization later fails. Recovery itself is already durable.
            resultGeneration += 1
        }
        let partial = project.recognition.flatMap { $0.isIncomplete ? $0 : nil }
        guard project.recognition == nil || partial != nil else { throw SpeechError.alreadyTranscribed }
        if let partial { chosenModelID = partial.modelID }
        guard !models.isRemoving, models.isAvailable(chosenModelID) else { throw SpeechError.missingModel }
        let code = SpeechLanguage.codes.contains(language) && language != "auto" ? language : nil
        // A terminal job can have aged out of JobQueue's bounded history while
        // its project still owns valid unfinished work. Retain that operation ID.
        let recovery = try await repository.speechRecovery(projectID: projectID)
        let id: UUID
        if let partial {
            guard !queue.sortedRecords.contains(where: { $0.id == partial.id }) else { throw SpeechError.busy }
            id = partial.id
        } else if let recovery, recovery.reusableRevision,
           !queue.sortedRecords.contains(where: { $0.id == recovery.jobID }) {
            id = recovery.jobID
        } else { id = UUID() }
        let free = !access.hasPro
        if free {
            allowance = try await repository.reconcileSpeechAllowance(activeJobIDs: activeJobIDs)
            try await repository.reserveSpeechAllowance(jobID: id, projectID: projectID, revision: project.contentRevision)
        }
        try Task.checkCancellation()
        guard lifecycle.error == nil, persistenceError == nil else { throw ProjectStoreError.unavailableRoot }
        guard !models.isRemoving, models.isAvailable(chosenModelID) else { throw SpeechError.missingModel }
        try queue.enqueue(SpeechJob(id: id, payload: .init(projectID: projectID,
            expectedRevision: project.contentRevision, languageCode: partial != nil ? partial!.requestedLanguageCode : code, modelID: chosenModelID,
            requiresAllowance: free, windowIndices: windowIndices, projectTitle: project.title)))
    }

    func cancel(_ id: UUID) throws { try queue?.cancel(id: id) }

    func remove(_ id: UUID) async throws {
        guard !isAuthorizing, let queue, let record = queue.records[id],
              record.status.isTerminal, !queue.executingJobIDs.contains(id) else { throw SpeechError.busy }
        try queue.remove(id: id)
        // Removing a record never removes accepted captions or retry checkpoints.
        await refreshAllowance()
    }

    func retryMissing(projectID: UUID, windowIndices: [Int]? = nil) async throws {
        start()
        let project = try await repository.open(projectID)
        guard let result = project.recognition, result.isIncomplete else { throw SpeechError.alreadyTranscribed }
        if let record = record(for: projectID), record.id == result.id, record.status.isRetryable {
            try await retry(record, language: result.requestedLanguageCode ?? "auto", windowIndices: windowIndices)
        } else {
            try await enqueue(projectID: projectID, language: result.requestedLanguageCode ?? "auto", windowIndices: windowIndices)
        }
    }

    func discardSavedProgress(projectID: UUID, expectedRevision: UInt64) async throws {
        guard queueStarted, persistenceError == nil else { throw ProjectStoreError.unavailableRoot }
        guard !isAuthorizing, !isActive(projectID) else { throw SpeechError.busy }
        isAuthorizing = true
        defer { endAuthorization() }
        try await repository.discardSpeechCheckpoint(projectID: projectID, expectedRevision: expectedRevision)
        resultGeneration += 1
    }

    func retry(_ record: JobRecord, language: String, windowIndices: [Int]? = nil) async throws {
        guard lifecycle.error == nil, queueStarted, persistenceError == nil, let queue else { throw ProjectStoreError.unavailableRoot }
        guard !isAuthorizing else { throw SpeechError.busy }
        isAuthorizing = true
        defer { needsAllowanceRefresh = true; endAuthorization() }
        await access.refreshForRequest()
        await models.refresh()
        guard let current = queue.records[record.id], current.status.isRetryable,
              current.hasSamePayload(as: record) else { throw SpeechError.busy }
        let previous = try current.decode(SpeechJob.self)
        var chosenModelID = previous.payload.resolvedModelID
        guard !isActive(previous.payload.projectID) else { throw SpeechError.busy }
        let project = try await repository.open(previous.payload.projectID)
        guard !isActive(project.id) else { throw SpeechError.busy }
        if let saved = project.recognition, saved.id == record.id, !saved.words.isEmpty, !saved.isIncomplete {
            // Job completion may have failed to persist after document publication.
            try queue.retry(id: record.id)
            return
        }
        let partial = project.recognition.flatMap { $0.isIncomplete && $0.id == record.id ? $0 : nil }
        guard project.recognition == nil || partial != nil else { throw SpeechError.alreadyTranscribed }
        if let partial { chosenModelID = partial.modelID }
        guard !models.isRemoving, models.isAvailable(chosenModelID) else { throw SpeechError.missingModel }
        let free = !access.hasPro
        if free {
            allowance = try await repository.reconcileSpeechAllowance(activeJobIDs: activeJobIDs)
            try await repository.reserveSpeechAllowance(jobID: record.id, projectID: project.id, revision: project.contentRevision)
        } else {
            try await repository.releaseSpeechAllowance(record.id)
        }
        try Task.checkCancellation()
        guard lifecycle.error == nil, persistenceError == nil else { throw ProjectStoreError.unavailableRoot }
        guard !models.isRemoving, models.isAvailable(chosenModelID) else { throw SpeechError.missingModel }
        // Retry captures the latest saved revision and preserves partial captions.
        // The original model/language and durable operation identity stay fixed.
        try queue.replace(id: record.id, with: SpeechJob(id: record.id, payload: .init(
            projectID: project.id, expectedRevision: project.contentRevision,
            languageCode: partial != nil ? partial!.requestedLanguageCode :
                previous.payload.languageCode,
            modelID: chosenModelID, requiresAllowance: free, windowIndices: windowIndices, projectTitle: project.title)))
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

extension TranscriptionRequest {
    var resolvedModelID: String { modelID ?? SpeechModelCatalog.smallID }
}
