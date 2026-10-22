import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation

/// Decode only one <=28-second window; no full-file PCM array or prefetch queue.
actor SpeechDecoder {
    static let sampleRate = 16_000

    func read(url: URL, interval: MediaInterval) async throws -> [Float] {
        try Task.checkCancellation()
        let duration = CMTimeGetSeconds(interval.duration)
        guard duration.isFinite, duration > 0, duration <= 30 else { throw SpeechError.invalidAudio }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw SpeechError.noAudio
        }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: interval.start.cmTime, duration: interval.duration)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
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
        // Silence fills track offsets/gaps; buffer PTS places samples at their real source times.
        var samples = [Float](repeating: 0, count: Int(ceil(duration * Double(Self.sampleRate))))
        while true {
            try Task.checkCancellation()
            let hadBuffer = try autoreleasepool { () throws -> Bool in
                guard let buffer = output.copyNextSampleBuffer() else { return false }
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { throw SpeechError.invalidAudio }
                let bytes = CMBlockBufferGetDataLength(block)
                guard bytes.isMultiple(of: MemoryLayout<Float>.size) else { throw SpeechError.invalidAudio }
                let count = bytes / MemoryLayout<Float>.size
                let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
                let offset = CMTimeConvertScale(CMTimeSubtract(pts, interval.start.cmTime),
                    timescale: Int32(Self.sampleRate), method: .roundHalfAwayFromZero)
                guard offset.isNumeric else { throw SpeechError.invalidAudio }
                guard offset.value > -Int64(count), offset.value < Int64(samples.count) else { return true }
                let firstInput = max(0, -Int(offset.value))
                let firstOutput = max(0, Int(offset.value))
                let amount = min(count - firstInput, samples.count - firstOutput)
                guard amount > 0 else { return true }
                let status = samples.withUnsafeMutableBytes { destination in
                    CMBlockBufferCopyDataBytes(block, atOffset: firstInput * MemoryLayout<Float>.size,
                        dataLength: amount * MemoryLayout<Float>.size,
                        destination: destination.baseAddress!.advanced(by: firstOutput * MemoryLayout<Float>.size))
                }
                guard status == noErr else { throw SpeechError.invalidAudio }
                return true
            }
            if !hadBuffer { break }
        }
        guard reader.status == .completed else { throw reader.error ?? SpeechError.invalidAudio }
        try Task.checkCancellation()
        guard samples.allSatisfy(\.isFinite) else { throw SpeechError.invalidAudio }
        return samples
    }
}
