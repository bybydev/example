import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

/// Metadata is read from the copied, app-owned media, not an expiring provider URL.
/// Failure is a failed import; never manufacture a timeline duration or frame rate.
enum MediaInspector {
    static func inspect(url: URL) async throws -> (MediaKind, MediaMetadata) {
        let asset = AVURLAsset(url: url)
        let duration = try MediaTime(validating: await asset.load(.duration))
        guard duration > .zero else { throw ProjectStoreError.unsupportedMedia }
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        guard !videos.isEmpty || !audios.isEmpty else {
            throw ProjectStoreError.unsupportedMedia
        }
        var naturalWidth = 0
        var naturalHeight = 0
        var width = 0
        var height = 0
        var degrees = 0
        var frameRate: Double?
        if let video = videos.first {
            let natural = try await video.load(.naturalSize)
            let transform = try await video.load(.preferredTransform)
            let bounds = CGRect(origin: .zero, size: natural).applying(transform).standardized
            // Reject malformed metadata before floating-point-to-Int conversion.
            let dimensions = [natural.width, natural.height, bounds.width, bounds.height]
            guard dimensions.allSatisfy({ $0.isFinite && $0 > 0 && $0 < CGFloat(Int32.max) }),
                  bounds.minX.isFinite, bounds.minY.isFinite,
                  [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty].allSatisfy(\.isFinite) else {
                throw ProjectStoreError.unsupportedMedia
            }
            naturalWidth = Int(abs(natural.width).rounded())
            naturalHeight = Int(abs(natural.height).rounded())
            width = Int(abs(bounds.width).rounded())
            height = Int(abs(bounds.height).rounded())
            let rawDegrees = atan2(transform.b, transform.a) * 180 / .pi
            degrees = Int((rawDegrees / 90).rounded()) * 90
            let nominal = Double(try await video.load(.nominalFrameRate))
            if nominal.isFinite && nominal > 0 {
                frameRate = nominal
            }
        }
        let result = MediaMetadata(
            duration: duration, naturalWidth: naturalWidth, naturalHeight: naturalHeight,
            displayedWidth: width, displayedHeight: height,
            rotationDegrees: degrees, nominalFrameRate: frameRate,
            videoTrackCount: videos.count, audioTrackCount: audios.count
        )
        try result.validate()
        return (videos.isEmpty ? .audio : .video, result)
    }
}
