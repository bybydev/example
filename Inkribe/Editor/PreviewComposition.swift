@preconcurrency import AVFoundation
import CoreGraphics
import Foundation

/// Published as immutable AVComposition/AVVideoComposition copies. An export
/// receives its own graph; no player or mutable track is shared with its worker.
struct MediaGraph: @unchecked Sendable {
    let asset: AVComposition
    let videoComposition: AVVideoComposition?
    let videoIntervals: [MediaInterval]
    let duration: CMTime
    let hasAudio: Bool
    let audioMix: AVAudioMix?
}

/// One composition per media graph, never per caption keystroke, selection or panel.
@MainActor
enum PreviewComposition {
    static func make(document: ProjectDocument, urls: [UUID: URL]) async throws -> AVPlayerItem {
        let size = previewSize(for: document.canvas)
        let graph = try await mediaGraph(document: document, urls: urls, size: size)
        let item = AVPlayerItem(asset: graph.asset)
        item.videoComposition = graph.videoComposition
        item.audioMix = graph.audioMix
        return item
    }

    static func previewSize(for canvas: ProjectCanvas) -> CGSize {
        let scale = min(1, 1_080 / CGFloat(max(canvas.width, canvas.height)))
        return CGSize(width: max(2, (CGFloat(canvas.width) * scale / 2).rounded(.down) * 2),
                      height: max(2, (CGFloat(canvas.height) * scale / 2).rounded(.down) * 2))
    }

    /// P5 and preview share source/track intersections, placement and orientation.
    /// Trim, framing and original-audio mix are shared, not a second pipeline.
    static func mediaGraph(document: ProjectDocument, urls: [UUID: URL], size: CGSize) async throws -> MediaGraph {
        try document.validate()
        let composition = AVMutableComposition()
        let timeline = OutputTimeline(document)
        let duration = timeline.duration
        let edits = document.effectiveMediaEdits
        let used = Set(document.clips.filter { timeline.retained($0.timelineInterval) != nil }.map(\.sourceAssetID))
        let hasVideo = document.assets.contains { used.contains($0.id) && $0.metadata.videoTrackCount > 0 }
        let video = hasVideo ? composition.addMutableTrack(withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        let audio = composition.addMutableTrack(withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid)
        guard (!hasVideo || video != nil), audio != nil else { throw ProjectStoreError.unsupportedMedia }
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
        let projectBounds = CGRect(x: (size.width - projectSize.width) / 2, y: (size.height - projectSize.height) / 2,
                                   width: projectSize.width, height: projectSize.height)
        for original in document.clips.sorted(by: { $0.timelineInterval.start < $1.timelineInterval.start }) {
            try Task.checkCancellation()
            guard let retained = timeline.retained(original.timelineInterval),
                  let output = timeline.outputInterval(original.timelineInterval) else { continue }
            let sourceStart = try MediaTime(validating: CMTimeAdd(original.sourceInterval.start.cmTime,
                CMTimeSubtract(retained.start.cmTime, original.timelineInterval.start.cmTime)))
            let clip = ProjectClip(id: original.id, sourceAssetID: original.sourceAssetID,
                sourceInterval: try MediaInterval(start: sourceStart,
                    end: MediaTime(validating: CMTimeAdd(sourceStart.cmTime, retained.duration))), timelineInterval: output)
            guard let url = urls[clip.sourceAssetID] else {
                throw ProjectStoreError.missingOriginal(clip.sourceAssetID.uuidString)
            }
            if cursor < clip.timelineInterval.start {
                instructions.append(instruction(start: cursor, end: clip.timelineInterval.start, layer: nil))
            }
            let asset = AVURLAsset(url: url)
            guard let source = assets[clip.sourceAssetID] else { throw ProjectStoreError.unsupportedMedia }
            var layer: AVMutableVideoCompositionLayerInstruction?
            var videoInterval: MediaInterval?
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard (source.metadata.videoTrackCount == 0 || !videoTracks.isEmpty),
                  (source.metadata.audioTrackCount == 0 || !audioTracks.isEmpty) else { throw ExportError.decoding }
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
                          bounds.width > 0, bounds.height > 0 else { throw ExportError.decoding }
                    let final = try transform.concatenating(edits.placement(orientedBounds: bounds, target: projectBounds))
                    let value = AVMutableVideoCompositionLayerInstruction(assetTrack: video)
                    value.setTransform(final, at: interval.start.cmTime)
                    let crop = projectBounds.applying(final.inverted())
                        .intersection(CGRect(origin: .zero, size: natural))
                    guard !crop.isNull, !crop.isEmpty else { throw MediaEditError.invalidSettings }
                    value.setCropRectangle(crop, at: interval.start.cmTime)
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
        if cursor < duration {
            instructions.append(instruction(start: cursor, end: duration, layer: nil))
        }
        var finalMix: AVAudioMix?
        if insertedAudio, let audio {
            finalMix = originalAudioMix(trackID: audio.trackID, volume: edits.volume)
        }
        if let video, !insertedVideo { composition.removeTrack(video) }
        if let audio, !insertedAudio { composition.removeTrack(audio) }
        if !inserted {
            // A valid trim can retain only an intentional gap. A held black
            // frame gives AVPlayer a real clock; the export renderer stays black.
            let seed = AVURLAsset(url: try await BlackClockAsset.url())
            guard let source = try await seed.loadTracks(withMediaType: .video).first,
                  let clock = composition.addMutableTrack(withMediaType: .video,
                    preferredTrackID: kCMPersistentTrackID_Invalid) else { throw ExportError.decoding }
            let frame = CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 30))
            try clock.insertTimeRange(frame, of: source, at: .zero)
            clock.scaleTimeRange(frame, toDuration: duration.cmTime)
            instructions = [instruction(start: .zero, end: duration, layer: nil)]
            insertedVideo = true
        }
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
        guard let asset = composition.copy() as? AVComposition else { throw ExportError.invalidRequest }
        return MediaGraph(asset: asset, videoComposition: finalVideo, videoIntervals: videoIntervals,
                             duration: duration.cmTime, hasAudio: insertedAudio, audioMix: finalMix)
    }

    static func originalAudioMix(trackID: CMPersistentTrackID, volume: Double) -> AVAudioMix {
        let parameters = AVMutableAudioMixInputParameters()
        parameters.trackID = trackID
        parameters.setVolume(Float(volume), at: .zero)
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return (mix.copy() as? AVAudioMix) ?? mix
    }

    private static func insert(track: AVAssetTrack, clip: ProjectClip,
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
