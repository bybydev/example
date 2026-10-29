import CoreMedia
import Foundation
import SwiftUI

/// A static, square, renderer-backed tile. The sample is local presentation data;
/// no user-media decode, player, animation timer, transcription or save is created.
struct CaptionTemplateThumbnail: View {
    let preset: CaptionPreset
    @State private var snapshot: CaptionSnapshot?
    @State private var failed = false
    private let time = try? EditorTime.stamp(CaptionStyleSample.previewSeconds)

    var body: some View {
        ZStack {
            CaptionSampleScenery(phase: CaptionStyleSample.previewSeconds / CaptionStyleSample.duration)
            if let snapshot, let time {
                StyledCaptionOverlay(snapshot: snapshot, time: time,
                    mediaSize: CGSize(width: 720, height: 720)) { failed = $0 != nil }
            }
            if failed {
                Image(systemName: "textformat").font(.title2).foregroundStyle(.white)
                    .padding(12).background(.black.opacity(0.5), in: Circle())
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityHidden(true)
        .task(id: preset.reference) {
            do { snapshot = try CaptionStyleSample.snapshot(style: preset.resolved, thumbnail: true); failed = false }
            catch { snapshot = nil; failed = true }
        }
    }
}

