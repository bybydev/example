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
    private nonisolated struct Entry {
        let id: UUID
        let itemID: UUID
        var consumers: [UUID: CheckedContinuation<KokoroAudio, Error>]
    }

    private nonisolated struct Producer {
        let itemID: UUID
        let task: Task<Void, Never>
    }

    private nonisolated struct Suspension {
        // nil covers the entire project cache.
        let itemIDs: Set<UUID>?
    }

    private var inFlight: [String: Entry] = [:]
    // Retain cancelled producers until they finish, even if a replacement
    // request for the same key has already been admitted.
    private var producers: [UUID: Producer] = [:]
    private var suspensions: [UUID: Suspension] = [:]
    private var isShutdown = false
    // Whole operations retain disk dependencies, including reads of chunks
    // that are already cached and therefore never enter `inFlight`.
    private var usages: [UUID: UUID] = [:]

    private nonisolated struct Reclamation {
        let audioRevision: String
        let operation: @Sendable () async throws -> Void
    }
    private nonisolated struct ReclamationExecution {
        let id: UUID
        let audioRevision: String
        let operation: @Sendable () async throws -> Void
        let task: Task<Void, Never>
    }
    private var pendingReclamations: [UUID: Reclamation] = [:]
    private var reclaiming: [UUID: ReclamationExecution] = [:]
    private var reclamationAllowed = true
    private var reclamationActivityRevision: UInt64 = 0

    func setReclamationAllowed(_ allowed: Bool, revision: UInt64) {
        guard revision >= reclamationActivityRevision else { return }
        reclamationActivityRevision = revision
        reclamationAllowed = allowed
        if allowed {
            for itemID in Array(pendingReclamations.keys) { scheduleReclamation(itemID: itemID) }
        } else {
            for (itemID, execution) in reclaiming {
                if !isShutdown, !isSuspended(itemID), pendingReclamations[itemID] == nil {
                    pendingReclamations[itemID] = Reclamation(
                        audioRevision: execution.audioRevision, operation: execution.operation
                    )
                }
                execution.task.cancel()
            }
        }
    }

    var activeUsageCount: Int { usages.count }
    var activeSuspensionCount: Int { suspensions.count }
    var pendingReclamationCount: Int { pendingReclamations.count }

    /// New readers wait for an already admitted cleanup, rather than failing
    /// playback or racing deletion. Cached reads inside the scope stay safe.
    func withUsage<Value: Sendable>(
        itemID: UUID,
        operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        while let execution = reclaiming[itemID] { await execution.task.value }
        try requireAdmission(for: itemID)
        let token = UUID()
        usages[token] = itemID
        defer {
            usages.removeValue(forKey: token)
            scheduleReclamation(itemID: itemID)
        }
        let value = try await operation()
        try Task.checkCancellation()
        return value
    }

    /// The operation must validate the committed final pair and delete only
    /// its exact chunk keys in one ProjectStore transaction (no suspension).
    func requestReclamation(
        itemID: UUID, audioRevision: String,
        operation: @escaping @Sendable () async throws -> Void
    ) {
        guard !Task.isCancelled, !isShutdown,
              !isSuspended(itemID),
              pendingReclamations[itemID]?.audioRevision != audioRevision,
              reclaiming[itemID]?.audioRevision != audioRevision else { return }
        pendingReclamations[itemID] = Reclamation(audioRevision: audioRevision, operation: operation)
        scheduleReclamation(itemID: itemID)
    }

    func waitForReclamation(itemID: UUID) async {
        while let execution = reclaiming[itemID] { await execution.task.value }
    }

    private func scheduleReclamation(itemID: UUID) {
        guard reclamationAllowed, !isShutdown, !isSuspended(itemID), reclaiming[itemID] == nil,
              !usages.values.contains(itemID),
              !producers.values.contains(where: { $0.itemID == itemID }),
              !inFlight.values.contains(where: { $0.itemID == itemID }),
              let pending = pendingReclamations.removeValue(forKey: itemID) else { return }
        let id = UUID()
        let task = Task {
            do {
                try Task.checkCancellation()
                try await pending.operation()
            } catch {
                // Housekeeping is best effort. A failed validation/delete must
                // not turn successful playback or generation into a failure.
            }
            self.finishReclamation(itemID: itemID, id: id)
        }
        // Reserve before the first await. New usages/audio requests wait on
        // this task; invalidation drains it before touching final/chunk files.
        reclaiming[itemID] = ReclamationExecution(id: id, audioRevision: pending.audioRevision, operation: pending.operation, task: task)
    }

    private func finishReclamation(itemID: UUID, id: UUID) {
        guard reclaiming[itemID]?.id == id else { return }
        reclaiming.removeValue(forKey: itemID)
        inspectedReadyKeys.removeAll()
        scheduleReclamation(itemID: itemID)
    }

    private func isSuspended(_ itemID: UUID) -> Bool {
        suspensions.values.contains { $0.itemIDs?.contains(itemID) ?? true }
    }

    var activeConsumerCount: Int {
        inFlight.values.reduce(0) { $0 + $1.consumers.count }
    }

    var activeProducerCount: Int { producers.count }
    // A completed chunk is indexed only after its WAV and metadata exist.
    // This index is an optimization; disk presence is rechecked on every query.
    private var inspectedReadyKeys: Set<String> = []

    init(packageURL: URL) {
        let paths = ProjectPackagePaths(packageURL: packageURL)
        directory = paths.chunkCacheDirectory
        temporaryDirectory = paths.tempDirectory
    }

    func load(_ request: ChunkAudioRequest) throws -> KokoroAudio? {
        try requireAdmission(for: request.itemID)
        let key = request.cacheKey
        let wav = directory.appending(path: "\(key).wav")
        let json = directory.appending(path: "\(key).json")
        let fm = FileManager.default
        let hasWAV = fm.fileExists(atPath: wav.path)
        let hasJSON = fm.fileExists(atPath: json.path)
        guard hasWAV && hasJSON else {
            inspectedReadyKeys.remove(key)
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
            inspectedReadyKeys.insert(key)
            return audio
        } catch {
            inspectedReadyKeys.remove(key)
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
        try Task.checkCancellation()
        while let execution = reclaiming[request.itemID] { await execution.task.value }
        try Task.checkCancellation()
        if let cached = try load(request) {
            try Task.checkCancellation()
            return cached
        }
        let key = request.cacheKey
        let consumerID = UUID()
        let audio = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<KokoroAudio, Error>) in
                // Cancellation may precede registration of the continuation.
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if var entry = inFlight[key] {
                    entry.consumers[consumerID] = continuation
                    inFlight[key] = entry
                    return
                }

                let entryID = UUID()
                inFlight[key] = Entry(
                    id: entryID, itemID: request.itemID,
                    consumers: [consumerID: continuation]
                )
                let task = Task {
                    let result: Result<KokoroAudio, Error>
                    do {
                        try Task.checkCancellation()
                        let generated = try await synthesize()
                        try Task.checkCancellation()
                        result = .success(generated)
                    } catch {
                        result = .failure(error)
                    }
                    self.finish(result, request: request, entryID: entryID)
                }
                producers[entryID] = Producer(itemID: request.itemID, task: task)
            }
        } onCancel: {
            Task { await self.cancelConsumer(consumerID, key: key) }
        }
        // A completion can win the actor hop from onCancel. Never deliver
        // that result back into a cancelled playback/generation operation.
        try Task.checkCancellation()
        return audio
    }

    private func cancelConsumer(_ id: UUID, key: String) {
        guard var entry = inFlight[key],
              let continuation = entry.consumers.removeValue(forKey: id)
        else { return }
        if entry.consumers.isEmpty {
            inFlight.removeValue(forKey: key)
            producers[entry.id]?.task.cancel()
        } else {
            inFlight[key] = entry
        }
        continuation.resume(throwing: CancellationError())
    }

    private func finish(
        _ result: Result<KokoroAudio, Error>,
        request: ChunkAudioRequest,
        entryID: UUID
    ) {
        defer {
            producers.removeValue(forKey: entryID)
            scheduleReclamation(itemID: request.itemID)
        }
        let key = request.cacheKey
        // The entry ID acts as its invalidation epoch. Clear/cancellation
        // removes the entry before awaiting; old completion cannot write or
        // remove a replacement entry with the same durable cache key.
        guard let entry = inFlight[key], entry.id == entryID else { return }
        inFlight.removeValue(forKey: key)
        let committed: Result<KokoroAudio, Error>
        do {
            try requireAdmission(for: request.itemID)
            let audio = try result.get()
            try store(audio, for: request)
            committed = .success(audio)
        } catch {
            committed = .failure(error)
        }
        for continuation in entry.consumers.values {
            continuation.resume(with: committed)
        }
    }

    private func requireAdmission(for itemID: UUID) throws {
        try Task.checkCancellation()
        guard !isShutdown, !isSuspended(itemID), reclaiming[itemID] == nil
        else { throw CancellationError() }
    }

    /// Close admission before the first await. Callers hold the returned
    /// token across their entire storage transaction, then explicitly resume.
    func suspendAndDrain(itemIDs: Set<UUID>? = nil) async -> UUID {
        let token = UUID()
        suspensions[token] = Suspension(itemIDs: itemIDs)
        pendingReclamations = pendingReclamations.filter { !(itemIDs?.contains($0.key) ?? true) }
        let cleanups = reclaiming.filter { itemIDs?.contains($0.key) ?? true }.values.map(\.task)
        for task in cleanups { task.cancel() }
        let entries = inFlight.filter { itemIDs?.contains($0.value.itemID) ?? true }
        for (key, entry) in entries {
            inFlight.removeValue(forKey: key)
            for continuation in entry.consumers.values {
                continuation.resume(throwing: CancellationError())
            }
        }
        let pending = producers.values.filter { itemIDs?.contains($0.itemID) ?? true }
        for producer in pending { producer.task.cancel() }
        for producer in pending { await producer.task.value }
        for task in cleanups { await task.value }
        return token
    }

    func resumeAdmission(_ token: UUID) {
        suspensions.removeValue(forKey: token)
    }

    func shutdown() async {
        isShutdown = true
        _ = await suspendAndDrain()
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
        inspectedReadyKeys.insert(key)
    }

    /// Returns independently playable, finished chunk source ranges. A key
    /// counts only if both committed files and matching metadata exist.
    /// Never count in-flight inference or the furthest generated index.
    func cachedSourceRanges(for requests: [ChunkAudioRequest]) -> [AudioSourceRange] {
        guard !requests.isEmpty else { return [] }
        let fm = FileManager.default
        guard let filenames = try? fm.contentsOfDirectory(atPath: directory.path)
        else {
            inspectedReadyKeys.removeAll()
            return []
        }
        let existing = Set(filenames)
        var result: [AudioSourceRange] = []
        result.reserveCapacity(min(requests.count, existing.count / 2))

        for request in requests {
            guard (try? requireAdmission(for: request.itemID)) != nil else { continue }
            let key = request.cacheKey
            let wavName = "\(key).wav"
            let jsonName = "\(key).json"
            guard existing.contains(wavName), existing.contains(jsonName) else {
                inspectedReadyKeys.remove(key)
                continue
            }
            if !inspectedReadyKeys.contains(key) {
                let wav = directory.appending(path: wavName)
                let json = directory.appending(path: jsonName)
                guard
                    let jsonSize = try? json.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                    jsonSize > 0, jsonSize <= 16_384,
                    let wavSize = try? wav.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                    let metadata = try? ProjectJSONCodec.decode(
                        ChunkAudioMetadata.self,
                        from: Data(contentsOf: json),
                        relativePath: "cache/chunks/\(jsonName)"
                    ),
                    metadata.schemaVersion == ProjectSchema.currentVersion,
                    metadata.cacheKey == key,
                    metadata.itemID == request.itemID,
                    metadata.sourceRange == request.chunk.sourceRange,
                    metadata.sampleCount > 0,
                    metadata.sampleCount <= ReadAloudSafety.maximumBufferSamples,
                    wavSize == 44 + metadata.sampleCount * 2,
                    // Verify unfamiliar on-disk chunks once. Subsequent
                    // polls reuse the actor index and check file presence.
                    let digest = try? ProjectDigest.sha256(fileAt: wav),
                    digest == metadata.audioRevision
                else { continue }
                inspectedReadyKeys.insert(key)
            }
            result.append(request.chunk.sourceRange)
        }
        return result
    }

    func clear(itemIDs: Set<UUID>) async throws {
        guard !itemIDs.isEmpty else { return }
        let token = await suspendAndDrain(itemIDs: itemIDs)
        defer { resumeAdmission(token) }
        inspectedReadyKeys.removeAll()
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

    func clearAll() async throws {
        let token = await suspendAndDrain()
        defer { resumeAdmission(token) }
        inspectedReadyKeys.removeAll()
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return }
        for url in try fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) {
            try fm.removeItem(at: url)
        }
    }
}

/// Disk-backed live production, independent of the two-PCM-buffer player.
/// Prepares at most 20 chunks ahead, including while playback is paused in any
/// scene. A fixed audible position naturally stops production at capacity.
actor ChunkReadAhead {
    // Internal tuning only; deliberately not persisted or exposed in Settings.
    static let liveReadAheadChunkLimit = 20
    private var audibleIndex: Int
    private var latestReady: Int
    private var failure: Error?
    private var productionWaiters: [UUID: (index: Int, continuation: CheckedContinuation<Void, Error>)] = [:]
    private var readyWaiters: [UUID: (index: Int, continuation: CheckedContinuation<Void, Error>)] = [:]

    init(startIndex: Int) {
        audibleIndex = startIndex - 1
        latestReady = startIndex - 1
    }

    func canProduce(_ index: Int) -> Bool {
        index <= audibleIndex + Self.liveReadAheadChunkLimit
    }

    var waitingProductionCount: Int { productionWaiters.count }

    func awaitProduction(for index: Int) async throws {
        try Task.checkCancellation()
        guard !canProduce(index) else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if canProduce(index) { continuation.resume() }
                else { productionWaiters[id] = (index, continuation) }
            }
        } onCancel: { Task { await self.cancelProductionWaiter(id) } }
        try Task.checkCancellation()
    }

    private func cancelProductionWaiter(_ id: UUID) {
        productionWaiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }

    func loadAudio(
        for index: Int,
        _ operation: @escaping @Sendable () async throws -> KokoroAudio
    ) async throws -> KokoroAudio {
        try await awaitProduction(for: index)
        try Task.checkCancellation()
        // Stop/seek still releases the cache consumer promptly. Playback pause
        // does not cancel this task: it is allowed to finish the bounded window.
        let task = Task { try await operation() }
        let audio = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
        try Task.checkCancellation()
        return audio
    }

    func markAudible(_ index: Int) {
        audibleIndex = max(audibleIndex, index)
        resumeEligibleProduction()
    }

    private func resumeEligibleProduction() {
        let eligible = productionWaiters.filter { canProduce($0.value.index) }
        for (id, waiter) in eligible {
            productionWaiters.removeValue(forKey: id)
            waiter.continuation.resume()
        }
    }

    func markReady(_ index: Int) {
        latestReady = max(latestReady, index)
        let ready = readyWaiters.filter { $0.value.index <= latestReady }
        for (id, waiter) in ready {
            readyWaiters.removeValue(forKey: id)
            waiter.continuation.resume()
        }
    }

    func fail(_ error: Error) {
        failure = error
        let waiters = readyWaiters.values.map(\.continuation)
        readyWaiters.removeAll()
        for waiter in waiters { waiter.resume(throwing: error) }
    }

    func awaitReady(_ index: Int) async throws {
        try Task.checkCancellation()
        guard latestReady < index else { return }
        if let failure { throw failure }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if latestReady >= index { continuation.resume() }
                else if let failure { continuation.resume(throwing: failure) }
                else { readyWaiters[id] = (index, continuation) }
            }
        } onCancel: { Task { await self.cancelReadyWaiter(id) } }
        try Task.checkCancellation()
    }

    private func cancelReadyWaiter(_ id: UUID) {
        readyWaiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }
}
