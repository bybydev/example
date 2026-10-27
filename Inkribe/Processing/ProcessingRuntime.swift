import Foundation
import InkribeCore

/// Native task cancellation must not depend on successfully saving a queue
/// pause during a low-disk/storage failure. JobQueue still owns durable status.
@MainActor
final class ProcessingRuntime {
    static let shared = ProcessingRuntime()
    private weak var lifecycle: ProcessingLifecycle?
    private var tasks: [UUID: (kind: ProcessingKind, task: Task<Void, any Error>)] = [:]

    func configure(_ lifecycle: ProcessingLifecycle) { self.lifecycle = lifecycle }

    func cancelForInterruption() { tasks.values.forEach { $0.task.cancel() } }

    func cancelTranscription() {
        tasks.values.filter { $0.kind == .transcription }.forEach { $0.task.cancel() }
    }

    func waitForTranscriptionIdle() async {
        // Model switching blocks new speech work only. Exports retain their
        // place at the shared gate and do not delay engine activation.
        let pending = tasks.values.filter { $0.kind == .transcription }.map(\.task)
        for task in pending { _ = try? await task.value }
    }

    func run(kind: ProcessingKind, _ operation: @escaping @Sendable () async throws -> Void) async throws {
        try requireForeground(for: kind)
        let token = UUID()
        let task = Task {
            try await ProcessingWorkGate.shared.withPermit {
                try await self.requireForeground(for: kind)
                try Task.checkCancellation()
                try await operation()
            }
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

    private func requireForeground(for kind: ProcessingKind) throws {
        guard let lifecycle, lifecycle.canRun,
              kind != .transcription || lifecycle.canTranscribe else { throw CancellationError() }
    }
}
