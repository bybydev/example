import Foundation
import InkribeCore

public actor JSONTranscriptRepository: TranscriptRepository {
    private struct Snapshot: Codable, Sendable {
        static let currentVersion = 1

        let version: Int
        var transcripts: [Transcript]
    }

    public enum RepositoryError: LocalizedError, Equatable, Sendable {
        case unsupportedVersion(Int)
        case duplicateTranscriptID(TranscriptID)

        public var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version):
                "Transcript store version \(version) is not supported."
            case .duplicateTranscriptID(let id):
                "Transcript store contains duplicate ID \(id.rawValue.uuidString)."
            }
        }
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private var cache: [TranscriptID: Transcript]?

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public func transcript(id: TranscriptID) async throws -> Transcript? {
        try loadIfNeeded()[id]
    }

    public func transcripts() async throws -> [Transcript] {
        try loadIfNeeded().values.sorted {
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt > $1.updatedAt
            }
            return $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
        }
    }

    public func save(_ transcript: Transcript) async throws {
        var transcripts = try loadIfNeeded()
        transcripts[transcript.id] = transcript
        try persist(transcripts)
        cache = transcripts
    }

    public func delete(id: TranscriptID) async throws {
        var transcripts = try loadIfNeeded()
        guard transcripts.removeValue(forKey: id) != nil else { return }
        try persist(transcripts)
        cache = transcripts
    }

    private func loadIfNeeded() throws -> [TranscriptID: Transcript] {
        if let cache { return cache }

        guard fileManager.fileExists(atPath: fileURL.path) else {
            let empty: [TranscriptID: Transcript] = [:]
            cache = empty
            return empty
        }

        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        guard snapshot.version == Snapshot.currentVersion else {
            throw RepositoryError.unsupportedVersion(snapshot.version)
        }

        var loaded: [TranscriptID: Transcript] = [:]
        loaded.reserveCapacity(snapshot.transcripts.count)
        for transcript in snapshot.transcripts {
            guard loaded[transcript.id] == nil else {
                throw RepositoryError.duplicateTranscriptID(transcript.id)
            }
            loaded[transcript.id] = transcript
        }
        cache = loaded
        return loaded
    }

    private func persist(_ transcripts: [TranscriptID: Transcript]) throws {
        let parent = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )

        let ordered = transcripts.values.sorted {
            $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
        }
        let snapshot = Snapshot(
            version: Snapshot.currentVersion,
            transcripts: ordered
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: [.atomic])
    }
}
