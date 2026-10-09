import Foundation

// Build once off the main actor. Publishing a passage must not rescan all text
// in a long book for every Now Playing/highlight/progress update.
nonisolated struct ProjectReadingProgressIndex: Sendable {
    var lengths: [UUID: Int] = [:]
    var prefixes: [UUID: Int] = [:]
    var totalLength = 0

    static func make(in items: [ProjectContentItem]) async throws -> Self {
        let task = Task.detached(priority: .userInitiated) {
            var result = Self()
            for item in items.sorted(by: { $0.order < $1.order }) {
                try Task.checkCancellation()
                let length = item.text.utf16.count
                result.lengths[item.id] = length
                result.prefixes[item.id] = result.totalLength
                let (total, overflow) = result.totalLength.addingReportingOverflow(max(1, length))
                guard !overflow else {
                    throw ProjectStoreError.invalidData("This book exceeds safe reading progress limits.")
                }
                result.totalLength = total
            }
            try Task.checkCancellation()
            return result
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func progress(itemID: UUID, offsetUTF16: Int) -> Double {
        guard totalLength > 0, let prefix = prefixes[itemID],
              let length = lengths[itemID] else { return 0 }
        let consumed = prefix + min(max(0, offsetUTF16), max(1, length))
        return min(1, max(0, Double(consumed) / Double(totalLength)))
    }
}

nonisolated struct ReaderParagraph: Identifiable, Equatable, Sendable {
    let index: Int
    let text: String
    let sourceRange: AudioSourceRange

    var id: Int { index }

    func estimatedDurationSeconds(
        speed: Double
    ) -> Double {
        let normalizedSpeed =
            speed.isFinite ? max(speed, 0.1) : 1.0
        let words = text.split {
            $0.isWhitespace
        }.count
        let characters = text.count

        let wordEstimate = Double(words) / 2.6
        let characterEstimate =
            Double(characters) / 14.0

        return max(
            wordEstimate,
            characterEstimate,
            0.25
        ) / normalizedSpeed
    }
}

nonisolated enum ReaderTextLayout {
    static func paragraphs(in text: String) -> [ReaderParagraph] {
        // Preserve exact source UTF-16 offsets while grouping *whole*
        // sentences into a bounded reader paragraph. Never cut at an
        // arbitrary whitespace threshold in the middle of a sentence.
        let pieces = SpeechTextSegmentation.ranges(
            in: text,
            maximumUTF16: ReadAloudSafety.maximumParagraphUTF16
        )
        var result: [ReaderParagraph] = []
        var paragraphStart = text.startIndex
        var paragraphEnd = text.startIndex
        var startUTF16 = 0
        var endUTF16 = 0

        func flush() {
            guard paragraphEnd > paragraphStart else { return }
            let raw = text[paragraphStart..<paragraphEnd]
            let leading = raw.prefix(while: { $0.isWhitespace }).utf16.count
            let trimmed = String(raw)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            result.append(ReaderParagraph(
                index: result.count,
                text: trimmed,
                sourceRange: AudioSourceRange(
                    startUTF16: startUTF16 + leading,
                    endUTF16: startUTF16 + leading + trimmed.utf16.count
                )
            ))
        }

        for piece in pieces {
            let pieceLength = text[piece].utf16.count
            let wouldOverflow = endUTF16 - startUTF16 + pieceLength
                > ReadAloudSafety.maximumParagraphUTF16

            if paragraphEnd > paragraphStart && wouldOverflow {
                flush()
                paragraphStart = piece.lowerBound
                startUTF16 = endUTF16
            }
            if paragraphEnd == paragraphStart {
                paragraphStart = piece.lowerBound
                startUTF16 = endUTF16
            }
            paragraphEnd = piece.upperBound
            endUTF16 += pieceLength

            // Actual line/paragraph boundaries take precedence over
            // opportunistic packing of neighboring short sentences.
            if text[piece].contains(where: { $0.isNewline }) {
                flush()
                paragraphStart = paragraphEnd
                startUTF16 = endUTF16
            }
        }
        flush()
        return result
    }

    static func paragraphIndex(
        forUTF16Offset offset: Int,
        in paragraphs: [ReaderParagraph]
    ) -> Int {
        guard !paragraphs.isEmpty else { return 0 }

        if let exact = paragraphs.firstIndex(where: {
            offset >= $0.sourceRange.startUTF16
                && offset < $0.sourceRange.endUTF16
        }) {
            return exact
        }

        if let next = paragraphs.firstIndex(where: {
            $0.sourceRange.startUTF16 >= offset
        }) {
            return next
        }

        return paragraphs.count - 1
    }

}
