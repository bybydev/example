import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

/// Metadata is read from the copied, app-owned media, not an expiring provider URL.
/// Failure is a failed import; never manufacture a timeline duration or frame rate.
enum IOSMediaInspector {
    static func inspect(url: URL) async throws -> (IOSMediaKind, IOSMediaMetadata) {
        let asset = AVURLAsset(url: url)
        let duration = try MediaTime(validating: await asset.load(.duration))
        guard duration > .zero else { throw IOSProjectStoreError.unsupportedMedia }
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        guard !videos.isEmpty || !audios.isEmpty else {
            throw IOSProjectStoreError.unsupportedMedia
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
        let result = IOSMediaMetadata(
            duration: duration, naturalWidth: naturalWidth, naturalHeight: naturalHeight,
            displayedWidth: width, displayedHeight: height,
            rotationDegrees: degrees, nominalFrameRate: frameRate,
            videoTrackCount: videos.count, audioTrackCount: audios.count
        )
        try result.validate()
        return (videos.isEmpty ? .audio : .video, result)
    }
}
