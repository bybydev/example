import AVFoundation
import CryptoKit
import Foundation

enum IOSImportDisposition: String, Hashable, Sendable {
    case separateProjects
    case combineAsClips
}

struct IOSImportInput: Sendable, Identifiable {
    let id: UUID
    let localURL: URL
    let origin: IOSMediaOrigin
    let displayName: String

    init(id: UUID = UUID(), localURL: URL, origin: IOSMediaOrigin, displayName: String? = nil) {
        self.id = id
        self.localURL = localURL
        self.origin = origin
        self.displayName = displayName ?? localURL.lastPathComponent
    }
}

struct IOSImportFailure: Sendable, Identifiable {
    let id: UUID
    let filename: String
    let reason: String
}

struct IOSImportResult: Sendable {
    let documents: [IOSProjectDocument]
    let failures: [IOSImportFailure]
}

/// Non-UI ingress for Files, iCloud/document providers, Photos transferable
/// files and HTTPS direct downloads.
/// Source-picker, permissions and review UI must supply the actual URLs.
actor IOSMediaImporter {
    private let repository: IOSProjectRepository
    private let files = FileManager.default

    init(repository: IOSProjectRepository) {
        self.repository = repository
    }

    func importFiles(
        _ inputs: [IOSImportInput], disposition: IOSImportDisposition,
        preset: IOSCanvasPreset = .original, customCanvas: IOSCanvas? = nil,
        title: String? = nil
    ) async throws -> IOSImportResult {
        guard !inputs.isEmpty else {
            throw IOSProjectStoreError.invalidDocument("No media selected")
        }
        if preset == .custom {
            guard let customCanvas else {
                throw IOSProjectStoreError.invalidDocument("Custom project dimensions are required")
            }
            try customCanvas.validate()
        }
        switch disposition {
        case .combineAsClips:
            let document = try await createProject(inputs, preset: preset,
                                                   customCanvas: customCanvas, title: title)
            return IOSImportResult(documents: [document], failures: [])
        case .separateProjects:
            var completed: [IOSProjectDocument] = []
            var failures: [IOSImportFailure] = []
            for input in inputs {
                try Task.checkCancellation()
                do {
                    if let existing = try? await repository.open(input.id) {
                        completed.append(existing)
                        continue
                    }
                    completed.append(try await createProject([input], preset: preset,
                                               customCanvas: customCanvas, title: nil,
                                               projectID: input.id))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failures.append(IOSImportFailure(id: input.id,
                                                    filename: input.displayName,
                                                    reason: error.localizedDescription))
                }
            }
            return IOSImportResult(documents: completed, failures: failures)
        }
    }

    /// No streaming site scraping or DRM bypass: this is direct HTTPS media only.
    /// Caller must obtain explicit media rights confirmation before this is called.
    func importDirectURL(_ remoteURL: URL, rightsConfirmed: Bool,
                         preset: IOSCanvasPreset = .original) async throws -> IOSProjectDocument {
        guard rightsConfirmed else { throw IOSProjectStoreError.rightsNotConfirmed }
        guard remoteURL.scheme?.lowercased() == "https",
              remoteURL.host != nil, remoteURL.user == nil,
              remoteURL.password == nil else {
            throw IOSProjectStoreError.unsupportedURL
        }
        try Task.checkCancellation()
        let directory = files.temporaryDirectory
            .appendingPathComponent("InkribeURLImports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: directory) }
        let temporary = directory.appendingPathComponent("media")
        guard files.createFile(atPath: temporary.path, contents: nil) else {
            throw IOSProjectStoreError.unavailableRoot
        }
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }

        // Stream into our own bounded file instead of letting a download task
        // finish an arbitrarily large temporary file before checking its size.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            return try await withTaskCancellationHandler {
                let (bytes, response) = try await session.bytes(from: remoteURL)
                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode),
                      http.url?.scheme?.lowercased() == "https" else {
                    throw IOSProjectStoreError.unsupportedURL
                }
                let maximumRemoteBytes: Int64 = 16 * 1024 * 1024 * 1024
                guard http.expectedContentLength < 0 ||
                      http.expectedContentLength <= maximumRemoteBytes else {
                    throw IOSProjectStoreError.oversizedImport
                }
                let bufferSize = 64 * 1024
                var buffer = Data()
                buffer.reserveCapacity(bufferSize)
                var received: Int64 = 0
                for try await byte in bytes {
                    // Count actual bytes too: Content-Length may be absent or
                    // wrong, and decoded response bytes may exceed that header.
                    guard received < maximumRemoteBytes else {
                        throw IOSProjectStoreError.oversizedImport
                    }
                    received += 1
                    buffer.append(byte)
                    if buffer.count == bufferSize {
                        try Task.checkCancellation()
                        try output.write(contentsOf: buffer)
                        buffer.removeAll(keepingCapacity: true)
                    }
                }
                try Task.checkCancellation()
                guard received > 0 else { throw IOSProjectStoreError.unsupportedMedia }
                if !buffer.isEmpty { try output.write(contentsOf: buffer) }
                try output.synchronize()
                try output.close()
                let name = remoteURL.lastPathComponent.isEmpty
                    ? "Imported Media" : remoteURL.lastPathComponent
                return try await createProject(
                    [IOSImportInput(localURL: temporary, origin: .directURL, displayName: name)],
                    preset: preset, customCanvas: nil, title: name
                )
            } onCancel: {
                session.invalidateAndCancel()
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private func createProject(
        _ inputs: [IOSImportInput], preset: IOSCanvasPreset,
        customCanvas: IOSCanvas?, title: String?,
        projectID: UUID? = nil
    ) async throws -> IOSProjectDocument {
        if let projectID, let existing = try? await repository.open(projectID) {
            return existing
        }
        let staging = try await repository.makeStagingDirectory()
        do {
            var assets: [IOSSourceAsset] = []
            var clips: [IOSProjectClip] = []
            var end = MediaTime.zero
            for input in inputs {
                try Task.checkCancellation()
                let adopted = try copySource(input, into: staging)
                let (kind, metadata) = try await IOSMediaInspector.inspect(url: adopted.url)
                let asset = IOSSourceAsset(
                    id: adopted.id, relativeOriginalPath: adopted.path, kind: kind,
                    origin: input.origin, displayName: String(input.displayName.prefix(512)),
                    byteCount: adopted.size, sha256: adopted.digest,
                    metadata: metadata
                )
                assets.append(asset)
                let sourceInterval = try MediaInterval(start: .zero, end: metadata.duration)
                let mapping = try IdentityClipMapping(sourceAssetID: asset.id,
                                                       sourceInterval: sourceInterval,
                                                       timelineStart: end)
                clips.append(IOSProjectClip(id: mapping.clipID,
                                            sourceAssetID: asset.id,
                                            sourceInterval: mapping.sourceInterval,
                                            timelineInterval: mapping.timelineInterval))
                end = mapping.timelineInterval.end
            }
            try Task.checkCancellation()
            let firstVideo = assets.first(where: { $0.kind == .video })?.metadata
            let natural = IOSCanvas(width: max(64, firstVideo?.displayedWidth ?? 1080),
                                    height: max(64, firstVideo?.displayedHeight ?? 1080))
            let dimensions = preset.canvas ?? (preset == .custom ? customCanvas : nil) ?? natural
            try dimensions.validate()
            let rawTitle = title ?? inputs.first?.displayName ?? "Untitled Project"
            let safeTitle = String(rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256))
            let now = Date()
            let document = IOSProjectDocument(
                schemaVersion: IOSProjectSchema.current,
                id: projectID ?? UUID(), contentRevision: 1,
                title: safeTitle.isEmpty ? "Untitled Project" : safeTitle,
                createdAt: now, updatedAt: now,
                preset: preset, canvas: dimensions,
                assets: assets, clips: clips
            )
            return try await repository.commitNew(document, stagedAt: staging)
        } catch {
            try? await repository.discardStaging(staging)
            throw error
        }
    }

    private struct CopiedMedia {
        let id: UUID
        let path: String
        let url: URL
        let size: Int64
        let digest: String
    }

    /// Copies in bounded chunks, checking cancellation between chunks and before
    /// publishing. NSFileCoordinator makes document-provider/iCloud reads stable.
    nonisolated private func copySource(_ input: IOSImportInput, into staging: URL) throws -> CopiedMedia {
        let files = FileManager.default
        guard input.localURL.isFileURL else { throw IOSProjectStoreError.unsupportedURL }
        let id = UUID()
        let ext = URL(fileURLWithPath: input.displayName).pathExtension
            .lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let suffix = String(ext.prefix(12))
        let path = "Originals/" + id.uuidString + (suffix.isEmpty ? "" : "." + suffix)
        let destination = try IOSOwnedPath.secureURL(for: path, base: "Originals", in: staging)

        let granted = input.localURL.startAccessingSecurityScopedResource()
        defer { if granted { input.localURL.stopAccessingSecurityScopedResource() } }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var outcome: Result<CopiedMedia, Error>?
        coordinator.coordinate(readingItemAt: input.localURL, options: [],
                               error: &coordinationError) { readable in
            outcome = Result {
                let sourceSize = (try? files.attributesOfItem(atPath: readable.path)[.size] as? NSNumber)?.int64Value
                let available = try? staging.resourceValues(forKeys: [
                    .volumeAvailableCapacityForImportantUsageKey
                ]).volumeAvailableCapacityForImportantUsage
                if let sourceSize, let available, sourceSize > max(0, available - 16_777_216) {
                    throw IOSProjectStoreError.insufficientSpace
                }
                let inputHandle = try FileHandle(forReadingFrom: readable)
                defer { try? inputHandle.close() }
                guard files.createFile(atPath: destination.path, contents: nil) else {
                    throw IOSProjectStoreError.unavailableRoot
                }
                let outputHandle = try FileHandle(forWritingTo: destination)
                defer { try? outputHandle.close() }
                var hasher = SHA256()
                var size: Int64 = 0
                while true {
                    try Task.checkCancellation()
                    guard let chunk = try inputHandle.read(upToCount: 1024 * 1024),
                          !chunk.isEmpty else { break }
                    let (next, overflow) = size.addingReportingOverflow(Int64(chunk.count))
                    guard !overflow else { throw IOSProjectStoreError.oversizedImport }
                    size = next
                    hasher.update(data: chunk)
                    try outputHandle.write(contentsOf: chunk)
                }
                guard size > 0 else { throw IOSProjectStoreError.unsupportedMedia }
                try outputHandle.synchronize()
                let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                return CopiedMedia(id: id, path: path, url: destination,
                                   size: size, digest: digest)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw IOSProjectStoreError.unavailableRoot }
        return try outcome.get()
    }
}

