import Foundation
#if os(iOS)
import os
#endif

nonisolated enum ReadAloudSafety {
    static let maximumParagraphUTF16 = 600
    static let maximumSynthesisUTF16 = 300
    static let maximumReaderParagraphs = 20_000
    static let maximumParagraphSamples = 24_000 * 180
    static let maximumBufferSamples = 24_000 * 30
    static let maximumDocumentBytes = 16 * 1_024 * 1_024
    static let maximumProjectBytes = 64 * 1_024 * 1_024

    static func validateReaderText(_ text: String) throws {
        var units = 0
        var paragraphs = 0
        for character in text {
            let width = String(character).utf16.count
            guard width <= maximumParagraphUTF16 else {
                throw ProjectStoreError.invalidData("This section contains a text character too large to render safely. The original document is preserved.")
            }
            if units > 0 && units + width > maximumParagraphUTF16 {
                paragraphs += 1
                units = 0
            }
            units += width
            if character.isNewline || (character.isWhitespace && units >= maximumParagraphUTF16 * 3 / 4) {
                paragraphs += 1
                units = 0
            }
            guard paragraphs < maximumReaderParagraphs else {
                throw ProjectStoreError.invalidData("This section is too large to render safely on this device. The original document is preserved.")
            }
        }
    }

    static func requireMemoryHeadroom() throws {
        #if os(iOS)
        // Advisory admission check; bounded work is the primary protection.
        guard os_proc_available_memory() >= 256 * 1_024 * 1_024 else {
            throw ProjectStoreError.invalidData(
                "Listening stopped because the device is low on memory. Your progress is saved. Close other apps and try again."
            )
        }
        #endif
        try Task.checkCancellation()
    }

    static func validate(_ audio: KokoroAudio, maximumSamples: Int) throws {
        guard audio.sampleRate == ProjectWAVCodec.requiredSampleRate,
              !audio.samples.isEmpty,
              audio.samples.count <= maximumSamples,
              audio.samples.allSatisfy(\.isFinite) else {
            throw ProjectStoreError.invalidData("Speech output exceeded safe audio limits or contained invalid samples.")
        }
    }

    static func append(_ audio: KokoroAudio, to samples: inout [Float]) throws {
        try validate(audio, maximumSamples: maximumBufferSamples)
        guard samples.count <= maximumParagraphSamples - audio.samples.count else {
            throw ProjectStoreError.invalidData("This section produced too much audio to process safely. Your reading progress is saved.")
        }
        samples.append(contentsOf: audio.samples)
    }
}
