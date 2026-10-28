@preconcurrency import AVFoundation
import CoreImage
import CoreGraphics
import CoreVideo
import Foundation

/// One media-only still plus the caption presentation that belongs to its clock.
/// Kept only by mounted preview hosts; never persisted or used by an export.
struct PreviewHeldFrame {
    let id = UUID()
    let image: CGImage?
    let time: MediaTime
    let snapshot: CaptionSnapshot?
}

@MainActor
protocol PreviewVideoOwner: AnyObject {
    func relinquishVideo()
}

/// Shares decoded output with the existing player, without suppressing its video.
/// Retains one pixel buffer; converts to a bounded still only at a display handoff.
@MainActor
final class PreviewFrameBuffer {
    private(set) var heldFrame: PreviewHeldFrame?
    private weak var item: AVPlayerItem?
    private var output: AVPlayerItemVideoOutput?
    private var pixelBuffer: CVPixelBuffer?
    private var pixelTime: MediaTime?
    private weak var owner: (any PreviewVideoOwner)?
    private let context = CIContext(options: [.cacheIntermediates: false])

    func attach(to item: AVPlayerItem) {
        // Preserve the outgoing item before its decoded output is invalidated.
        owner?.relinquishVideo()
        owner = nil
        clearOutput()
        self.item = item
        guard item.videoComposition != nil else { return }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.suppressesPlayerRendering = false
        item.add(output)
        self.output = output
    }

    @discardableResult
    func sample(at time: CMTime, force: Bool = false) -> Bool {
        guard let output, (try? MediaTime(validating: time)) != nil,
              force || output.hasNewPixelBuffer(forItemTime: time) else { return false }
        var displayed = CMTime.invalid
        guard let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &displayed),
              let stamp = (try? MediaTime(validating: displayed)) ?? (try? MediaTime(validating: time)) else { return false }
        pixelBuffer = buffer
        pixelTime = stamp
        return true
    }

    func capture(at time: CMTime, snapshot: CaptionSnapshot?, presentationTime: MediaTime) -> PreviewHeldFrame? {
        let fresh = sample(at: time, force: true)
        guard let pixelBuffer, let pixelTime else { return nil }
        let age = abs(CMTimeGetSeconds(CMTimeSubtract(time, pixelTime.cmTime)))
        // A seek may outrun decoding. Never relabel an old cached scene with
        // a new caption clock; the host can keep its earlier matched still.
        guard fresh || (age.isFinite && age <= 0.1) else { return nil }
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let longest = max(source.extent.width, source.extent.height)
        guard longest.isFinite, longest > 0 else { return nil }
        let scale = min(1, 768 / longest)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let bounds = CGRect(x: scaled.extent.minX, y: scaled.extent.minY,
            width: max(1, scaled.extent.width.rounded(.down)), height: max(1, scaled.extent.height.rounded(.down)))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = context.createCGImage(scaled, from: bounds,
                  format: .RGBA8, colorSpace: colorSpace) else { return nil }
        let captured = PreviewHeldFrame(image: image, time: presentationTime, snapshot: snapshot)
        heldFrame = captured
        return captured
    }

    func claim(_ next: any PreviewVideoOwner) {
        guard owner !== next else { return }
        // Capture before disconnecting, even if SwiftUI mounts the incoming
        // host before updating or dismantling the outgoing host.
        owner?.relinquishVideo()
        owner = next
    }

    func release(_ previous: any PreviewVideoOwner) {
        if owner === previous { owner = nil }
    }

    func reset() {
        owner?.relinquishVideo()
        owner = nil
        clearOutput()
        context.clearCaches()
    }

    private func clearOutput() {
        if let item, let output { item.remove(output) }
        output = nil
        item = nil
        pixelBuffer = nil
        pixelTime = nil
        heldFrame = nil
    }
}
