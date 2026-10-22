import Foundation
import JobQueue

// JobQueue 1.0 persists String(describing: Job.Type). Keep only these legacy
// decode adapters under their original names so existing durable records restore.
// New work uses SpeechJob/ExportJob; payload bytes and storage paths stay stable.
struct IOSSpeechJob: Job {
    typealias Payload = SpeechJob.Payload
    static let maxConcurrentExecutions = 1
    let id: UUID
    let payload: Payload
    func execute(progress: JobProgressReporter) async throws {
        try await SpeechJob(id: id, payload: payload).execute(progress: progress)
    }
}

struct IOSExportJob: Job {
    typealias Payload = ExportJob.Payload
    static let maxConcurrentExecutions = 1
    let id: UUID
    let payload: Payload
    func execute(progress: JobProgressReporter) async throws {
        try await ExportJob(id: id, payload: payload).execute(progress: progress)
    }
}
