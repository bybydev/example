@preconcurrency import AVFoundation
import CoreGraphics
import Foundation

/// One composition per media graph, never per caption keystroke, selection or panel.
@MainActor
enum IOSPreviewComposition {
    static func make(document: IOSProjectDocument, urls: [UUID: URL]) async throws -> AVPlayerItem {
        let composition = AVMutableComposition()
        let duration = document.clips.map(\.timelineInterval.end).max() ?? .zero
        let hasVideo = document.assets.contains { $0.metadata.videoTrackCount > 0 }
        let video = hasVideo ? composition.addMutableTrack(withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        let audio = composition.addMutableTrack(withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid)
        let scale = min(1, 1_080 / CGFloat(max(document.canvas.width, document.canvas.height)))
        let size = CGSize(width: max(2, (CGFloat(document.canvas.width) * scale / 2).rounded(.down) * 2),
                          height: max(2, (CGFloat(document.canvas.height) * scale / 2).rounded(.down) * 2))
        var instructions: [AVMutableVideoCompositionInstruction] = []
        var cursor = MediaTime.zero
        var inserted = false
        var insertedVideo = false
        var insertedAudio = false
        for clip in document.clips.sorted(by: { $0.timelineInterval.start < $1.timelineInterval.start }) {
            try Task.checkCancellation()
            guard let url = urls[clip.sourceAssetID] else {
                throw IOSProjectStoreError.missingOriginal(clip.sourceAssetID.uuidString)
            }
            if cursor < clip.timelineInterval.start {
                instructions.append(instruction(start: cursor, end: clip.timelineInterval.start, layer: nil))
            }
            let asset = AVURLAsset(url: url)
            var layer: AVMutableVideoCompositionLayerInstruction?
            if let video, let track = try await asset.loadTracks(withMediaType: .video).first {
                if try await insert(track: track, clip: clip, into: video) {
                    inserted = true
                    insertedVideo = true
                    let transform = try await track.load(.preferredTransform)
                    let natural = try await track.load(.naturalSize)
                    let bounds = CGRect(origin: .zero, size: natural).applying(transform)
                    guard bounds.width > 0, bounds.height > 0 else { throw IOSSpeechError.invalidAudio }
                    let fit = min(size.width / bounds.width, size.height / bounds.height)
                    let final = transform
                        .concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
                        .concatenating(CGAffineTransform(scaleX: fit, y: fit))
                        .concatenating(CGAffineTransform(translationX: (size.width - bounds.width * fit) / 2,
                                                        y: (size.height - bounds.height * fit) / 2))
                    let value = AVMutableVideoCompositionLayerInstruction(assetTrack: video)
                    value.setTransform(final, at: clip.timelineInterval.start.cmTime)
                    layer = value
                }
            }
            if let audio, let track = try await asset.loadTracks(withMediaType: .audio).first {
                if try await insert(track: track, clip: clip, into: audio) { inserted = true; insertedAudio = true }
            }
            instructions.append(instruction(start: clip.timelineInterval.start, end: clip.timelineInterval.end, layer: layer))
            cursor = clip.timelineInterval.end
        }
        guard inserted else { throw IOSProjectStoreError.unsupportedMedia }
        if let video, !insertedVideo { composition.removeTrack(video) }
        if let audio, !insertedAudio { composition.removeTrack(audio) }
        if CMTimeCompare(composition.duration, duration.cmTime) < 0 {
            composition.insertEmptyTimeRange(CMTimeRange(start: composition.duration,
                duration: CMTimeSubtract(duration.cmTime, composition.duration)))
        }
        let item = AVPlayerItem(asset: composition)
        if insertedVideo {
            let videoComposition = AVMutableVideoComposition()
            videoComposition.renderSize = size
            videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
            videoComposition.instructions = instructions
            item.videoComposition = videoComposition
        }
        return item
    }

    private static func insert(track: AVAssetTrack, clip: IOSProjectClip,
                               into target: AVMutableCompositionTrack) async throws -> Bool {
        // Track offsets/gaps remain at their source positions, rather than sliding audio to zero.
        let available = try await track.load(.timeRange)
        let requested = CMTimeRange(start: clip.sourceInterval.start.cmTime, duration: clip.sourceInterval.duration)
        let range = CMTimeRangeGetIntersection(available, requested)
        guard range.isValid, !range.isEmpty, CMTimeCompare(range.duration, .zero) > 0 else { return false }
        let at = CMTimeAdd(clip.timelineInterval.start.cmTime,
            CMTimeSubtract(range.start, clip.sourceInterval.start.cmTime))
        try target.insertTimeRange(range, of: track, at: at)
        return true
    }

    private static func instruction(start: MediaTime, end: MediaTime,
                                    layer: AVMutableVideoCompositionLayerInstruction?) -> AVMutableVideoCompositionInstruction {
        let value = AVMutableVideoCompositionInstruction()
        value.timeRange = CMTimeRange(start: start.cmTime, duration: CMTimeSubtract(end.cmTime, start.cmTime))
        value.backgroundColor = CGColor(gray: 0, alpha: 1)
        value.layerInstructions = layer.map { [$0] } ?? []
        return value
    }
}
