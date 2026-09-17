import Foundation

enum WhisperWaveDecoder {
    static func decode(url: URL) throws -> WhisperAudioBuffer {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try decode(data: data)
    }

    static func decode(data: Data) throws -> WhisperAudioBuffer {
        guard data.count >= 12,
              ascii(data, offset: 0, count: 4) == "RIFF",
              ascii(data, offset: 8, count: 4) == "WAVE" else {
            throw WhisperRuntimeError.malformedWaveFile
        }

        var format: WaveFormat?
        var audioRange: Range<Int>?
        var offset = 12

        while offset + 8 <= data.count {
            let chunkID = ascii(data, offset: offset, count: 4)
            let chunkSize = Int(readUInt32LE(data, offset: offset + 4))
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + chunkSize
            guard payloadEnd <= data.count else {
                throw WhisperRuntimeError.malformedWaveFile
            }

            switch chunkID {
            case "fmt ":
                guard chunkSize >= 16 else { throw WhisperRuntimeError.malformedWaveFile }
                format = WaveFormat(
                    encoding: readUInt16LE(data, offset: payloadStart),
                    channels: Int(readUInt16LE(data, offset: payloadStart + 2)),
                    sampleRate: Int(readUInt32LE(data, offset: payloadStart + 4)),
                    bitsPerSample: Int(readUInt16LE(data, offset: payloadStart + 14))
                )
            case "data":
                audioRange = payloadStart..<payloadEnd
            default:
                break
            }

            let paddedEnd = payloadEnd + (chunkSize.isMultiple(of: 2) ? 0 : 1)
            guard paddedEnd <= data.count || payloadEnd == data.count else {
                throw WhisperRuntimeError.malformedWaveFile
            }
            offset = paddedEnd
        }

        guard let format, let audioRange else {
            throw WhisperRuntimeError.malformedWaveFile
        }
        guard format.sampleRate == WhisperAudioBuffer.requiredSampleRate else {
            throw WhisperRuntimeError.unsupportedSampleRate(format.sampleRate)
        }
        guard (1...2).contains(format.channels) else {
            throw WhisperRuntimeError.unsupportedWaveFormat
        }

        let bytesPerSample: Int
        switch (format.encoding, format.bitsPerSample) {
        case (1, 16):
            bytesPerSample = 2
        case (3, 32):
            bytesPerSample = 4
        default:
            throw WhisperRuntimeError.unsupportedWaveFormat
        }

        let bytesPerFrame = bytesPerSample * format.channels
        guard bytesPerFrame > 0, audioRange.count.isMultiple(of: bytesPerFrame) else {
            throw WhisperRuntimeError.malformedWaveFile
        }

        let frameCount = audioRange.count / bytesPerFrame
        var samples: [Float] = []
        samples.reserveCapacity(frameCount)

        for frame in 0..<frameCount {
            let frameOffset = audioRange.lowerBound + frame * bytesPerFrame
            var mixed: Float = 0

            for channel in 0..<format.channels {
                let sampleOffset = frameOffset + channel * bytesPerSample
                switch format.encoding {
                case 1:
                    let raw = Int16(bitPattern: readUInt16LE(data, offset: sampleOffset))
                    mixed += Float(raw) / 32_768.0
                case 3:
                    let raw = readUInt32LE(data, offset: sampleOffset)
                    let value = Float(bitPattern: raw)
                    guard value.isFinite else { throw WhisperRuntimeError.malformedWaveFile }
                    mixed += value
                default:
                    throw WhisperRuntimeError.unsupportedWaveFormat
                }
            }

            samples.append(mixed / Float(format.channels))
        }

        return WhisperAudioBuffer(samples: samples, sampleRate: format.sampleRate)
    }

    private static func ascii(_ data: Data, offset: Int, count: Int) -> String {
        guard offset >= 0, count >= 0, offset + count <= data.count else { return "" }
        return data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return "" }
            let start = base.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
            return String(bytes: UnsafeBufferPointer(start: start, count: count), encoding: .ascii) ?? ""
        }
    }

    private static func readUInt16LE(_ data: Data, offset: Int) -> UInt16 {
        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        }
    }

    private static func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
        }
    }
}

private struct WaveFormat {
    let encoding: UInt16
    let channels: Int
    let sampleRate: Int
    let bitsPerSample: Int
}
