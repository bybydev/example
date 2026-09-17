import InkribeCore

public protocol TranscriptRepository: Sendable {
    func transcript(id: TranscriptID) async throws -> Transcript?
    func transcripts() async throws -> [Transcript]
    func save(_ transcript: Transcript) async throws
    func delete(id: TranscriptID) async throws
}
