import Foundation
import InkribeCore
import JobQueue
import Observation

public enum TranscriptionQueueState: Equatable, Sendable {
    case idle
    case processing
    case cancelling
    case pausing
    case paused
}

public enum TranscriptionQueueItemState: String, Equatable, Sendable {
    case waiting
    case transcribing
    case cancelling
    case pausing
    case complete
    case failed
    case cancelled
    case needsAttention
}

public enum TranscriptionQueueEvent: Equatable, Sendable {
    case added(UUID)
    case started(UUID)
    case pausing(UUID)
    case cancelling(UUID)
    case completed(UUID)
    case failed(UUID)
    case cancelled(UUID)
    case removed(UUID)
    case statusChanged(TranscriptionQueueState)
    case drained
    case persistenceFailed
}

public struct TranscriptionQueueItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let transcriptID: TranscriptID?
    public let state: TranscriptionQueueItemState
    public let fractionCompleted: Double?
    public let progressMessage: String?
    public let errorDescription: String?
    public let createdAt: Date

    public init(
        id: UUID,
        transcriptID: TranscriptID?,
        state: TranscriptionQueueItemState,
        fractionCompleted: Double?,
        progressMessage: String?,
        errorDescription: String?,
        createdAt: Date
    ) {
        self.id = id
        self.transcriptID = transcriptID
        self.state = state
        self.fractionCompleted = fractionCompleted
        self.progressMessage = progressMessage
        self.errorDescription = errorDescription
        self.createdAt = createdAt
    }
}

@MainActor
@Observable
public final class TranscriptionQueueController {
    public private(set) var startupErrorDescription: String?
    @ObservationIgnored public var eventHandler: ((TranscriptionQueueEvent) -> Void)?

    private let registry: JobRegistry
    private let queue: JobQueue
    private let executor: any TranscriptionJobExecuting

    public var state: TranscriptionQueueState {
        mapQueueState(queue.status)
    }

    public var isPaused: Bool { queue.isPaused }
    public var recordCount: Int { queue.records.count }
    public var activeCount: Int { queue.activeCount }
    public var persistenceIssueDescription: String? {
        queue.persistenceIssue?.errorDescription
    }

    public var items: [TranscriptionQueueItem] {
        queue.sortedRecords.map { record in
            let job = try? record.decode(TranscriptionJob.self)
            let progress = queue.liveProgress[record.id]
            return TranscriptionQueueItem(
                id: record.id,
                transcriptID: job.map { TranscriptID(rawValue: $0.payload.transcriptID) },
                state: itemState(for: record.status),
                fractionCompleted: progress?.fractionCompleted,
                progressMessage: progress?.message,
                errorDescription: record.error,
                createdAt: record.createdAt
            )
        }
    }

    public init(
        storeURL: URL,
        executor: any TranscriptionJobExecuting,
        maxRecords: Int = 100
    ) {
        let registry = JobRegistry()
        self.registry = registry
        self.executor = executor
        self.queue = JobQueue(
            fileURL: storeURL,
            policy: JobQueuePolicy(maxConcurrentExecutions: 1),
            registry: registry,
            maxRecords: maxRecords,
            autoCleanupEnabled: true
        )
        self.queue.eventHandler = { [weak self] event in
            self?.forward(event)
        }
    }

    public func start() throws {
        do {
            TranscriptionJobEnvironment.shared.install(executor)
            try registerPersistentJobTypes()
            try queue.start()
            startupErrorDescription = nil
        } catch {
            startupErrorDescription = String(describing: error)
            throw error
        }
    }

    @discardableResult
    public func enqueue(
        transcriptID: TranscriptID,
        sourceMediaRelativePath: String,
        requestedLanguage: String? = nil,
        startImmediately: Bool = false
    ) throws -> UUID {
        try queue.enqueue(
            TranscriptionJob(
                payload: .init(
                    transcriptID: transcriptID.rawValue,
                    sourceMediaRelativePath: sourceMediaRelativePath,
                    requestedLanguage: requestedLanguage
                )
            ),
            startPolicy: startImmediately ? .immediate : .scheduled
        )
    }

    public func cancel(id: UUID) throws {
        try queue.cancel(id: id)
    }

    public func retry(id: UUID) throws {
        try queue.retry(id: id)
    }

    public func remove(id: UUID) throws {
        try queue.remove(id: id)
    }

    public func pause() throws {
        try queue.pause()
    }

    public func resume() throws {
        try queue.resume()
    }

    public func cancelAll() throws {
        try queue.cancelAll()
    }

    public func retryAll() throws {
        try queue.retryAll()
    }

    private func registerPersistentJobTypes() throws {
        try registry.register(TranscriptionJob.self)
    }

    private func forward(_ event: JobQueueEvent) {
        let mapped: TranscriptionQueueEvent?
        switch event {
        case .jobAdded(let id):
            mapped = .added(id)
        case .jobStarted(let id):
            mapped = .started(id)
        case .jobPausing(let id):
            mapped = .pausing(id)
        case .jobCancelling(let id):
            mapped = .cancelling(id)
        case .jobCompleted(let id):
            mapped = .completed(id)
        case .jobFailed(let id, _):
            mapped = .failed(id)
        case .jobCancelled(let id):
            mapped = .cancelled(id)
        case .jobRemoved(let id):
            mapped = .removed(id)
        case .queueStatusChanged(let status):
            mapped = .statusChanged(mapQueueState(status))
        case .queueDrained:
            mapped = .drained
        case .persistenceFailed:
            mapped = .persistenceFailed
        case .jobProgressUpdated:
            mapped = nil
        }
        if let mapped {
            eventHandler?(mapped)
        }
    }

    private func mapQueueState(_ status: JobQueueStatus) -> TranscriptionQueueState {
        switch status {
        case .idle: .idle
        case .processing: .processing
        case .cancelling: .cancelling
        case .pausing: .pausing
        case .paused: .paused
        }
    }

    private func itemState(for status: JobStatus) -> TranscriptionQueueItemState {
        switch status {
        case .pending: .waiting
        case .processing: .transcribing
        case .cancelling: .cancelling
        case .pausing: .pausing
        case .completed: .complete
        case .failed: .failed
        case .cancelled: .cancelled
        case .unrecoverable: .needsAttention
        }
    }
}
