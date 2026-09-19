import DiarizationRuntime
import InkribeCore
import Testing
import WhisperRuntime
@testable import InkribeTranscription

@Suite("Speaker alignment")
struct SpeakerAlignmentEngineTests {
    @Test func splitsOneWhisperSegmentAcrossSpeakersUsingTokenTimestamps() {
        let result = SpeakerAlignmentEngine().align(
            tokens: [
                .init(startTime: 0.0, endTime: 0.4, text: " Hello"),
                .init(startTime: 0.4, endTime: 0.8, text: " there"),
                .init(startTime: 0.9, endTime: 1.2, text: " Yes"),
                .init(startTime: 1.2, endTime: 1.6, text: " exactly")
            ],
            speakerTurns: [
                .init(speakerID: 0, startTime: 0, endTime: 0.85),
                .init(speakerID: 1, startTime: 0.85, endTime: 1.7)
            ],
            fallbackSegments: [
                .init(startTime: 0, endTime: 1.7, text: " Hello there Yes exactly")
            ]
        )

        #expect(result.segments.count == 2)
        #expect(result.segments[0].speakerID == 0)
        #expect(result.segments[0].text == "Hello there")
        #expect(result.segments[1].speakerID == 1)
        #expect(result.segments[1].text == "Yes exactly")
        #expect(result.speakers.map(\.name) == ["Speaker 1", "Speaker 2"])
    }

    @Test func suppressesVeryShortSpeakerIslandBetweenSameSpeaker() {
        let result = SpeakerAlignmentEngine(shortIslandDuration: 0.35).align(
            tokens: [
                .init(startTime: 0, endTime: 0.8, text: " Alpha"),
                .init(startTime: 0.8, endTime: 1.0, text: " noise"),
                .init(startTime: 1.0, endTime: 1.8, text: " omega")
            ],
            speakerTurns: [
                .init(speakerID: 0, startTime: 0, endTime: 0.8),
                .init(speakerID: 1, startTime: 0.8, endTime: 1.0),
                .init(speakerID: 0, startTime: 1.0, endTime: 1.8)
            ],
            fallbackSegments: []
        )

        #expect(result.segments.count == 1)
        #expect(result.segments[0].speakerID == 0)
        #expect(result.segments[0].text == "Alpha noise omega")
    }

    @Test func fallsBackToWhisperSegmentsWhenNoSpeakerTurnsExist() {
        let result = SpeakerAlignmentEngine().align(
            tokens: [.init(startTime: 0, endTime: 1, text: " Hello")],
            speakerTurns: [],
            fallbackSegments: [.init(startTime: 0, endTime: 1, text: "Hello")]
        )

        #expect(result.segments.count == 1)
        #expect(result.segments[0].speakerID == nil)
        #expect(result.speakers.isEmpty)
    }
}


@Suite("Speaker identity stabilization")
struct SpeakerIdentityStabilizerTests {
    @Test func preservesNamesWhenClusteringSwapsSpeakerIDs() {
        let previousSegments = [
            TranscriptSegment(
                startTime: 0,
                endTime: 1,
                text: "Alice",
                speakerID: 0
            ),
            TranscriptSegment(
                startTime: 1,
                endTime: 2,
                text: "Bob",
                speakerID: 1
            )
        ]
        let previousSpeakers = [
            TranscriptSpeaker(id: 0, name: "Alice"),
            TranscriptSpeaker(id: 1, name: "Bob")
        ]

        let rerun = SpeakerAlignmentResult(
            segments: [
                TranscriptSegment(
                    startTime: 0,
                    endTime: 1,
                    text: "Alice",
                    speakerID: 1
                ),
                TranscriptSegment(
                    startTime: 1,
                    endTime: 2,
                    text: "Bob",
                    speakerID: 0
                )
            ],
            speakers: [
                TranscriptSpeaker(id: 0),
                TranscriptSpeaker(id: 1)
            ]
        )

        let stabilized = SpeakerIdentityStabilizer().stabilize(
            rerun,
            against: previousSegments,
            previousSpeakers: previousSpeakers
        )

        #expect(stabilized.segments.map(\.speakerID) == [0, 1])
        #expect(stabilized.speakers.map(\.name) == ["Alice", "Bob"])
    }

    @Test func assignsFreshIdentityToNewUnmatchedSpeaker() {
        let result = SpeakerAlignmentResult(
            segments: [
                TranscriptSegment(
                    startTime: 0,
                    endTime: 1,
                    text: "Known",
                    speakerID: 0
                ),
                TranscriptSegment(
                    startTime: 2,
                    endTime: 3,
                    text: "New",
                    speakerID: 1
                )
            ],
            speakers: [TranscriptSpeaker(id: 0), TranscriptSpeaker(id: 1)]
        )

        let stabilized = SpeakerIdentityStabilizer().stabilize(
            result,
            against: [
                TranscriptSegment(
                    startTime: 0,
                    endTime: 1,
                    text: "Known",
                    speakerID: 4
                )
            ],
            previousSpeakers: [TranscriptSpeaker(id: 4, name: "Known Person")]
        )

        #expect(stabilized.segments[0].speakerID == 4)
        #expect(stabilized.speakers.first?.name == "Known Person")
        #expect(stabilized.segments[1].speakerID != 4)
    }
}
