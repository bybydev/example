import SwiftUI
import Foundation

struct EditorPlaybackControls: View {
    let session: EditorSession
    var showsOverview = true
    var showsTimeline = true
    var onInteraction: () -> Void = {}
    var onExpand: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            if showsTimeline {
                CaptionTimeline(snapshot: session.snapshot, selectedCueID: session.selectedCueID,
                    duration: EditorTime.seconds(session.duration), seconds: EditorTime.seconds(session.time),
                    showsOverview: showsOverview, seek: { endEditing(); session.scrub(seconds: $0) })
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    playButton
                    Spacer(minLength: 0)
                    readout.fixedSize(horizontal: true, vertical: true)
                    Spacer(minLength: 0)
                    historyButtons
                    expandButton
                }
                VStack(spacing: 4) {
                    readout.fixedSize(horizontal: false, vertical: true)
                    HStack { playButton; Spacer(minLength: 0); historyButtons; expandButton }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var readout: some View {
        Text(playbackTime(session.time) + " / " + playbackTime(session.duration))
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            .accessibilityLabel("\(playbackTime(session.time)) of \(playbackTime(session.duration))")
    }
    private var playButton: some View {
        Button(session.isPlaying ? "Pause" : "Play", systemImage: session.isPlaying ? "pause.fill" : "play.fill") {
            endEditing(); session.togglePlayback()
        }
        .labelStyle(.iconOnly).font(.title3).frame(width: 44, height: 44)
        .disabled(session.isPreparingPreview || session.previewError != nil)
    }
    private var historyButtons: some View {
        HStack(spacing: 0) {
            Button(session.undoLabel, systemImage: "arrow.uturn.backward") { endEditing(); session.undo() }
                .labelStyle(.iconOnly).frame(width: 44, height: 44).disabled(!session.canUndo)
            Button(session.redoLabel, systemImage: "arrow.uturn.forward") { endEditing(); session.redo() }
                .labelStyle(.iconOnly).frame(width: 44, height: 44).disabled(!session.canRedo)
        }
    }
    @ViewBuilder private var expandButton: some View {
        if let onExpand {
            Button("Fullscreen preview", systemImage: "arrow.up.left.and.arrow.down.right") { endEditing(); onExpand() }
                .labelStyle(.iconOnly).frame(width: 44, height: 44)
        }
    }

    private func playbackTime(_ time: MediaTime) -> String {
        let value = EditorTime.seconds(time)
        guard value.isFinite, value >= 0, value < Double(Int.max / 1_000) else { return "—" }
        let seconds = Int(value)
        if seconds >= 3_600 { return String(format: "%d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func endEditing() {
        onInteraction()
        session.endTyping(); session.endStyleEditing(); session.endMediaEditing()
    }
}

