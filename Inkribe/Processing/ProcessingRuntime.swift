import Foundation
import InkribeCore

/// Native task cancellation must not depend on successfully saving a queue
/// pause during a low-disk/storage failure. JobQueue still owns durable status.
@MainActor
final class ProcessingRuntime {
    static let shared = ProcessingRuntime()
    private weak var lifecycle: ProcessingLifecycle?
    private var tasks: [UUID: Task<Void, any Error>] = [:]

    func configure(_ lifecycle: ProcessingLifecycle) { self.lifecycle = lifecycle }

    func cancelForInterruption() { tasks.values.forEach { $0.cancel() } }

    func run(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        try requireForeground()
        let token = UUID()
        let task = Task {
            try await ProcessingWorkGate.shared.withPermit {
                try await self.requireForeground()
                try Task.checkCancellation()
                try await operation()
            }
        }
        tasks[token] = task
        defer { tasks.removeValue(forKey: token) }
        try await withTaskCancellationHandler {
            // Await teardown even when this caller is cancelled. Returning early
            // would make a terminal queue record removable while native work
            // still owns its request/media files.
            try await task.value
        } onCancel: { task.cancel() }
    }

    private func requireForeground() throws {
        guard lifecycle?.canRun == true else { throw CancellationError() }
    }
}
