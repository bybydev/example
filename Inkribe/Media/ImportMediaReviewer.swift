@preconcurrency import AVFoundation
import Foundation
import CoreGraphics
import CoreMedia
import ImageIO
import UniformTypeIdentifiers

struct ImportSourceReview: Sendable {
    let metadata: MediaMetadata?
    let kind: MediaKind?
    let thumbnail: Data?
    let error: String?
}

/// Disposable ingress previews. Publication revalidates the copied original.
actor ImportMediaReviewer {
    func review(_ source: ImportInput) async -> ImportSourceReview {
        let granted = source.localURL.startAccessingSecurityScopedResource()
        defer { if granted { source.localURL.stopAccessingSecurityScopedResource() } }
        do {
            try Task.checkCancellation()
            let (kind, metadata) = try await MediaInspector.inspect(url: source.localURL)
            var image: Data?
            if kind == .video { image = try? await thumbnail(url: source.localURL, duration: metadata.duration) }
            return ImportSourceReview(metadata: metadata, kind: kind, thumbnail: image, error: nil)
        } catch { return ImportSourceReview(metadata: nil, kind: nil, thumbnail: nil, error: error.localizedDescription) }
    }

    private func thumbnail(url: URL, duration: MediaTime) async throws -> Data? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 180, height: 180)
        let (image, _) = try await generator.image(at: CMTimeMinimum(CMTime(value: 1, timescale: 2),
            CMTimeMultiplyByFloat64(duration.cmTime, multiplier: 0.5)))
        try Task.checkCancellation()
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length <= 262_144 else { return nil }
        return data as Data
    }
}
