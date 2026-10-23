import CoreMedia
import Foundation
import NaturalLanguage
import WhisperRuntime

/// Prefer native token unions. Missing word timing falls back to the model's
/// own segment text/interval as one timed phrase, never invented word boundaries.
enum WordMapper {
    static let currentMappingVersion = 2
    static func rawWindow(_ result: WhisperTranscriptionResult, clipID: UUID,
                          interval: MediaInterval) -> RecognitionWindow {
        RecognitionWindow(id: UUID(), clipID: clipID, sourceInterval: interval,
            languageCode: result.detectedLanguageCode,
            segments: result.segments.map {
                RawSpeechSegment(text: $0.text, startSeconds: $0.startTime, endSeconds: $0.endTime)
            }, tokens: result.tokens.map {
                RawSpeechToken(utf8: $0.utf8 ?? Data($0.text.utf8),
                    startSeconds: $0.startTime, endSeconds: $0.endTime,
                    hasTiming: $0.hasValidTimestamps ?? ($0.endTime > $0.startTime))
            })
    }

    static func words(in window: RecognitionWindow, clip: ProjectClip,
                      core: MediaInterval, mappingVersion: Int = 1) throws -> [CaptionWord] {
        guard (1...currentMappingVersion).contains(mappingVersion) else { throw SpeechRecoveryError.incompatible }
        // Keep the original mapping reproducible for already accepted identities.
        if mappingVersion == 1 { return try tokenWords(in: window, clip: clip, core: core) }
        guard window.segments.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return try tokenWords(in: window, clip: clip, core: core)
        }

        let segmentBytes = window.segments.map { Data($0.text.utf8) }
        let text = segmentBytes.reduce(into: Data()) { $0.append($1) }
        var bytes = Data()
        var boundaries = [0]
        for token in window.tokens { bytes.append(token.utf8); boundaries.append(bytes.count) }
        // Native segment and token streams normally match exactly. Only then
        // partition tokens; never guess text/byte associations across segments.
        var segmentBoundaries = Set([0])
        var byteCount = 0
        for part in segmentBytes { byteCount += part.count; segmentBoundaries.insert(byteCount) }
        let tokenBoundaries = Set(boundaries)
        let canPartition = bytes == text && boundaries.count == tokenBoundaries.count &&
            segmentBoundaries.isSubset(of: tokenBoundaries)
        var offset = 0
        var output: [CaptionWord] = []
        for (index, segment) in window.segments.enumerated() {
            let end = offset + segmentBytes[index].count
            defer { offset = end }
            if segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            if canPartition, let first = boundaries.firstIndex(of: offset), let last = boundaries.firstIndex(of: end) {
                let part = RecognitionWindow(id: window.id, clipID: window.clipID,
                    sourceInterval: window.sourceInterval, languageCode: window.languageCode,
                    segments: [segment], tokens: Array(window.tokens[first..<last]))
                do {
                    output.append(contentsOf: try tokenWords(in: part, clip: clip, core: core))
                    continue
                } catch let error as SpeechError {
                    switch error {
                    case .wordTimingUnavailable, .invalidUTF8: break
                    default: throw error
                    }
                } catch is MediaTimeError {
                    // Try the independently reported native segment interval.
                }
            }
            if let phrase = try segmentPhrase(segment, window: window, clip: clip, core: core) {
                output.append(phrase)
            }
        }
        return output
    }

    private static func segmentPhrase(_ segment: RawSpeechSegment, window: RecognitionWindow,
                                      clip: ProjectClip, core: MediaInterval) throws -> CaptionWord? {
        guard !segment.text.contains("\u{FFFD}") else { throw SpeechError.invalidUTF8 }
        guard segment.startSeconds.isFinite, segment.endSeconds.isFinite,
              segment.startSeconds >= 0, segment.endSeconds > segment.startSeconds else {
            throw SpeechError.wordTimingUnavailable
        }
        let start = max(max(clip.sourceInterval.start, window.sourceInterval.start),
            try MediaTime(validating: CMTimeAdd(window.sourceInterval.start.cmTime,
                CMTime(seconds: segment.startSeconds, preferredTimescale: 16_000))))
        let end = min(min(clip.sourceInterval.end, window.sourceInterval.end),
            try MediaTime(validating: CMTimeAdd(window.sourceInterval.start.cmTime,
                CMTime(seconds: segment.endSeconds, preferredTimescale: 16_000))))
        guard start < end else { throw SpeechError.wordTimingUnavailable }
        let interval = try MediaInterval(start: start, end: end)
        let midpoint = CMTimeAdd(start.cmTime, CMTimeMultiplyByFloat64(interval.duration, multiplier: 0.5))
        guard CMTimeCompare(midpoint, core.start.cmTime) >= 0,
              CMTimeCompare(midpoint, core.end.cmTime) < 0 else { return nil }
        let projectStart = CMTimeAdd(clip.timelineInterval.start.cmTime,
            CMTimeSubtract(start.cmTime, clip.sourceInterval.start.cmTime))
        return CaptionWord(id: UUID(), clipID: clip.id, rawWindowID: window.id,
            text: segment.text, sourceInterval: interval,
            projectInterval: try MediaInterval(start: MediaTime(validating: projectStart),
                end: MediaTime(validating: CMTimeAdd(projectStart, interval.duration))),
            timingProvenance: "whisper-segment")
    }

    private static func tokenWords(in window: RecognitionWindow, clip: ProjectClip,
                                   core: MediaInterval) throws -> [CaptionWord] {
        var joined = Data()
        var tokenRanges: [Range<Int>] = []
        for token in window.tokens {
            let start = joined.count
            joined.append(token.utf8)
            tokenRanges.append(start..<joined.count)
        }
        guard let text = String(data: joined, encoding: .utf8) else { throw SpeechError.invalidUTF8 }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard window.segments.allSatisfy({ $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw SpeechError.wordTimingUnavailable
            }
            return []
        }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        if let language = window.languageCode {
            tokenizer.setLanguage(language == "zh" ? .simplifiedChinese : NLLanguage(rawValue: language))
        }
        var ranges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            ranges.append(range)
            return true
        }
        guard !ranges.isEmpty else { throw SpeechError.wordTimingUnavailable }
        var output: [CaptionWord] = []
        for (index, range) in ranges.enumerated() {
            let startByte = text.utf8.distance(from: text.utf8.startIndex, to: range.lowerBound)
            let endByte = text.utf8.distance(from: text.utf8.startIndex, to: range.upperBound)
            let timed = zip(window.tokens, tokenRanges).filter {
                $0.1.overlaps(startByte..<endByte) && $0.0.hasTiming &&
                    $0.0.startSeconds.isFinite && $0.0.endSeconds.isFinite &&
                    $0.0.startSeconds >= 0 && $0.0.endSeconds > $0.0.startSeconds
            }.map(\.0)
            guard let start = timed.map(\.startSeconds).min(),
                  let end = timed.map(\.endSeconds).max() else {
                throw SpeechError.wordTimingUnavailable
            }
            let sourceStart = max(window.sourceInterval.start, try MediaTime(validating:
                CMTimeAdd(window.sourceInterval.start.cmTime, CMTime(seconds: start, preferredTimescale: 16_000))))
            let sourceEnd = min(window.sourceInterval.end, try MediaTime(validating:
                CMTimeAdd(window.sourceInterval.start.cmTime, CMTime(seconds: end, preferredTimescale: 16_000))))
            guard sourceStart < sourceEnd else { throw SpeechError.wordTimingUnavailable }
            let midpoint = CMTimeAdd(sourceStart.cmTime, CMTimeMultiplyByFloat64(
                CMTimeSubtract(sourceEnd.cmTime, sourceStart.cmTime), multiplier: 0.5))
            guard CMTimeCompare(midpoint, core.start.cmTime) >= 0,
                  CMTimeCompare(midpoint, core.end.cmTime) < 0 else { continue }
            let displayStart = index == 0 ? text.startIndex : range.lowerBound
            let displayEnd = index + 1 < ranges.count ? ranges[index + 1].lowerBound : text.endIndex
            let offset = CMTimeSubtract(sourceStart.cmTime, clip.sourceInterval.start.cmTime)
            let projectStart = CMTimeAdd(clip.timelineInterval.start.cmTime, offset)
            let projectEnd = CMTimeAdd(projectStart, CMTimeSubtract(sourceEnd.cmTime, sourceStart.cmTime))
            output.append(CaptionWord(id: UUID(), clipID: clip.id, rawWindowID: window.id,
                text: String(text[displayStart..<displayEnd]),
                sourceInterval: try MediaInterval(start: sourceStart, end: sourceEnd),
                projectInterval: try MediaInterval(start: MediaTime(validating: projectStart),
                                                   end: MediaTime(validating: projectEnd)),
                timingProvenance: "whisper-token-union"))
        }
        return output
    }

    /// Core ownership handles most overlap. Conservatively reconcile the same
    /// acoustic word predicted on opposite sides of a window boundary.
    static func append(_ incoming: [CaptionWord], to words: inout [CaptionWord]) {
        for word in incoming {
            let duplicate = words.suffix(8).contains { duplicates(word, $0) }
            if !duplicate { words.append(word) }
        }
    }

    static func duplicateKey(_ word: CaptionWord) -> String {
        word.clipID.uuidString + ":" + normalized(word.text)
    }

    static func duplicates(_ word: CaptionWord, _ previous: CaptionWord) -> Bool {
        guard previous.clipID == word.clipID, previous.rawWindowID != word.rawWindowID,
              normalized(previous.text) == normalized(word.text) else { return false }
        let overlap = CMTimeGetSeconds(CMTimeSubtract(
            min(previous.sourceInterval.end, word.sourceInterval.end).cmTime,
            max(previous.sourceInterval.start, word.sourceInterval.start).cmTime))
        let shortest = min(CMTimeGetSeconds(previous.sourceInterval.duration),
                           CMTimeGetSeconds(word.sourceInterval.duration))
        return overlap > 0 && overlap >= shortest * 0.5
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func cues(for words: [CaptionWord]) throws -> [CaptionCue] {
        var result: [CaptionCue] = []
        var group: [CaptionWord] = []
        func flush() throws {
            guard let first = group.first, let end = group.map(\.projectInterval.end).max() else { return }
            result.append(CaptionCue(id: UUID(), wordIDs: group.map(\.id),
                interval: try MediaInterval(start: first.projectInterval.start, end: end)))
            group.removeAll(keepingCapacity: true)
        }
        for word in words {
            if let first = group.first,
               first.clipID != word.clipID || group.count >= 6 ||
                CMTimeGetSeconds(CMTimeSubtract(word.projectInterval.end.cmTime,
                                               first.projectInterval.start.cmTime)) > 3 {
                try flush()
            }
            group.append(word)
        }
        try flush()
        return result
    }
}

