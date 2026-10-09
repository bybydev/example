import Foundation

/// Strictly local text/phoneme-to-Kokoro-token adapter. The vocabulary comes
/// from the already-bundled, SHA-256-pinned Misaki ONNX sidecar JSON.
nonisolated struct KokoroPhonemeResult: Sendable {
    let phonemes: String
    let droppedTokens: Int
    var utf16Count: Int { phonemes.utf16.count }
}

nonisolated struct KokoroTextProcessor {
    private let phonemizer: ONNXG2PPhonemizer
    private let vocab: [String: Int32]

    init(phonemizer: ONNXG2PPhonemizer, vocab: [String: Int32]) throws {
        guard !vocab.isEmpty, vocab.values.allSatisfy({ $0 >= 0 }),
              vocab[" "] != nil else {
            throw SpeechEngineError.loadFailed("Bundled Kokoro vocabulary is invalid.")
        }
        self.phonemizer = phonemizer
        self.vocab = vocab
    }

    func phonemize(_ text: String) throws -> KokoroPhonemeResult {
        let normalized = Self.normalizeWhitespace(text)
        guard !normalized.isEmpty else {
            throw SpeechEngineError.synthesisFailed("Empty speech text.")
        }
        return try phonemizer.phonemize(normalized)
    }

    func tokenization(forPhonemes phonemes: String)
        -> (tokenIDs: [Int32], droppedCharacters: Int) {
        var tokenIDs: [Int32] = []
        var dropped = 0
        for char in phonemes {
            if let id = vocab[String(char)] {
                tokenIDs.append(id)
            } else {
                dropped += 1
            }
        }
        return (tokenIDs, dropped)
    }

    static func normalizeWhitespace(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
