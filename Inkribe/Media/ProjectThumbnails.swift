import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Optional, reproducible cache only. Missing/corrupt thumbnails never make a
/// project unavailable. The original media remains the authority.
actor ProjectThumbnails {
    private let repository: ProjectRepository

    init(repository: ProjectRepository) {
        self.repository = repository
    }

    func regenerate(projectID: UUID) async throws -> URL? {
        let project = try await repository.open(projectID)
        let timeline = OutputTimeline(project)
        let assets = Dictionary(uniqueKeysWithValues: project.assets.map { ($0.id, $0) })
        guard let clip = project.orderedClips.first(where: {
            assets[$0.sourceAssetID]?.kind == .video && timeline.retained($0.timelineInterval) != nil
        }), let source = assets[clip.sourceAssetID], let retained = timeline.retained(clip.timelineInterval) else {
            try await repository.purgeThumbnail(projectID: projectID, expectedRevision: project.contentRevision)
            return nil
        }
        let mediaURL = try await repository.sourceURL(projectID: projectID, assetID: source.id)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: mediaURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 720)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 4)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 4)
        let sourceStart = CMTimeAdd(clip.sourceInterval.start.cmTime,
            CMTimeSubtract(retained.start.cmTime, clip.timelineInterval.start.cmTime))
        let sampleTime = CMTimeAdd(sourceStart, CMTimeMinimum(CMTime(value: 1, timescale: 2),
            CMTimeMultiplyByFloat64(retained.duration, multiplier: 0.5)))
        let (image, _) = try await generator.image(at: sampleTime)
        try Task.checkCancellation()
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let encoder = CGImageDestinationCreateWithURL(temporary as CFURL,
                 UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ProjectStoreError.unavailableRoot
        }
        let properties = [kCGImageDestinationLossyCompressionQuality as String: 0.8] as NSDictionary
        CGImageDestinationAddImage(encoder, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(encoder) else {
            throw ProjectStoreError.unavailableRoot
        }
        // Small derived cache file; atomic replacement avoids partial JPEGs.
        return try await repository.publishThumbnail(Data(contentsOf: temporary), projectID: projectID,
                                                     assetID: source.id, sourceHash: source.sha256, expectedRevision: project.contentRevision)
    }
}
