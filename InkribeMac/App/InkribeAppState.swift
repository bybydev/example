import Foundation
import InkribeAudio
import InkribeCore
import InkribePersistence
import InkribeTranscription
import Logging
import Observation

@MainActor
@Observable
final class InkribeAppState {
    typealias URLProvider = () throws -> URL
    typealias ExecutorFactory = (
        DurableMediaStore,
        JSONTranscriptRepository
    ) throws -> any TranscriptionJobExecuting

    let microphoneRecorder: MicrophoneRecorder

    private(set) var transcriptionQueue: TranscriptionQueueController?
    private(set) var transcriptRepository: JSONTranscriptRepository?
    private(set) var mediaStore: DurableMediaStore?
    private(set) var startupIssue: String?
    private(set) var activeRecordingLocation: DurableMediaLocation?

    private let queueStoreURLProvider: URLProvider
    private let transcriptStoreURLProvider: URLProvider
    private let mediaDirectoryURLProvider: URLProvider
    private let executorFactory: ExecutorFactory
    private let logger = Logger(label: "Inkribe.AppState")

    init(
        queueStoreURLProvider: @escaping URLProvider = {
            try InkribeAppDirectories.jobStoreURL()
        },
        transcriptStoreURLProvider: @escaping URLProvider = {
            try InkribeAppDirectories.transcriptStoreURL()
        },
        mediaDirectoryURLProvider: @escaping URLProvider = {
            try InkribeAppDirectories.mediaDirectoryURL()
        },
        executorFactory: @escaping ExecutorFactory = { mediaStore, repository in
            try DefaultTranscriptionJobExecutor.bundled(
                mediaStore: mediaStore,
                transcriptRepository: repository
            )
        },
        microphoneRecorder: MicrophoneRecorder = MicrophoneRecorder()
    ) {
        self.queueStoreURLProvider = queueStoreURLProvider
        self.transcriptStoreURLProvider = transcriptStoreURLProvider
        self.mediaDirectoryURLProvider = mediaDirectoryURLProvider
        self.executorFactory = executorFactory
        self.microphoneRecorder = microphoneRecorder
    }

    func start() throws {
        guard transcriptionQueue == nil else {
            startupIssue = nil
            return
        }

        do {
            let repository = JSONTranscriptRepository(
                fileURL: try transcriptStoreURLProvider()
            )
            let mediaStore = DurableMediaStore(
                rootDirectoryURL: try mediaDirectoryURLProvider()
            )
            let executor = try executorFactory(mediaStore, repository)
            let queue = TranscriptionQueueController(
                storeURL: try queueStoreURLProvider(),
                executor: executor
            )
            let queueLogger = logger
            queue.eventHandler = { event in
                Self.logQueueEvent(event, logger: queueLogger)
            }
            try queue.start()

            self.transcriptRepository = repository
            self.mediaStore = mediaStore
            transcriptionQueue = queue
            startupIssue = nil
            logger.info("Transcription pipeline initialized")
        } catch {
            startupIssue = String(describing: error)
            logger.error("App startup failed: \(String(describing: error))")
            throw error
        }
    }

    func importMedia(
        from sourceURL: URL,
        requestedLanguage: String? = nil
    ) async throws -> TranscriptID {
        guard let mediaStore else { throw AppStateError.pipelineUnavailable }

        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let reference = try await mediaStore.ingest(sourceURL: sourceURL)
        let title = sourceURL.deletingPathExtension().lastPathComponent
        return try await createTranscriptAndEnqueue(
            mediaReference: reference,
            title: title.isEmpty ? "Untitled Transcript" : title,
            requestedLanguage: requestedLanguage,
            removeMediaOnFailure: true
        )
    }

    func startRecording(deviceID: String?) async throws {
        guard let mediaStore else { throw AppStateError.pipelineUnavailable }

        if let staleLocation = activeRecordingLocation,
           microphoneRecorder.state == .idle {
            activeRecordingLocation = nil
            try? await mediaStore.remove(staleLocation.reference)
        }
        guard activeRecordingLocation == nil else {
            throw AppStateError.recordingAlreadyActive
        }
        guard await microphoneRecorder.requestPermission() else {
            throw AppStateError.microphonePermissionDenied
        }

        let location = try await mediaStore.makeRecordingDestination(fileExtension: "caf")
        do {
            try microphoneRecorder.start(to: location.url, deviceID: deviceID)
            activeRecordingLocation = location
            logger.info("Recording started")
        } catch {
            try? await mediaStore.remove(location.reference)
            throw error
        }
    }

    func pauseRecording() {
        microphoneRecorder.pause()
    }

    func resumeRecording() {
        microphoneRecorder.resume()
    }

    func finishRecording(
        title: String,
        requestedLanguage: String? = nil
    ) async throws -> TranscriptID {
        guard let location = activeRecordingLocation else {
            throw AppStateError.noActiveRecording
        }

        _ = microphoneRecorder.stop()
        activeRecordingLocation = nil

        if let failure = microphoneRecorder.lastErrorDescription {
            try? await mediaStore?.remove(location.reference)
            throw AppStateError.recordingFailed(failure)
        }

        let transcriptID = try await createTranscriptAndEnqueue(
            mediaReference: location.reference,
            title: title,
            requestedLanguage: requestedLanguage,
            removeMediaOnFailure: true
        )
        logger.info("Recording queued for transcription")
        return transcriptID
    }

    func cancelRecording() async {
        _ = microphoneRecorder.stop()
        guard let location = activeRecordingLocation else { return }
        activeRecordingLocation = nil
        try? await mediaStore?.remove(location.reference)
        logger.info("Recording discarded")
    }

    func transcript(id: TranscriptID) async throws -> Transcript? {
        guard let transcriptRepository else { throw AppStateError.pipelineUnavailable }
        return try await transcriptRepository.transcript(id: id)
    }

    func transcripts() async throws -> [Transcript] {
        guard let transcriptRepository else { throw AppStateError.pipelineUnavailable }
        return try await transcriptRepository.transcripts()
    }

    func renameTranscript(id: TranscriptID, title: String) async throws -> Transcript {
        guard let transcriptRepository else { throw AppStateError.pipelineUnavailable }
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw AppStateError.emptyTranscriptTitle }
        guard var transcript = try await transcriptRepository.transcript(id: id) else {
            throw AppStateError.transcriptNotFound
        }
        guard transcript.title != normalized else { return transcript }

        transcript.title = normalized
        transcript.updatedAt = .now
        try await transcriptRepository.save(transcript)
        logger.info("Transcript renamed: \(id.rawValue.uuidString)")
        return transcript
    }

    func saveEditedText(id: TranscriptID, text: String) async throws -> Transcript {
        guard let transcriptRepository else { throw AppStateError.pipelineUnavailable }
        guard var transcript = try await transcriptRepository.transcript(id: id) else {
            throw AppStateError.transcriptNotFound
        }
        guard transcript.editedText != text else { return transcript }

        transcript.editedText = text
        transcript.revision += 1
        transcript.updatedAt = .now
        try await transcriptRepository.save(transcript)
        return transcript
    }

    func mediaURL(for transcript: Transcript) async throws -> URL? {
        guard let mediaStore else { throw AppStateError.pipelineUnavailable }
        guard let relativePath = transcript.sourceMediaRelativePath else { return nil }
        return try await mediaStore.url(for: DurableMediaReference(relativePath: relativePath))
    }

    func deleteTranscript(id: TranscriptID) async throws {
        guard let transcriptRepository,
              let mediaStore,
              let transcriptionQueue else {
            throw AppStateError.pipelineUnavailable
        }
        guard let transcript = try await transcriptRepository.transcript(id: id) else {
            throw AppStateError.transcriptNotFound
        }

        let relatedItems = transcriptionQueue.items.filter { $0.transcriptID == id }
        let hasActiveJob = relatedItems.contains {
            switch $0.state {
            case .waiting, .transcribing, .pausing, .cancelling:
                true
            case .complete, .failed, .cancelled, .needsAttention:
                false
            }
        }
        guard !hasActiveJob else { throw AppStateError.transcriptBusy }

        for item in relatedItems {
            try transcriptionQueue.remove(id: item.id)
        }

        try await transcriptRepository.delete(id: id)

        if let relativePath = transcript.sourceMediaRelativePath {
            do {
                try await mediaStore.remove(DurableMediaReference(relativePath: relativePath))
            } catch {
                logger.warning("Transcript deleted but associated media cleanup failed: \(id.rawValue.uuidString)")
            }
        }

        logger.info("Transcript deleted: \(id.rawValue.uuidString)")
    }

    private func createTranscriptAndEnqueue(
        mediaReference: DurableMediaReference,
        title: String,
        requestedLanguage: String?,
        removeMediaOnFailure: Bool
    ) async throws -> TranscriptID {
        guard let transcriptRepository,
              let mediaStore,
              let transcriptionQueue else {
            throw AppStateError.pipelineUnavailable
        }

        let transcript = Transcript(
            title: title,
            sourceMediaRelativePath: mediaReference.relativePath
        )
        try await transcriptRepository.save(transcript)

        do {
            try transcriptionQueue.enqueue(
                transcriptID: transcript.id,
                sourceMediaRelativePath: mediaReference.relativePath,
                requestedLanguage: requestedLanguage
            )
            return transcript.id
        } catch {
            try? await transcriptRepository.delete(id: transcript.id)
            if removeMediaOnFailure {
                try? await mediaStore.remove(mediaReference)
            }
            throw error
        }
    }

    private static func logQueueEvent(
        _ event: TranscriptionQueueEvent,
        logger: Logger
    ) {
        switch event {
        case .added(let id):
            logger.info("Transcription job added: \(id.uuidString)")
        case .started(let id):
            logger.info("Transcription job started: \(id.uuidString)")
        case .pausing(let id):
            logger.debug("Transcription job pausing: \(id.uuidString)")
        case .cancelling(let id):
            logger.debug("Transcription job cancelling: \(id.uuidString)")
        case .completed(let id):
            logger.info("Transcription job completed: \(id.uuidString)")
        case .failed(let id):
            logger.error("Transcription job failed: \(id.uuidString)")
        case .cancelled(let id):
            logger.info("Transcription job cancelled: \(id.uuidString)")
        case .removed(let id):
            logger.debug("Transcription job removed: \(id.uuidString)")
        case .statusChanged(let state):
            logger.debug("Transcription queue state: \(String(describing: state))")
        case .drained:
            logger.debug("Transcription queue drained")
        case .persistenceFailed:
            logger.error("Transcription queue persistence failed")
        }
    }

    enum AppStateError: LocalizedError {
        case pipelineUnavailable
        case recordingAlreadyActive
        case noActiveRecording
        case microphonePermissionDenied
        case recordingFailed(String)
        case transcriptNotFound
        case emptyTranscriptTitle
        case transcriptBusy

        var errorDescription: String? {
            switch self {
            case .pipelineUnavailable:
                "The local transcription pipeline is unavailable."
            case .recordingAlreadyActive:
                "A recording is already active."
            case .noActiveRecording:
                "There is no active recording to finish."
            case .microphonePermissionDenied:
                "Microphone access is required to record audio."
            case .recordingFailed(let description):
                "Recording failed: \(description)"
            case .transcriptNotFound:
                "The transcript no longer exists."
            case .emptyTranscriptTitle:
                "Transcript titles cannot be empty."
            case .transcriptBusy:
                "Wait for transcription to finish or cancel it before deleting this transcript."
            }
        }
    }
}
