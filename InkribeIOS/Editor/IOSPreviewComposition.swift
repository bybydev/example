@preconcurrency import AVFoundation
import CoreGraphics
import Foundation

/// Published as immutable AVComposition/AVVideoComposition copies. An export
/// receives its own graph; no player or mutable track is shared with its worker.
struct IOSMediaGraph: @unchecked Sendable {
    let asset: AVComposition
    let videoComposition: AVVideoComposition?
    let videoIntervals: [MediaInterval]
    let duration: CMTime
    let hasAudio: Bool
}

/// One composition per media graph, never per caption keystroke, selection or panel.
@MainActor
enum IOSPreviewComposition {
    static func make(document: IOSProjectDocument, urls: [UUID: URL]) async throws -> AVPlayerItem {
        let scale = min(1, 1_080 / CGFloat(max(document.canvas.width, document.canvas.height)))
        let size = CGSize(width: max(2, (CGFloat(document.canvas.width) * scale / 2).rounded(.down) * 2),
                          height: max(2, (CGFloat(document.canvas.height) * scale / 2).rounded(.down) * 2))
        let graph = try await mediaGraph(document: document, urls: urls, size: size)
        let item = AVPlayerItem(asset: graph.asset)
        item.videoComposition = graph.videoComposition
        return item
    }

    /// P5 and preview share source/track intersections, placement and orientation.
    /// P6 adds trim/crop/audio-mix changes here rather than in a second pipeline.
    static func mediaGraph(document: IOSProjectDocument, urls: [UUID: URL], size: CGSize) async throws -> IOSMediaGraph {
        try document.validate()
        let composition = AVMutableComposition()
        let duration = document.clips.map(\.timelineInterval.end).max() ?? .zero
        let hasVideo = document.assets.contains { $0.metadata.videoTrackCount > 0 }
        let video = hasVideo ? composition.addMutableTrack(withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        let audio = composition.addMutableTrack(withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid)
        guard (!hasVideo || video != nil), audio != nil else { throw IOSProjectStoreError.unsupportedMedia }
        let assets = Dictionary(uniqueKeysWithValues: document.assets.map { ($0.id, $0) })
        var instructions: [AVMutableVideoCompositionInstruction] = []
        var videoIntervals: [MediaInterval] = []
        var cursor = MediaTime.zero
        var inserted = false
        var insertedVideo = false
        var insertedAudio = false
        let projectFit = min(size.width / CGFloat(document.canvas.width), size.height / CGFloat(document.canvas.height))
        let projectSize = CGSize(width: CGFloat(document.canvas.width) * projectFit,
                                 height: CGFloat(document.canvas.height) * projectFit)
        for clip in document.clips.sorted(by: { $0.timelineInterval.start < $1.timelineInterval.start }) {
            try Task.checkCancellation()
            guard let url = urls[clip.sourceAssetID] else {
                throw IOSProjectStoreError.missingOriginal(clip.sourceAssetID.uuidString)
            }
            if cursor < clip.timelineInterval.start {
                instructions.append(instruction(start: cursor, end: clip.timelineInterval.start, layer: nil))
            }
            let asset = AVURLAsset(url: url)
            guard let source = assets[clip.sourceAssetID] else { throw IOSProjectStoreError.unsupportedMedia }
            var layer: AVMutableVideoCompositionLayerInstruction?
            var videoInterval: MediaInterval?
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard (source.metadata.videoTrackCount == 0 || !videoTracks.isEmpty),
                  (source.metadata.audioTrackCount == 0 || !audioTracks.isEmpty) else { throw IOSExportError.decoding }
            if let video, let track = videoTracks.first {
                if let interval = try await insert(track: track, clip: clip, into: video) {
                    inserted = true
                    insertedVideo = true
                    videoInterval = interval
                    videoIntervals.append(interval)
                    let transform = try await track.load(.preferredTransform)
                    let natural = try await track.load(.naturalSize)
                    let bounds = CGRect(origin: .zero, size: natural).applying(transform)
                    guard bounds.minX.isFinite, bounds.minY.isFinite, bounds.width.isFinite, bounds.height.isFinite,
                          bounds.width > 0, bounds.height > 0 else { throw IOSExportError.decoding }
                    let fit = min(projectSize.width / bounds.width, projectSize.height / bounds.height)
                    let final = transform
                        .concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
                        .concatenating(CGAffineTransform(scaleX: fit, y: fit))
                        .concatenating(CGAffineTransform(translationX: (size.width - bounds.width * fit) / 2,
                                                        y: (size.height - bounds.height * fit) / 2))
                    let value = AVMutableVideoCompositionLayerInstruction(assetTrack: video)
                    value.setTransform(final, at: interval.start.cmTime)
                    layer = value
                }
            }
            if let audio, let track = audioTracks.first {
                if try await insert(track: track, clip: clip, into: audio) != nil { inserted = true; insertedAudio = true }
            }
            if let videoInterval, let layer {
                if clip.timelineInterval.start < videoInterval.start {
                    instructions.append(instruction(start: clip.timelineInterval.start, end: videoInterval.start, layer: nil))
                }
                instructions.append(instruction(start: videoInterval.start, end: videoInterval.end, layer: layer))
                if videoInterval.end < clip.timelineInterval.end {
                    instructions.append(instruction(start: videoInterval.end, end: clip.timelineInterval.end, layer: nil))
                }
            } else {
                instructions.append(instruction(start: clip.timelineInterval.start, end: clip.timelineInterval.end, layer: nil))
            }
            cursor = clip.timelineInterval.end
        }
        guard inserted else { throw IOSProjectStoreError.unsupportedMedia }
        if let video, !insertedVideo { composition.removeTrack(video) }
        if let audio, !insertedAudio { composition.removeTrack(audio) }
        if CMTimeCompare(composition.duration, duration.cmTime) < 0 {
            composition.insertEmptyTimeRange(CMTimeRange(start: composition.duration,
                duration: CMTimeSubtract(duration.cmTime, composition.duration)))
        }
        var finalVideo: AVVideoComposition?
        if insertedVideo {
            let videoComposition = AVMutableVideoComposition()
            videoComposition.renderSize = size
            videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
            videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
            videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
            videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
            videoComposition.instructions = instructions
            finalVideo = videoComposition.copy() as? AVVideoComposition
        }
        guard let asset = composition.copy() as? AVComposition else { throw IOSExportError.invalidRequest }
        return IOSMediaGraph(asset: asset, videoComposition: finalVideo, videoIntervals: videoIntervals,
                             duration: duration.cmTime, hasAudio: insertedAudio)
    }

    private static func insert(track: AVAssetTrack, clip: IOSProjectClip,
                               into target: AVMutableCompositionTrack) async throws -> MediaInterval? {
        // Track offsets/gaps remain at their source positions, rather than sliding audio to zero.
        let available = try await track.load(.timeRange)
        let requested = CMTimeRange(start: clip.sourceInterval.start.cmTime, duration: clip.sourceInterval.duration)
        let range = CMTimeRangeGetIntersection(available, requested)
        guard range.isValid, !range.isEmpty, CMTimeCompare(range.duration, .zero) > 0 else { return nil }
        let at = CMTimeAdd(clip.timelineInterval.start.cmTime,
            CMTimeSubtract(range.start, clip.sourceInterval.start.cmTime))
        try target.insertTimeRange(range, of: track, at: at)
        return try MediaInterval(start: MediaTime(validating: at),
                                 end: MediaTime(validating: CMTimeAdd(at, range.duration)))
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
