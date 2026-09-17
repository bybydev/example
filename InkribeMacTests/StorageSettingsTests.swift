import Foundation
import InkribeCore
import InkribeTranscription
import Testing
@testable import Inkribe

@Suite("Storage settings", .serialized)
@MainActor
struct StorageSettingsTests {
    @Test func cleanupRemovesFinishedMediaButKeepsTranscript() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let appState = makeAppState(directory: directory)
        try appState.start()
        let repository = try #require(appState.transcriptRepository)
        let mediaStore = try #require(appState.mediaStore)

        let sourceURL = directory.appendingPathComponent("source.wav")
        try Data(repeating: 7, count: 4_096).write(to: sourceURL)
        let reference = try await mediaStore.ingest(sourceURL: sourceURL)
        let ownedURL = try await mediaStore.url(for: reference)

        let transcript = Transcript(
            title: "Finished",
            sourceMediaRelativePath: reference.relativePath,
            rawText: "raw",
            editedText: "edited"
        )
        try await repository.save(transcript)

        let result = try await appState.removeSourceMediaForFinishedTranscripts()

        #expect(result.removedTranscriptCount == 1)
        #expect(result.skippedTranscriptCount == 0)
        #expect(result.reclaimedBytes == 4_096)
        #expect(!FileManager.default.fileExists(atPath: ownedURL.path))

        let reloadedOptional = try await repository.transcript(id: transcript.id)
        let reloaded = try #require(reloadedOptional)
        #expect(reloaded.sourceMediaRelativePath == nil)
        #expect(reloaded.rawText == "raw")
        #expect(reloaded.editedText == "edited")
    }

    @Test func cleanupSkipsMediaNeededByActiveQueueWork() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let appState = makeAppState(directory: directory)
        try appState.start()
        let repository = try #require(appState.transcriptRepository)
        let mediaStore = try #require(appState.mediaStore)
        let queue = try #require(appState.transcriptionQueue)

        let sourceURL = directory.appendingPathComponent("retryable.wav")
        try Data(repeating: 9, count: 1_024).write(to: sourceURL)
        let reference = try await mediaStore.ingest(sourceURL: sourceURL)
        let ownedURL = try await mediaStore.url(for: reference)

        let transcript = Transcript(
            title: "Pending",
            sourceMediaRelativePath: reference.relativePath,
            rawText: "raw"
        )
        try await repository.save(transcript)

        try queue.pause()
        _ = try queue.enqueue(
            transcriptID: transcript.id,
            sourceMediaRelativePath: reference.relativePath
        )

        let result = try await appState.removeSourceMediaForFinishedTranscripts()

        #expect(result.removedTranscriptCount == 0)
        #expect(result.skippedTranscriptCount == 1)
        #expect(FileManager.default.fileExists(atPath: ownedURL.path))

        let reloadedOptional = try await repository.transcript(id: transcript.id)
        let reloaded = try #require(reloadedOptional)
        #expect(reloaded.sourceMediaRelativePath == reference.relativePath)
    }

    private func makeAppState(directory: URL) -> InkribeAppState {
        InkribeAppState(
            queueStoreURLProvider: { directory.appendingPathComponent("jobs.json") },
            transcriptStoreURLProvider: { directory.appendingPathComponent("transcripts.json") },
            mediaDirectoryURLProvider: { directory.appendingPathComponent("Media", isDirectory: true) },
            executorFactory: { _, _ in PhaseEightStorageExecutor() }
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private struct PhaseEightStorageExecutor: TranscriptionJobExecuting {
    func execute(
        payload: TranscriptionJob.Payload,
        progress: @escaping TranscriptionProgressHandler
    ) async throws {
        await progress(1, "Complete")
    }
}
