import CoreMedia
import Foundation
import SwiftUI

/// Presentation-only authored sample timing. It never enters a real project,
/// changes recognition provenance or participates in speech allowance/exports.
enum CaptionStyleSample {
    static let sentences = [
        "A new day brings new possibilities.",
        "Take a moment to enjoy the view.",
        "The best stories start with you."
    ]
    static let sentenceDuration = 4.0
    static let previewSeconds = 1.2
    static var duration: Double { Double(sentences.count) * sentenceDuration }
    static var text: String { sentences.joined(separator: " ") }

    static func snapshot(style: CaptionStyle, thumbnail: Bool = false) throws -> CaptionSnapshot {
        let assetID = UUID(), clipID = UUID(), windowID = UUID()
        let interval = try MediaInterval(start: .zero, end: EditorTime.stamp(duration))
        var words: [CaptionWord] = []
        var cues: [CaptionCue] = []
        var segments: [RawSpeechSegment] = []
        for (sentenceIndex, sentence) in sentences.enumerated() {
            let start = Double(sentenceIndex) * sentenceDuration
            let texts = sentence.split(separator: " ").map(String.init)
            let step = (sentenceDuration - 0.4) / Double(texts.count)
            let sentenceWords = try texts.enumerated().map { index, text in
                let wordStart = start + 0.2 + Double(index) * step
                let range = try MediaInterval(start: EditorTime.stamp(wordStart),
                    end: EditorTime.stamp(wordStart + step * 0.92))
                return CaptionWord(id: UUID(), clipID: clipID, rawWindowID: windowID,
                    text: text + (index < texts.count - 1 ? " " : ""),
                    sourceInterval: range, projectInterval: range, timingProvenance: "authored-style-demo")
            }
            words.append(contentsOf: sentenceWords)
            cues.append(CaptionCue(id: UUID(), wordIDs: sentenceWords.map(\.id),
                interval: try MediaInterval(start: EditorTime.stamp(start), end: EditorTime.stamp(start + sentenceDuration))))
            segments.append(RawSpeechSegment(text: sentence, startSeconds: start + 0.2,
                endSeconds: start + sentenceDuration - 0.2))
        }
        let window = RecognitionWindow(id: windowID, clipID: clipID, sourceInterval: interval, languageCode: "en",
            segments: segments,
            tokens: words.map { .init(utf8: Data($0.text.utf8), startSeconds: EditorTime.seconds($0.sourceInterval.start),
                endSeconds: EditorTime.seconds($0.sourceInterval.end), hasTiming: true) })
        let date = Date(timeIntervalSince1970: 0)
        // Enlarge/recenter only the authored sample for a legible small tile.
        // The catalog preset and the user's chosen style are never altered.
        var thumbnailStyle = style
        if thumbnail {
            thumbnailStyle.positionX = 0.5; thumbnailStyle.positionY = 0.5
            thumbnailStyle.formatVersion = 2
            thumbnailStyle.fontSize = min(0.12, max(0.1, thumbnailStyle.fontSize * 1.6))
            thumbnailStyle.lineWidth = 0.92; thumbnailStyle.maximumLines = max(2, thumbnailStyle.maximumLines)
        }
        let document = ProjectDocument(schemaVersion: ProjectSchema.current, id: UUID(), contentRevision: 1,
            title: "Caption style sample", createdAt: date, updatedAt: date, preset: .custom,
            canvas: ProjectCanvas(width: thumbnail ? 720 : 1280, height: 720),
            assets: [SourceAsset(id: assetID, relativeOriginalPath: "Originals/style-demo", kind: .video,
                origin: .files, displayName: "Style demo", byteCount: 1, sha256: String(repeating: "0", count: 64),
                metadata: MediaMetadata(duration: interval.end, naturalWidth: 1280, naturalHeight: 720,
                    displayedWidth: 1280, displayedHeight: 720, rotationDegrees: 0, nominalFrameRate: 30,
                    videoTrackCount: 1, audioTrackCount: 1))],
            clips: [ProjectClip(id: clipID, sourceAssetID: assetID, sourceInterval: interval, timelineInterval: interval)],
            recognition: Recognition(id: UUID(), modelID: "authored-style-demo", modelSHA256: String(repeating: "0", count: 64),
                requestedLanguageCode: "en", completedAt: date, rawWindows: [window], words: words,
                cues: cues),
            captionStyle: thumbnailStyle)
        // The same value/render contracts as user footage, without opening media.
        try document.validate()
        return CaptionSnapshot(document)
    }
}

/// One procedural sample backdrop shared by the static template thumbnails.
struct CaptionSampleScenery: View {
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
