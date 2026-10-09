import Foundation

/// Durable identity is independent of which consumer requested the chunk.
nonisolated struct ChunkAudioRequest: Sendable {
    let itemID: UUID
    let index: Int
    let chunk: SpeechChunk
    let generationKey: String
    let resolved: ResolvedNarrationSettings
    let runtimeRevision: String
    let synthesisConfigVersion: Int

    var cacheKey: String {
        ProjectDigest.sha256(
            "readaloud-chunk-v1\n"
            + "item:\(itemID.uuidString.lowercased())\n"
            + "index:\(index)\n"
            + "text:\(ProjectDigest.sha256(chunk.text))\n"
            + "range:\(chunk.sourceRange.startUTF16)-\(chunk.sourceRange.endUTF16)\n"
            + "generation:\(generationKey)\n"
            + "voice:\(resolved.voiceID)\n"
            + "speed:\(String(format: "%016llx", resolved.speed.bitPattern))\n"
            + "runtime:\(runtimeRevision)\n"
            + "config:\(synthesisConfigVersion)\n"
        )
    }
}

nonisolated struct ChunkAudioMetadata: Codable, Sendable {
    // All project JSON decoding goes through ProjectJSONCodec, which requires
    // schemaVersion in the envelope. Without it every generated cache entry
    // fails on first playback, even though WAV synthesis succeeded.
    let schemaVersion: Int
    let cacheKey: String
    let itemID: UUID
    let sourceRange: AudioSourceRange
    let sampleCount: Int
    let audioRevision: String
}

/// Both foreground streaming and offline generation use this same cache.
/// Only the requested chunk is decoded; ahead-of-playback chunks live on disk.
actor SharedChunkAudioCache {
    nonisolated let directory: URL
    nonisolated let temporaryDirectory: URL
    private var inFlight: [String: Task<KokoroAudio, Error>] = [:]
    private var inFlightItems: [String: UUID] = [:]

    init(packageURL: URL) {
        let paths = ProjectPackagePaths(packageURL: packageURL)
        directory = paths.chunkCacheDirectory
        temporaryDirectory = paths.tempDirectory
    }

    func load(_ request: ChunkAudioRequest) throws -> KokoroAudio? {
        let key = request.cacheKey
        let wav = directory.appending(path: "\(key).wav")
        let json = directory.appending(path: "\(key).json")
        let fm = FileManager.default
        let hasWAV = fm.fileExists(atPath: wav.path)
        let hasJSON = fm.fileExists(atPath: json.path)
        guard hasWAV && hasJSON else {
            if hasWAV { try? fm.removeItem(at: wav) }
            if hasJSON { try? fm.removeItem(at: json) }
            return nil
        }

        do {
            guard (try json.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 16_384,
                  (try wav.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                     <= 44 + ReadAloudSafety.maximumBufferSamples * 2 else {
                throw ProjectStoreError.invalidData("Chunk cache exceeds safe limits.")
            }
            let metadata = try ProjectJSONCodec.decode(
                ChunkAudioMetadata.self,
                from: Data(contentsOf: json),
                relativePath: "cache/chunks/\(key).json"
            )
            guard metadata.schemaVersion == ProjectSchema.currentVersion,
                  metadata.cacheKey == key,
                  metadata.itemID == request.itemID,
                  metadata.sourceRange == request.chunk.sourceRange else {
                throw ProjectStoreError.invalidData("Chunk cache identity mismatch.")
            }
            let bytes = try Data(contentsOf: wav)
            guard ProjectDigest.sha256(bytes) == metadata.audioRevision else {
                throw ProjectStoreError.invalidData("Chunk cache checksum mismatch.")
            }
            let audio = try ProjectWAVCodec.decode(bytes)
            try ReadAloudSafety.validate(
                audio, maximumSamples: ReadAloudSafety.maximumBufferSamples
            )
            guard audio.samples.count == metadata.sampleCount else {
                throw ProjectStoreError.invalidData("Chunk cache sample count mismatch.")
            }
            return audio
        } catch {
            try? fm.removeItem(at: wav)
            try? fm.removeItem(at: json)
            return nil
        }
    }

    /// Coalesces requests from playback and the durable generation queue.
    func audio(
        for request: ChunkAudioRequest,
        synthesize: @escaping @Sendable () async throws -> KokoroAudio
    ) async throws -> KokoroAudio {
        if let cached = try load(request) { return cached }
        let key = request.cacheKey
        if let active = inFlight[key] { return try await active.value }

        let task = Task<KokoroAudio, Error> {
            let generated = try await synthesize()
            try Task.checkCancellation()
            try await self.store(generated, for: request)
            return generated
        }
        inFlight[key] = task
        inFlightItems[key] = request.itemID
        defer {
            inFlight[key] = nil
            inFlightItems[key] = nil
        }
        return try await task.value
    }

    private func store(_ audio: KokoroAudio, for request: ChunkAudioRequest) throws {
        try ReadAloudSafety.validate(
            audio, maximumSamples: ReadAloudSafety.maximumBufferSamples
        )
        let key = request.cacheKey
        let bytes = try ProjectWAVCodec.encode(
            samples: audio.samples, sampleRate: audio.sampleRate
        )
        let metadata = ChunkAudioMetadata(
            schemaVersion: ProjectSchema.currentVersion,
            cacheKey: key, itemID: request.itemID,
            sourceRange: request.chunk.sourceRange,
            sampleCount: audio.samples.count, audioRevision: ProjectDigest.sha256(bytes)
        )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        try ProjectAtomicWriter.write(
            bytes, to: directory.appending(path: "\(key).wav"),
            temporaryDirectory: temporaryDirectory, fileManager: .default
        )
        try ProjectAtomicWriter.write(
            metadata, to: directory.appending(path: "\(key).json"),
            temporaryDirectory: temporaryDirectory, fileManager: .default
        )
    }

    func clear(itemIDs: Set<UUID>) throws {
        guard !itemIDs.isEmpty else { return }
        for (key, task) in inFlight {
            if let itemID = inFlightItems[key], itemIDs.contains(itemID) {
                task.cancel()
            }
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return }
        for json in try fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) where json.pathExtension == "json" {
            guard let bytes = try? Data(contentsOf: json),
                  let metadata = try? ProjectJSONCodec.decode(
                      ChunkAudioMetadata.self, from: bytes,
                      relativePath: "cache/chunks/\(json.lastPathComponent)"
                  ), itemIDs.contains(metadata.itemID) else { continue }
            try fm.removeItem(at: json)
            let wav = json.deletingPathExtension().appendingPathExtension("wav")
            if fm.fileExists(atPath: wav.path) { try fm.removeItem(at: wav) }
        }
    }

    func clearAll() throws {
        for task in inFlight.values { task.cancel() }
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return }
        for url in try fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) {
            try fm.removeItem(at: url)
        }
    }
}

/// A bounded *synthesis* window, separate from AVAudioPlayerNode's queue.
/// Uses disk-backed chunks rather than retaining 20 PCM buffers in RAM.
actor ChunkReadAhead {
    private let startIndex: Int
    private let maxAhead: Int
    private var audibleIndex: Int
    private var latestReady: Int
    private var failure: Error?

    init(startIndex: Int, maxAhead: Int = 20) {
        self.startIndex = startIndex
        self.maxAhead = maxAhead
        audibleIndex = startIndex - 1
        latestReady = startIndex - 1
    }

    func awaitCapacity(for index: Int) async throws {
        while index > max(startIndex - 1, audibleIndex) + maxAhead {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(60))
        }
        try Task.checkCancellation()
    }

    func markReady(_ index: Int) {
        latestReady = max(latestReady, index)
    }

    func markAudible(_ index: Int) {
        audibleIndex = max(audibleIndex, index)
    }

    func fail(_ error: Error) { failure = error }

    func awaitReady(_ index: Int) async throws {
        while latestReady < index {
            try Task.checkCancellation()
            if let failure { throw failure }
            try await Task.sleep(for: .milliseconds(35))
        }
        try Task.checkCancellation()
    }
}
