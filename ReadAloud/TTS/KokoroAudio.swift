import AVFoundation
import Foundation

/// Kokoro's mono PCM output, owned by ReadAloud; no Core ML SDK required.
nonisolated struct KokoroAudio: Equatable, Sendable {
    let samples: [Float]
    let sampleRate: Int

    init(samples: [Float], sampleRate: Int = 24_000) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    var durationSeconds: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(samples.count) / Double(sampleRate)
    }

    func makePCMBuffer() throws -> AVAudioPCMBuffer {
        guard sampleRate > 0,
              !samples.isEmpty,
              samples.count <= Int(UInt32.max),
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(sampleRate),
                channels: 1,
                interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
              ) else {
            throw SpeechEngineError.synthesisFailed("Invalid mono PCM output.")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channel = buffer.floatChannelData?[0] else {
            throw SpeechEngineError.synthesisFailed("Missing PCM channel.")
        }
        for (index, sample) in samples.enumerated() {
            channel[index] = sample
        }
        return buffer
    }
}
