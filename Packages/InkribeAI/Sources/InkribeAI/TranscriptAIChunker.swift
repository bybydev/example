import Foundation

public struct TranscriptAIChunker: Equatable, Sendable {
    public let maximumCharacters: Int

    public init(maximumCharacters: Int = 4_000) {
        self.maximumCharacters = max(256, maximumCharacters)
    }

    public func chunks(for text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        guard text.count > maximumCharacters else { return [text] }

        var chunks: [String] = []
        var start = text.startIndex

        while start < text.endIndex {
            let hardEnd = text.index(
                start,
                offsetBy: maximumCharacters,
                limitedBy: text.endIndex
            ) ?? text.endIndex

            if hardEnd == text.endIndex {
                chunks.append(String(text[start..<text.endIndex]))
                break
            }

            let preferredRange = start..<hardEnd
            let cut = preferredCut(in: text, range: preferredRange) ?? hardEnd
            guard cut > start else {
                chunks.append(String(text[start..<hardEnd]))
                start = hardEnd
                continue
            }

            chunks.append(String(text[start..<cut]))
            start = cut
        }

        return chunks.filter { !$0.isEmpty }
    }

    private func preferredCut(
        in text: String,
        range: Range<String.Index>
    ) -> String.Index? {
        let minimumPreferredLength = maximumCharacters / 2
        let minimumIndex = text.index(
            range.lowerBound,
            offsetBy: minimumPreferredLength,
            limitedBy: range.upperBound
        ) ?? range.lowerBound
        let preferredSearchRange = minimumIndex..<range.upperBound

        for separator in ["\n\n", "\n", ". ", "? ", "! ", "; ", ", ", " "] {
            if let match = text.range(
                of: separator,
                options: .backwards,
                range: preferredSearchRange
            ) {
                return match.upperBound
            }
        }

        return nil
    }
}
