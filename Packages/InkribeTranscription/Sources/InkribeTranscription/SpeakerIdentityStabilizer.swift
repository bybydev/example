import Foundation
import InkribeCore

struct SpeakerIdentityStabilizer: Sendable {
    func stabilize(
        _ result: SpeakerAlignmentResult,
        against previousSegments: [TranscriptSegment],
        previousSpeakers: [TranscriptSpeaker]
    ) -> SpeakerAlignmentResult {
        let previousIDs = Set(previousSegments.compactMap(\.speakerID))
        let newIDs = Set(result.segments.compactMap(\.speakerID))

        guard !previousIDs.isEmpty, !newIDs.isEmpty else {
            return result
        }

        var overlapByPair: [SpeakerPair: TimeInterval] = [:]
        for oldSegment in previousSegments {
            guard let oldID = oldSegment.speakerID else { continue }
            for newSegment in result.segments {
                guard let newID = newSegment.speakerID else { continue }
                let overlap = max(
                    0,
                    min(oldSegment.endTime, newSegment.endTime)
                        - max(oldSegment.startTime, newSegment.startTime)
                )
                guard overlap > 0 else { continue }
                overlapByPair[
                    SpeakerPair(oldID: oldID, newID: newID),
                    default: 0
                ] += overlap
            }
        }

        let candidates = overlapByPair
            .filter { $0.value > 0 }
            .sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                if $0.key.oldID != $1.key.oldID { return $0.key.oldID < $1.key.oldID }
                return $0.key.newID < $1.key.newID
            }

        var usedOldIDs = Set<Int>()
        var usedNewIDs = Set<Int>()
        var stableIDByNewID: [Int: Int] = [:]

        for (pair, _) in candidates {
            guard !usedOldIDs.contains(pair.oldID),
                  !usedNewIDs.contains(pair.newID) else {
                continue
            }
            stableIDByNewID[pair.newID] = pair.oldID
            usedOldIDs.insert(pair.oldID)
            usedNewIDs.insert(pair.newID)
        }

        var nextID = max(
            previousIDs.max() ?? -1,
            newIDs.max() ?? -1
        ) + 1
        for newID in newIDs.sorted() where stableIDByNewID[newID] == nil {
            while usedOldIDs.contains(nextID) {
                nextID += 1
            }
            stableIDByNewID[newID] = nextID
            usedOldIDs.insert(nextID)
            nextID += 1
        }

        let renamedByID = previousSpeakers.reduce(into: [Int: String]()) {
            $0[$1.id] = $1.name
        }

        let segments = result.segments.map { segment -> TranscriptSegment in
            guard let newID = segment.speakerID,
                  let stableID = stableIDByNewID[newID] else {
                return segment
            }
            var segment = segment
            segment.speakerID = stableID
            return segment
        }

        let speakerIDs = Set(segments.compactMap(\.speakerID)).sorted()
        let speakers = speakerIDs.map { id in
            TranscriptSpeaker(id: id, name: renamedByID[id])
        }

        return SpeakerAlignmentResult(
            segments: segments,
            speakers: speakers
        )
    }
}

private struct SpeakerPair: Hashable {
    let oldID: Int
    let newID: Int
}
