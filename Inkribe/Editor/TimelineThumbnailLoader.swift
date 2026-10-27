@preconcurrency import AVFoundation
import UIKit

/// One generator per in-flight request. Configuration is immutable after init;
/// AVFoundation's cancellation entry point is the only cross-task operation.
private final class TimelineFrameDecoder: @unchecked Sendable {
    private let generator: AVAssetImageGenerator
    private let time: CMTime
    init(_ request: TimelineFrameRequest) {
        generator = AVAssetImageGenerator(asset: AVURLAsset(url: request.url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: CGFloat(request.pixels), height: CGFloat(request.pixels))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        time = CMTime(value: request.tick, timescale: 60_000)
    }
    func image() async throws -> TimelineDecodedFrame {
        try Task.checkCancellation()
        let (image, _) = try await generator.image(at: time)
        try Task.checkCancellation()
        return TimelineDecodedFrame(image: image)
    }
    func cancel() { generator.cancelAllCGImageGeneration() }
}

/// CGImage bytes are immutable; UIKit image/cache ownership stays on MainActor.
private struct TimelineDecodedFrame: @unchecked Sendable { let image: CGImage }

@MainActor
final class TimelineThumbnailLoader {
    private struct Work {
        let token: UUID
        let task: Task<Void, Never>
    }
    private let cache = NSCache<NSString, UIImage>()
    private var desired: [TimelineFrameRequest] = []
    private var wanted: Set<TimelineFrameRequest> = []
    private var active: [TimelineFrameRequest: Work] = [:]
    private var failed: Set<TimelineFrameRequest> = []
    private var attempted: Set<TimelineFrameRequest> = []
    private var enabled = true
    var onChange: (() -> Void)?

    init() {
        cache.totalCostLimit = 12 * 1024 * 1024
        cache.countLimit = 128
    }
    func image(for request: TimelineFrameRequest) -> UIImage? { cache.object(forKey: request.key as NSString) }
    func unavailable(_ request: TimelineFrameRequest) -> Bool { failed.contains(request) }

    /// Requests arrive in visible-first order. A far-off or obsolete request never
    /// sits in a serial backlog ahead of the new viewport.
    func update(_ requests: [TimelineFrameRequest], enabled: Bool) {
        if enabled && !self.enabled { failed.removeAll(keepingCapacity: true) }
        self.enabled = enabled
        var seen = Set<TimelineFrameRequest>()
        desired = Array(requests.filter { seen.insert($0).inserted }.prefix(64))
        wanted = enabled ? Set(desired) : []
        attempted.removeAll(keepingCapacity: true)
        // Retain cancelled tasks in active until teardown completes. This keeps
        // at most two live AVFoundation decoders even during rapid scrolling.
        for (request, work) in active where !wanted.contains(request) { work.task.cancel() }
        pump()
    }
    private func pump() {
        guard enabled else { return }
        for request in desired where active.count < 2 {
            guard active[request] == nil, image(for: request) == nil,
                  !failed.contains(request), !attempted.contains(request) else { continue }
            attempted.insert(request)
            let token = UUID()
            let decoder = TimelineFrameDecoder(request)
            let task = Task { @MainActor [weak self] in
                var image: UIImage?
                var didFail = false
                do {
                    let frame = try await withTaskCancellationHandler {
                        try await decoder.image()
                    } onCancel: { decoder.cancel() }
                    try Task.checkCancellation()
                    // Standard-range 8-bit output gives the cache a predictable
                    // cost even when AVFoundation returns a wide/HDR CGImage.
                    let format = UIGraphicsImageRendererFormat()
                    format.scale = 1; format.opaque = true; format.preferredRange = .standard
                    let size = CGSize(width: CGFloat(frame.image.width), height: CGFloat(frame.image.height))
                    image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                        UIColor.black.setFill(); context.fill(CGRect(origin: .zero, size: size))
                        UIImage(cgImage: frame.image).draw(in: CGRect(origin: .zero, size: size))
                    }
                } catch {
                    didFail = !Task.isCancelled && !(error is CancellationError)
                }
                guard let self, self.active[request]?.token == token else { return }
                self.active.removeValue(forKey: request)
                if let image, !Task.isCancelled {
                    let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? request.pixels * request.pixels * 4
                    self.cache.setObject(image, forKey: request.key as NSString, cost: cost)
                } else if didFail {
                    if self.failed.count >= 256 { self.failed.removeAll(keepingCapacity: true) }
                    self.failed.insert(request)
                }
                self.onChange?()
                self.pump()
            }
            active[request] = Work(token: token, task: task)
        }
    }
    func stop() {
        enabled = false
        wanted.removeAll(); desired.removeAll()
        for work in active.values { work.task.cancel() }
        onChange = nil
        cache.removeAllObjects()
    }
}
