import Foundation

/// One heavy native operation across speech and export. Waiting acquires no
/// model/media handles. FIFO admission prevents either persisted queue starving
/// the other; each queue retains its own scheduler and stable record IDs.
public actor ProcessingWorkGate {
    public static let shared = ProcessingWorkGate()
    private struct Waiter {
        let token: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }
    private var owner: UUID?
    private var waiters: [Waiter] = []

    public init() {}

    public func withPermit<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        let token = UUID()
        try await acquire(token)
        do {
            try Task.checkCancellation()
            let result = try await operation()
            release(token)
            return result
        } catch {
            release(token)
            throw error
        }
    }

    private func acquire(_ token: UUID) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if owner == nil { owner = token; return }
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(token: token, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(token) }
        }
    }

    private func cancelWaiter(_ token: UUID) {
        guard let index = waiters.firstIndex(where: { $0.token == token }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release(_ token: UUID) {
        guard owner == token else { return }
        owner = nil
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            owner = next.token
            next.continuation.resume()
        }
    }
}
