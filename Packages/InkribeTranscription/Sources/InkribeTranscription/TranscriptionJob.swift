import Foundation
import JobQueue

public typealias TranscriptionProgressHandler = @Sendable (
    _ fractionCompleted: Double?,
    _ message: String?
) async -> Void

public protocol TranscriptionJobExecuting: Sendable {
    func execute(
        payload: TranscriptionJob.Payload,
        progress: @escaping TranscriptionProgressHandler
    ) async throws
}

public struct TranscriptionJob: Job, Sendable {
    public struct Payload: Codable, Equatable, Sendable {
        public let transcriptID: UUID
        public let sourceMediaRelativePath: String
        public let requestedLanguage: String?

        public init(
            transcriptID: UUID,
            sourceMediaRelativePath: String,
            requestedLanguage: String?
        ) {
            self.transcriptID = transcriptID
            self.sourceMediaRelativePath = sourceMediaRelativePath
            self.requestedLanguage = requestedLanguage
        }
    }

    public static let maxConcurrentExecutions = 1

    public let id: UUID
    public let payload: Payload

    public init(id: UUID = UUID(), payload: Payload) {
        self.id = id
        self.payload = payload
    }

    public var title: String? { "Transcription" }
    public var detail: String? { nil }
    public var priority: JobPriority { .userInitiated }

    public func execute(progress: JobProgressReporter) async throws {
        guard let executor = TranscriptionJobEnvironment.shared.executor else {
            throw TranscriptionJobError.executorUnavailable
        }
        try await executor.execute(payload: payload) { fractionCompleted, message in
            await progress.report(
                fractionCompleted: fractionCompleted,
                message: message
            )
        }
    }
}

public enum TranscriptionJobError: LocalizedError, Equatable, Sendable {
    case executorUnavailable
    case transcriptNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .executorUnavailable:
            "The transcription service is unavailable."
        case .transcriptNotFound:
            "The transcript target no longer exists."
        }
    }
}

final class TranscriptionJobEnvironment: @unchecked Sendable {
    static let shared = TranscriptionJobEnvironment()

    private let lock = NSLock()
    private var storedExecutor: (any TranscriptionJobExecuting)?

    var executor: (any TranscriptionJobExecuting)? {
        lock.withLock { storedExecutor }
    }

    func install(_ executor: any TranscriptionJobExecuting) {
        lock.withLock {
            storedExecutor = executor
        }
    }
}
