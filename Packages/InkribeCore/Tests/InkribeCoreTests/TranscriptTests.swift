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
