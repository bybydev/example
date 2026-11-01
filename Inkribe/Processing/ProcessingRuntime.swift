import Foundation

/// Native task cancellation must not depend on successfully saving a queue
/// pause during a low-disk/storage failure. JobQueue still owns durable status.
/// JobQueue owns concurrency; this runtime tracks cancellation and teardown only.
@MainActor
final class ProcessingRuntime {
    static let shared = ProcessingRuntime()
    private weak var lifecycle: ProcessingLifecycle?
    private var tasks: [UUID: (kind: ProcessingKind, task: Task<Void, any Error>)] = [:]

    func configure(_ lifecycle: ProcessingLifecycle) { self.lifecycle = lifecycle }

    func cancelTranscription() {
        tasks.values.filter { $0.kind == .transcription }.forEach { $0.task.cancel() }
    }
    func cancelExports() {
        tasks.values.filter { $0.kind == .export }.forEach { $0.task.cancel() }
    }

    /// Capture only this session's current native work. A later user request
    /// must not extend the old system task's completion/expiration cleanup.
    func teardownBarrier(for kind: ProcessingKind) -> Task<Void, Never> {
        let pending = tasks.values.filter { $0.kind == kind }.map(\.task)
        return Task { for task in pending { _ = try? await task.value } }
    }

    func waitForTranscriptionIdle() async {
        // Model switching blocks new speech work only. Independent exports
        // keep running and do not delay engine activation.
        let pending = tasks.values.filter { $0.kind == .transcription }.map(\.task)
        for task in pending { _ = try? await task.value }
    }

    func run(kind: ProcessingKind, _ operation: @escaping @Sendable () async throws -> Void) async throws {
        try requireExecution(for: kind)
        let token = UUID()
        let task = Task {
            try self.requireExecution(for: kind)
            try Task.checkCancellation()
            try await operation()
        }
        tasks[token] = (kind, task)
        defer { tasks.removeValue(forKey: token) }
        try await withTaskCancellationHandler {
            // Await teardown even when this caller is cancelled. Returning early
            // would make a terminal queue record removable while native work
            // still owns its request/media files.
            try await task.value
        } onCancel: { task.cancel() }
    }

    private func requireExecution(for kind: ProcessingKind) throws {
        guard let lifecycle,
              (kind == .transcription ? lifecycle.canTranscribe : lifecycle.canExport) else { throw CancellationError() }
    }
}
