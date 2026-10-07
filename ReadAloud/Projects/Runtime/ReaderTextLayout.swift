import Foundation

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
    static func paragraphs(
        in text: String
    ) -> [ReaderParagraph] {
        let nsText = text as NSString
        let length = nsText.length
        guard length > 0 else { return [] }

        var paragraphs: [ReaderParagraph] = []
        var cursor = 0

        while cursor < length {
            while cursor < length,
                  isNewline(at: cursor, in: nsText) {
                cursor += 1
            }

            guard cursor < length else { break }

            let start = cursor
            var end = cursor

            while end < length {
                if isParagraphBreak(
                    at: end,
                    in: nsText
                ) {
                    break
                }
                end += 1
            }

            let rawRange = NSRange(
                location: start,
                length: end - start
            )
            let raw = nsText.substring(
                with: rawRange
            )
            let trimmed = raw.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

            if !trimmed.isEmpty {
                let leadingLength =
                    raw.utf16.count
                    - raw.drop {
                        $0.isWhitespace
                    }.utf16.count
                let trailingLength =
                    raw.reversed().prefix {
                        $0.isWhitespace
                    }.count
                let rangeStart =
                    start + leadingLength
                let rangeEnd =
                    max(
                        rangeStart,
                        end - trailingLength
                    )

                paragraphs.append(
                    ReaderParagraph(
                        index: paragraphs.count,
                        text: trimmed,
                        sourceRange: AudioSourceRange(
                            startUTF16: rangeStart,
                            endUTF16: rangeEnd
                        )
                    )
                )
            }

            cursor = end
            while cursor < length,
                  isNewline(at: cursor, in: nsText) {
                cursor += 1
            }
        }

        if paragraphs.isEmpty {
            let trimmed = text.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !trimmed.isEmpty {
                paragraphs.append(
                    ReaderParagraph(
                        index: 0,
                        text: trimmed,
                        sourceRange: AudioSourceRange(
                            startUTF16: 0,
                            endUTF16: length
                        )
                    )
                )
            }
        }

        return paragraphs
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

    private static func isParagraphBreak(
        at index: Int,
        in text: NSString
    ) -> Bool {
        guard isNewline(at: index, in: text) else {
            return false
        }

        var cursor = index + 1
        while cursor < text.length {
            let scalar = text.character(at: cursor)
            if scalar == 10 || scalar == 13 {
                return true
            }
            if scalar == 32 || scalar == 9 {
                cursor += 1
                continue
            }
            return false
        }

        return false
    }

    private static func isNewline(
        at index: Int,
        in text: NSString
    ) -> Bool {
        guard index < text.length else {
            return false
        }
        let scalar = text.character(at: index)
        return scalar == 10 || scalar == 13
    }
}
