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
}
