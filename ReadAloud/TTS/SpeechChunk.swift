import Foundation

nonisolated struct SpeechChunk: Identifiable, Equatable, Sendable {
    let id: Int
    let text: String
    let sourceRange: AudioSourceRange
    let targetBucketSeconds: Int
    let maxChunkSeconds: Double
    let estimatedDurationSeconds: Double
}

/// Plans complete sentences first, instead of splitting every ~3/7 seconds.
/// Only an unusually long sentence is divided at its hard safety ceiling,
/// preferring clauses and then whole-word boundaries.
nonisolated struct SpeechChunkScheduler: Sendable {
    private let availableBuckets: [Int]

    init(availableBuckets: [Int] = [3, 7, 10, 15]) {
        let normalized = Array(Set(availableBuckets.filter { $0 > 0 })).sorted()
        self.availableBuckets = normalized.isEmpty ? [15] : normalized
    }

    func chunks(for text: String, speed: Float = 1.0) -> [SpeechChunk] {
        let normalizedSpeed = speed.isFinite
            ? min(2.0, max(Double(speed), 0.5)) : 1.0
        // Slower voices need smaller safety ceilings to remain within the
        // playback buffer's 30-second maximum. This is not a duration target.
        // ONNX prefers short clauses. The 100-unit ceiling is independent of
        // acoustic model buckets and is never a reason to cut inside a word.
        let hardUTF16 = min(ReadAloudSafety.maximumSynthesisUTF16, 100)
        let sentences = SpeechTextSegmentation.ranges(
            in: text, maximumUTF16: hardUTF16
        )
        let ranges = sentences.flatMap {
            SpeechTextSegmentation.clauseRanges(in: text, within: $0)
        }

        var result: [SpeechChunk] = []
        var cursor = text.startIndex
        var cursorUTF16 = 0
        for range in ranges {
            cursorUTF16 += text[cursor..<range.lowerBound].utf16.count
            let source = text[range]
            let leading = source.prefix(while: { $0.isWhitespace }).utf16.count
            let sentence = String(source)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let start = cursorUTF16 + leading
            cursorUTF16 += source.utf16.count
            cursor = range.upperBound
            guard !sentence.isEmpty else { continue }

            let words = sentence.split(whereSeparator: { $0.isWhitespace }).count
            let estimated = max(
                Double(words) / 2.6,
                Double(sentence.count) / 14.0,
                0.25
            ) / normalizedSpeed
            let bucket = availableBuckets.first(where: {
                Double($0) >= estimated
            }) ?? availableBuckets.last ?? 15

            result.append(SpeechChunk(
                id: result.count,
                text: sentence,
                sourceRange: AudioSourceRange(
                    startUTF16: start, endUTF16: start + sentence.utf16.count
                ),
                targetBucketSeconds: bucket,
                maxChunkSeconds: min(30, max(3, estimated)),
                estimatedDurationSeconds: estimated
            ))
        }
        return result
    }
}
