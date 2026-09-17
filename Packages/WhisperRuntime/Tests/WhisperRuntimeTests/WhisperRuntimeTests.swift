import Foundation
import Testing
@testable import WhisperRuntime

@Suite("Whisper runtime")
struct WhisperRuntimeTests {
    @Test func releaseAndModelPinsAreStable() throws {
        #expect(WhisperRuntimeRelease.stableVersion == "1.9.4")
        #expect(WhisperRuntimeRelease.binaryTag == "b5130")
        #expect(WhisperRuntimeRelease.revision.count == 40)
        #expect(WhisperRuntimeRelease.archiveSHA256.count == 64)

        let descriptor = try WhisperModelAsset.descriptor()
        #expect(descriptor.id == "whisper-small-multilingual")
        #expect(descriptor.relativePath == "whisper/ggml-small.bin")
    }

    @Test func explicitConfigurationNormalizesUnsafeValues() {
        let configuration = WhisperRuntimeConfiguration(
            threadCount: 0,
            useGPU: false,
            flashAttention: true
        )

        #expect(configuration.threadCount == 1)
        #expect(!configuration.useGPU)
        #expect(!configuration.flashAttention)
    }

    @Test func transcriptTextPreservesSegmentOrder() {
        let result = WhisperTranscriptionResult(
            detectedLanguageCode: "en",
            segments: [
                .init(startTime: 0, endTime: 1, text: "Hello"),
                .init(startTime: 1, endTime: 2, text: " world")
            ]
        )

        #expect(result.text == "Hello world")
    }

    @Test func decodesPCM16StereoWaveToMono() throws {
        let wave = makePCM16Wave(
            sampleRate: 16_000,
            channels: 2,
            frames: [
                [16_384, -16_384],
                [32_767, 32_767]
            ]
        )

        let decoded = try WhisperWaveDecoder.decode(data: wave)
        #expect(decoded.sampleRate == 16_000)
        #expect(decoded.samples.count == 2)
        #expect(abs(decoded.samples[0]) < 0.0001)
        #expect(decoded.samples[1] > 0.99)
    }

    @Test func rejectsNon16kWave() {
        let wave = makePCM16Wave(
            sampleRate: 44_100,
            channels: 1,
            frames: [[1]]
        )

        #expect(throws: WhisperRuntimeError.unsupportedSampleRate(44_100)) {
            try WhisperWaveDecoder.decode(data: wave)
        }
    }

    private func makePCM16Wave(
        sampleRate: UInt32,
        channels: UInt16,
        frames: [[Int16]]
    ) -> Data {
        var payload = Data()
        for frame in frames {
            #expect(frame.count == Int(channels))
            for sample in frame {
                append(UInt16(bitPattern: sample), to: &payload)
            }
        }

        var data = Data("RIFF".utf8)
        append(UInt32(36 + payload.count), to: &data)
        data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8))
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(channels, to: &data)
        append(sampleRate, to: &data)
        let byteRate = sampleRate * UInt32(channels) * 2
        append(byteRate, to: &data)
        append(UInt16(channels * 2), to: &data)
        append(UInt16(16), to: &data)
        data.append(Data("data".utf8))
        append(UInt32(payload.count), to: &data)
        data.append(payload)
        return data
    }

    private func append(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private func append(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
