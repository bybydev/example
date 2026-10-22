import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Optional, reproducible cache only. Missing/corrupt thumbnails never make a
/// project unavailable. The original media remains the authority.
actor IOSProjectThumbnails {
    private let repository: IOSProjectRepository

    init(repository: IOSProjectRepository) {
        self.repository = repository
    }

    func regenerate(projectID: UUID) async throws -> URL? {
        let project = try await repository.open(projectID)
        guard let source = project.assets.first(where: { $0.kind == .video }) else {
            return nil
        }
        let mediaURL = try await repository.sourceURL(projectID: projectID, assetID: source.id)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: mediaURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 720)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 4)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 4)
        let sampleTime = CMTimeMinimum(
            CMTime(value: 1, timescale: 2),
            CMTimeMultiplyByFloat64(source.metadata.duration.cmTime, multiplier: 0.5)
        )
        let (image, _) = try await generator.image(at: sampleTime)
        try Task.checkCancellation()
        let output = try await repository.thumbnailURL(id: projectID)
        let temporary = output.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let encoder = CGImageDestinationCreateWithURL(temporary as CFURL,
                 UTType.jpeg.identifier as CFString, 1, nil) else {
            throw IOSProjectStoreError.unavailableRoot
        }
        let properties = [kCGImageDestinationLossyCompressionQuality as String: 0.8] as NSDictionary
        CGImageDestinationAddImage(encoder, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(encoder) else {
            throw IOSProjectStoreError.unavailableRoot
        }
        // Small derived cache file; atomic replacement avoids partial JPEGs.
        try Data(contentsOf: temporary).write(to: output, options: .atomic)
        return output
    }
}
