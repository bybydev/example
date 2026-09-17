import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation

public struct DecodedAudioMedia: Sendable {
    public let samples: [Float]
    public let metadata: AudioMediaMetadata

    public init(samples: [Float], metadata: AudioMediaMetadata) {
        self.samples = samples
        self.metadata = metadata
    }
}

public struct AudioMediaDecoder: Sendable {
    public static let transcriptionSampleRate = 16_000

    public enum DecodeError: LocalizedError, Equatable, Sendable {
        case noAudioTrack
        case couldNotStartReader
        case malformedPCMBuffer
        case readerFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noAudioTrack:
                "The selected media does not contain an audio track."
            case .couldNotStartReader:
                "Inkribe could not start decoding the media file."
            case .malformedPCMBuffer:
                "The decoded audio data is malformed."
            case .readerFailed(let description):
                "Media decoding failed: \(description)"
            }
        }
    }

    public init() {}

    public func decodeForTranscription(url: URL) async throws -> DecodedAudioMedia {
        try Task.checkCancellation()

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw DecodeError.noAudioTrack
        }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.transcriptionSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: outputSettings
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw DecodeError.couldNotStartReader
        }
        reader.add(output)
        guard reader.startReading() else {
            throw DecodeError.readerFailed(
                reader.error?.localizedDescription ?? "unknown reader error"
            )
        }

        var samples: [Float] = []
        do {
            while let sampleBuffer = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                    throw DecodeError.malformedPCMBuffer
                }

                let byteCount = CMBlockBufferGetDataLength(blockBuffer)
                guard byteCount.isMultiple(of: MemoryLayout<Float>.size) else {
                    throw DecodeError.malformedPCMBuffer
                }
                let sampleCount = byteCount / MemoryLayout<Float>.size
                if sampleCount == 0 { continue }

                var chunk = [Float](repeating: 0, count: sampleCount)
                var copyStatus: OSStatus = -1
                chunk.withUnsafeMutableBytes { bytes in
                    guard let baseAddress = bytes.baseAddress else { return }
                    copyStatus = CMBlockBufferCopyDataBytes(
                        blockBuffer,
                        atOffset: 0,
                        dataLength: byteCount,
                        destination: baseAddress
                    )
                }
                guard copyStatus == noErr else {
                    throw DecodeError.malformedPCMBuffer
                }
                samples.append(contentsOf: chunk)
            }
        } catch {
            reader.cancelReading()
            throw error
        }

        if reader.status == .failed {
            throw DecodeError.readerFailed(
                reader.error?.localizedDescription ?? "unknown reader error"
            )
        }
        try Task.checkCancellation()

        return DecodedAudioMedia(
            samples: samples,
            metadata: AudioMediaMetadata(
                duration: Double(samples.count) / Double(Self.transcriptionSampleRate),
                sampleRate: Double(Self.transcriptionSampleRate),
                channelCount: 1
            )
        )
    }
}
