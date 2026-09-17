import Foundation
import Testing
@testable import InkribeCore

@Test func transcriptRoundTripsThroughJSON() throws {
    let transcript = Transcript(
        title: "Interview",
        duration: 12.5,
        rawText: "Hello",
        editedText: "Hello",
        revision: 2,
        segments: [
            TranscriptSegment(startTime: 0, endTime: 1.2, text: "Hello")
        ],
        derivedDocuments: [
            DerivedDocument(
                kind: .summary,
                content: "A short interview.",
                sourceRevision: 2
            )
        ]
    )

    let data = try JSONEncoder().encode(transcript)
    let decoded = try JSONDecoder().decode(Transcript.self, from: data)

    #expect(decoded == transcript)
}

@Test func libraryQuerySearchesTitleRawAndEditedText() {
    let titleMatch = Transcript(title: "Project Aurora", rawText: "alpha", editedText: "alpha")
    let rawMatch = Transcript(title: "Meeting", rawText: "budget zebra", editedText: "clean copy")
    let editedMatch = Transcript(title: "Notes", rawText: "original", editedText: "release zebra")
    let miss = Transcript(title: "Other", rawText: "nothing", editedText: "nothing")

    let results = TranscriptLibraryQuery.apply(
        to: [miss, editedMatch, titleMatch, rawMatch],
        searchText: "zebra",
        sort: .title
    )

    #expect(results.map(\.id) == [rawMatch.id, editedMatch.id])

    let titleResults = TranscriptLibraryQuery.apply(
        to: [miss, titleMatch],
        searchText: "AURORA",
        sort: .newest
    )
    #expect(titleResults.map(\.id) == [titleMatch.id])
}

@Test func libraryQuerySortsDeterministically() {
    let older = Transcript(
        id: TranscriptID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
        title: "Zulu",
        updatedAt: Date(timeIntervalSince1970: 1)
    )
    let newer = Transcript(
        id: TranscriptID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!),
        title: "Alpha",
        updatedAt: Date(timeIntervalSince1970: 2)
    )

    #expect(
        TranscriptLibraryQuery.apply(to: [older, newer], searchText: "", sort: .newest).map(\.id)
            == [newer.id, older.id]
    )
    #expect(
        TranscriptLibraryQuery.apply(to: [older, newer], searchText: "", sort: .oldest).map(\.id)
            == [older.id, newer.id]
    )
    #expect(
        TranscriptLibraryQuery.apply(to: [older, newer], searchText: "", sort: .title).map(\.id)
            == [newer.id, older.id]
    )
}
