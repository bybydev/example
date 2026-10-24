@preconcurrency import AVFoundation
import Observation
import SwiftUI

/// One bounded media-only frame shared by every preset, never one player/decoder
/// per card. Generation checks reject an old composition or cancelled request.
@MainActor @Observable
final class CaptionPreviewFrame {
    private(set) var image: CGImage?
    private(set) var time: MediaTime?
    private(set) var error: String?
    private(set) var isLoading = false
    @ObservationIgnored private var generator: AVAssetImageGenerator?
    private var generation = UUID()

    func capture(item: AVPlayerItem?, at time: MediaTime, audioOnly: Bool) async {
        cancel()
        image = nil; self.time = nil; error = nil
        guard !audioOnly else { self.time = time; return }
        guard let item else { error = "Footage preview is unavailable. Retry preview above."; return }
        let token = generation
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.appliesPreferredTrackTransform = true
        generator.videoComposition = item.videoComposition
        generator.maximumSize = CGSize(width: 480, height: 480)
        // Exact output clock; do not silently compare captions against a nearby cue.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        self.generator = generator
        isLoading = true
        defer { if token == generation { isLoading = false; self.generator = nil } }
        do {
            let result = try await generator.image(at: time.cmTime)
            guard token == generation, !Task.isCancelled else { return }
            image = result.image
            self.time = try MediaTime(validating: result.actualTime)
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            self.error = "The comparison frame could not be loaded. " + error.localizedDescription
        }
    }
    func clear() {
        cancel()
        image = nil; time = nil; error = nil
    }
    func cancel() {
        generation = UUID()
        generator?.cancelAllCGImageGeneration()
        generator = nil
        isLoading = false
    }
}

struct CaptionFrameRequest: Equatable {
    let generation: UUID
    let time: MediaTime?
    let preparing: Bool
    let refreshID: UUID
    let isActive: Bool
}

/// Actual media frame and the exact same caption renderer used by live/export.
/// An empty/hidden caption or paused gap stays empty; no sample text is invented.
struct CaptionStillPreview: View {
    let frame: CaptionPreviewFrame
    let snapshot: CaptionSnapshot?
    let audioOnly: Bool
    @State private var renderError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Color.black
                if let image = frame.image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                } else if audioOnly {
                    Image(systemName: "waveform").font(.title).foregroundStyle(.white.opacity(0.45))
                }
                if let snapshot, let time = frame.time {
                    StyledCaptionOverlay(snapshot: snapshot, time: time,
                        mediaSize: PreviewComposition.previewSize(for: snapshot.canvas)) { renderError = $0 }
                }
                if frame.isLoading { ProgressView().tint(.white) }
            }
            .aspectRatio(aspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)
            if let renderError, frame.time != nil {
                Label(renderError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }
    private var aspect: CGFloat {
        guard let canvas = snapshot?.canvas else { return 9 / 16 }
        return CGFloat(canvas.width) / CGFloat(canvas.height)
    }
}

private struct CaptionStylePreviewKey: Equatable {
    let snapshotID: UUID?
    let style: CaptionStyle
}

/// Retain one styled snapshot/index per card instead of relaying out every
/// preset on each playback tick or unrelated parent redraw.
struct CaptionPresetPreview: View {
    let frame: CaptionPreviewFrame
    let snapshot: CaptionSnapshot?
    let style: CaptionStyle
    let audioOnly: Bool
    @State private var styled: CaptionSnapshot?
    var body: some View {
        CaptionStillPreview(frame: frame, snapshot: styled, audioOnly: audioOnly)
            .task(id: CaptionStylePreviewKey(snapshotID: snapshot?.id, style: style)) {
                styled = snapshot?.styled(style)
            }
    }
}
