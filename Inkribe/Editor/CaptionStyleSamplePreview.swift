import Foundation
import SwiftUI

/// The same sample words, timings and scenery as the template tiles. Only this
/// visible sample animates; the project's player and caption clock are untouched.
struct CaptionStyleSamplePreview: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let style: CaptionStyle
    var isActive = true
    @State private var sample: CaptionSnapshot?
    @State private var styled: CaptionSnapshot?
    @State private var renderError: String?
    @State private var visible = false
    @State private var paused = false
    @State private var explicitlyPlaying = false
    @State private var epoch = Date().addingTimeInterval(-CaptionStyleSample.previewSeconds)
    @State private var heldSeconds = CaptionStyleSample.previewSeconds

    private var running: Bool {
        visible && isActive && scenePhase == .active && !paused && (!reduceMotion || explicitlyPlaying)
    }
    private func seconds(at date: Date) -> Double {
        max(0, date.timeIntervalSince(epoch)).truncatingRemainder(dividingBy: CaptionStyleSample.duration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !running)) { context in
                let value = running ? seconds(at: context.date) : heldSeconds
                ZStack {
                    CaptionSampleScenery(phase: value / CaptionStyleSample.duration)
                    if let styled, let time = try? EditorTime.stamp(value) {
                        StyledCaptionOverlay(snapshot: styled, time: time,
                            mediaSize: CGSize(width: 1280, height: 720)) { renderError = $0 }
                            .accessibilityHidden(true)
                    }
                }
                .aspectRatio(16.0 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .overlay(alignment: .bottomTrailing) {
                Button {
                    if running { paused = true }
                    else { explicitlyPlaying = true; paused = false }
                } label: {
                    Image(systemName: running ? "pause.fill" : "play.fill")
                        .foregroundStyle(.white).frame(width: 44, height: 44)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .buttonStyle(.plain).padding(6)
                .accessibilityLabel(running ? "Pause sample preview" : "Play sample preview")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Template sample: " + CaptionStyleSample.text)
            if let renderError {
                Label(renderError, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }
        .task {
            do { sample = try CaptionStyleSample.snapshot(style: .standard); restyle() }
            catch { renderError = "The sample preview could not be prepared." }
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .onChange(of: style) { _, _ in restyle() }
        .onChange(of: style.preset) { _, _ in
            // Return from the grid at its sample frame, retaining visual continuity.
            heldSeconds = CaptionStyleSample.previewSeconds; epoch = Date().addingTimeInterval(-heldSeconds)
        }
        .onChange(of: running) { wasRunning, nowRunning in
            if wasRunning { heldSeconds = seconds(at: Date()) }
            if nowRunning { epoch = Date().addingTimeInterval(-heldSeconds) }
        }
    }

    private func restyle() {
        styled = sample?.styled(style)
    }
}
