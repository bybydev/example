@preconcurrency import AVFoundation
import Foundation

/// Shared by the editor and immutable MP4 graphs. Repetitions reuse a source
/// track; no temporary audio render or second AVPlayer is created.
@MainActor
enum MusicComposition {
    static func append(_ music: ProjectMusic, url: URL, to composition: AVMutableComposition,
                       outputDuration: MediaTime) async throws -> AVMutableAudioMixInputParameters? {
        try music.validate(outputDuration: outputDuration)
        guard let playback = try music.playbackInterval(outputDuration: outputDuration) else { return nil }
        let asset = AVURLAsset(url: url)
        guard let source = try await asset.loadTracks(withMediaType: .audio).first,
              let lane = composition.addMutableTrack(withMediaType: .audio,
                  preferredTrackID: kCMPersistentTrackID_Invalid) else { throw MusicEditError.invalidImport }
        let available = try await source.load(.timeRange)
        var cursor = playback.start.cmTime
        var repetitions = 0
        var inserted = false
        while CMTimeCompare(cursor, playback.end.cmTime) < 0 {
            try Task.checkCancellation()
            guard repetitions < ProjectMusic.maximumRepetitions else { throw MusicEditError.tooManyRepetitions }
            repetitions += 1
            let length = CMTimeMinimum(music.sourceInterval.duration, CMTimeSubtract(playback.end.cmTime, cursor))
            guard length.isNumeric, CMTimeCompare(length, .zero) > 0 else { throw MusicEditError.invalidSettings }
            let requested = CMTimeRange(start: music.sourceInterval.start.cmTime, duration: length)
            let kept = CMTimeRangeGetIntersection(available, otherRange: requested)
            if kept.isValid, !kept.isEmpty, CMTimeCompare(kept.duration, .zero) > 0 {
                // Preserve source-track offsets/gaps inside every song section.
                let at = CMTimeAdd(cursor, CMTimeSubtract(kept.start, requested.start))
                try lane.insertTimeRange(kept, of: source, at: at)
                inserted = true
            }
            // Derive every boundary from the original start rather than adding
            // rounded durations repeatedly through a long looped soundtrack.
            let boundary = CMTimeAdd(playback.start.cmTime,
                CMTimeMultiply(music.sourceInterval.duration, multiplier: Int32(repetitions)))
            let next = CMTimeMinimum(playback.end.cmTime, boundary)
            guard next.isNumeric, CMTimeCompare(next, cursor) > 0 else { throw MusicEditError.invalidSettings }
            cursor = next
            if !music.loopToFit { break }
        }
        guard inserted else { throw MusicEditError.invalidImport }
        let parameters = AVMutableAudioMixInputParameters(track: lane)
        let level = music.isMuted ? Float(0) : Float(music.volume)
        parameters.setVolume(0, at: .zero)
        parameters.setVolume(level, at: playback.start.cmTime)
        let seconds = CMTimeGetSeconds(playback.duration)
        // Long/overlapping fades meet proportionally, with no gain jump between them.
        var fadeIn = min(music.fadeIn, seconds)
        var fadeOut = min(music.fadeOut, seconds)
        if fadeIn + fadeOut > seconds {
            let scale = seconds / (fadeIn + fadeOut)
            fadeIn *= scale; fadeOut *= scale
        }
        let requestedIn = CMTime(seconds: fadeIn, preferredTimescale: 600_000)
        let requestedOut = CMTime(seconds: fadeOut, preferredTimescale: 600_000)
        guard requestedIn.isNumeric, requestedOut.isNumeric else { throw MusicEditError.invalidSettings }
        let inLength = CMTimeMinimum(playback.duration, requestedIn)
        // Round-trip conversion must not make two short ramps overlap or put
        // either outside the retained playback interval.
        let outLength = CMTimeMinimum(CMTimeSubtract(playback.duration, inLength), requestedOut)
        if CMTimeCompare(inLength, .zero) > 0 {
            parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: level,
                timeRange: CMTimeRange(start: playback.start.cmTime, duration: inLength))
        }
        if CMTimeCompare(outLength, .zero) > 0 {
            parameters.setVolumeRamp(fromStartVolume: level, toEndVolume: 0,
                timeRange: CMTimeRange(start: CMTimeSubtract(playback.end.cmTime, outLength), duration: outLength))
        }
        parameters.setVolume(0, at: playback.end.cmTime)
        return parameters
    }
}
