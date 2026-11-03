import SwiftUI
import Foundation

struct EditorPlaybackControls: View {
    let session: EditorSession
    var showsOverview = true
    var showsTimeline = true
    var showsHistory = true
    var showsEditorTransport = false
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
                HStack(spacing: showsEditorTransport ? 0 : 12) {
                    transportButtons
                    Spacer(minLength: showsEditorTransport ? 8 : 0)
                    readout.fixedSize(horizontal: true, vertical: true)
                    Spacer(minLength: showsEditorTransport ? 8 : 0)
                    trailingButtons
                }
                VStack(spacing: 4) {
                    readout.fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: showsEditorTransport ? 0 : nil) {
                        transportButtons
                        Spacer(minLength: showsEditorTransport ? 8 : 0)
                        trailingButtons
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var transportButtons: some View {
        HStack(spacing: 0) {
            if showsEditorTransport {
                transportButton("Jump to start", symbol: "backward.end.fill") {
                    endEditing(); session.jumpToStart()
                }
                .disabled(playbackUnavailable)
            }
            playButton
            if showsEditorTransport {
                transportButton("Jump to end", symbol: "forward.end.fill") {
                    endEditing(); session.jumpToEnd()
                }
                .disabled(playbackUnavailable)
            }
        }
    }

    private var trailingButtons: some View {
        HStack(spacing: 0) {
            if showsHistory { historyButtons }
            if showsEditorTransport { speedMenu }
            expandButton
        }
    }

    private var playbackUnavailable: Bool {
        session.isEditingClipTrim || session.isPreparingPreview ||
            session.previewError != nil || session.player.currentItem == nil
    }

    private var readout: some View {
        Text(playbackTime(session.time) + " / " + playbackTime(session.duration))
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            .accessibilityLabel("\(playbackTime(session.time)) of \(playbackTime(session.duration))")
    }
    private var playButton: some View {
        transportButton(session.isPlaying ? "Pause" : "Play", symbol: session.isPlaying ? "pause.fill" : "play.fill") {
            endEditing(); session.togglePlayback()
        }
        .disabled(playbackUnavailable)
    }

    private func transportButton(_ title: String, symbol: String, font: Font = .title3, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(font)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .accessibilityLabel(title)
    }
    private var historyButtons: some View {
        HStack(spacing: 0) {
            Button(session.undoLabel, systemImage: "arrow.uturn.backward") { endEditing(); session.undo() }
                .labelStyle(.iconOnly).frame(width: 44, height: 44).disabled(!session.canUndo)
            Button(session.redoLabel, systemImage: "arrow.uturn.forward") { endEditing(); session.redo() }
                .labelStyle(.iconOnly).frame(width: 44, height: 44).disabled(!session.canRedo)
        }
    }
    private var speedMenu: some View {
        Menu {
            Picker("Preview speed", selection: Binding(
                get: { session.previewPlaybackSpeed },
                set: { endEditing(); session.setPreviewPlaybackSpeed($0) })) {
                ForEach(EditorSession.previewPlaybackSpeeds, id: \.self) { speed in
                    Text(speedLabel(speed)).tag(speed)
                }
            }
        } label: {
            Text(speedLabel(session.previewPlaybackSpeed))
                .font(.title3.weight(.medium)).monospacedDigit()
                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
        .disabled(playbackUnavailable)
        .accessibilityLabel("Preview speed")
        .accessibilityValue(speedLabel(session.previewPlaybackSpeed))
    }

    private func speedLabel(_ speed: Float) -> String {
        speed.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }
    @ViewBuilder private var expandButton: some View {
        if let onExpand {
            transportButton("Fullscreen preview", symbol: "arrow.up.left.and.arrow.down.right", font: .body) { endEditing(); onExpand() }
                .disabled(session.isEditingClipTrim)
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


