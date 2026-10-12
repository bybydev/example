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

        executionQueue.eventHandler = {
            [weak self] event in
            self?.handle(event)
        }

        try executionQueue.start()

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

    func setPlaybackActive(
        _ isActive: Bool
    ) {
        guard let executionQueue
        else {
            return
        }

        do {
            if isActive || ReadAloudPreferences.backgroundPrefetchPaused {
                if !executionQueue.isPaused {
                    try executionQueue.pause()
                }
            } else {
                if executionQueue.isPaused {
                    try executionQueue.resume()
                }
                try reconcile()
            }
        } catch {
            runtime?.lastErrorMessage =
                Self.message(for: error)
        }
    }

    func shutdown() {
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

        if (runtime?.blocksQueuedGeneration == true
            || ReadAloudPreferences.backgroundPrefetchPaused),
           !executionQueue.isPaused
        {
            try executionQueue.pause()
        }
    }

    private func handle(
        _ event: JobQueueEvent
    ) {
        guard let runtime else {
            return
        }

        switch event {
        case .jobStarted(let id):
            Task {
                await runtime
                    .generationJobStarted(
                        id
                    )
            }

        case .jobPausing(let id):
            Task {
                await runtime
                    .generationJobYielded(
                        id
                    )
            }

        case .jobCompleted(let id):
            Task {
                await runtime
                    .generationJobCompleted(
                        id
                    )
            }

        case .jobFailed(
            let id,
            let errorDescription
        ):
            Task {
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

