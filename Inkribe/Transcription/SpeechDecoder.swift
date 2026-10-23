import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation
import OSLog

struct DecodedSpeechWindow: Sendable {
    let samples: [Float]
    let copiedSampleCount: Int
    let peak: Float
}

/// One <=28-second window. AVFoundation mixes/resamples source audio before
/// source PTS places Float32 mono samples in the bounded 16 kHz speech buffer.
actor SpeechDecoder {
    static let sampleRate = 16_000
    private let logger = Logger(subsystem: "com.hoangbkit.inkribe", category: "SpeechDecoder")

    func read(url: URL, interval: MediaInterval) async throws -> DecodedSpeechWindow {
        try Task.checkCancellation()
        let duration = CMTimeGetSeconds(interval.duration)
        guard duration.isFinite, duration > 0, duration <= 30 else { throw SpeechError.invalidAudio }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw SpeechError.noAudio }
        let range = CMTimeRange(start: interval.start.cmTime, duration: interval.duration)
        var expectsSamples = false
        for track in tracks {
            let trackRange = try await track.load(.timeRange)
            if CMTimeGetSeconds(CMTimeRangeGetIntersection(trackRange, otherRange: range).duration) > 0 {
                expectsSamples = true
            }
        }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        // A silent first track must not hide speech on another source track.
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw SpeechError.invalidAudio }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? SpeechError.invalidAudio }
        defer { reader.cancelReading() }
        var samples = [Float](repeating: 0, count: Int(ceil(duration * Double(Self.sampleRate))))
        var copied = 0
        var decoded = 0
        while true {
            try Task.checkCancellation()
            let hadBuffer = try autoreleasepool { () throws -> Bool in
                guard let buffer = output.copyNextSampleBuffer() else { return false }
                let frameCount = CMSampleBufferGetNumSamples(buffer)
                guard frameCount > 0 else { return true }
                // Verify the actual output instead of interpreting arbitrary PCM
                // bytes as Float32 merely because that format was requested.
                guard let format = CMSampleBufferGetFormatDescription(buffer),
                      let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                      description.mFormatID == kAudioFormatLinearPCM,
                      description.mSampleRate == Double(Self.sampleRate),
                      description.mChannelsPerFrame == 1, description.mBitsPerChannel == 32,
                      description.mBytesPerFrame == UInt32(MemoryLayout<Float>.size),
                      description.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                      description.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
                      let block = CMSampleBufferGetDataBuffer(buffer) else { throw SpeechError.invalidAudio }
                let bytes = CMBlockBufferGetDataLength(block)
                guard bytes.isMultiple(of: MemoryLayout<Float>.size),
                      bytes / MemoryLayout<Float>.size == frameCount else { throw SpeechError.invalidAudio }
                decoded += frameCount
                let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
                let offset = CMTimeConvertScale(CMTimeSubtract(pts, interval.start.cmTime),
                    timescale: Int32(Self.sampleRate), method: .roundHalfAwayFromZero)
                guard offset.isNumeric else { throw SpeechError.invalidAudio }
                guard offset.value > -Int64(frameCount), offset.value < Int64(samples.count) else { return true }
                let firstInput = max(0, -Int(offset.value))
                let firstOutput = max(0, Int(offset.value))
                let amount = min(frameCount - firstInput, samples.count - firstOutput)
                guard amount > 0 else { return true }
                let status = samples.withUnsafeMutableBytes { destination in
                    CMBlockBufferCopyDataBytes(block, atOffset: firstInput * MemoryLayout<Float>.size,
                        dataLength: amount * MemoryLayout<Float>.size,
                        destination: destination.baseAddress!.advanced(by: firstOutput * MemoryLayout<Float>.size))
                }
                guard status == noErr else { throw SpeechError.invalidAudio }
                copied += amount
                return true
            }
            if !hadBuffer { break }
        }
        guard reader.status == .completed else { throw reader.error ?? SpeechError.invalidAudio }
        try Task.checkCancellation()
        var peak: Float = 0
        var energy = 0.0
        for sample in samples {
            guard sample.isFinite else { throw SpeechError.invalidAudio }
            peak = max(peak, abs(sample))
            energy += Double(sample) * Double(sample)
        }
        let rms = sqrt(energy / Double(samples.count))
        // Counts/levels only: never log source paths, audio or recognized text.
        logger.info("Speech window start=\(CMTimeGetSeconds(interval.start.cmTime)) duration=\(duration) tracks=\(tracks.count) decoded=\(decoded) copied=\(copied) peak=\(peak) rms=\(rms)")
        if expectsSamples && copied == 0 { throw SpeechError.emptyAudio }
        return DecodedSpeechWindow(samples: samples, copiedSampleCount: copied, peak: peak)
    }
}
