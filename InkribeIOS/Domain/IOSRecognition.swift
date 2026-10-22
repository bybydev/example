import CoreMedia
import Foundation

/// Raw model output is retained independently of the editable words/cues.
struct IOSRawSpeechToken: Codable, Equatable, Sendable {
    let utf8: Data
    let startSeconds: Double
    let endSeconds: Double
    let hasTiming: Bool
}

struct IOSRawSpeechSegment: Codable, Equatable, Sendable {
    let text: String
    let startSeconds: Double
    let endSeconds: Double
}

struct IOSRecognitionWindow: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let clipID: UUID
    let sourceInterval: MediaInterval
    let languageCode: String?
    let segments: [IOSRawSpeechSegment]
    let tokens: [IOSRawSpeechToken]
}

struct IOSCaptionWord: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let clipID: UUID
    let rawWindowID: UUID
    var text: String
    let sourceInterval: MediaInterval
    var projectInterval: MediaInterval
    /// Token aggregation is approximate model timing, never forced alignment.
    let timingProvenance: String
    /// Manual timing never rewrites the native interval or raw window. Missing in v2.
    var adjustedSourceInterval: MediaInterval? = nil

    var effectiveSourceInterval: MediaInterval { adjustedSourceInterval ?? sourceInterval }
}

struct IOSCaptionCue: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var wordIDs: [UUID]
    var interval: MediaInterval
}

struct IOSRecognition: Codable, Equatable, Sendable, Identifiable {
    /// The durable job ID makes completion idempotent after interrupted publication.
    let id: UUID
    let modelID: String
    let modelSHA256: String
    let requestedLanguageCode: String?
    let completedAt: Date
    let rawWindows: [IOSRecognitionWindow]
    var words: [IOSCaptionWord]
    var cues: [IOSCaptionCue]

    func validate(clips: [IOSProjectClip], assets: [IOSSourceAsset]) throws {
        let assetIndex = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        let clipIndex = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0) })
        guard !modelID.isEmpty, modelSHA256.count == 64,
              Set(rawWindows.map(\.id)).count == rawWindows.count,
              Set(words.map(\.id)).count == words.count,
              Set(cues.map(\.id)).count == cues.count else {
            throw IOSProjectStoreError.invalidDocument("Invalid recognition identities")
        }
        let windowIndex = Dictionary(uniqueKeysWithValues: rawWindows.map { ($0.id, $0) })
        for window in rawWindows {
            guard let clip = clipIndex[window.clipID],
                  let source = assetIndex[clip.sourceAssetID],
                  window.sourceInterval.start >= .zero,
                  window.sourceInterval.end <= source.metadata.duration,
                  CMTimeGetSeconds(window.sourceInterval.duration) <= 30,
                  window.tokens.allSatisfy({ $0.startSeconds.isFinite && $0.endSeconds.isFinite }),
                  window.segments.allSatisfy({ $0.startSeconds.isFinite && $0.endSeconds.isFinite }) else {
                throw IOSProjectStoreError.invalidDocument("Invalid recognition window")
            }
        }
        let wordIndex = Dictionary(uniqueKeysWithValues: words.map { ($0.id, $0) })
        for word in words {
            guard let clip = clipIndex[word.clipID],
                  let window = windowIndex[word.rawWindowID], window.clipID == word.clipID,
                  word.sourceInterval.start >= window.sourceInterval.start,
                  word.sourceInterval.end <= window.sourceInterval.end,
                  word.sourceInterval.start >= clip.sourceInterval.start,
                  word.sourceInterval.end <= clip.sourceInterval.end,
                  word.effectiveSourceInterval.start >= clip.sourceInterval.start,
                  word.effectiveSourceInterval.end <= clip.sourceInterval.end else {
                throw IOSProjectStoreError.invalidDocument("Invalid timed word")
            }
            let offset = CMTimeSubtract(word.effectiveSourceInterval.start.cmTime, clip.sourceInterval.start.cmTime)
            let start = CMTimeAdd(clip.timelineInterval.start.cmTime, offset)
            guard CMTimeCompare(start, word.projectInterval.start.cmTime) == 0,
                  CMTimeCompare(word.effectiveSourceInterval.duration, word.projectInterval.duration) == 0 else {
                throw IOSProjectStoreError.invalidDocument("Word/source timing mapping differs")
            }
        }
        var used = Set<UUID>()
        for cue in cues {
            let linked = cue.wordIDs.compactMap { wordIndex[$0] }
            guard !linked.isEmpty, linked.count == cue.wordIDs.count,
                  Set(linked.map(\.clipID)).count == 1,
                  linked.allSatisfy({ used.insert($0.id).inserted }),
                  linked.allSatisfy({ word in
                      guard let clip = clipIndex[word.clipID] else { return false }
                      return cue.interval.start >= clip.timelineInterval.start &&
                          cue.interval.end <= clip.timelineInterval.end
                  }),
                  linked.allSatisfy({ cue.interval.start <= $0.projectInterval.start &&
                      cue.interval.end >= $0.projectInterval.end }) else {
                throw IOSProjectStoreError.invalidDocument("Invalid caption cue references")
            }
        }
        guard used == Set(words.map(\.id)) else {
            throw IOSProjectStoreError.invalidDocument("Words are missing caption cues")
        }
    }

    func duplicated(assetClips: [UUID: UUID]) -> Self {
        let windowIDs = Dictionary(uniqueKeysWithValues: rawWindows.map { ($0.id, UUID()) })
        let wordIDs = Dictionary(uniqueKeysWithValues: words.map { ($0.id, UUID()) })
        return Self(id: UUID(), modelID: modelID, modelSHA256: modelSHA256,
            requestedLanguageCode: requestedLanguageCode, completedAt: completedAt,
            rawWindows: rawWindows.map {
                IOSRecognitionWindow(id: windowIDs[$0.id]!, clipID: assetClips[$0.clipID]!,
                    sourceInterval: $0.sourceInterval, languageCode: $0.languageCode,
                    segments: $0.segments, tokens: $0.tokens)
            }, words: words.map {
                IOSCaptionWord(id: wordIDs[$0.id]!, clipID: assetClips[$0.clipID]!,
                    rawWindowID: windowIDs[$0.rawWindowID]!, text: $0.text,
                    sourceInterval: $0.sourceInterval, projectInterval: $0.projectInterval,
                    timingProvenance: $0.timingProvenance, adjustedSourceInterval: $0.adjustedSourceInterval)
            }, cues: cues.map {
                IOSCaptionCue(id: UUID(), wordIDs: $0.wordIDs.map { wordIDs[$0]! }, interval: $0.interval)
            })
    }
}

enum IOSSpeechError: LocalizedError {
    case missingModel, noAudio, wordTimingUnavailable, invalidUTF8, invalidAudio, busy, alreadyTranscribed
    var errorDescription: String? {
        switch self {
        case .missingModel: "The selected speech model is unavailable. Open Speech Models to download it, or select an available model."
        case .noAudio: "This project has no audio track to transcribe."
        case .wordTimingUnavailable: "The speech model did not return usable word timing. No caption result was saved."
        case .invalidUTF8: "The speech model returned incomplete text. Retry transcription."
        case .invalidAudio: "The audio could not be decoded into a supported speech window."
        case .busy: "This project already has a transcription in progress."
        case .alreadyTranscribed: "This project already has saved captions. Existing text has been preserved."
        }
    }
}
