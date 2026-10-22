import Foundation
import JobQueue
import Observation

struct IOSSpeechJob: Job {
    struct Payload: Codable, Sendable {
        let projectID: UUID
        let expectedRevision: UInt64
        let languageCode: String?
    }
    static let maxConcurrentExecutions = 1
    let id: UUID
    let payload: Payload
    var title: String? { "Transcription" }
    var priority: JobPriority { .userInitiated }

    func execute(progress: JobProgressReporter) async throws {
        guard let executor = IOSSpeechEnvironment.shared.executor else { throw IOSSpeechError.missingModel }
        try await executor.execute(id: id, payload: payload, progress: progress)
    }
}

/// Separate from the Mac job environment: never replace its executor or records.
private final class IOSSpeechEnvironment: @unchecked Sendable {
    static let shared = IOSSpeechEnvironment()
    private let lock = NSLock()
    private var stored: IOSLocalTranscriber?
    var executor: IOSLocalTranscriber? { lock.withLock { stored } }
    func install(_ executor: IOSLocalTranscriber) { lock.withLock { stored = executor } }
}

@MainActor
@Observable
final class IOSTranscriptionController {
    private(set) var queue: JobQueue?
    private(set) var startupError: String?
    private(set) var resultGeneration = 0
    private let registry = JobRegistry()
    private let repository = IOSProjectRepository.shared
    private let modelURL = Bundle.main.url(forResource: "ggml-small", withExtension: "bin")
    var modelAvailable: Bool { modelURL != nil }
    var persistenceError: String? { startupError ?? queue?.persistenceIssue?.errorDescription }

    func start() {
        guard queue == nil else { return }
        do {
            let root = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("InkribeIOSProcessing", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try registry.register(IOSSpeechJob.self)
            IOSSpeechEnvironment.shared.install(IOSLocalTranscriber(repository: repository, modelURL: modelURL))
            let value = JobQueue(fileURL: root.appendingPathComponent("speech-jobs.json"),
                policy: JobQueuePolicy(maxConcurrentExecutions: 1), registry: registry,
                maxRecords: 100, autoCleanupEnabled: true)
            value.eventHandler = { [weak self] event in
                if case .jobCompleted = event { self?.resultGeneration += 1 }
            }
            queue = value
            try value.start()
            startupError = nil
        } catch { startupError = error.localizedDescription }
    }

    func retryStorage() {
        if let queue {
            do { try queue.perform(.retryPersistence); startupError = nil }
            catch { startupError = error.localizedDescription }
        } else { start() }
    }

    func record(for projectID: UUID) -> JobRecord? {
        // An older active operation must win over a newer terminal record.
        let matching = queue?.sortedRecords.filter {
            (try? $0.decode(IOSSpeechJob.self).payload.projectID) == projectID
        } ?? []
        return matching.first(where: { !$0.status.isTerminal }) ?? matching.first
    }

    func isActive(_ projectID: UUID) -> Bool {
        guard let record = record(for: projectID) else { return false }
        return !record.status.isTerminal
    }

    func enqueue(projectID: UUID, language: String) async throws {
        start()
        guard let queue else { throw IOSProjectStoreError.unavailableRoot }
        guard modelAvailable else { throw IOSSpeechError.missingModel }
        guard !isActive(projectID) else { throw IOSSpeechError.busy }
        let project = try await repository.open(projectID)
        // Recheck after suspension so rapid double taps cannot enqueue duplicates.
        guard !isActive(projectID) else { throw IOSSpeechError.busy }
        guard project.recognition == nil else { throw IOSSpeechError.alreadyTranscribed }
        let code = IOSSpeechLanguage.codes.contains(language) && language != "auto" ? language : nil
        try queue.enqueue(IOSSpeechJob(id: UUID(), payload: .init(projectID: projectID,
            expectedRevision: project.contentRevision, languageCode: code)))
    }

    func cancel(_ id: UUID) throws { try queue?.cancel(id: id) }

    func retry(_ record: JobRecord, language: String) async throws {
        guard let queue else { throw IOSProjectStoreError.unavailableRoot }
        let previous = try record.decode(IOSSpeechJob.self)
        guard !isActive(previous.payload.projectID) else { throw IOSSpeechError.busy }
        let project = try await repository.open(previous.payload.projectID)
        guard !isActive(project.id) else { throw IOSSpeechError.busy }
        if project.recognition?.id == record.id {
            // Job completion may have failed to persist after document publication.
            try queue.retry(id: record.id)
            return
        }
        guard project.recognition == nil else { throw IOSSpeechError.alreadyTranscribed }
        // Explicit retry takes a new document revision only while there are no
        // saved captions to overwrite. Reuse the durable operation identity.
        try queue.replace(id: record.id, with: IOSSpeechJob(id: record.id, payload: .init(
            projectID: project.id, expectedRevision: project.contentRevision,
            languageCode: IOSSpeechLanguage.codes.contains(language) && language != "auto" ? language : nil)))
    }
}

enum IOSSpeechLanguage {
    // The same initial language set as the existing Mac catalog, without linking
    // its diarization/persistence pipeline into the iOS target.
    static let codes = ["auto", "en", "vi", "zh", "ja", "ko", "es", "fr", "de", "it", "pt"]
    static func name(_ code: String) -> String {
        code == "auto" ? "Automatic" : (Locale.current.localizedString(forLanguageCode: code) ?? code)
    }
}
