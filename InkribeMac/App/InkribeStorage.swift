import Foundation
import InkribeAudio
import InkribeCore
import InkribePersistence
import InkribeTranscription

struct InkribeStorageSnapshot: Equatable, Sendable {
    let sourceMediaBytes: Int64
    let transcriptStoreBytes: Int64
    let queueStoreBytes: Int64
    let transcriptCount: Int

    var appDataBytes: Int64 {
        sourceMediaBytes + transcriptStoreBytes + queueStoreBytes
    }
}

struct InkribeMediaCleanupResult: Equatable, Sendable {
    let removedTranscriptCount: Int
    let reclaimedBytes: Int64
    let skippedTranscriptCount: Int
}

@MainActor
extension InkribeAppState {
    func storageSnapshot() async throws -> InkribeStorageSnapshot {
        let allTranscripts = try await transcripts()
        let transcriptCount = allTranscripts.count
        let mediaDirectory = try InkribeAppDirectories.mediaDirectoryURL()
        let transcriptStore = try InkribeAppDirectories.transcriptStoreURL()
        let queueStore = try InkribeAppDirectories.jobStoreURL()

        let sizes = try await Task.detached(priority: .utility) {
            (
                try InkribeStorageScanner.recursiveByteCount(at: mediaDirectory),
                InkribeStorageScanner.fileByteCount(at: transcriptStore),
                InkribeStorageScanner.fileByteCount(at: queueStore)
            )
        }.value

        return InkribeStorageSnapshot(
            sourceMediaBytes: sizes.0,
            transcriptStoreBytes: sizes.1,
            queueStoreBytes: sizes.2,
            transcriptCount: transcriptCount
        )
    }

    func removeSourceMediaForFinishedTranscripts() async throws -> InkribeMediaCleanupResult {
        guard let transcriptRepository,
              let mediaStore,
              let transcriptionQueue else {
            throw AppStateError.pipelineUnavailable
        }

        var removedCount = 0
        var skippedCount = 0
        var reclaimedBytes: Int64 = 0

        for var transcript in try await transcriptRepository.transcripts() {
            guard let relativePath = transcript.sourceMediaRelativePath else { continue }

            let relatedItems = transcriptionQueue.items.filter {
                $0.transcriptID == transcript.id
            }
            let canRemoveMedia = relatedItems.isEmpty || relatedItems.allSatisfy {
                $0.state == .complete
            }
            guard canRemoveMedia else {
                skippedCount += 1
                continue
            }

            let reference = DurableMediaReference(relativePath: relativePath)
            let mediaURL = try await mediaStore.url(for: reference)
            let mediaExists = FileManager.default.fileExists(atPath: mediaURL.path)
            let bytes = mediaExists ? InkribeStorageScanner.fileByteCount(at: mediaURL) : 0
            let original = transcript

            transcript.sourceMediaRelativePath = nil
            transcript.updatedAt = .now
            try await transcriptRepository.save(transcript)

            if mediaExists {
                do {
                    try await mediaStore.remove(reference)
                } catch {
                    try? await transcriptRepository.save(original)
                    throw error
                }
            }

            removedCount += 1
            reclaimedBytes += bytes
        }

        return InkribeMediaCleanupResult(
            removedTranscriptCount: removedCount,
            reclaimedBytes: reclaimedBytes,
            skippedTranscriptCount: skippedCount
        )
    }
}

private enum InkribeStorageScanner {
    nonisolated static func fileByteCount(at url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let size = values.fileSize else {
            return 0
        }
        return Int64(size)
    }

    nonisolated static func recursiveByteCount(at directory: URL) throws -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            if values.isRegularFile == true, let fileSize = values.fileSize {
                total += Int64(fileSize)
            }
        }
        return total
    }
}
