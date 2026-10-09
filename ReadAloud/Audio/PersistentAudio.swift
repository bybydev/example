import Foundation

nonisolated struct ProjectFinalAudioAsset: Sendable {
    let metadata: GeneratedAudioMetadata
    let wavURL: URL
}

nonisolated struct ParagraphCacheMetadata: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let cacheKey: String
    let itemID: UUID
    let paragraphIndex: Int
    let paragraphRevision: String
    let generationKey: String
    let voiceID: String
    let speed: Double
    let runtimeRevision: String
    let synthesisConfigVersion: Int
    let sourceRange: AudioSourceRange
    let sampleRate: Int
    let sampleCount: Int
    let audioRevision: String

    init(
        schemaVersion: Int = 1,
        cacheKey: String,
        itemID: UUID,
        paragraphIndex: Int,
        paragraphRevision: String,
        generationKey: String,
        voiceID: String,
        speed: Double,
        runtimeRevision: String,
        synthesisConfigVersion: Int,
        sourceRange: AudioSourceRange,
        sampleRate: Int,
        sampleCount: Int,
        audioRevision: String
    ) {
        self.schemaVersion = schemaVersion
        self.cacheKey = cacheKey
        self.itemID = itemID
        self.paragraphIndex = paragraphIndex
        self.paragraphRevision = paragraphRevision
        self.generationKey = generationKey
        self.voiceID = voiceID
        self.speed = speed
        self.runtimeRevision = runtimeRevision
        self.synthesisConfigVersion = synthesisConfigVersion
        self.sourceRange = sourceRange
        self.sampleRate = sampleRate
        self.sampleCount = sampleCount
        self.audioRevision = audioRevision
    }
}

nonisolated struct CachedParagraphAudio: Sendable {
    let metadata: ParagraphCacheMetadata
    let audio: KokoroAudio
}

nonisolated enum ParagraphCacheIdentity {
    static func key(
        itemID: UUID,
        paragraphIndex: Int,
        paragraphText: String,
        resolved: ResolvedNarrationSettings,
        runtimeRevision: String,
        synthesisConfigVersion: Int
    ) throws -> String {
        guard paragraphIndex >= 0,
              resolved.speed.isFinite,
              resolved.speed > 0,
              !resolved.voiceID.isEmpty,
              !runtimeRevision.isEmpty,
              synthesisConfigVersion >= 1 else {
            throw ProjectStoreError.invalidData(
                "Paragraph cache identity is invalid."
            )
        }

        let paragraphRevision =
            ProjectDigest.sha256(paragraphText)

        var canonical =
            "readaloud-paragraph-cache-v1\n"
        canonical +=
            "itemID:\(ProjectPackagePaths.fileID(itemID))\n"
        canonical +=
            "paragraphIndex:\(paragraphIndex)\n"
        canonical +=
            "paragraphRevision:\(paragraphRevision)\n"
        canonical +=
            "voiceID:\(resolved.voiceID)\n"
        canonical +=
            "speedBits:\(String(format: "%016llx", resolved.speed.bitPattern))\n"
        canonical +=
            "runtimeRevision:\(runtimeRevision)\n"
        canonical +=
            "synthesisConfigVersion:\(synthesisConfigVersion)\n"

        return ProjectDigest.sha256(canonical)
    }
}

nonisolated enum ProjectWAVCodec {
    static let requiredSampleRate = 24_000

    static func encode(
        samples: [Float],
        sampleRate: Int
    ) throws -> Data {
        guard !samples.isEmpty,
              sampleRate == requiredSampleRate else {
            throw ProjectStoreError.invalidData(
                "ReadAloud WAV output must contain 24 kHz mono PCM."
            )
        }

        let bytesPerSample = 2
        guard samples.count <= (Int(UInt32.max) - 36) / bytesPerSample,
              samples.allSatisfy(\.isFinite) else {
            throw ProjectStoreError.invalidData(
                "Generated audio is too large for a WAV file."
            )
        }

        let dataByteCount = samples.count * bytesPerSample
        var data = Data()
        data.reserveCapacity(44 + dataByteCount)

        data.append(contentsOf: Array("RIFF".utf8))
        appendUInt32(
            UInt32(36 + dataByteCount),
            to: &data
        )
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendUInt32(16, to: &data)
        appendUInt16(1, to: &data)
        appendUInt16(1, to: &data)
        appendUInt32(
            UInt32(sampleRate),
            to: &data
        )
        appendUInt32(
            UInt32(sampleRate * bytesPerSample),
            to: &data
        )
        appendUInt16(
            UInt16(bytesPerSample),
            to: &data
        )
        appendUInt16(16, to: &data)
        data.append(contentsOf: Array("data".utf8))
        appendUInt32(
            UInt32(dataByteCount),
            to: &data
        )

        for sample in samples {
            let clamped = max(-1, min(1, sample))
            let scaled: Int16
            if clamped <= -1 {
                scaled = Int16.min
            } else {
                scaled = Int16(
                    (clamped * Float(Int16.max))
                        .rounded()
                )
            }
            appendUInt16(
                UInt16(bitPattern: scaled),
                to: &data
            )
        }

        return data
    }

    static func decode(
        _ data: Data
    ) throws -> KokoroAudio {
        guard data.count <= 44 + ReadAloudSafety.maximumParagraphSamples * 2 else {
            throw ProjectStoreError.invalidData("Cached audio exceeds safe paragraph limits.")
        }
        let bytes = [UInt8](data)
        guard bytes.count >= 44,
              ascii(bytes, 0, 4) == "RIFF",
              ascii(bytes, 8, 4) == "WAVE" else {
            throw ProjectStoreError.invalidData(
                "Generated audio is not a valid WAV file."
            )
        }

        var cursor = 12
        var audioFormat: UInt16?
        var channels: UInt16?
        var sampleRate: UInt32?
        var bitsPerSample: UInt16?
        var sampleBytes: ArraySlice<UInt8>?

        while cursor + 8 <= bytes.count {
            let chunkID = ascii(
                bytes,
                cursor,
                4
            )
            let chunkSize = Int(
                readUInt32(
                    bytes,
                    cursor + 4
                )
            )
            let payloadStart = cursor + 8
            let payloadEnd =
                payloadStart + chunkSize

            guard payloadEnd <= bytes.count else {
                throw ProjectStoreError.invalidData(
                    "WAV chunk exceeds file bounds."
                )
            }

            if chunkID == "fmt " {
                guard chunkSize >= 16 else {
                    throw ProjectStoreError.invalidData(
                        "WAV format chunk is incomplete."
                    )
                }
                audioFormat =
                    readUInt16(
                        bytes,
                        payloadStart
                    )
                channels =
                    readUInt16(
                        bytes,
                        payloadStart + 2
                    )
                sampleRate =
                    readUInt32(
                        bytes,
                        payloadStart + 4
                    )
                bitsPerSample =
                    readUInt16(
                        bytes,
                        payloadStart + 14
                    )
            } else if chunkID == "data" {
                sampleBytes =
                    bytes[payloadStart..<payloadEnd]
            }

            cursor =
                payloadEnd + (chunkSize % 2)
        }

        guard audioFormat == 1,
              channels == 1,
              sampleRate
                == UInt32(requiredSampleRate),
              bitsPerSample == 16,
              let sampleBytes,
              !sampleBytes.isEmpty,
              sampleBytes.count % 2 == 0 else {
            throw ProjectStoreError.invalidData(
                "ReadAloud WAV must be 24 kHz mono 16-bit PCM."
            )
        }

        let raw = Array(sampleBytes)
        var samples: [Float] = []
        samples.reserveCapacity(raw.count / 2)

        var index = 0
        while index < raw.count {
            let value =
                UInt16(raw[index])
                | (UInt16(raw[index + 1]) << 8)
            let signed =
                Int16(bitPattern: value)
            let sample =
                signed == Int16.min
                ? -1
                : Float(signed)
                    / Float(Int16.max)
            samples.append(sample)
            index += 2
        }

        return KokoroAudio(
            samples: samples,
            sampleRate: requiredSampleRate
        )
    }

    struct FileInfo: Sendable {
        let sampleCount: Int
        var durationSeconds: Double {
            Double(sampleCount) / Double(requiredSampleRate)
        }
    }

    static func inspect(fileAt url: URL) throws -> FileInfo {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let bytes = [UInt8](try handle.read(upToCount: 44) ?? Data())
        guard bytes.count == 44,
              ascii(bytes, 0, 4) == "RIFF",
              ascii(bytes, 8, 4) == "WAVE",
              ascii(bytes, 12, 4) == "fmt ",
              readUInt32(bytes, 16) == 16,
              readUInt16(bytes, 20) == 1,
              readUInt16(bytes, 22) == 1,
              readUInt32(bytes, 24) == UInt32(requiredSampleRate),
              readUInt32(bytes, 28) == UInt32(requiredSampleRate * 2),
              readUInt16(bytes, 32) == 2,
              readUInt16(bytes, 34) == 16,
              ascii(bytes, 36, 4) == "data" else {
            throw ProjectStoreError.invalidData("Final audio has an invalid WAV header.")
        }
        let byteCount = UInt64(readUInt32(bytes, 40))
        guard byteCount > 0, byteCount % 2 == 0,
              fileSize == byteCount + 44,
              UInt64(readUInt32(bytes, 4)) == byteCount + 36 else {
            throw ProjectStoreError.invalidData("Final audio has invalid WAV bounds.")
        }
        return FileInfo(sampleCount: Int(byteCount / 2))
    }

    static func header(sampleCount: Int) throws -> Data {
        guard sampleCount >= 0,
              sampleCount <= (Int(UInt32.max) - 36) / 2 else {
            throw ProjectStoreError.invalidData("Generated audio exceeds WAV file limits.")
        }
        let size = UInt32(sampleCount * 2)
        var data = Data("RIFF".utf8)
        appendUInt32(36 + size, to: &data)
        data.append(contentsOf: "WAVEfmt ".utf8)
        appendUInt32(16, to: &data)
        appendUInt16(1, to: &data)
        appendUInt16(1, to: &data)
        appendUInt32(UInt32(requiredSampleRate), to: &data)
        appendUInt32(UInt32(requiredSampleRate * 2), to: &data)
        appendUInt16(2, to: &data)
        appendUInt16(16, to: &data)
        data.append(contentsOf: "data".utf8)
        appendUInt32(size, to: &data)
        return data
    }

    private static func appendUInt16(
        _ value: UInt16,
        to data: inout Data
    ) {
        data.append(
            UInt8(value & 0xff)
        )
        data.append(
            UInt8((value >> 8) & 0xff)
        )
    }

    private static func appendUInt32(
        _ value: UInt32,
        to data: inout Data
    ) {
        data.append(
            UInt8(value & 0xff)
        )
        data.append(
            UInt8((value >> 8) & 0xff)
        )
        data.append(
            UInt8((value >> 16) & 0xff)
        )
        data.append(
            UInt8((value >> 24) & 0xff)
        )
    }

    private static func readUInt16(
        _ bytes: [UInt8],
        _ offset: Int
    ) -> UInt16 {
        UInt16(bytes[offset])
            | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32(
        _ bytes: [UInt8],
        _ offset: Int
    ) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func ascii(
        _ bytes: [UInt8],
        _ offset: Int,
        _ count: Int
    ) -> String {
        guard offset >= 0,
              count >= 0,
              offset + count <= bytes.count else {
            return ""
        }

        return String(
            bytes: bytes[offset..<(offset + count)],
            encoding: .ascii
        ) ?? ""
    }
}

