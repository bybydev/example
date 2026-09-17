import Foundation
import InkribeAI
import InkribeCore
import InkribeTranscription
import Testing
@testable import Inkribe

@Suite("Transcript AI results", .serialized)
@MainActor
struct TranscriptAIResultTests {
    @Test func cleanReplacementPreservesRawTextAndAdvancesRevision() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let appState = makeAppState(directory: directory)
        try appState.start()
        let repository = try #require(appState.transcriptRepository)
        let transcript = Transcript(
            title: "Interview",
            rawText: "raw whisper text",
            editedText: "working text",
            revision: 5
        )
        try await repository.save(transcript)

        let result = TranscriptAIResult(
            action: .clean,
            sourceRevision: 5,
            content: "Clean working text."
        )
        let updated = try await appState.applyTranscriptAIResult(
            transcriptID: transcript.id,
            result: result,
            mode: .replaceEditedText
        )

        #expect(updated.rawText == "raw whisper text")
        #expect(updated.editedText == "Clean working text.")
        #expect(updated.revision == 6)
        #expect(updated.derivedDocuments.isEmpty)
    }

    @Test func staleAIResultCannotOverwriteNewerTranscriptRevision() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let appState = makeAppState(directory: directory)
        try appState.start()
        let repository = try #require(appState.transcriptRepository)
        let transcript = Transcript(
            title: "Notes",
            rawText: "raw source",
            editedText: "revision two",
            revision: 2
        )
        try await repository.save(transcript)

        _ = try await appState.saveEditedText(
            id: transcript.id,
            text: "revision three"
        )

        let stale = TranscriptAIResult(
            action: .polish,
            sourceRevision: 2,
            content: "stale result"
        )

        do {
            _ = try await appState.applyTranscriptAIResult(
                transcriptID: transcript.id,
                result: stale,
                mode: .replaceEditedText
            )
            Issue.record("A stale AI result should not overwrite a newer transcript revision")
        } catch TranscriptAIError.staleResult(let expected, let current) {
            #expect(expected == 2)
            #expect(current == 3)
        }

        let reloadedValue = try await appState.transcript(id: transcript.id)
        let reloaded = try #require(reloadedValue)
        #expect(reloaded.editedText == "revision three")
        #expect(reloaded.revision == 3)
    }

    @Test func derivedAIResultPersistsWithoutAdvancingTranscriptRevision() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let appState = makeAppState(directory: directory)
        try appState.start()
        let repository = try #require(appState.transcriptRepository)
        let transcript = Transcript(
            title: "Planning",
            rawText: "planning transcript",
            editedText: "planning transcript",
            revision: 4
        )
        try await repository.save(transcript)

        let result = TranscriptAIResult(
            action: .summarize,
            sourceRevision: 4,
            content: "A concise summary."
        )
        let first = try await appState.applyTranscriptAIResult(
            transcriptID: transcript.id,
            result: result,
            mode: .saveDerivedDocument
        )
        let second = try await appState.applyTranscriptAIResult(
            transcriptID: transcript.id,
            result: result,
            mode: .saveDerivedDocument
        )

        #expect(first.revision == 4)
        #expect(second.revision == 4)
        #expect(second.derivedDocuments.count == 1)
        #expect(second.derivedDocuments[0].kind == .summary)
        #expect(second.derivedDocuments[0].sourceRevision == 4)
        #expect(second.derivedDocuments[0].content == "A concise summary.")
    }

    @Test func summaryCannotReplaceEditedTranscriptText() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let appState = makeAppState(directory: directory)
        try appState.start()
        let repository = try #require(appState.transcriptRepository)
        let transcript = Transcript(
            title: "Summary",
            rawText: "source transcript",
            editedText: "source transcript",
            revision: 1
        )
        try await repository.save(transcript)

        let result = TranscriptAIResult(
            action: .summarize,
            sourceRevision: 1,
            content: "Summary content"
        )

        do {
            _ = try await appState.applyTranscriptAIResult(
                transcriptID: transcript.id,
                result: result,
                mode: .replaceEditedText
            )
            Issue.record("Summary results must not replace edited transcript text")
        } catch TranscriptAIError.unsupportedApplyMode {
            // Expected.
        }

        let reloadedValue = try await appState.transcript(id: transcript.id)
        let reloaded = try #require(reloadedValue)
        #expect(reloaded.editedText == "source transcript")
        #expect(reloaded.revision == 1)
    }

    private func makeAppState(directory: URL) -> InkribeAppState {
        InkribeAppState(
            queueStoreURLProvider: { directory.appendingPathComponent("jobs.json") },
            transcriptStoreURLProvider: { directory.appendingPathComponent("transcripts.json") },
            mediaDirectoryURLProvider: { directory.appendingPathComponent("Media", isDirectory: true) },
            executorFactory: { _, _ in PhaseSixTranscriptionExecutor() }
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private struct PhaseSixTranscriptionExecutor: TranscriptionJobExecuting {
    func execute(
        payload: TranscriptionJob.Payload,
        progress: @escaping TranscriptionProgressHandler
    ) async throws {
        await progress(1, "Complete")
    }
}
