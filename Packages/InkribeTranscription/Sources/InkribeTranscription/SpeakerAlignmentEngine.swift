import DiarizationRuntime
import Foundation
import InkribeCore
import WhisperRuntime

struct SpeakerAlignmentResult: Equatable, Sendable {
    let segments: [TranscriptSegment]
    let speakers: [TranscriptSpeaker]
}

struct SpeakerAlignmentEngine: Sendable {
    private let nearestTurnTolerance: TimeInterval
    private let mergeGapTolerance: TimeInterval
    private let shortIslandDuration: TimeInterval

    init(
        nearestTurnTolerance: TimeInterval = 0.35,
        mergeGapTolerance: TimeInterval = 1.0,
        shortIslandDuration: TimeInterval = 0.35
    ) {
        self.nearestTurnTolerance = max(0, nearestTurnTolerance)
        self.mergeGapTolerance = max(0, mergeGapTolerance)
        self.shortIslandDuration = max(0, shortIslandDuration)
    }

    func align(
        tokens: [WhisperToken],
        speakerTurns: [SpeakerTurn],
        fallbackSegments: [WhisperSegment]
    ) -> SpeakerAlignmentResult {
        let turns = speakerTurns
            .filter { $0.endTime > $0.startTime }
            .sorted {
                if $0.startTime != $1.startTime {
                    return $0.startTime < $1.startTime
                }
                return $0.speakerID < $1.speakerID
            }

        guard !turns.isEmpty else {
            return fallback(fallbackSegments)
        }

        let aligned = tokens.compactMap { token -> AlignedToken? in
            guard !token.text.isEmpty else { return nil }
            return AlignedToken(
                token: token,
                speakerID: bestSpeaker(for: token, turns: turns)
            )
        }

        let rawSegments: [TranscriptSegment]
        if aligned.isEmpty {
            rawSegments = fallbackSegments.map {
                TranscriptSegment(
                    startTime: $0.startTime,
                    endTime: $0.endTime,
                    text: $0.text,
                    speakerID: bestSpeaker(
                        startTime: $0.startTime,
                        endTime: $0.endTime,
                        turns: turns
                    )
                )
            }
        } else {
            rawSegments = group(aligned)
        }

        let segments = smooth(rawSegments)
        let speakerIDs = Set(segments.compactMap(\.speakerID)).sorted()
        return SpeakerAlignmentResult(
            segments: segments,
            speakers: speakerIDs.map { TranscriptSpeaker(id: $0) }
        )
    }

    private func fallback(_ segments: [WhisperSegment]) -> SpeakerAlignmentResult {
        SpeakerAlignmentResult(
            segments: segments.map {
                TranscriptSegment(
                    startTime: $0.startTime,
                    endTime: $0.endTime,
                    text: $0.text
                )
            },
            speakers: []
        )
    }

    private func bestSpeaker(
        for token: WhisperToken,
        turns: [SpeakerTurn]
    ) -> Int? {
        bestSpeaker(
            startTime: token.startTime,
            endTime: token.endTime,
            turns: turns
        )
    }

    private func bestSpeaker(
        startTime: TimeInterval,
        endTime: TimeInterval,
        turns: [SpeakerTurn]
    ) -> Int? {
        let start = min(startTime, endTime)
        let end = max(startTime, endTime)
        let midpoint = (start + end) / 2

        var bestID: Int?
        var bestOverlap: TimeInterval = 0
        var bestMidpointDistance = TimeInterval.greatestFiniteMagnitude

        for turn in turns {
            let overlap = max(0, min(end, turn.endTime) - max(start, turn.startTime))
            let distance: TimeInterval
            if midpoint < turn.startTime {
                distance = turn.startTime - midpoint
            } else if midpoint > turn.endTime {
                distance = midpoint - turn.endTime
            } else {
                distance = 0
            }

            if overlap > bestOverlap
                || (overlap == bestOverlap && overlap > 0 && distance < bestMidpointDistance) {
                bestID = turn.speakerID
                bestOverlap = overlap
                bestMidpointDistance = distance
            }
        }

        if bestOverlap > 0 {
            return bestID
        }

        let nearest = turns.min { lhs, rhs in
            distance(from: midpoint, to: lhs) < distance(from: midpoint, to: rhs)
        }
        guard let nearest,
              distance(from: midpoint, to: nearest) <= nearestTurnTolerance else {
            return nil
        }
        return nearest.speakerID
    }

    private func distance(from time: TimeInterval, to turn: SpeakerTurn) -> TimeInterval {
        if time < turn.startTime { return turn.startTime - time }
        if time > turn.endTime { return time - turn.endTime }
        return 0
    }

    private func group(_ tokens: [AlignedToken]) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []

        for aligned in tokens {
            let token = aligned.token
            if var last = segments.last,
               last.speakerID == aligned.speakerID,
               token.startTime <= last.endTime + mergeGapTolerance {
                last.endTime = max(last.endTime, token.endTime)
                last.text += token.text
                segments[segments.count - 1] = last
            } else {
                segments.append(
                    TranscriptSegment(
                        startTime: token.startTime,
                        endTime: token.endTime,
                        text: token.text,
                        speakerID: aligned.speakerID
                    )
                )
            }
        }

        return segments.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func smooth(_ input: [TranscriptSegment]) -> [TranscriptSegment] {
        guard input.count >= 3 else {
            return mergeAdjacent(input).map {
                var segment = $0
                segment.text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return segment
            }
        }
        var segments = input
        var index = 1

        while index < segments.count - 1 {
            let previous = segments[index - 1]
            let current = segments[index]
            let next = segments[index + 1]
            let duration = max(0, current.endTime - current.startTime)

            if duration <= shortIslandDuration,
               previous.speakerID != nil,
               previous.speakerID == next.speakerID,
               current.speakerID != previous.speakerID {
                var merged = previous
                merged.endTime = max(next.endTime, current.endTime)
                merged.text = previous.text + current.text + next.text
                segments.replaceSubrange((index - 1)...(index + 1), with: [merged])
                index = max(1, index - 1)
                continue
            }
            index += 1
        }

        return mergeAdjacent(segments).map {
            var segment = $0
            segment.text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return segment
        }
    }

    private func mergeAdjacent(_ input: [TranscriptSegment]) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        for segment in input {
            if var last = result.last,
               last.speakerID == segment.speakerID,
               segment.startTime <= last.endTime + mergeGapTolerance {
                last.endTime = max(last.endTime, segment.endTime)
                last.text += segment.text
                result[result.count - 1] = last
            } else {
                result.append(segment)
            }
        }
        return result
    }


}

private struct AlignedToken {
    let token: WhisperToken
    let speakerID: Int?
}
