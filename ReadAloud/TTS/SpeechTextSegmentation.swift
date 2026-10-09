import Foundation
import NaturalLanguage

/// Shared, source-preserving speech boundaries for the reader and the ONNX
/// scheduler. NLTokenizer handles sentence punctuation and abbreviations;
/// length limits are safety ceilings, never a target speaking duration.
nonisolated enum SpeechTextSegmentation {
    static func ranges(
        in text: String,
        maximumUTF16: Int
    ) -> [Range<String.Index>] {
        guard !text.isEmpty else { return [] }
        let limit = max(1, maximumUTF16)
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.setLanguage(.english)

        var sentences: [Range<String.Index>] = []
        var cursor = text.startIndex
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            // Include every inter-token character (spaces, quotes, etc.).
            guard range.upperBound > cursor else { return true }
            sentences.append(cursor..<range.upperBound)
            cursor = range.upperBound
            return true
        }
        if cursor < text.endIndex {
            sentences.append(cursor..<text.endIndex)
        }
        if sentences.isEmpty {
            sentences = [text.startIndex..<text.endIndex]
        }

        var result: [Range<String.Index>] = []
        for sentence in sentences {
            result.append(contentsOf: boundedRanges(
                in: text, within: sentence, maximumUTF16: limit
            ))
        }
        return result
    }

    /// Prefer punctuation boundaries inside otherwise lengthy sentences,
    /// while coalescing short fragments into speakable clauses.
    static func clauseRanges(
        in text: String,
        within range: Range<String.Index>
    ) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var start = range.lowerBound
        var cursor = start
        var count = 0
        while cursor < range.upperBound {
            let character = text[cursor]
            count += String(character).utf16.count
            let next = text.index(after: cursor)
            if ",;:—–".contains(character),
               count >= 28 {
                let remaining = text[next..<range.upperBound].utf16.count
                if remaining == 0 || remaining >= 24 {
                    result.append(start..<next)
                    start = next
                    count = 0
                }
            }
            cursor = next
        }
        if start < range.upperBound {
            result.append(start..<range.upperBound)
        }
        return result
    }

    /// A last-resort model-token overflow split. Prefer the most natural
    /// boundary near the center; never drop words or split a word silently.
    static func splitForModelBudget(_ text: String) -> (String, String)? {
        let characters = Array(text)
        guard characters.count >= 2 else { return nil }
        let middle = characters.count / 2
        var sentence: Int?
        var clause: Int?
        var space: Int?
        var sentenceDistance = Int.max
        var clauseDistance = Int.max
        var spaceDistance = Int.max

        for index in 1..<characters.count {
            let previous = characters[index - 1]
            let next = characters[index]
            guard next.isWhitespace else { continue }
            let distance = abs(index - middle)
            if ".!?".contains(previous), distance < sentenceDistance {
                sentence = index
                sentenceDistance = distance
            } else if ",;:—–".contains(previous), distance < clauseDistance {
                clause = index
                clauseDistance = distance
            } else if distance < spaceDistance {
                space = index
                spaceDistance = distance
            }
        }
        guard let cut = sentence ?? clause ?? space else { return nil }
        let left = String(characters[..<cut])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let right = String(characters[cut...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty, !right.isEmpty else { return nil }
        return (left, right)
    }

    private static func boundedRanges(
        in text: String,
        within range: Range<String.Index>,
        maximumUTF16 limit: Int
    ) -> [Range<String.Index>] {
        var pieces: [Range<String.Index>] = []
        var start = range.lowerBound

        while start < range.upperBound {
            var cursor = start
            var units = 0
            var clause: String.Index?
            var word: String.Index?

            while cursor < range.upperBound {
                let character = text[cursor]
                let width = String(character).utf16.count
                if units > 0 && units + width > limit { break }
                let next = text.index(after: cursor)
                units += width
                if units >= limit / 2 {
                    if ",;:—–".contains(character) { clause = next }
                    if character.isWhitespace { word = next }
                }
                cursor = next
                if units >= limit { break }
            }

            if cursor == range.upperBound {
                pieces.append(start..<cursor)
                break
            }

            // A long sentence is split only when its *hard* safe limit is
            // reached: clauses first, words second, then a grapheme boundary.
            // All characters belong to exactly one emitted range.
            let end = clause ?? word ?? cursor
            guard end > start else {
                let next = text.index(after: start)
                pieces.append(start..<next)
                start = next
                continue
            }
            pieces.append(start..<end)
            start = end
        }
        return pieces
    }
}
