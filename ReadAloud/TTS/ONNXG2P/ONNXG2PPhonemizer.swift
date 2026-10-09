import Foundation

/// Misaki-compatible US English dictionary + CPU-ONNX BART fallback.
/// This component never imports or creates MisakiSwift/MLX objects.
/// Caller (KokoroONNXEngine actor) serializes all calls.
nonisolated final class ONNXG2PPhonemizer {
    enum Error: LocalizedError {
        case invalidMetadata
        case unsupportedText
        case unsupportedCharacter(UInt32)
        case missingPronunciation
        case invalidNumber

        var errorDescription: String? {
            switch self {
            case .invalidMetadata:
                "The ONNX pronunciation dictionary is invalid."
            case .unsupportedText:
                "This English voice could not find any readable text in the passage."
            case .unsupportedCharacter(let codepoint):
                "This English voice cannot pronounce a character in the passage (U+\(String(format: "%04X", codepoint)))."
            case .missingPronunciation:
                "The ONNX pronunciation model could not resolve a word."
            case .invalidNumber:
                "This ONNX voice cannot safely normalize a number."
            }
        }
    }

    let vocabulary: [String: Int32]
    private let gold: [String: Any]
    private let silver: [String: Any]
    private let fallback: ONNXG2PBART
    private let tokenizer: NSRegularExpression
    private var recent: [String: String] = [:]
    private static let punctuation = Set(";:,.!?—…“”()\"")
    private static let vowelSounds = Set("aeiou")

    init(modelURL: URL, metadataURL: URL) throws {
        let data = try Data(contentsOf: metadataURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gold = json["gold"] as? [String: Any],
              let silver = json["silver"] as? [String: Any] else {
            throw Error.invalidMetadata
        }
        guard let rawVocab = json["kokoro_vocab"] as? [String: Any],
              !rawVocab.isEmpty else {
            throw Error.invalidMetadata
        }
        var vocab: [String: Int32] = [:]
        for (symbol, rawValue) in rawVocab {
            guard let number = rawValue as? NSNumber,
                  number.int64Value >= 0,
                  number.int64Value <= Int32.max else {
                throw Error.invalidMetadata
            }
            vocab[symbol] = number.int32Value
        }
        self.vocabulary = vocab
        self.gold = gold
        self.silver = silver
        self.fallback = try ONNXG2PBART(model: modelURL, metadata: json)
        self.tokenizer = try NSRegularExpression(
            pattern: #"\p{L}[\p{L}'’]*|\p{N}+(?:[.,]\p{N}+)*|[^\s]"#
        )
    }

    /// Covers every word or fails. We deliberately do not return the silent
    /// unknown-word marker ("❓") or drop speech-bearing tokens.
    func phonemize(_ text: String) throws -> KokoroPhonemeResult {
        try Task.checkCancellation()
        // EPUB dialogue commonly uses curly single quotes. Distinguish those
        // standalone marks from contractions before passing words to G2P.
        let source = ONNXEnglishTextNormalizer.normalize(text)
        let ns = source as NSString
        let matches = tokenizer.matches(
            in: source, range: NSRange(location: 0, length: ns.length)
        )
        guard !matches.isEmpty else { throw Error.unsupportedText }
        let tokens = matches.map { ns.substring(with: $0.range) }

        var output = ""
        var previousWasWord = false

        for (index, token) in tokens.enumerated() {
            try Task.checkCancellation()

            if token.count == 1, let character = token.first,
               Self.punctuation.contains(character) {
                output += token
                previousWasWord = false
                continue
            }

            if token == "[" || token == "]" {
                output += token == "[" ? "(" : ")"
                previousWasWord = false
                continue
            }

            let spokenText: String
            if token.first?.isNumber == true {
                spokenText = try Self.spellNumber(token)
            } else if token == "&" {
                spokenText = "and"
            } else if token == "%" {
                spokenText = "percent"
            } else if token == "+" {
                spokenText = "plus"
            } else if token == "=" {
                spokenText = "equals"
            } else if token == "@" {
                spokenText = "at"
            } else if token == "$" {
                spokenText = "dollars"
            } else if token == "#" {
                spokenText = "number"
            } else if token == "/" {
                spokenText = "slash"
            } else if token == "-" || token == "–" {
                output += "—"
                previousWasWord = false
                continue
            } else {
                spokenText = token
            }

            let next = tokens.dropFirst(index + 1).first { next in
                next.first?.isLetter == true
            }
            let pronunciation = try phrase(spokenText, following: next)
            guard !pronunciation.isEmpty else {
                throw Error.missingPronunciation
            }
            if previousWasWord && !output.isEmpty {
                output += " "
            } else if !output.isEmpty,
                      let previous = output.last,
                      !Self.punctuation.contains(previous),
                      previous != " " {
                output += " "
            }
            output += pronunciation
            previousWasWord = true
        }

        guard output.contains(where: { $0.isLetter }) else {
            throw Error.missingPronunciation
        }
        return KokoroPhonemeResult(phonemes: output, droppedTokens: 0)
    }

    private func phrase(_ source: String, following: String?) throws -> String {
        let words = source.split(separator: " ").map(String.init)
        guard !words.isEmpty else { throw Error.missingPronunciation }
        var results: [String] = []
        for (index, word) in words.enumerated() {
            try Task.checkCancellation()
            let next = words.indices.contains(index + 1)
                ? words[index + 1] : following
            results.append(try pronounce(word, following: next))
        }
        return results.joined(separator: " ")
    }

    private func pronounce(_ source: String, following: String?) throws -> String {
        let ascii = source.folding(
            options: [.diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US")
        )
        guard !ascii.isEmpty else { throw Error.unsupportedText }
        for scalar in ascii.unicodeScalars {
            let value = scalar.value
            guard (65...90).contains(value) || (97...122).contains(value)
                    || value == 39 else {
                throw Error.unsupportedCharacter(value)
            }
        }

        let lower = ascii.lowercased()
        if let special = specialPronunciation(ascii, following: following) {
            return special
        }
        if let found = lookup(ascii) ?? lookup(lower) {
            return found
        }
        if let stem = inflection(lower) {
            return stem
        }
        if let cached = recent[lower] { return cached }
        let result = try fallback.pronounce(lower)
        guard !result.isEmpty else { throw Error.missingPronunciation }

        // Keep unknown-word inference reusable but bounded per engine lifetime.
        if recent.count >= 256 {
            recent.removeAll(keepingCapacity: true)
        }
        recent[lower] = result
        return result
    }

    private func specialPronunciation(_ word: String, following: String?) -> String? {
        if word == "I" { return "ˌI" }
        if word == "a" || word == "A" { return following == nil ? "ˈA" : "ɐ" }
        let lower = word.lowercased()
        if word.count > 1 && word == word.uppercased() { return nil }
        let isVowelNext = following?.first.map {
            Self.vowelSounds.contains(Character(String($0).lowercased()))
        } ?? false
        switch lower {
        case "the": return isVowelNext ? "ði" : "ðə"
        case "to": return following == nil ? lookup("to") : (isVowelNext ? "tʊ" : "tə")
        case "an": return "ɐn"
        default: return nil
        }
    }

    private func lookup(_ word: String) -> String? {
        // Gold > silver. Dictionary values may be a heteronym map with
        // "DEFAULT" pronunciation rather than a direct IPA string.
        for variant in [word, word.capitalized, word.lowercased()] {
            if let result = Self.entry(gold[variant]) {
                return result
            }
            if let result = Self.entry(silver[variant]) {
                return result
            }
        }
        if word.count == 1, word.first?.isLetter == true {
            return Self.entry(gold[word.uppercased()])
        }
        return nil
    }

    private static func entry(_ value: Any?) -> String? {
        if let pronunciation = value as? String, !pronunciation.isEmpty {
            return pronunciation
        }
        if let heteronyms = value as? [String: Any] {
            return heteronyms["DEFAULT"] as? String
        }
        return nil
    }

    private func inflection(_ word: String) -> String? {
        // A limited set of deterministic English suffixes avoids invoking
        // BART for common inflections not separately listed in the lexicon.
        if word.count >= 4 && word.hasSuffix("s") {
            let stem = String(word.dropLast())
            if let base = lookup(stem), let last = base.last {
                let tail = "ptkfθ".contains(last) ? "s"
                    : "szʃʒʧʤ".contains(last) ? "ᵻz" : "z"
                return base + tail
            }
            if word.hasSuffix("ies"), let base = lookup(String(word.dropLast(3)) + "y") {
                return base + "z"
            }
        }
        if word.count >= 5 && word.hasSuffix("ed") {
            let stem = String(word.dropLast(2))
            let root = lookup(stem) ?? lookup(stem + "e")
            if let base = root, let last = base.last {
                return base + ("td".contains(last) ? "ᵻd" : "pkfθʃsʧ".contains(last) ? "t" : "d")
            }
        }
        if word.count >= 6 && word.hasSuffix("ing") {
            let stem = String(word.dropLast(3))
            if let base = lookup(stem) ?? lookup(stem + "e") {
                return base + "ɪŋ"
            }
        }
        return nil
    }

    private static func spellNumber(_ text: String) throws -> String {
        let number = text.replacingOccurrences(of: ",", with: "")
        guard number.count <= 18 else { throw Error.invalidNumber }
        let components = number.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count <= 2,
              let value = Int64(components[0]) else {
            throw Error.invalidNumber
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = Locale(identifier: "en_US")
        guard let spelled = formatter.string(from: NSNumber(value: value)) else {
            throw Error.invalidNumber
        }
        guard components.count == 2 else {
            return spelled.replacingOccurrences(of: "-", with: " ")
        }
        let digits = components[1].map { String($0) }
        guard !digits.isEmpty else { throw Error.invalidNumber }
        var spoken = spelled + " point"
        for digit in digits {
            guard let value = Int(digit),
                  let name = formatter.string(from: NSNumber(value: value)) else {
                throw Error.invalidNumber
            }
            spoken += " " + name
        }
        return spoken.replacingOccurrences(of: "-", with: " ")
    }
}
