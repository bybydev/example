import Foundation
import InkribeTranscription
import Logging
import Observation

@MainActor
@Observable
final class InkribeAppState {
    typealias QueueStoreURLProvider = () throws -> URL

    private(set) var transcriptionQueue: TranscriptionQueueController?
    private(set) var startupIssue: String?

    private let queueStoreURLProvider: QueueStoreURLProvider
    private let logger = Logger(label: "Inkribe.AppState")

    init(
        queueStoreURLProvider: @escaping QueueStoreURLProvider = {
            try InkribeAppDirectories.jobStoreURL()
        }
    ) {
        self.queueStoreURLProvider = queueStoreURLProvider
    }

    func start() throws {
        guard transcriptionQueue == nil else {
            startupIssue = nil
            return
        }

        do {
            let queue = TranscriptionQueueController(
                storeURL: try queueStoreURLProvider()
            )
            try queue.start()
            transcriptionQueue = queue
            startupIssue = nil
            logger.info("Transcription queue initialized")
        } catch {
            startupIssue = String(describing: error)
            logger.error("App startup failed: \(String(describing: error))")
            throw error
        }
    }
}
