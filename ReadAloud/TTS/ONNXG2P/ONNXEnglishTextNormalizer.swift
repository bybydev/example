import Foundation

/// Normalize common English-book typography *before* G2P tokenization.
///
/// A literal dialogue quote must never be passed to the unknown-word BART
/// decoder. Keep apostrophes *inside* words for contracted/possessive lookup.
/// Unexpected letters remain intact so non-English text still fails
/// recoverably instead of being silently discarded or mispronounced.
nonisolated enum ONNXEnglishTextNormalizer {
    static func normalize(_ text: String) -> String {
        let characters = Array(text.precomposedStringWithCompatibilityMapping)
        var result = String()
        result.reserveCapacity(characters.count)

        for (index, char) in characters.enumerated() {
            let before = index > 0 && characters[index - 1].isLetter
            let after = index + 1 < characters.count
                && characters[index + 1].isLetter

            switch char {
            // Curly right apostrophe is a word character in "Alice’s", but
            // quotation punctuation in "‘Hello,’ said Alice".
            case "’", "ʼ":
                result.append(before && after ? "'" : "”")
            case "‘", "‚", "‛", "‹", "«":
                result.append("“")
            case "›", "»":
                result.append("”")
            case "'":
                if before && after {
                    result.append("'")
                } else {
                    result.append(after ? "“" : "”")
                }
            case "\u{0060}", "´":
                result.append("“")

            // Line-breaking and nonbreaking dashes should create a pause,
            // rather than being misclassified as words.
            case "‐", "‑", "‒", "–", "―", "−", "-":
                result.append("—")

            case "[", "{":
                result.append("(")
            case "]", "}":
                result.append(")")
            case "⁝", "⋯":
                result.append("…")
            case "•", "◦", "·", "‧":
                result.append(",")
            case "※":
                result.append(".")

            // Invisible EPUB layout characters are not spoken. Preserve
            // separation to avoid joining distinct words accidentally.
            case "\u{200B}", "\u{2060}", "\u{FEFF}",
                 "\u{200E}", "\u{200F}", "\u{00AD}":
                result.append(" ")

            // Common speech-bearing symbols become words, not dropped text.
            case "&":
                result.append(" and ")
            case "%":
                result.append(" percent ")
            case "+":
                result.append(" plus ")
            case "=":
                result.append(" equals ")
            case "@":
                result.append(" at ")
            case "$":
                result.append(" dollars ")
            case "£":
                result.append(" pounds ")
            case "€":
                result.append(" euros ")
            case "¥":
                result.append(" yen ")
            case "°":
                result.append(" degrees ")
            case "×":
                result.append(" times ")
            case "÷":
                result.append(" divided by ")
            case "#":
                result.append(" number ")
            case "/":
                result.append(" slash ")

            default:
                result.append(char)
            }
        }
        return result
    }
}
