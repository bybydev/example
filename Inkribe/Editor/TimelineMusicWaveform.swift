@preconcurrency import AVFoundation
import AudioToolbox
import Foundation

struct MusicWaveformRequest: Equatable, Sendable {
    let assetID: UUID
    let fingerprint: String
    let url: URL
    let duration: Double
}

/// Stream real mono PCM into a fixed 2,048-bin envelope. Only one buffer and
/// envelope are retained; a song never becomes a project-sized sample array.
private actor MusicWaveformDecoder {
    func read(_ request: MusicWaveformRequest) async throws -> [Float] {
        try Task.checkCancellation()
        guard request.duration.isFinite, request.duration > 0 else { throw MusicEditError.invalidImport }
        let asset = AVURLAsset(url: request.url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw MusicEditError.invalidImport }
        let reader = try AVAssetReader(asset: asset)
        let rate = 8_000
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MusicEditError.invalidImport }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? MusicEditError.invalidImport }
        defer { reader.cancelReading() }
        var peaks = [Float](repeating: 0, count: 2_048)
        var hasSamples = false
        while true {
            try Task.checkCancellation()
            let read = try autoreleasepool { () throws -> Bool in
                guard let sample = output.copyNextSampleBuffer() else { return false }
                let count = CMSampleBufferGetNumSamples(sample)
                guard count > 0 else { return true }
                guard let format = CMSampleBufferGetFormatDescription(sample),
                      let info = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                      info.mFormatID == kAudioFormatLinearPCM, info.mSampleRate == Double(rate),
                      info.mChannelsPerFrame == 1, info.mBitsPerChannel == 32,
                      info.mBytesPerFrame == UInt32(MemoryLayout<Float>.size),
                      info.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                      info.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
                      let block = CMSampleBufferGetDataBuffer(sample) else { throw MusicEditError.invalidImport }
                let bytes = CMBlockBufferGetDataLength(block)
                guard bytes <= 4 * 1_024 * 1_024, bytes.isMultiple(of: MemoryLayout<Float>.size),
                      bytes / MemoryLayout<Float>.size == count else { throw MusicEditError.invalidImport }
                let start = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                guard start.isFinite else { throw MusicEditError.invalidImport }
                var samples = [Float](repeating: 0, count: count)
                let status = samples.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!)
                }
                guard status == noErr else { throw MusicEditError.invalidImport }
                for (index, value) in samples.enumerated() {
                    guard value.isFinite else { throw MusicEditError.invalidImport }
                    let position = (start + Double(index) / Double(rate)) / request.duration
                    guard position >= 0, position < 1 else { continue }
                    let bin = min(peaks.count - 1, Int(position * Double(peaks.count)))
                    peaks[bin] = max(peaks[bin], min(1, abs(value)))
                    hasSamples = true
                }
                return true
            }
            if !read { break }
        }
        guard reader.status == .completed, hasSamples else { throw reader.error ?? MusicEditError.invalidImport }
        try Task.checkCancellation()
        let maximum = max(peaks.max() ?? 0, 0.0001)
        return peaks.map { sqrt($0 / maximum) }
    }
}

/// A cancelled reader keeps its slot until teardown finishes. Rapid scrolling,
/// sheet presentation or replacing a song cannot accumulate native readers.
@MainActor
final class TimelineMusicWaveform {
    private let decoder = MusicWaveformDecoder()
    private var desired: MusicWaveformRequest?
    private var current: MusicWaveformRequest?
    private var completed: MusicWaveformRequest?
    private var failed: MusicWaveformRequest?
    private var task: Task<Void, Never>?
    private var cachedPeaks: [Float] = []
    private(set) var peaks: [Float] = []
    var onChange: (() -> Void)?
    var unavailable: Bool { desired != nil && failed == desired }

    func update(_ request: MusicWaveformRequest?, enabled: Bool) {
        let next = enabled ? request : nil
        if desired == nil, next != nil { failed = nil }
        if desired != next {
            desired = next
            if current != next { task?.cancel() }
        }
        peaks = request == completed ? cachedPeaks : []
        pump()
    }

    private func pump() {
        guard task == nil, let request = desired, request != completed, request != failed else { return }
        current = request
        task = Task { [weak self, decoder] in
            var result: [Float]?
            do { result = try await decoder.read(request); try Task.checkCancellation() }
            catch { }
            guard let self else { return }
            let cancelled = Task.isCancelled
            self.task = nil; self.current = nil
            if self.desired == request, !cancelled {
                if let result { self.peaks = result; self.cachedPeaks = result; self.completed = request; self.failed = nil }
                else { self.failed = request }
                self.onChange?()
            }
            self.pump()
        }
    }

    func stop() { desired = nil; task?.cancel(); onChange = nil; peaks = [] }
}
