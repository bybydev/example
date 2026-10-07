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
        case skip(Double)
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
        artwork = nil
        artworkURL = nil
    }

    private func installRemoteCommands() {
        let center =
            MPRemoteCommandCenter.shared()

        center.skipForwardCommand
            .preferredIntervals = [
                NSNumber(value: 15),
            ]
        center.skipBackwardCommand
            .preferredIntervals = [
                NSNumber(value: 15),
            ]

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
            action: .skip(15)
        )
        addTarget(
            to: center.skipBackwardCommand,
            action: .skip(-15)
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
                .addTarget { event in
                    guard let event =
                            event
                            as? MPChangePlaybackPositionCommandEvent
                    else {
                        return .commandFailed
                    }

                    let position =
                        event.positionTime

                    Task { @MainActor in
                        ProjectSystemMediaController
                            .shared
                            .perform(
                                .seek(
                                    position
                                )
                            )
                    }

                    return .success
                }

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
            command.addTarget { _ in
                Task { @MainActor in
                    ProjectSystemMediaController
                        .shared
                        .perform(action)
                }
                return .success
            }

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

        case .skip(let seconds):
            try? runtime.seekPlayback(
                by: seconds
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
            isActive
        center.togglePlayPauseCommand
            .isEnabled = hasPlayableItem
        center.skipForwardCommand
            .isEnabled = isActive
        center.skipBackwardCommand
            .isEnabled = isActive

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
            artwork = nil
            artworkURL = nil
            return nil
        }

        if artworkURL == url,
           let artwork {
            return artwork
        }

        guard let image =
                UIImage(
                    contentsOfFile:
                        url.path
                )
        else {
            artwork = nil
            artworkURL = url
            return nil
        }

        let mediaArtwork =
            MPMediaItemArtwork(
                boundsSize:
                    image.size
            ) { _ in
                image
            }

        artworkURL = url
        artwork = mediaArtwork
        return mediaArtwork
    }
}
