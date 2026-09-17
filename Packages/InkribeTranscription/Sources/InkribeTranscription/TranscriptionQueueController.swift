import Foundation
import JobQueue
import Observation

public enum TranscriptionQueueState: Equatable, Sendable {
    case idle
    case processing
    case cancelling
    case pausing
    case paused
}

@MainActor
@Observable
public final class TranscriptionQueueController {
    public private(set) var startupErrorDescription: String?

    private let registry: JobRegistry
    private let queue: JobQueue

    public var state: TranscriptionQueueState {
        switch queue.status {
        case .idle: .idle
        case .processing: .processing
        case .cancelling: .cancelling
        case .pausing: .pausing
        case .paused: .paused
        }
    }

    public var recordCount: Int {
        queue.records.count
    }

    public init(storeURL: URL, maxRecords: Int = 100) {
        let registry = JobRegistry()
        self.registry = registry
        self.queue = JobQueue(
            fileURL: storeURL,
            policy: JobQueuePolicy(maxConcurrentExecutions: 1),
            registry: registry,
            maxRecords: maxRecords,
            autoCleanupEnabled: true
        )
    }

    public func start() throws {
        do {
            try registerPersistentJobTypes()
            try queue.start()
            startupErrorDescription = nil
        } catch {
            startupErrorDescription = String(describing: error)
            throw error
        }
    }

    private func registerPersistentJobTypes() throws {
        // Phase 4 adds TranscriptionJob registration here before queue startup.
    }
}
