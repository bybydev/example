import Foundation
import Testing
@testable import InkribeAudio

@Suite("Inkribe audio")
struct InkribeAudioTests {
    @Test func durableStoreCopiesSourcesAndRejectsTraversal() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: source)
        }
        try Data([1, 2, 3, 4]).write(to: source)

        let store = DurableMediaStore(rootDirectoryURL: root)
        let reference = try await store.ingest(sourceURL: source)
        let copiedURL = try await store.url(for: reference)

        #expect(reference.relativePath.hasPrefix("Sources/"))
        #expect(try Data(contentsOf: copiedURL) == Data([1, 2, 3, 4]))

        do {
            _ = try await store.url(for: .init(relativePath: "../outside.wav"))
            Issue.record("Path traversal should be rejected")
        } catch is DurableMediaStore.StoreError {
            // Expected.
        }
    }

    @Test func decoderProducesWhisperRateMonoSamples() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try makePCM16Wave(sampleRate: 16_000, frames: [0, 8_192, -8_192, 0])
            .write(to: fileURL)

        let decoded = try await AudioMediaDecoder().decodeForTranscription(url: fileURL)
        #expect(decoded.metadata.sampleRate == 16_000)
        #expect(decoded.metadata.channelCount == 1)
        #expect(!decoded.samples.isEmpty)
    }

    private func makePCM16Wave(sampleRate: UInt32, frames: [Int16]) -> Data {
        var payload = Data()
        for sample in frames {
            append(UInt16(bitPattern: sample), to: &payload)
        }

        var data = Data("RIFF".utf8)
        append(UInt32(36 + payload.count), to: &data)
        data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8))
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(UInt16(1), to: &data)
        append(sampleRate, to: &data)
        append(sampleRate * 2, to: &data)
        append(UInt16(2), to: &data)
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
