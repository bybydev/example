import SwiftUI

/// A held video frame retains its own caption clock/snapshot while another host
/// plays or edits. The incoming live layer is revealed only when ready to display.
struct EditorPlayerPreview: View {
    let session: EditorSession
    var isActive = true
    let onError: (String?) -> Void
    @State private var held: PreviewHeldFrame?

    private var snapshot: CaptionSnapshot? {
        if let held { return held.snapshot }
        return session.snapshot
    }
    private var time: MediaTime { held?.time ?? session.time }

    var body: some View {
        ZStack {
            Color.black
            PlayerSurface(player: session.player, frames: session.previewFrames,
                generation: session.previewGeneration, snapshot: session.snapshot,
                time: session.time, isActive: isActive, onPresentation: { held = $0 })
            if session.document?.assets.allSatisfy({ $0.kind == .audio }) == true {
                Image(systemName: "waveform").font(.title).foregroundStyle(.white.opacity(0.45))
            }
            if let snapshot {
                StyledCaptionOverlay(snapshot: snapshot, time: time,
                    mediaSize: PreviewComposition.previewSize(for: snapshot.canvas), onError: onError)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(snapshot.evaluate(at: time)?.text ?? "No caption at playhead")
            }
            if EditorPreparationPresentation.showsLoadingIndicators && session.isPreparingPreview {
                ProgressView().tint(.white).accessibilityLabel("Preparing preview")
            }
        }
    }
}
