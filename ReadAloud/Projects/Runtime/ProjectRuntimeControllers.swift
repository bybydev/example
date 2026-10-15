import Foundation
import JobQueue
import Observation

@Observable
@MainActor
final class ProjectQueueController {
    private(set) var queue =
        ProjectQueueDocument()

    @ObservationIgnored
    private weak var runtime:
        ProjectRuntime?

    @ObservationIgnored
    private var executionQueue:
        JobQueue?

    @ObservationIgnored
    private var registry:
        JobRegistry?

    @ObservationIgnored
    private var isConfigured = false

    @ObservationIgnored private var generationExecutions: [UUID: Task<Void, Error>] = [:]
    @ObservationIgnored private var configurationID: UUID?
    @ObservationIgnored private var drainDepth = 0
    private(set) var hasGlobalAdmission = false
    private(set) var schedulingStatus = "Queued"

    func publishSchedulingStatus(_ status: String) { schedulingStatus = status }

    /// Keep an awaitable handle to the complete job, including final WAV
    /// assembly/commit. Cancelling JobQueue alone does not drain that work.
    func executeGeneration(
        _ operation: @escaping @MainActor () async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        guard isConfigured, hasGlobalAdmission, drainDepth == 0 else { throw CancellationError() }
        let id = UUID()
        let task = Task { @MainActor in
            try Task.checkCancellation()
            try await operation()
        }
        generationExecutions[id] = task
        defer { generationExecutions.removeValue(forKey: id) }
        try await withTaskCancellationHandler {
            try await task.value
            try Task.checkCancellation()
        } onCancel: {
            task.cancel()
        }
    }

    func cancelAndDrain() async {
        drainDepth += 1
        defer { drainDepth -= 1 }
        let pending = Array(generationExecutions.values)
        for task in pending { task.cancel() }
        for task in pending { _ = await task.result }
    }

    var waitingCount: Int {
        queue.jobs.filter {
            $0.state == .queued
        }.count
    }

    var generatingCount: Int {
        queue.jobs.filter {
            $0.state == .generating
        }.count
    }

    var failedCount: Int {
        queue.jobs.filter {
            $0.state == .failed
        }.count
    }

    var hasExecutingWork: Bool {
        generatingCount > 0
    }

    func configure(
        runtime: ProjectRuntime
    ) throws {
        guard !isConfigured else {
            self.runtime = runtime
            ProjectGenerationExecutionRegistry
                .shared
                .register(runtime)
            try reconcile()
            return
        }

        self.runtime = runtime
        ProjectGenerationExecutionRegistry
            .shared
            .register(runtime)

        let registry = JobRegistry()
        try registry.register(
            ReadAloudGenerationJob.self
        )

        let runtimeQueueURL =
            ProjectPackagePaths(
                packageURL:
                    runtime.packageURL
            )
            .tempDirectory
            .appending(
                path:
                    "runtime-generation-queue.json"
            )

        if FileManager.default
            .fileExists(
                atPath:
                    runtimeQueueURL.path
            )
        {
            try? FileManager.default
                .removeItem(
                    at: runtimeQueueURL
                )
        }

        let executionQueue =
            JobQueue(
                fileURL:
                    runtimeQueueURL,
                policy:
                    JobQueuePolicy(
                        maxConcurrentExecutions:
                            1
                    ),
                registry: registry,
                maxRecords: 500,
                autoCleanupEnabled:
                    true
            )

        let configurationID = UUID()
        self.configurationID = configurationID
        executionQueue.eventHandler = {
            [weak self] event in
            guard self?.configurationID == configurationID else { return }
            self?.handle(event)
        }

        try executionQueue.start()
        try executionQueue.pause()

        self.registry = registry
        self.executionQueue =
            executionQueue
        isConfigured = true

        try reconcile()
    }

    func publish(
        _ queue:
            ProjectQueueDocument
    ) {
        self.queue = queue

        guard isConfigured else {
            return
        }

        do {
            try reconcile()
        } catch {
            runtime?.lastErrorMessage =
                Self.message(for: error)
        }
    }

    func reconcileScheduling() {
        // The registry considers playback in every project before granting
        // this queue access to the app-wide offline synthesis slot.
        ProjectGenerationExecutionRegistry.shared.reconcileAdmission()
    }

    func setGlobalAdmission(_ admitted: Bool) {
        hasGlobalAdmission = admitted
        if !admitted {
            for task in generationExecutions.values { task.cancel() }
        }
        guard let executionQueue else { return }
        do {
            if admitted {
                if executionQueue.isPaused { try executionQueue.resume() }
            } else if !executionQueue.isPaused {
                try executionQueue.pause()
            }
        } catch {
            runtime?.lastErrorMessage = Self.message(for: error)
        }
    }

    func shutdown() {
        setGlobalAdmission(false)
        configurationID = nil
        for task in generationExecutions.values { task.cancel() }
        if let executionQueue {
            try? executionQueue
                .cancelAll()
        }

        if let runtime {
            ProjectGenerationExecutionRegistry
                .shared
                .unregister(runtime)
        }

        executionQueue = nil
        registry = nil
        runtime = nil
        isConfigured = false
    }

    private func reconcile() throws {
        guard let executionQueue
        else {
            return
        }

        let durableActive =
            Dictionary(
                uniqueKeysWithValues:
                    queue.jobs
                        .filter {
                            $0.state == .queued
                                || $0.state
                                    == .generating
                        }
                        .map {
                            ($0.id, $0)
                        }
            )

        for record in executionQueue
            .records.values
        {
            guard durableActive[
                record.id
            ] == nil else {
                continue
            }

            try executionQueue.remove(
                id: record.id
            )
        }

        for durable in durableActive
            .values
            .sorted(by: {
                if $0.createdAt
                    != $1.createdAt
                {
                    return $0.createdAt
                        < $1.createdAt
                }
                return $0.id.uuidString
                    < $1.id.uuidString
            })
        {
            if let existing =
                executionQueue.records[
                    durable.id
                ]
            {
                if !existing.status
                    .isTerminal
                {
                    continue
                }

                try executionQueue.remove(
                    id: durable.id
                )
            }

            let job =
                ReadAloudGenerationJob(
                    id: durable.id,
                    payload:
                        ReadAloudGenerationJob
                            .Payload(
                                projectID:
                                    durable.projectID,
                                itemID:
                                    durable.itemID,
                                generationKey:
                                    durable
                                        .generationKey
                            )
                )

            try executionQueue.enqueue(
                job,
                startPolicy:
                    .scheduled
            )
        }

        ProjectGenerationExecutionRegistry.shared.reconcileAdmission()
    }

    private func handle(
        _ event: JobQueueEvent
    ) {
        guard let runtime, let configurationID else {
            return
        }

        switch event {
        case .jobStarted(let id):
            Task { [weak self] in
                guard self?.configurationID == configurationID,
                      self?.queue.jobs.contains(where: { $0.id == id }) == true
                else { return }
                await runtime
                    .generationJobStarted(
                        id
                    )
            }

        case .jobPausing(let id):
            Task { [weak self] in
                guard self?.configurationID == configurationID,
                      self?.queue.jobs.contains(where: { $0.id == id }) == true
                else { return }
                await runtime
                    .generationJobYielded(
                        id
                    )
            }

        case .jobCompleted(let id):
            Task { [weak self] in
                guard self?.configurationID == configurationID,
                      self?.queue.jobs.contains(where: { $0.id == id }) == true
                else { return }
                await runtime
                    .generationJobCompleted(
                        id
                    )
            }

        case .jobFailed(
            let id,
            let errorDescription
        ):
            Task { [weak self] in
                guard self?.configurationID == configurationID,
                      self?.queue.jobs.contains(where: { $0.id == id }) == true
                else { return }
                await runtime
                    .generationJobFailed(
                        id,
                        message:
                            errorDescription
                    )
            }

        case .persistenceFailed(
            let errorDescription
        ):
            runtime.lastErrorMessage =
                errorDescription

        case .jobAdded(_),
             .jobCancelling(_),
             .jobProgressUpdated(_, _),
             .jobCancelled(_),
             .jobRemoved(_),
             .queueStatusChanged(_),
             .queueDrained:
            break
        }
    }

    nonisolated
    private static func message(
        for error: Error
    ) -> String {
        if let localized =
            error as? LocalizedError,
           let description =
            localized.errorDescription
        {
            return description
        }

        return String(
            describing: error
        )
    }
}

actor ProjectCacheCoordinator {
    nonisolated let packageURL: URL
    private let fileManager: FileManager

    init(
        packageURL: URL,
        fileManager: FileManager = .default
    ) {
        self.packageURL =
            packageURL.standardizedFileURL
        self.fileManager = fileManager
    }

    nonisolated var paragraphCacheDirectory: URL {
        ProjectPackagePaths(
            packageURL: packageURL
        ).paragraphCacheDirectory
    }

    nonisolated var artworkCacheDirectory: URL {
        ProjectPackagePaths(
            packageURL: packageURL
        ).artworkCacheDirectory
    }

    nonisolated var audioDirectory: URL {
        ProjectPackagePaths(
            packageURL: packageURL
        ).audioDirectory
    }

    nonisolated var temporaryDirectory: URL {
        ProjectPackagePaths(
            packageURL: packageURL
        ).tempDirectory
    }

    func loadParagraph(
        cacheKey: String,
        itemID: UUID,
        paragraphIndex: Int,
        paragraphText: String,
        generationKey: String,
        resolved: ResolvedNarrationSettings,
        runtimeRevision: String,
        synthesisConfigVersion: Int,
        sourceRange: AudioSourceRange
    ) throws -> CachedParagraphAudio? {
        let wavURL = paragraphWAV(
            cacheKey: cacheKey
        )
        let metadataURL = paragraphMetadata(
            cacheKey: cacheKey
        )

        let hasWAV =
            fileManager.fileExists(
                atPath: wavURL.path
            )
        let hasMetadata =
            fileManager.fileExists(
                atPath: metadataURL.path
            )

        guard hasWAV && hasMetadata else {
            if hasWAV || hasMetadata {
                removeParagraph(
                    cacheKey: cacheKey
                )
            }
            return nil
        }

        do {
            let metadataSize = try metadataURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard metadataSize <= 64 * 1_024 else {
                throw ProjectStoreError.invalidData("Paragraph cache metadata exceeds safe loading limits.")
            }
            let metadataData = try Data(contentsOf: metadataURL)
            let metadata =
                try ProjectJSONCodec.decode(
                    ParagraphCacheMetadata.self,
                    from: metadataData,
                    relativePath:
                        "cache/paragraphs/\(cacheKey).json"
                )

            try validate(
                metadata,
                cacheKey: cacheKey,
                itemID: itemID,
                paragraphIndex:
                    paragraphIndex,
                paragraphText:
                    paragraphText,
                generationKey:
                    generationKey,
                resolved: resolved,
                runtimeRevision:
                    runtimeRevision,
                synthesisConfigVersion:
                    synthesisConfigVersion,
                sourceRange:
                    sourceRange
            )

            let byteCount = try wavURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard byteCount <= 44 + ReadAloudSafety.maximumParagraphSamples * 2 else {
                throw ProjectStoreError.invalidData("Paragraph cache exceeds safe loading limits.")
            }
            let wavData = try Data(contentsOf: wavURL)
            guard ProjectDigest.sha256(
                wavData
            ) == metadata.audioRevision else {
                throw ProjectStoreError.invalidData(
                    "Paragraph cache audio hash does not match metadata."
                )
            }

            let audio =
                try ProjectWAVCodec.decode(
                    wavData
                )
            guard audio.sampleRate
                    == metadata.sampleRate,
                  audio.samples.count
                    == metadata.sampleCount else {
                throw ProjectStoreError.invalidData(
                    "Paragraph cache sample identity does not match metadata."
                )
            }

            return CachedParagraphAudio(
                metadata: metadata,
                audio: audio
            )
        } catch {
            removeParagraph(
                cacheKey: cacheKey
            )
            return nil
        }
    }

    func storeParagraph(
        cacheKey: String,
        itemID: UUID,
        paragraphIndex: Int,
        paragraphText: String,
        generationKey: String,
        resolved: ResolvedNarrationSettings,
        runtimeRevision: String,
        synthesisConfigVersion: Int,
        sourceRange: AudioSourceRange,
        audio: KokoroAudio
    ) throws -> CachedParagraphAudio {
        try ReadAloudSafety.validate(audio, maximumSamples: ReadAloudSafety.maximumParagraphSamples)
        guard audio.sampleRate
                == ProjectWAVCodec.requiredSampleRate,
              !audio.samples.isEmpty else {
            throw ProjectStoreError.invalidData(
                "Paragraph cache requires non-empty 24 kHz mono audio."
            )
        }

        let paragraphRevision =
            ProjectDigest.sha256(
                paragraphText
            )
        let wavData =
            try ProjectWAVCodec.encode(
                samples: audio.samples,
                sampleRate: audio.sampleRate
            )
        let audioRevision =
            ProjectDigest.sha256(wavData)

        let metadata =
            ParagraphCacheMetadata(
                cacheKey: cacheKey,
                itemID: itemID,
                paragraphIndex:
                    paragraphIndex,
                paragraphRevision:
                    paragraphRevision,
                generationKey:
                    generationKey,
                voiceID: resolved.voiceID,
                speed: resolved.speed,
                runtimeRevision:
                    runtimeRevision,
                synthesisConfigVersion:
                    synthesisConfigVersion,
                sourceRange: sourceRange,
                sampleRate:
                    audio.sampleRate,
                sampleCount:
                    audio.samples.count,
                audioRevision:
                    audioRevision
            )

        try validate(
            metadata,
            cacheKey: cacheKey,
            itemID: itemID,
            paragraphIndex:
                paragraphIndex,
            paragraphText:
                paragraphText,
            generationKey:
                generationKey,
            resolved: resolved,
            runtimeRevision:
                runtimeRevision,
            synthesisConfigVersion:
                synthesisConfigVersion,
            sourceRange:
                sourceRange
        )

        try fileManager.createDirectory(
            at: paragraphCacheDirectory,
            withIntermediateDirectories: true
        )

        try ProjectAtomicWriter.write(
            wavData,
            to: paragraphWAV(
                cacheKey: cacheKey
            ),
            temporaryDirectory:
                temporaryDirectory,
            fileManager: fileManager
        )
        try ProjectAtomicWriter.write(
            metadata,
            to: paragraphMetadata(
                cacheKey: cacheKey
            ),
            temporaryDirectory:
                temporaryDirectory,
            fileManager: fileManager
        )

        return CachedParagraphAudio(
            metadata: metadata,
            audio: audio
        )
    }

    func clearAllParagraphCache()
        throws
    {
        guard fileManager.fileExists(
            atPath:
                paragraphCacheDirectory
                    .path
        ) else {
            return
        }

        let entries =
            try fileManager
                .contentsOfDirectory(
                    at:
                        paragraphCacheDirectory,
                    includingPropertiesForKeys:
                        nil,
                    options: []
                )

        for entry in entries {
            try fileManager
                .removeItem(at: entry)
        }
    }

    func clearParagraphCache(
        itemIDs: Set<UUID>
    ) throws {
        guard !itemIDs.isEmpty,
              fileManager.fileExists(
                atPath:
                    paragraphCacheDirectory
                        .path
              )
        else {
            return
        }

        let entries =
            try fileManager
                .contentsOfDirectory(
                    at:
                        paragraphCacheDirectory,
                    includingPropertiesForKeys:
                        nil,
                    options:
                        [.skipsHiddenFiles]
                )

        for metadataURL in entries
            where metadataURL.pathExtension
                == "json"
        {
            guard let data =
                    try? Data(
                        contentsOf:
                            metadataURL
                    ),
                  let metadata =
                    try? ProjectJSONCodec
                        .decode(
                            ParagraphCacheMetadata.self,
                            from: data,
                            relativePath:
                                "cache/paragraphs/\(metadataURL.lastPathComponent)"
                        ),
                  itemIDs.contains(
                    metadata.itemID
                  )
            else {
                continue
            }

            removeParagraph(
                cacheKey:
                    metadata.cacheKey
            )
        }
    }

    func removeParagraph(
        cacheKey: String
    ) {
        for url in [
            paragraphWAV(
                cacheKey: cacheKey
            ),
            paragraphMetadata(
                cacheKey: cacheKey
            ),
        ] where fileManager.fileExists(
            atPath: url.path
        ) {
            try? fileManager.removeItem(
                at: url
            )
        }
    }

    private func validate(
        _ metadata:
            ParagraphCacheMetadata,
        cacheKey: String,
        itemID: UUID,
        paragraphIndex: Int,
        paragraphText: String,
        generationKey: String,
        resolved: ResolvedNarrationSettings,
        runtimeRevision: String,
        synthesisConfigVersion: Int,
        sourceRange: AudioSourceRange
    ) throws {
        guard metadata.schemaVersion == 1,
              metadata.cacheKey == cacheKey,
              ProjectDigest.isSHA256(
                metadata.cacheKey
              ),
              metadata.itemID == itemID,
              metadata.paragraphIndex
                == paragraphIndex,
              metadata.paragraphRevision
                == ProjectDigest.sha256(
                    paragraphText
                ),
              metadata.generationKey
                == generationKey,
              metadata.voiceID
                == resolved.voiceID,
              metadata.speed
                == resolved.speed,
              metadata.runtimeRevision
                == runtimeRevision,
              metadata
                .synthesisConfigVersion
                == synthesisConfigVersion,
              metadata.sourceRange
                == sourceRange,
              metadata.sampleRate
                == ProjectWAVCodec
                    .requiredSampleRate,
              metadata.sampleCount > 0,
              ProjectDigest.isSHA256(
                metadata.audioRevision
              ) else {
            throw ProjectStoreError.invalidData(
                "Paragraph cache metadata is incompatible."
            )
        }
    }

    private func paragraphWAV(
        cacheKey: String
    ) -> URL {
        paragraphCacheDirectory.appending(
            path: "\(cacheKey).wav"
        )
    }

    private func paragraphMetadata(
        cacheKey: String
    ) -> URL {
        paragraphCacheDirectory.appending(
            path: "\(cacheKey).json"
        )
    }
}



