import SwiftUI

struct EditorPlaybackControls: View {
    let session: EditorSession
    var showsOverview = true
    var onInteraction: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            Button(session.isPlaying ? "Pause" : "Play", systemImage: session.isPlaying ? "pause.fill" : "play.fill") {
                endEditing()
                session.togglePlayback()
            }
            .labelStyle(.iconOnly)
            .font(.title3)
            .frame(minWidth: 44, minHeight: 44)
            .disabled(session.isPreparingPreview || session.previewError != nil)
            VStack(spacing: 0) {
                CaptionTimeline(snapshot: session.snapshot, selectedCueID: session.selectedCueID,
                    duration: EditorTime.seconds(session.duration), seconds: EditorTime.seconds(session.time),
                    showsOverview: showsOverview, seek: { endEditing(); session.scrub(seconds: $0) })
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Text(EditorTime.display(session.time)).fixedSize()
                        Spacer()
                        Text(EditorTime.display(session.duration)).foregroundStyle(.secondary).fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(EditorTime.display(session.time))
                        Text(EditorTime.display(session.duration)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption2.monospacedDigit())
                .lineLimit(1)
            }
            Button(session.undoLabel, systemImage: "arrow.uturn.backward") { endEditing(); session.undo() }
                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).disabled(!session.canUndo)
        }
    }
    private func endEditing() {
        onInteraction()
        session.endTyping(); session.endStyleEditing(); session.endMediaEditing()
    }

}
