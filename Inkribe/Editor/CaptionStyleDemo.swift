import CoreMedia
import Foundation
import SwiftUI

/// A silent, self-contained sample loop. No user media, decoding, inference,
/// repository writes or additional AVPlayer is involved in the style browser.
struct CaptionStyleDemo: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let preset: CaptionPreset
    var isActive = true
    @State private var snapshot: CaptionSnapshot?
    @State private var renderError: String?
    @State private var paused = false
    @State private var explicitlyPlaying = false
    @State private var visible = false
    @State private var epoch = Date()
    @State private var heldSeconds = 1.2

    private var running: Bool {
        visible && isActive && scenePhase == .active && !paused && (!reduceMotion || explicitlyPlaying)
    }
    private func seconds(at date: Date) -> Double {
        max(0, date.timeIntervalSince(epoch)).truncatingRemainder(dividingBy: 4)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !running)) { context in
                let demoSeconds = running ? seconds(at: context.date) : heldSeconds
                ZStack {
                    CaptionDemoScenery(phase: demoSeconds / 4)
                    if let snapshot, let time = try? EditorTime.stamp(demoSeconds) {
                        StyledCaptionOverlay(snapshot: snapshot, time: time,
                            mediaSize: CGSize(width: 1280, height: 720)) { renderError = $0 }
                            .accessibilityHidden(true)
                    }
                }
                .aspectRatio(16.0 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 15))
            }
            .overlay(alignment: .topLeading) {
                Label("Style demo", systemImage: "repeat")
                    .font(.caption2.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 5)
                    .foregroundStyle(.white).background(.black.opacity(0.45), in: Capsule()).padding(10)
            }
            .overlay(alignment: .bottomTrailing) {
                Button {
                    if running { paused = true }
                    else { explicitlyPlaying = true; paused = false }
                } label: {
                    Image(systemName: running ? "pause.fill" : "play.fill")
                        .frame(width: 44, height: 44).foregroundStyle(.white)
                        .background(.black.opacity(0.5), in: Circle())
                }
                .buttonStyle(.plain).padding(6)
                .accessibilityLabel(running ? "Pause style demo" : "Play style demo")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(preset.name) sample: Make every word count")
            if let renderError {
                Label(renderError, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }
        .task(id: preset.id + "-" + String(preset.version)) {
            do { snapshot = try CaptionDemoSample.snapshot(for: preset); renderError = nil }
            catch { snapshot = nil; renderError = "This style demo could not be prepared." }
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .onChange(of: running) { wasRunning, nowRunning in
            if wasRunning { heldSeconds = seconds(at: Date()) }
            if nowRunning { epoch = Date().addingTimeInterval(-heldSeconds) }
        }
    }
}

/// Presentation-only authored sample timing. It never enters a real project,
/// changes recognition provenance or participates in speech allowance/exports.
private enum CaptionDemoSample {
    static func snapshot(for preset: CaptionPreset) throws -> CaptionSnapshot {
        let assetID = UUID(), clipID = UUID(), windowID = UUID(), cueID = UUID()
        let interval = try MediaInterval(start: .zero, end: EditorTime.stamp(4))
        let texts = ["Make ", "every ", "word ", "count."]
        let words = try texts.enumerated().map { index, text in
            let start = 0.25 + Double(index) * 0.7
            let range = try MediaInterval(start: EditorTime.stamp(start), end: EditorTime.stamp(start + 0.65))
            return CaptionWord(id: UUID(), clipID: clipID, rawWindowID: windowID, text: text,
                sourceInterval: range, projectInterval: range, timingProvenance: "authored-style-demo")
        }
        let window = RecognitionWindow(id: windowID, clipID: clipID, sourceInterval: interval, languageCode: "en",
            segments: [.init(text: texts.joined(), startSeconds: 0.25, endSeconds: 3)],
            tokens: words.map { .init(utf8: Data($0.text.utf8), startSeconds: EditorTime.seconds($0.sourceInterval.start),
                endSeconds: EditorTime.seconds($0.sourceInterval.end), hasTiming: true) })
        let date = Date(timeIntervalSince1970: 0)
        let document = ProjectDocument(schemaVersion: ProjectSchema.current, id: UUID(), contentRevision: 1,
            title: "Caption style sample", createdAt: date, updatedAt: date, preset: .custom,
            canvas: ProjectCanvas(width: 1280, height: 720),
            assets: [SourceAsset(id: assetID, relativeOriginalPath: "Originals/style-demo", kind: .video,
                origin: .files, displayName: "Style demo", byteCount: 1, sha256: String(repeating: "0", count: 64),
                metadata: MediaMetadata(duration: interval.end, naturalWidth: 1280, naturalHeight: 720,
                    displayedWidth: 1280, displayedHeight: 720, rotationDegrees: 0, nominalFrameRate: 30,
                    videoTrackCount: 1, audioTrackCount: 1))],
            clips: [ProjectClip(id: clipID, sourceAssetID: assetID, sourceInterval: interval, timelineInterval: interval)],
            recognition: Recognition(id: UUID(), modelID: "authored-style-demo", modelSHA256: String(repeating: "0", count: 64),
                requestedLanguageCode: "en", completedAt: date, rawWindows: [window], words: words,
                cues: [CaptionCue(id: cueID, wordIDs: words.map(\.id),
                    interval: try MediaInterval(start: EditorTime.stamp(0.15), end: EditorTime.stamp(3.35)))]),
            captionStyle: preset.resolved)
        // The same value/render contracts as user footage, without opening media.
        try document.validate()
        return CaptionSnapshot(document)
    }
}

/// An original procedural sample backdrop, shared by every look. Its slow
/// movement reads as a clip without shipping third-party footage or decoders.
private struct CaptionDemoScenery: View {
    let phase: Double
    var body: some View {
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            context.fill(Path(bounds), with: .linearGradient(Gradient(colors: [
                Color(red: 0.38, green: 0.51, blue: 0.60), Color(red: 0.88, green: 0.72, blue: 0.57)
            ]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height * 0.75)))
            let drift = CGFloat(sin(phase * .pi * 2)) * size.width * 0.015
            let sun = CGRect(x: size.width * 0.68 + drift, y: size.height * 0.16,
                width: size.height * 0.16, height: size.height * 0.16)
            context.fill(Path(ellipseIn: sun), with: .color(Color(red: 1, green: 0.9, blue: 0.73)))
            var mountain = Path()
            mountain.move(to: CGPoint(x: 0, y: size.height * 0.68))
            for (x, y) in [(0.0, 0.48), (0.16, 0.40), (0.32, 0.18), (0.46, 0.42), (0.57, 0.34), (0.78, 0.68)] {
                mountain.addLine(to: CGPoint(x: size.width * CGFloat(x) + drift, y: size.height * CGFloat(y)))
            }
            mountain.closeSubpath()
            context.fill(mountain, with: .color(Color(red: 0.23, green: 0.36, blue: 0.42)))
            context.fill(Path(CGRect(x: 0, y: size.height * 0.67, width: size.width, height: size.height * 0.33)),
                with: .linearGradient(Gradient(colors: [Color(red: 0.27, green: 0.41, blue: 0.46), Color(red: 0.11, green: 0.23, blue: 0.30)]),
                    startPoint: CGPoint(x: 0, y: size.height * 0.67), endPoint: CGPoint(x: 0, y: size.height)))
            for row in 0..<6 {
                var ripple = Path()
                let y = size.height * CGFloat(0.73 + Double(row) * 0.045)
                ripple.move(to: CGPoint(x: size.width * 0.1 + drift, y: y))
                ripple.addLine(to: CGPoint(x: size.width * 0.9 + drift, y: y))
                context.stroke(ripple, with: .color(.white.opacity(0.08)), lineWidth: 1)
            }
        }
        .accessibilityHidden(true)
    }
}
