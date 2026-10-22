@preconcurrency import AVFoundation
import CoreVideo
import Foundation

/// Only for a trim retaining no source samples (an intentional gap). A tiny held
/// black frame supplies a native AVPlayer clock, not synthetic speech or footage.
@MainActor
enum BlackClockAsset {
    private static var preparation: Task<URL, Error>?
    static func url() async throws -> URL {
        if let preparation {
            let result = try await preparation.value
            if FileManager.default.fileExists(atPath: result.path) { return result }
            self.preparation = nil
        }
        let task = Task { try await make() }
        preparation = task
        do { return try await task.value }
        catch { preparation = nil; throw error }
    }

    private static func make() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("InkribeBlackClock-" + UUID().uuidString + ".mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        var complete = false
        defer {
            if !complete { writer.cancelWriting(); try? FileManager.default.removeItem(at: url) }
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 16, AVVideoHeightKey: 16])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw ExportError.unavailableEncoder }
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.startWriting() else { throw writer.error ?? ExportError.encoding }
        writer.startSession(atSourceTime: .zero)
        let clock = ContinuousClock()
        let began = clock.now
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing, began.duration(to: clock.now) < .seconds(10) else { throw ExportError.stalled }
            try await Task.sleep(for: .milliseconds(10))
        }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32ARGB, nil, &buffer) == kCVReturnSuccess,
              let buffer else { throw ExportError.encoding }
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { throw ExportError.encoding }
        guard let address = CVPixelBufferGetBaseAddress(buffer) else {
            CVPixelBufferUnlockBaseAddress(buffer, [])
            throw ExportError.encoding
        }
        memset(address, 0, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard adaptor.append(buffer, withPresentationTime: .zero) else { throw writer.error ?? ExportError.encoding }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 30))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ExportError.encoding }
        complete = true
        return url
    }
}
