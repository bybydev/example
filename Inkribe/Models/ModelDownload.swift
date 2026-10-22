import Foundation

/// URLSession streams to disk. Delegate state is protected by one lock; the
/// continuation is consumed once across finish/error/cancellation callbacks.
private struct ModelTransferState {
    var continuation: CheckedContinuation<Void, Error>?
    var session: URLSession?
    var destination: URL?
    var expectedBytes: Int64 = 0
    var progress: (@Sendable (Int64) -> Void)?
    var cancelled = false
    var reportedPercent = -1
}

final class ModelDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var state = ModelTransferState()

    func fetch(from url: URL, to destination: URL, expectedBytes: Int64,
               progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 60 * 60
                configuration.urlCache = nil
                let callbacks = OperationQueue()
                callbacks.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self,
                                         delegateQueue: callbacks)
                let task = session.downloadTask(with: url)
                let cancelled = lock.withLock {
                    guard !state.cancelled else { return true }
                    state.continuation = continuation
                    state.destination = destination
                    state.expectedBytes = expectedBytes
                    state.progress = progress
                    state.session = session
                    task.resume()
                    return false
                }
                if cancelled { session.invalidateAndCancel(); continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            self.lock.withLock { self.state.cancelled = true }
            self.finish(.failure(CancellationError()))
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        let captured = lock.withLock {
            let value = (state.continuation, state.session)
            state.continuation = nil
            state.session = nil
            state.progress = nil
            return value
        }
        captured.1?.invalidateAndCancel()
        captured.0?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let value = lock.withLock { (state.expectedBytes, state.progress) }
        guard totalBytesWritten <= value.0,
              totalBytesExpectedToWrite <= 0 || totalBytesExpectedToWrite == value.0 else {
            finish(.failure(ModelError.invalidDownload)); return
        }
        let shouldReport = lock.withLock {
            let percent = Int(Double(totalBytesWritten) / Double(max(1, state.expectedBytes)) * 100)
            guard percent > state.reportedPercent else { return false }
            state.reportedPercent = percent
            return true
        }
        if shouldReport { value.1?(totalBytesWritten) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Keep move and finish serialized with cancellation so a cancelled
        // continuation cannot let caller cleanup run before this move.
        let outcome: (CheckedContinuation<Void, Error>?, URLSession?, Result<Void, Error>) = lock.withLock {
            guard let continuation = state.continuation else { return (nil, nil, .success(())) }
            let result: Result<Void, Error>
            do {
                guard !state.cancelled, let destination = state.destination,
                      let response = downloadTask.response as? HTTPURLResponse,
                      response.statusCode == 200, response.url?.scheme == "https",
                      try location.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) == state.expectedBytes else {
                    throw ModelError.invalidDownload
                }
                try FileManager.default.moveItem(at: location, to: destination)
                result = .success(())
            } catch { result = .failure(error) }
            let activeSession = state.session
            state.continuation = nil; state.session = nil; state.progress = nil
            return (continuation, activeSession, result)
        }
        outcome.1?.finishTasksAndInvalidate()
        outcome.0?.resume(with: outcome.2)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard request.url?.scheme == "https" else {
            completionHandler(nil); finish(.failure(ModelError.invalidDownload)); return
        }
        completionHandler(request)
    }
}
