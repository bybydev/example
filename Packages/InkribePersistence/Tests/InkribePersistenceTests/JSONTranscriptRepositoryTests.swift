import Foundation
import InkribeCore
import Testing
@testable import InkribePersistence

@Suite("JSON transcript repository")
struct JSONTranscriptRepositoryTests {
    @Test func saveReloadAndDeleteAreDurable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("transcripts.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let id = TranscriptID()
        var transcript = Transcript(
            id: id,
            title: "Interview",
            rawText: "raw",
            editedText: "raw"
        )

        let repository = JSONTranscriptRepository(fileURL: fileURL)
        try await repository.save(transcript)

        transcript.title = "Renamed"
        transcript.updatedAt = transcript.updatedAt.addingTimeInterval(10)
        try await repository.save(transcript)

        let reloaded = JSONTranscriptRepository(fileURL: fileURL)
        let saved = try await reloaded.transcript(id: id)
        let all = try await reloaded.transcripts()
        #expect(saved?.title == "Renamed")
        #expect(all.count == 1)

        try await reloaded.delete(id: id)
        let afterDelete = JSONTranscriptRepository(fileURL: fileURL)
        let deleted = try await afterDelete.transcript(id: id)
        #expect(deleted == nil)
    }

    @Test func newestTranscriptSortsFirst() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("transcripts.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = JSONTranscriptRepository(fileURL: fileURL)
        try await repository.save(
            Transcript(title: "Older", updatedAt: Date(timeIntervalSince1970: 1))
        )
        try await repository.save(
            Transcript(title: "Newer", updatedAt: Date(timeIntervalSince1970: 2))
        )

        let titles = try await repository.transcripts().map(\.title)
        #expect(titles == ["Newer", "Older"])
    }

    @Test func duplicateIDsFailWithoutTrapping() async throws {
        struct Snapshot: Codable {
            let version: Int
            let transcripts: [Transcript]
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("transcripts.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let id = TranscriptID()
        let snapshot = Snapshot(
            version: 1,
            transcripts: [
                Transcript(id: id, title: "One"),
                Transcript(id: id, title: "Two")
            ]
        )
        try JSONEncoder().encode(snapshot).write(to: fileURL)

        let repository = JSONTranscriptRepository(fileURL: fileURL)
        do {
            _ = try await repository.transcripts()
            Issue.record("Duplicate transcript IDs should fail")
        } catch let error as JSONTranscriptRepository.RepositoryError {
            #expect(error == .duplicateTranscriptID(id))
        }
    }
    @Test func unsupportedSnapshotVersionFailsWithoutResettingStore() async throws {
        struct Snapshot: Codable {
            let version: Int
            let transcripts: [Transcript]
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("transcripts.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let snapshot = Snapshot(
            version: 99,
            transcripts: [Transcript(title: "Future")]
        )
        let originalData = try JSONEncoder().encode(snapshot)
        try originalData.write(to: fileURL, options: .atomic)

        let repository = JSONTranscriptRepository(fileURL: fileURL)
        do {
            _ = try await repository.transcripts()
            Issue.record("Unsupported store versions must fail")
        } catch let error as JSONTranscriptRepository.RepositoryError {
            #expect(error == .unsupportedVersion(99))
        }

        let preservedData = try Data(contentsOf: fileURL)
        #expect(preservedData == originalData)
    }

    @Test func corruptSnapshotFailsWithoutSilentEmptyFallback() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("transcripts.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let corrupt = Data("{ definitely-not-valid-json".utf8)
        try corrupt.write(to: fileURL, options: .atomic)

        let repository = JSONTranscriptRepository(fileURL: fileURL)
        do {
            _ = try await repository.transcripts()
            Issue.record("Corrupt transcript storage must fail")
        } catch {
            // Expected: corrupt data is not interpreted as an empty store.
        }
        let preservedData = try Data(contentsOf: fileURL)
        #expect(preservedData == corrupt)
    }

    @Test func failedPersistDoesNotMutateLoadedCache() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("transcripts.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let id = TranscriptID()
        let repository = JSONTranscriptRepository(fileURL: fileURL)
        try await repository.save(
            Transcript(id: id, title: "Committed", rawText: "original")
        )
        let committedValue = try await repository.transcript(id: id)
        let committed = try #require(committedValue)
        #expect(committed.title == "Committed")

        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: true)

        var replacement = committed
        replacement.title = "Must not leak into cache"
        do {
            try await repository.save(replacement)
            Issue.record("Saving over a directory should fail")
        } catch {
            // Expected: the durable write failed.
        }

        let stillCommittedValue = try await repository.transcript(id: id)
        let stillCommitted = try #require(stillCommittedValue)
        #expect(stillCommitted.title == "Committed")
        #expect(stillCommitted.rawText == "original")
    }

}
