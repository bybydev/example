import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class TranscriptPlaybackController {
    enum PlaybackError: LocalizedError {
        case sourceUnavailable
        case mediaNotPlayable

        var errorDescription: String? {
            switch self {
            case .sourceUnavailable:
                "The transcript source media is no longer available."
            case .mediaNotPlayable:
                "The transcript source media cannot be played."
            }
        }
    }

    private(set) var isPrepared = false
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?

    func prepare(url: URL) async throws {
        unload()

        guard url.isFileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            throw PlaybackError.sourceUnavailable
        }

        let asset = AVURLAsset(url: url)
        let isPlayable = (try? await asset.load(.isPlayable)) ?? false
        guard isPlayable else {
            throw PlaybackError.mediaNotPlayable
        }

        let loadedDuration = try? await asset.load(.duration)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        self.player = player
        isPrepared = true

        if let loadedDuration {
            let seconds = loadedDuration.seconds
            duration = seconds.isFinite && seconds > 0 ? seconds : 0
        }

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: nil
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = max(0, time.seconds.isFinite ? time.seconds : 0)
                if self.duration > 0,
                   self.currentTime >= self.duration - 0.05 {
                    self.isPlaying = false
                }
            }
        }
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let player else { return }
        if duration > 0, currentTime >= duration - 0.05 {
            seek(to: 0)
        }
        player.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func seek(to seconds: TimeInterval) {
        guard let player else { return }
        let upperBound = duration > 0 ? duration : max(0, seconds)
        let clamped = min(max(0, seconds), upperBound)
        currentTime = clamped
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func skip(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    func unload() {
        if let player, let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        player?.pause()
        player = nil
        timeObserver = nil
        isPrepared = false
        isPlaying = false
        currentTime = 0
        duration = 0
    }
}
