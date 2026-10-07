import Foundation
import KokoroTTS
import Observation

@Observable
@MainActor
final class ProjectQueueController {
    private(set) var queue = ProjectQueueDocument()

    var waitingCount: Int {
        queue.jobs.filter { $0.state == .queued }.count
    }

    var generatingCount: Int {
        queue.jobs.filter { $0.state == .generating }.count
    }

    var failedCount: Int {
        queue.jobs.filter { $0.state == .failed }.count
    }

    var hasExecutingWork: Bool {
        generatingCount > 0
    }

    func publish(_ queue: ProjectQueueDocument) {
        self.queue = queue
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
            let metadataData =
                try Data(contentsOf: metadataURL)
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

            let wavData =
                try Data(contentsOf: wavURL)
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
