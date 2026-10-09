import Foundation
import MediaPlayer
import UIKit

@MainActor
final class ProjectSystemMediaController {
    private nonisolated enum RemoteAction:
        Sendable
    {
        case play
        case pause
        case togglePlayPause
        case skipForward
        case skipBackward
        case next
        case previous
        case seek(Double)
    }

    static let shared =
        ProjectSystemMediaController()

    private weak var runtime:
        ProjectRuntime?

    private var commandTargets:
        [(MPRemoteCommand, Any)] = []

    private var artworkURL: URL?
    private var artwork:
        MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?

    private init() {
        installRemoteCommands()
    }

    func activate(
        _ runtime: ProjectRuntime
    ) {
        if let current = self.runtime,
           current !== runtime,
           current.isPlaybackActive
        {
            current.stopPlayback()
        }

        self.runtime = runtime
        publish(runtime)
    }

    func publish(
        _ runtime: ProjectRuntime
    ) {
        guard self.runtime === runtime
        else {
            return
        }

        guard runtime
            .activity
            .hasActivePlaybackWork,
              let itemID =
                runtime.activity
                    .activeItemID
                    ?? runtime
                        .currentItemID,
              let state =
                runtime.itemState(
                    itemID
                )
        else {
            clear(runtime)
            return
        }

        var info:
            [String: Any] = [
                MPMediaItemPropertyTitle:
                    state.item.title,
                MPNowPlayingInfoPropertyPlaybackRate:
                    runtime.isPlaybackPaused
                    || runtime.activity.queuedAudioBuffers == 0
                    ? 0.0
                    : 1.0,
                MPNowPlayingInfoPropertyDefaultPlaybackRate:
                    1.0,
            ]

        if let project =
            runtime.project
        {
            info[
                MPMediaItemPropertyAlbumTitle
            ] = project.title

            if let author =
                project.author,
               !author.isEmpty
            {
                info[
                    MPMediaItemPropertyArtist
                ] = author
            }
        }

        if let artwork =
            artworkFor(runtime)
        {
            info[
                MPMediaItemPropertyArtwork
            ] = artwork
        }

        if let asset =
            runtime.finalAudioAsset,
           asset.metadata.itemID
            == itemID
        {
            info[
                MPMediaItemPropertyPlaybackDuration
            ] = asset.metadata
                .durationSeconds
            info[
                MPNowPlayingInfoPropertyElapsedPlaybackTime
            ] = min(
                asset.metadata
                    .durationSeconds,
                max(
                    0,
                    runtime
                        .currentFinalAudioPositionSeconds
                )
            )
        }

        let center =
            MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState =
            runtime.isPlaybackPaused
            ? .paused
            : .playing

        updateSkipIntervals()
        updateCommandAvailability(
            runtime
        )
    }

    func clear(
        _ runtime: ProjectRuntime
    ) {
        guard self.runtime === runtime
        else {
            return
        }

        let center =
            MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
        resetArtwork()

        updateCommandAvailability(nil)
    }

    func detach(
        _ runtime: ProjectRuntime
    ) {
        guard self.runtime === runtime
        else {
            return
        }

        clear(runtime)
        self.runtime = nil
    }

    private func installRemoteCommands() {
        let center =
            MPRemoteCommandCenter.shared()

        updateSkipIntervals()

        addTarget(
            to: center.playCommand,
            action: .play
        )
        addTarget(
            to: center.pauseCommand,
            action: .pause
        )
        addTarget(
            to: center.togglePlayPauseCommand,
            action:
                .togglePlayPause
        )
        addTarget(
            to: center.skipForwardCommand,
            action: .skipForward
        )
        addTarget(
            to: center.skipBackwardCommand,
            action: .skipBackward
        )
        addTarget(
            to: center.nextTrackCommand,
            action: .next
        )
        addTarget(
            to: center.previousTrackCommand,
            action: .previous
        )

        let seekToken =
            center
                .changePlaybackPositionCommand
                .addTarget(handler: Self.makeSeekHandler())

        commandTargets.append(
            (
                center
                    .changePlaybackPositionCommand,
                seekToken
            )
        )

        updateCommandAvailability(nil)
    }

    private func addTarget(
        to command: MPRemoteCommand,
        action: RemoteAction
    ) {
        let token =
            command.addTarget(handler: Self.makeCommandHandler(action: action))

        commandTargets.append(
            (command, token)
        )
    }

    private func perform(
        _ action: RemoteAction
    ) {
        guard let runtime
        else {
            return
        }

        switch action {
        case .play:
            if runtime.isPlaybackPaused {
                runtime.resumePlayback()
            } else if !runtime
                .isPlaybackActive,
                      let itemID =
                        runtime.continueItemID
            {
                try? runtime.play(
                    itemID: itemID
                )
            }

        case .pause:
            runtime.pausePlayback()

        case .togglePlayPause:
            if runtime.isPlaybackPaused {
                runtime.resumePlayback()
            } else if runtime
                .isPlaybackActive
            {
                runtime.pausePlayback()
            } else if let itemID =
                        runtime.continueItemID
            {
                try? runtime.play(
                    itemID: itemID
                )
            }

        case .skipForward:
            try? runtime.seekPlayback(
                by: Double(
                    ReadAloudPreferences
                        .skipInterval
                )
            )

        case .skipBackward:
            try? runtime.seekPlayback(
                by: -Double(
                    ReadAloudPreferences
                        .skipInterval
                )
            )

        case .next:
            guard let itemID =
                    runtime.activity
                        .activeItemID
                        ?? runtime
                            .currentItemID
            else {
                return
            }

            try? runtime.playNextItem(
                after: itemID
            )

        case .previous:
            guard let itemID =
                    runtime.activity
                        .activeItemID
                        ?? runtime
                            .currentItemID
            else {
                return
            }

            try? runtime
                .playPreviousItem(
                    before: itemID
                )

        case .seek(let seconds):
            try? runtime.seekPlayback(
                to: seconds
            )
        }

        publish(runtime)
    }

    private func updateSkipIntervals() {
        let interval =
            NSNumber(
                value:
                    ReadAloudPreferences
                        .skipInterval
            )
        let center =
            MPRemoteCommandCenter.shared()
        center.skipForwardCommand
            .preferredIntervals = [
                interval,
            ]
        center.skipBackwardCommand
            .preferredIntervals = [
                interval,
            ]
    }

    private func updateCommandAvailability(
        _ runtime: ProjectRuntime?
    ) {
        let center =
            MPRemoteCommandCenter.shared()

        guard let runtime else {
            center.playCommand.isEnabled =
                false
            center.pauseCommand.isEnabled =
                false
            center.togglePlayPauseCommand
                .isEnabled = false
            center.skipForwardCommand
                .isEnabled = false
            center.skipBackwardCommand
                .isEnabled = false
            center.nextTrackCommand
                .isEnabled = false
            center.previousTrackCommand
                .isEnabled = false
            center.changePlaybackPositionCommand
                .isEnabled = false
            return
        }

        let hasPlayableItem =
            runtime.continueItemID != nil
        let isActive =
            runtime.isPlaybackActive

        center.playCommand.isEnabled =
            hasPlayableItem
        center.pauseCommand.isEnabled =
            isActive && !runtime.isPlaybackPaused
        center.togglePlayPauseCommand
            .isEnabled = hasPlayableItem
        center.skipForwardCommand
            .isEnabled = runtime.canSkipPlayback
        center.skipBackwardCommand
            .isEnabled = runtime.canSkipPlayback

        let itemID =
            runtime.activity
                .activeItemID
                ?? runtime.currentItemID
        let index =
            itemID.flatMap {
                id in
                runtime.itemStates
                    .firstIndex(
                        where: {
                            $0.id == id
                        }
                    )
            }

        center.previousTrackCommand
            .isEnabled =
                index.map { $0 > 0 }
                ?? false
        center.nextTrackCommand
            .isEnabled =
                index.map {
                    $0 + 1
                        < runtime.itemStates
                            .count
                }
                ?? false
        center.changePlaybackPositionCommand
            .isEnabled =
                isActive
                && runtime.finalAudioAsset
                    != nil
    }

    private func artworkFor(
        _ runtime: ProjectRuntime
    ) -> MPMediaItemArtwork? {
        guard let url =
                runtime.artworkURL
        else {
            resetArtwork()
            return nil
        }

        // nil also means a request is in flight or the cover was rejected.
        // Repeated playback events must not decode/retry the same image.
        if artworkURL == url {
            return artwork
        }

        resetArtwork()
        artworkURL = url
        artworkTask = Task { @MainActor [weak self, weak runtime] in
            let data = await ProjectArtworkThumbnail.load(at: url, maximumPixelSize: 512)
            guard !Task.isCancelled, let self, let runtime,
                  self.runtime === runtime, self.artworkURL == url,
                  runtime.activity.hasActivePlaybackWork else { return }
            self.artworkTask = nil
            guard let data, let image = UIImage(data: data) else { return }
            self.artwork = Self.makeArtwork(image: image)
            self.publish(runtime)
        }
        // Publish transport state immediately; artwork is optional and follows
        // asynchronously once a bounded thumbnail is ready.
        return nil
    }

    private func resetArtwork() {
        artworkTask?.cancel()
        artworkTask = nil
        artwork = nil
        artworkURL = nil
    }

    // Objective-C system callbacks may run off the main queue. Creating their
    // closures in an explicitly nonisolated context avoids inheriting this
    // controller's MainActor and trapping before the callback body executes.
    private nonisolated static func makeArtwork(image: UIImage) -> MPMediaItemArtwork {
        let handler: @Sendable (CGSize) -> UIImage = { _ in image }
        return MPMediaItemArtwork(boundsSize: image.size, requestHandler: handler)
    }

    private nonisolated static func makeCommandHandler(
        action: RemoteAction
    ) -> @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { _ in
            Task { @MainActor in
                ProjectSystemMediaController.shared.perform(action)
            }
            return .success
        }
    }

    private nonisolated static func makeSeekHandler()
        -> @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { event in
            guard let seek = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = seek.positionTime
            Task { @MainActor in
                ProjectSystemMediaController.shared.perform(.seek(position))
            }
            return .success
        }
    }
}

