@preconcurrency import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import InkribeCore
import JobQueue
import OSLog
import Synchronization

/// One job task owns every reader, writer, CIContext and caption renderer here.
/// No pixel arrays or PCM are accumulated across the movie. AVFoundation applies
/// the shared media graph; the P4 overlay receives the exact output-frame PTS.
enum MP4Exporter {
    private static let logger = Logger(subsystem: "com.hoangbkit.inkribe", category: "MP4Exporter")

    static func write(_ request: FrozenExport, progress: JobProgressReporter) async throws {
        let document = request.manifest.document
        let profile = request.manifest.profile
        let canvas = try profile.resolution.canvas(for: document.canvas)
        let size = CGSize(width: CGFloat(canvas.width), height: CGFloat(canvas.height))
        let frameRate = profile.frameRate
        let timescale = frameRate.timescale
        let videoBitRate = canvas.width * canvas.height * 5 * frameRate.rawValue / 30
        await progress.report(fractionCompleted: 0, message: "Preparing media…")
        let graph = try await PreviewComposition.mediaGraph(document: document, urls: request.urls,
                                                            size: size, frameRate: timescale)
        try Task.checkCancellation()
        let durationSeconds = CMTimeGetSeconds(graph.duration)
        let estimate = Double(videoBitRate) / 8 * durationSeconds * 1.15
            + durationSeconds * 24_000 + 64 * 1_024 * 1_024
        guard durationSeconds.isFinite, durationSeconds > 0, estimate.isFinite, estimate < Double(Int64.max) else {
            throw ExportError.invalidRequest
        }
        let capacity = try request.directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        if let capacity, capacity < Int64(estimate) { throw ExportError.noSpace }
        let reader = try AVAssetReader(asset: graph.asset)
        reader.timeRange = CMTimeRange(start: .zero, duration: graph.duration)
        let videoTracks = try await graph.asset.loadTracks(withMediaType: .video)
        var videoOutput: AVAssetReaderVideoCompositionOutput?
        if let composition = graph.videoComposition, !videoTracks.isEmpty {
            let output = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks,
                videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            output.videoComposition = composition
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw mediaFailure("The video reader could not be configured", reader: reader)
            }
            reader.add(output)
            videoOutput = output
        }
        var audioOutput: AVAssetReaderAudioMixOutput?
        if graph.hasAudio {
            let tracks = try await graph.asset.loadTracks(withMediaType: .audio)
            let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
            output.alwaysCopiesSampleData = false
            output.audioMix = graph.audioMix
            guard reader.canAdd(output) else {
                throw mediaFailure("The audio reader could not be configured", reader: reader)
            }
            reader.add(output)
            audioOutput = output
        }
        let writer = try AVAssetWriter(outputURL: request.partialURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: canvas.width, AVVideoHeightKey: canvas.height,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: videoBitRate,
                AVVideoExpectedSourceFrameRateKey: frameRate.rawValue,
                AVVideoMaxKeyFrameIntervalKey: frameRate.rawValue * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else { throw ExportError.unavailableEncoder }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw ExportError.unavailableEncoder }
        writer.add(videoInput)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: canvas.width, kCVPixelBufferHeightKey as String: canvas.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                                          AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000]
            guard writer.canApply(outputSettings: settings, forMediaType: .audio) else { throw ExportError.unavailableEncoder }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw ExportError.unavailableEncoder }
            writer.add(input)
            audioInput = input
        }
        var finished = false
        defer {
            reader.cancelReading()
            if !finished { writer.cancelWriting() }
        }
        guard writer.startWriting() else { throw writer.error ?? ExportError.encoding }
        writer.startSession(atSourceTime: .zero)
        // An audio-only graph still generates real black video/caption frames.
        if videoOutput != nil || audioOutput != nil {
            guard reader.startReading() else {
                throw mediaFailure("The media reader could not start", reader: reader)
            }
        }
        // Honor old immutable requests; newly frozen requests contain project style only.
        let snapshot = CaptionSnapshot(document, usesClipStyles: true,
            requireWordTiming: request.manifest.wordEffectVersion == 1)
        let renderer = CaptionRenderer()
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { throw ExportError.encoding }
        let bounds = CGRect(origin: .zero, size: size)
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: bounds)
        let frameTime = CMTimeConvertScale(graph.duration, timescale: timescale, method: .roundAwayFromZero)
        let frames = frameTime.value
        guard frameTime.isNumeric, frames > 0, frames < Int64.max / 2 else { throw ExportError.invalidRequest }
        var frame: Int64 = 0
        var videoFinished = false
        var audioFinished = audioInput == nil
        var pendingVideo: CMSampleBuffer?
        var currentVideo: CMSampleBuffer?
        var videoEOF = videoOutput == nil
        var lastVideoPTS = CMTime.invalid
        var videoIntervalIndex = 0
        var lastAudioPTS = CMTime.invalid
        // Only EOF validation needs a duration fallback. Between samples the
        // next presentation timestamp defines when the current frame is replaced.
        let composedFrameDuration: CMTime
        if let composition = graph.videoComposition,
           composition.sourceTrackIDForFrameTiming == kCMPersistentTrackID_Invalid {
            composedFrameDuration = composition.frameDuration
        } else {
            // A source-timed composition cannot infer a missing VFR duration
            // from its nominal cadence. Do not guess if that mode is ever used.
            composedFrameDuration = .invalid
        }
        // The reader emits source-timed composed samples with no duration.
        // frameDuration is only a maximum cadence, so exporting above the
        // source rate would otherwise credit the terminal source frame with
        // too little time at EOF. Use the slower of the two frame intervals.
        let eofFallbackDuration: CMTime
        if graph.finalVideoFrameDuration.isNumeric,
           CMTimeCompare(graph.finalVideoFrameDuration, .zero) > 0 {
            eofFallbackDuration = composedFrameDuration.isNumeric
                ? CMTimeMaximum(composedFrameDuration, graph.finalVideoFrameDuration)
                : graph.finalVideoFrameDuration
        } else {
            eofFallbackDuration = composedFrameDuration
        }

        func readVideo(at time: CMTime) throws -> CMSampleBuffer? {
            try Task.checkCancellation()
            let sample = videoOutput?.copyNextSampleBuffer()
            if reader.status == .failed {
                throw mediaFailure("The video reader failed", at: time, reader: reader, sample: sample)
            }
            guard let sample else { videoEOF = true; return nil }
            let samplePTS = CMSampleBufferGetPresentationTimeStamp(sample)
            // Validate on read, including the lookahead sample: an invalid future
            // timestamp must not silently leave the previous frame selected.
            guard samplePTS.isNumeric,
                  !lastVideoPTS.isValid || CMTimeCompare(samplePTS, lastVideoPTS) > 0 else {
                throw mediaFailure("Video frame timestamps are invalid or out of order",
                    at: time, reader: reader, sample: sample)
            }
            lastVideoPTS = samplePTS
            return sample
        }
        let clock = ContinuousClock()
        var lastAdvance = clock.now
        var lastProgress = -1

        // Interleave a single video frame and one audio buffer per iteration.
        // Poll only while back-pressured; do not enqueue unbounded callbacks.
        while !videoFinished || !audioFinished {
            try Task.checkCancellation()
            if writer.status == .failed { throw writer.error ?? ExportError.encoding }
            if reader.status == .failed {
                throw mediaFailure("The media reader failed", at: CMTime(value: frame, timescale: timescale), reader: reader)
            }
            var advanced = false
            if !videoFinished, videoInput.isReadyForMoreMediaData,
               let outputPixels = try pixelBuffer(from: adaptor.pixelBufferPool) {
                let pts = CMTime(value: frame, timescale: timescale)
                try autoreleasepool {
                    if !videoEOF, pendingVideo == nil {
                        pendingVideo = try readVideo(at: pts)
                    }
                    while let sample = pendingVideo,
                          CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), pts) <= 0 {
                        currentVideo = sample
                        pendingVideo = try readVideo(at: pts)
                    }
                    let time = try MediaTime(validating: pts)
                    while videoIntervalIndex < graph.videoIntervals.count,
                          graph.videoIntervals[videoIntervalIndex].end <= time { videoIntervalIndex += 1 }
                    let activeInterval = videoIntervalIndex < graph.videoIntervals.count
                        && graph.videoIntervals[videoIntervalIndex].contains(time) ? graph.videoIntervals[videoIntervalIndex] : nil
                    var image = black
                    if activeInterval != nil {
                        guard let sample = currentVideo, let pixels = CMSampleBufferGetImageBuffer(sample) else {
                            throw mediaFailure("A video frame is missing", at: pts, reader: reader,
                                sample: currentVideo, next: pendingVideo, interval: activeInterval)
                        }
                        // The loop above selects currentPTS <= pts < nextPTS.
                        // Hold that decoded frame until the next presentation,
                        // even if its duration metadata ends sooner. Clip cuts
                        // and transforms have already been applied by AVFoundation;
                        // graph intervals here only mask intentional black gaps.
                        // EOF has no next PTS, so validate the remaining video tail
                        // separately rather than holding a truncated stream forever.
                        if videoEOF, pendingVideo == nil,
                           let finalInterval = graph.videoIntervals.last,
                           !videoReachedEnd(sample, requiredEnd: finalInterval.end.cmTime,
                                            fallbackDuration: eofFallbackDuration, timescale: timescale) {
                            throw mediaFailure("The video reader ended before the final video interval",
                                at: pts, reader: reader, sample: sample, interval: finalInterval)
                        }
                        image = CIImage(cvPixelBuffer: pixels).cropped(to: bounds)
                    }
                    // This is exactly the P4 Core Text/motion path used by preview.
                    if let overlay = try renderer.overlay(snapshot: snapshot, at: time, canvas: canvas) {
                        image = CIImage(cgImage: overlay).composited(over: image)
                    }
                    context.render(image, to: outputPixels, bounds: bounds, colorSpace: colorSpace)
                    guard adaptor.append(outputPixels, withPresentationTime: pts) else { throw writer.error ?? ExportError.encoding }
                }
                frame += 1
                if frame == frames { videoInput.markAsFinished(); videoFinished = true }
                advanced = true
            }
            if !audioFinished, let audioInput, audioInput.isReadyForMoreMediaData {
                try autoreleasepool {
                    if let sample = audioOutput?.copyNextSampleBuffer() {
                        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                        guard pts.isNumeric, CMTimeCompare(pts, .zero) >= 0,
                              !lastAudioPTS.isValid || CMTimeCompare(pts, lastAudioPTS) > 0 else {
                            throw mediaFailure("Audio sample timestamps are invalid or out of order",
                                at: pts, reader: reader, sample: sample)
                        }
                        lastAudioPTS = pts
                        guard audioInput.append(sample) else { throw writer.error ?? ExportError.encoding }
                    } else {
                        if reader.status == .failed {
                            throw mediaFailure("The audio reader failed",
                                at: CMTime(value: frame, timescale: timescale), reader: reader)
                        }
                        audioInput.markAsFinished()
                        audioFinished = true
                    }
                }
                advanced = true
            }
            if advanced { lastAdvance = clock.now }
            else {
                guard lastAdvance.duration(to: clock.now) < .seconds(30) else { throw ExportError.stalled }
                try await Task.sleep(for: .milliseconds(10))
            }
            let percent = Int(Double(frame) / Double(frames) * 95)
            if percent > lastProgress {
                lastProgress = percent
                await progress.report(fractionCompleted: Double(percent) / 100, message: "Rendering captioned video…")
            }
            await Task.yield()
        }
        try Task.checkCancellation()
        if reader.status == .failed {
            throw mediaFailure("The media reader failed", at: graph.duration, reader: reader)
        }
        writer.endSession(atSourceTime: graph.duration)
        await progress.report(fractionCompleted: 0.96, message: "Finalizing MP4…")
        // Only the completion flag crosses into AVFoundation's callback.
        // Cancellation unwinds this task through the existing defer, which
        // finishes cancelWriting before the caller removes the partial file.
        try Task.checkCancellation()
        let completion = MP4WritingCompletion()
        writer.finishWriting {
            completion.markCompleted()
        }
        while !completion.isCompleted {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
        try Task.checkCancellation()
        guard writer.status == .completed else { throw writer.error ?? ExportError.encoding }
        finished = true
        try await validate(url: request.partialURL, document: document, canvas: canvas, expectAudio: graph.hasAudio)
    }

    private static func videoReachedEnd(_ sample: CMSampleBuffer, requiredEnd: CMTime,
                                        fallbackDuration: CMTime, timescale: CMTimeScale) -> Bool {
        let start = CMSampleBufferGetPresentationTimeStamp(sample)
        let declared = CMSampleBufferGetDuration(sample)
        let hasDeclaredDuration = declared.isNumeric && CMTimeCompare(declared, .zero) > 0
        let hasFallback = fallbackDuration.isNumeric && CMTimeCompare(fallbackDuration, .zero) > 0
        guard start.isNumeric, requiredEnd.isNumeric, hasDeclaredDuration || hasFallback else { return false }
        // The fallback is the output cadence or the terminal source frame
        // interval, whichever is longer. Preserve a longer declared terminal
        // hold (e.g. a static screen-recording tail).
        let duration: CMTime
        if hasDeclaredDuration, hasFallback {
            duration = CMTimeMaximum(declared, fallbackDuration)
        } else {
            duration = hasDeclaredDuration ? declared : fallbackDuration
        }
        let end = CMTimeAdd(start, duration)
        guard end.isNumeric else { return false }
        if CMTimeCompare(end, requiredEnd) >= 0 { return true }
        // The writer's final frame is clipped to graph.duration. Permit only a
        // sub-output-frame tail discrepancy beyond the credited terminal frame,
        // not an arbitrary missing segment.
        // This allowance is EOF-only; normal frame selection never uses age or
        // duration thresholds.
        let shortfall = CMTimeSubtract(requiredEnd, end)
        return shortfall.isNumeric && CMTimeCompare(shortfall, CMTime(value: 1, timescale: timescale)) < 0
    }

    private static func mediaFailure(_ reason: String, at time: CMTime = .invalid,
                                     reader: AVAssetReader, sample: CMSampleBuffer? = nil,
                                     next: CMSampleBuffer? = nil, interval: MediaInterval? = nil) -> NSError {
        func describe(_ time: CMTime) -> String {
            time.isNumeric ? "\(time.value)/\(time.timescale)" : "invalid"
        }
        let pts = sample.map { describe(CMSampleBufferGetPresentationTimeStamp($0)) } ?? "none"
        let duration = sample.map { describe(CMSampleBufferGetDuration($0)) } ?? "none"
        let nextPTS = next.map { describe(CMSampleBufferGetPresentationTimeStamp($0)) } ?? "none"
        let active = interval.map { "\(describe($0.start.cmTime))..<\(describe($0.end.cmTime))" } ?? "none"
        let underlying = reader.error as NSError?
        let native = underlying.map { "\($0.domain) (\($0.code))" } ?? "none"
        let details = "\(reason); output=\(describe(time)); sample=\(pts); duration=\(duration); next=\(nextPTS); interval=\(active); reader=\(reader.status.rawValue); native=\(native)"
        // Timing/status only: no media paths, project titles or caption text.
        logger.error("\(details, privacy: .public)")
        let location = time.isNumeric ? " at \(String(format: "%.3f", CMTimeGetSeconds(time))) s" : ""
        var info: [String: Any] = [NSLocalizedDescriptionKey: "\(reason)\(location)."]
        if let underlying {
            info[NSUnderlyingErrorKey] = underlying
            // Job history persists localizedDescription, so retain the native
            // domain/code there as well as the complete underlying NSError.
            info[NSLocalizedDescriptionKey] = "\(reason)\(location). \(native). \(underlying.localizedDescription)"
        }
        return NSError(domain: "Inkribe.MP4Export.MediaRead", code: 1, userInfo: info)
    }

    private static func pixelBuffer(from pool: CVPixelBufferPool?) throws -> CVPixelBuffer? {
        guard let pool else { throw ExportError.encoding }
        var pixels: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool,
            [kCVPixelBufferPoolAllocationThresholdKey as String: 6] as CFDictionary, &pixels)
        // The encoder may briefly retain buffers despite input readiness. Wait
        // for recycling rather than allocate more frames or fail a healthy job.
        if status == kCVReturnWouldExceedAllocationThreshold { return nil }
        guard status == kCVReturnSuccess, let pixels else { throw ExportError.encoding }
        return pixels
    }

    static func validate(url: URL, document: ProjectDocument, canvas: RenderCanvas, expectAudio: Bool?) async throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { throw ExportError.invalidOutput }
        let asset = AVURLAsset(url: url)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.invalidOutput }
        let size = try await video.load(.naturalSize)
        let formats = try await video.load(.formatDescriptions)
        let duration = try await asset.load(.duration)
        let expected = document.outputDuration.cmTime
        guard size.width.isFinite, size.height.isFinite,
              abs(size.width - CGFloat(canvas.width)) < 0.5, abs(size.height - CGFloat(canvas.height)) < 0.5,
              formats.contains(where: { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 }),
              duration.isNumeric, abs(CMTimeGetSeconds(CMTimeSubtract(duration, expected))) <= 0.1 else {
            throw ExportError.invalidOutput
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        if expectAudio == true && audioTracks.isEmpty { throw ExportError.invalidOutput }
        if let audio = audioTracks.first {
            let formats = try await audio.load(.formatDescriptions)
            guard formats.contains(where: { CMFormatDescriptionGetMediaSubType($0) == kAudioFormatMPEG4AAC }) else {
                throw ExportError.invalidOutput
            }
        }
    }
}

/// Shared only between AVFoundation's completion callback and the export task.
private final class MP4WritingCompletion: Sendable {
    private let completed = Mutex(false)

    func markCompleted() {
        completed.withLock { $0 = true }
    }

    var isCompleted: Bool {
        completed.withLock { $0 }
    }
}
