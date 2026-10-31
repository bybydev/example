import CoreMedia
import Foundation

/// One optional soundtrack. It is not a transcription clip and never determines
/// project duration. Its start is measured on the retained, zero-based output clock.
struct ProjectMusic: Codable, Equatable, Sendable {
    var asset: SourceAsset
    var sourceInterval: MediaInterval
    var start: MediaTime = .zero
    var loopToFit = true
    var volume: Double = 0.2
    var isMuted = false
    var fadeIn: Double = 0
    var fadeOut: Double = 0
    var isEffectivelyMuted: Bool { isMuted || volume == 0 }

    // Bound AVComposition segment work for an extremely short selected section.
    static let maximumRepetitions = 10_000

    init(asset: SourceAsset) throws {
        self.asset = asset
        sourceInterval = try MediaInterval(start: .zero, end: asset.metadata.duration)
    }

    func validate(outputDuration: MediaTime) throws {
        try asset.validate()
        guard asset.kind == .audio, asset.metadata.videoTrackCount == 0,
              asset.metadata.audioTrackCount > 0,
              sourceInterval.start >= .zero, sourceInterval.end <= asset.metadata.duration,
              start >= .zero, volume.isFinite, (0...1).contains(volume),
              fadeIn.isFinite, fadeIn >= 0, fadeOut.isFinite, fadeOut >= 0 else {
            throw MusicEditError.invalidSettings
        }
        if loopToFit, let interval = try playbackInterval(outputDuration: outputDuration) {
            // Compare rational durations directly; a floating quotient can
            // misclassify a section that exactly meets the repetition ceiling.
            let budget = CMTimeMultiply(sourceInterval.duration, multiplier: Int32(Self.maximumRepetitions))
            guard budget.isNumeric, CMTimeCompare(interval.duration, budget) <= 0 else {
                throw MusicEditError.tooManyRepetitions
            }
        }
    }

    /// Keeping an offset beyond a shortened video is valid: it is silent until
    /// the video grows again, without destructively changing the saved settings.
    func playbackInterval(outputDuration: MediaTime) throws -> MediaInterval? {
        guard start < outputDuration else { return nil }
        let end: MediaTime
        if loopToFit { end = outputDuration }
        else {
            let remaining = CMTimeSubtract(outputDuration.cmTime, start.cmTime)
            let length = CMTimeMinimum(remaining, sourceInterval.duration)
            end = try MediaTime(validating: CMTimeAdd(start.cmTime, length))
        }
        return try MediaInterval(start: start, end: end)
    }

    /// A replacement resets only the selected song section. Mix, offset, loop
    /// and fade choices survive, even when the replacement is a shorter song.
    func replacingAsset(with asset: SourceAsset) throws -> Self {
        var next = self
        next.asset = asset
        next.sourceInterval = try MediaInterval(start: .zero, end: asset.metadata.duration)
        return next
    }
}

enum MusicEditError: LocalizedError {
    case invalidSettings, invalidImport, busy, stale, tooManyRepetitions

    var errorDescription: String? {
        switch self {
        case .invalidSettings: "Choose a valid song section, volume from 0 to 100%, and nonnegative fades."
        case .invalidImport: "Choose a playable audio file for background music."
        case .busy: "Finish the current edit before changing music."
        case .stale: "The music changed while you were editing. Open its controls again."
        case .tooManyRepetitions: "Choose a longer music section to loop across this video."
        }
    }
}

extension ProjectDocument {
    /// Only ownership, preview and frozen exports use this union. Speech keeps
    /// using assets/clips, so a soundtrack never enters inference or allowance.
    var ownedMediaAssets: [SourceAsset] { assets + (music.map { [$0.asset] } ?? []) }
    var isOriginalAudioMuted: Bool { originalAudioMuted == true }
}
