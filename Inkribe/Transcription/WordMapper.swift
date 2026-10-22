import CoreMedia
import Foundation
import NaturalLanguage
import WhisperRuntime

/// Joins raw UTF-8 BPE bytes before linguistic segmentation. Word intervals
/// are unions of real overlapping token intervals, never evenly divided time.
enum WordMapper {
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
            let duplicate = words.suffix(8).contains { previous in
                guard previous.clipID == word.clipID, previous.rawWindowID != word.rawWindowID,
                      normalized(previous.text) == normalized(word.text) else { return false }
                let overlap = CMTimeGetSeconds(CMTimeSubtract(
                    min(previous.sourceInterval.end, word.sourceInterval.end).cmTime,
                    max(previous.sourceInterval.start, word.sourceInterval.start).cmTime))
                let shortest = min(CMTimeGetSeconds(previous.sourceInterval.duration),
                                   CMTimeGetSeconds(word.sourceInterval.duration))
                return overlap > 0 && overlap >= shortest * 0.5
            }
            if !duplicate { words.append(word) }
        }
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
