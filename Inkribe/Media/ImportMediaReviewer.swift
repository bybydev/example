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
    func review(_ source: ImportInput, requireVideo: Bool = false,
                includeThumbnail: Bool = true) async -> ImportSourceReview {
        let granted = source.localURL.startAccessingSecurityScopedResource()
        defer { if granted { source.localURL.stopAccessingSecurityScopedResource() } }
        do {
            try Task.checkCancellation()
            let (kind, metadata) = try await MediaInspector.inspect(url: source.localURL)
            if requireVideo && kind != .video {
                throw ProjectStoreError.invalidDocument("Choose a video file. Audio-only files can be added in Music.")
            }
            var image: Data?
            if includeThumbnail, kind == .video {
                image = try? await thumbnail(url: source.localURL, duration: metadata.duration)
            }
            return ImportSourceReview(metadata: metadata, kind: kind, thumbnail: image, error: nil)
        } catch { return ImportSourceReview(metadata: nil, kind: nil, thumbnail: nil, error: error.localizedDescription) }
    }

    /// Add clips validates metadata first. Optional row artwork has an independent,
    /// cancellable deadline and cannot hold the Add action disabled.
    @MainActor static func preview(_ source: ImportInput, duration: MediaTime) async -> Data? {
        let request = ImportThumbnailRequest()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            return await withCheckedContinuation { continuation in
                request.start(source, duration: duration, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor in request.cancel() }
        }
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

/// All state and generator configuration stay on MainActor. Native completion,
/// cancellation and timeout compete for one continuation; late callbacks are ignored.
@MainActor
private final class ImportThumbnailRequest {
    private var generator: AVAssetImageGenerator?
    private var continuation: CheckedContinuation<Data?, Never>?
    private var deadline: Task<Void, Never>?
    private var scopedURL: URL?
    private var completed = false

    func start(_ source: ImportInput, duration: MediaTime,
               continuation: CheckedContinuation<Data?, Never>) {
        guard !completed else { continuation.resume(returning: nil); return }
        self.continuation = continuation
        if source.localURL.startAccessingSecurityScopedResource() { scopedURL = source.localURL }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source.localURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 180, height: 180)
        self.generator = generator
        let time = CMTimeMinimum(CMTime(value: 1, timescale: 2),
            CMTimeMultiplyByFloat64(duration.cmTime, multiplier: 0.5))
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, result, _ in
            Task { @MainActor in
                self.finish(result == .succeeded ? image : nil)
            }
        }
        deadline = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(3))
                self?.finish(nil)
            } catch { }
        }
    }

    func cancel() { finish(nil) }

    private func finish(_ image: CGImage?) {
        guard !completed else { return }
        completed = true
        deadline?.cancel(); deadline = nil
        generator?.cancelAllCGImageGeneration(); generator = nil
        scopedURL?.stopAccessingSecurityScopedResource(); scopedURL = nil
        let continuation = self.continuation
        self.continuation = nil
        let data: Data?
        if let image { data = Self.jpeg(image) } else { data = nil }
        continuation?.resume(returning: data)
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData,
            UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image,
            [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length <= 262_144 else { return nil }
        return data as Data
    }
}
