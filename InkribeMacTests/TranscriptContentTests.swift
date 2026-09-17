import Foundation
import InkribeCore
import InkribeTranscription
import Testing
@testable import Inkribe

@Suite("Transcript content", .serialized)
@MainActor
struct TranscriptContentTests {
    @Test func renameEditAndDeletePreserveContentRules() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let mediaRoot = directory.appendingPathComponent("Media", isDirectory: true)
        let sourceDirectory = mediaRoot.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        let sourceURL = sourceDirectory.appendingPathComponent("source.wav")
        try Data([1, 2, 3, 4]).write(to: sourceURL)

        let appState = makeAppState(directory: directory)
        try appState.start()
        let repository = try #require(appState.transcriptRepository)

        let transcript = Transcript(
            title: "Original",
            sourceMediaRelativePath: "Sources/source.wav",
            rawText: "raw text",
            editedText: "raw text",
            revision: 4
        )
        try await repository.save(transcript)

        let renamed = try await appState.renameTranscript(
            id: transcript.id,
            title: "  Renamed  "
        )
        #expect(renamed.title == "Renamed")
        #expect(renamed.revision == 4)

        let edited = try await appState.saveEditedText(
            id: transcript.id,
            text: "my edited copy"
        )
        #expect(edited.rawText == "raw text")
        #expect(edited.editedText == "my edited copy")
        #expect(edited.revision == 5)

        let unchanged = try await appState.saveEditedText(
            id: transcript.id,
            text: "my edited copy"
        )
        #expect(unchanged.revision == 5)

        try await appState.deleteTranscript(id: transcript.id)
        let deletedTranscript = try await repository.transcript(id: transcript.id)
        #expect(deletedTranscript == nil)
        #expect(!FileManager.default.fileExists(atPath: sourceURL.path))
    }

    @Test func activeQueueRecordBlocksTranscriptDeletion() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let appState = makeAppState(directory: directory)
        try appState.start()
        let repository = try #require(appState.transcriptRepository)
        let queue = try #require(appState.transcriptionQueue)

        let transcript = Transcript(title: "Busy")
        try await repository.save(transcript)
        try queue.pause()
        _ = try queue.enqueue(
            transcriptID: transcript.id,
            sourceMediaRelativePath: "Sources/source.wav"
        )

        do {
            try await appState.deleteTranscript(id: transcript.id)
            Issue.record("Deleting a transcript with active queue work should fail")
        } catch InkribeAppState.AppStateError.transcriptBusy {
            // Expected.
        }

        let stillPresent = try await repository.transcript(id: transcript.id)
        #expect(stillPresent != nil)
    }

    @Test func editedTranscriptSurvivesRelaunchAndRemainsSearchable() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstAppState = makeAppState(directory: directory)
        try firstAppState.start()
        let firstRepository = try #require(firstAppState.transcriptRepository)

        let transcript = Transcript(
            title: "Relaunch Notes",
            rawText: "original text",
            editedText: "original text",
            revision: 1
        )
        try await firstRepository.save(transcript)
        _ = try await firstAppState.saveEditedText(
            id: transcript.id,
            text: "persistent searchable phrase"
        )

        let relaunchedAppState = makeAppState(directory: directory)
        try relaunchedAppState.start()
        let reloadedOptional = try await relaunchedAppState.transcript(id: transcript.id)
        let reloaded = try #require(reloadedOptional)
        #expect(reloaded.rawText == "original text")
        #expect(reloaded.editedText == "persistent searchable phrase")
        #expect(reloaded.revision == 2)

        let relaunchedTranscripts = try await relaunchedAppState.transcripts()
        let results = TranscriptLibraryQuery.apply(
            to: relaunchedTranscripts,
            searchText: "SEARCHABLE",
            sort: .newest
        )
        #expect(results.map(\.id) == [transcript.id])
    }

    @Test func playbackRejectsMissingSourceMedia() async throws {
        let controller = TranscriptPlaybackController()
        let missingURL = temporaryDirectory().appendingPathComponent("missing.wav")

        do {
            try await controller.prepare(url: missingURL)
            Issue.record("Missing source media should not prepare playback")
        } catch TranscriptPlaybackController.PlaybackError.sourceUnavailable {
            // Expected.
        }

        #expect(!controller.isPrepared)
    }

    private func makeAppState(directory: URL) -> InkribeAppState {
        InkribeAppState(
            queueStoreURLProvider: { directory.appendingPathComponent("jobs.json") },
            transcriptStoreURLProvider: { directory.appendingPathComponent("transcripts.json") },
            mediaDirectoryURLProvider: { directory.appendingPathComponent("Media", isDirectory: true) },
            executorFactory: { _, _ in PhaseFiveTestExecutor() }
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private struct PhaseFiveTestExecutor: TranscriptionJobExecuting {
    func execute(
        payload: TranscriptionJob.Payload,
        progress: @escaping TranscriptionProgressHandler
    ) async throws {
        await progress(1, "Complete")
    }
}
