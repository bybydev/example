import CryptoKit
import Foundation

/// One document repository per app process. Views, imports, transcription and editor
/// sessions must all receive this same instance, never create per-screen stores.
actor IOSProjectRepository {
    static let shared = IOSProjectRepository()

    private let overrideRoot: URL?
    private let files = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(root: URL? = nil) {
        overrideRoot = root
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    private func root() throws -> URL {
        if let overrideRoot { return overrideRoot.standardizedFileURL }
        guard let appSupport = files.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw IOSProjectStoreError.unavailableRoot
        }
        return appSupport.appendingPathComponent("InkribeIOSProjects", isDirectory: true)
    }

    private func directory(_ name: String) throws -> URL {
        let url = try root().appendingPathComponent(name, isDirectory: true)
        try files.createDirectory(at: url, withIntermediateDirectories: true)
        if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw IOSProjectStoreError.invalidPath(url.path)
        }
        return url
    }

    private func projectDirectory(_ id: UUID) throws -> URL {
        try directory("Projects").appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func documentURL(in project: URL) -> URL {
        project.appendingPathComponent("document.json")
    }

    private func recoveryURL(in project: URL) -> URL {
        project.appendingPathComponent("document.previous.json")
    }

    func makeStagingDirectory() throws -> URL {
        let url = try directory("Pending").appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: url.appendingPathComponent("Originals", isDirectory: true),
                                  withIntermediateDirectories: true)
        return url
    }

    func discardStaging(_ url: URL) throws {
        let parent = try directory("Pending").resolvingSymlinksInPath().standardizedFileURL
        guard url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL == parent,
              UUID(uuidString: url.lastPathComponent) != nil else {
            throw IOSProjectStoreError.invalidPath(url.path)
        }
        if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
    }

    /// The staging directory is on the same volume as Projects. One final rename
    /// publishes a complete immutable set of originals and a validated document.
    func commitNew(_ document: IOSProjectDocument, stagedAt staging: URL) throws -> IOSProjectDocument {
        try Task.checkCancellation()
        try document.validate()
        let pending = try directory("Pending").resolvingSymlinksInPath().standardizedFileURL
        guard staging.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL == pending,
              UUID(uuidString: staging.lastPathComponent) != nil else {
            throw IOSProjectStoreError.invalidPath(staging.path)
        }
        let destination = try projectDirectory(document.id)
        guard !files.fileExists(atPath: destination.path) else {
            throw IOSProjectStoreError.duplicateProject(document.id)
        }
        try verifyOriginals(of: document, in: staging)
        let encoded = try encoder.encode(document)
        try encoded.write(to: documentURL(in: staging), options: .atomic)
        try Task.checkCancellation()
        try files.moveItem(at: staging, to: destination)
        return document
    }

    /// Do not report a successful edit until the complete document was atomically
    /// committed. A previous valid JSON copy remains available for recovery.
    func commitEdit(_ proposed: IOSProjectDocument, expectedRevision: UInt64) throws -> IOSProjectDocument {
        let current = try open(proposed.id)
        guard current.contentRevision == expectedRevision else {
            throw IOSProjectStoreError.staleRevision(expected: expectedRevision,
                                                      actual: current.contentRevision)
        }
        guard expectedRevision < UInt64.max else { throw ProjectEditConflict.revisionOverflow }
        var next = proposed
        next.schemaVersion = IOSProjectSchema.current
        next.contentRevision = expectedRevision + 1
        next.updatedAt = Date()
        guard next.id == current.id, next.createdAt == current.createdAt else {
            throw IOSProjectStoreError.invalidDocument("Project identity cannot be rewritten")
        }
        if let raw = current.recognition {
            guard let proposed = next.recognition, proposed.id == raw.id,
                  proposed.rawWindows == raw.rawWindows, proposed.modelID == raw.modelID,
                  proposed.modelSHA256 == raw.modelSHA256,
                  proposed.requestedLanguageCode == raw.requestedLanguageCode,
                  proposed.completedAt == raw.completedAt else {
                throw IOSProjectStoreError.invalidDocument("Raw recognition is immutable")
            }
        }
        let existing = Dictionary(uniqueKeysWithValues: current.assets.map { ($0.id, $0) })
        for asset in next.assets {
            guard existing[asset.id] == asset else {
                throw IOSProjectStoreError.invalidDocument("Existing originals are immutable")
            }
        }
        guard Set(next.assets.map(\.id)) == Set(current.assets.map(\.id)) else {
            throw IOSProjectStoreError.invalidDocument("Use the importer to add originals")
        }
        try next.validate()
        let directory = try projectDirectory(next.id)
        try verifyOriginals(of: next, in: directory)
        let url = documentURL(in: directory)
        let previous = recoveryURL(in: directory)
        // Never replace the prior recovery point before a valid new document is ready.
        let data = try encoder.encode(next)
        let backup = try encoder.encode(current)
        try backup.write(to: previous, options: .atomic)
        try data.write(to: url, options: .atomic)
        return next
    }

    /// One atomic publication of raw output and editable captions. The job ID
    /// handles a crash after publication but before JobQueue marks completion.
    func saveRecognition(_ result: IOSRecognition, projectID: UUID,
                         expectedRevision: UInt64) throws {
        try Task.checkCancellation()
        var current = try open(projectID)
        if current.recognition?.id == result.id { return }
        guard current.recognition == nil else { throw IOSSpeechError.alreadyTranscribed }
        guard current.contentRevision == expectedRevision else {
            throw IOSProjectStoreError.staleRevision(expected: expectedRevision,
                                                      actual: current.contentRevision)
        }
        current.recognition = result
        _ = try commitEdit(current, expectedRevision: expectedRevision)
    }

    func rename(_ id: UUID, title: String, expectedRevision: UInt64) throws -> IOSProjectDocument {
        var value = try open(id)
        value.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return try commitEdit(value, expectedRevision: expectedRevision)
    }

    func open(_ id: UUID) throws -> IOSProjectDocument {
        let directory = try projectDirectory(id)
        guard files.fileExists(atPath: directory.path) else { throw IOSProjectStoreError.missingProject(id) }
        let document: IOSProjectDocument
        do {
            document = try read(documentURL(in: directory))
        } catch IOSProjectStoreError.unsupportedSchema(let version) {
            throw IOSProjectStoreError.unsupportedSchema(version)
        } catch {
            // A corrupt last write never causes an implicit destructive reset.
            document = try read(recoveryURL(in: directory))
        }
        guard document.id == id else {
            throw IOSProjectStoreError.invalidDocument("Directory and document identities differ")
        }
        return document
    }

    private func read(_ url: URL) throws -> IOSProjectDocument {
        let data = try Data(contentsOf: url)
        if let header = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = header["schemaVersion"] as? Int,
           version > IOSProjectSchema.current {
            throw IOSProjectStoreError.unsupportedSchema(version)
        }
        let document = try decoder.decode(IOSProjectDocument.self, from: data)
        try document.validate()
        return document
    }


    /// Explicit integrity review (not on every library list/launch). Hash
    /// verification is streamed and cannot silently rewrite corrupted media.
    func integrityIssues(projectID: UUID) throws -> [IOSLibraryIssue] {
        let project = try open(projectID)
        var issues: [IOSLibraryIssue] = []
        for asset in project.assets {
            do {
                let url = try sourceURL(projectID: projectID, assetID: asset.id)
                let input = try FileHandle(forReadingFrom: url)
                defer { try? input.close() }
                var digest = SHA256()
                var bytes: Int64 = 0
                while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                    try Task.checkCancellation()
                    let (sum, overflow) = bytes.addingReportingOverflow(Int64(chunk.count))
                    guard !overflow else { throw IOSProjectStoreError.oversizedImport }
                    bytes = sum
                    digest.update(data: chunk)
                }
                let actualHash = digest.finalize().map { String(format: "%02x", $0) }.joined()
                if bytes != asset.byteCount || actualHash != asset.sha256 {
                    issues.append(IOSLibraryIssue(id: asset.id,
                                                  description: "Original media integrity check failed: " + asset.displayName))
                }
            } catch {
                issues.append(IOSLibraryIssue(id: asset.id,
                                              description: asset.displayName + ": " + error.localizedDescription))
            }
        }
        return issues
    }

    func sourceURL(projectID: UUID, assetID: UUID) throws -> URL {
        let project = try open(projectID)
        guard let asset = project.assets.first(where: { $0.id == assetID }) else {
            throw IOSProjectStoreError.invalidDocument("Asset is not in this project")
        }
        let url = try IOSOwnedPath.secureURL(for: asset.relativeOriginalPath,
                                             base: "Originals", in: projectDirectory(projectID))
        guard files.fileExists(atPath: url.path) else {
            throw IOSProjectStoreError.missingOriginal(asset.displayName)
        }
        return url
    }

    func list(titleQuery: String = "", sort: IOSLibrarySort = .recent,
              filter: IOSLibraryFilter = .all) throws -> IOSLibrarySnapshot {
        let base = try directory("Projects")
        let children = try files.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
        var projects: [IOSProjectSummary] = []
        var issues: [IOSLibraryIssue] = []
        for child in children where child.hasDirectoryPath {
            guard let id = UUID(uuidString: child.lastPathComponent) else { continue }
            do {
                let document = try open(id)
                let available = (try? originalsExist(of: document, in: child)) ?? false
                let matches: Bool
                switch filter {
                case .all: matches = true
                case .video: matches = document.assets.contains { $0.kind == .video }
                case .audio: matches = !document.assets.contains { $0.kind == .video }
                case .missingMedia: matches = !available
                }
                guard matches, titleQuery.isEmpty ||
                      document.title.localizedStandardContains(titleQuery) else { continue }
                let duration = document.clips.map(\.timelineInterval.end).max() ?? .zero
                let cache = try? thumbnailURL(id: id)
                projects.append(IOSProjectSummary(
                    id: id, title: document.title, updatedAt: document.updatedAt,
                    duration: duration,
                    mediaKind: document.assets.contains { $0.kind == .video } ? .video : .audio,
                    available: available,
                    thumbnailURL: cache.flatMap { files.fileExists(atPath: $0.path) ? $0 : nil }
                ))
                if !available { issues.append(IOSLibraryIssue(id: id, description: "Original media is missing")) }
            } catch {
                issues.append(IOSLibraryIssue(id: id, description: error.localizedDescription))
            }
        }
        switch sort {
        case .recent: projects.sort { $0.updatedAt > $1.updatedAt }
        case .oldest: projects.sort { $0.updatedAt < $1.updatedAt }
        case .title: projects.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        return IOSLibrarySnapshot(projects: projects, issues: issues)
    }

    /// Duplicates own physical originals. Clip and asset instance IDs never alias
    /// a previous project, so later deletion cannot break another document.
    func duplicate(_ id: UUID) throws -> IOSProjectDocument {
        let original = try open(id)
        let staging = try makeStagingDirectory()
        do {
            var newAssets: [IOSSourceAsset] = []
            var mapping: [UUID: UUID] = [:]
            for asset in original.assets {
                let newID = UUID()
                mapping[asset.id] = newID
                let ext = URL(fileURLWithPath: asset.relativeOriginalPath).pathExtension
                let name = newID.uuidString + (ext.isEmpty ? "" : "." + ext)
                let path = "Originals/" + name
                let origin = try sourceURL(projectID: id, assetID: asset.id)
                let destination = try IOSOwnedPath.secureURL(for: path, base: "Originals", in: staging)
                try files.copyItem(at: origin, to: destination)
                newAssets.append(IOSSourceAsset(id: newID, relativeOriginalPath: path,
                    kind: asset.kind, origin: asset.origin, displayName: asset.displayName,
                    byteCount: asset.byteCount, sha256: asset.sha256, metadata: asset.metadata))
            }
            var clipMapping: [UUID: UUID] = [:]
            let newClips = try original.clips.map { clip -> IOSProjectClip in
                guard let targetID = mapping[clip.sourceAssetID] else {
                    throw IOSProjectStoreError.invalidDocument("Missing duplicated asset mapping")
                }
                let clipID = UUID()
                clipMapping[clip.id] = clipID
                return IOSProjectClip(id: clipID, sourceAssetID: targetID,
                    sourceInterval: clip.sourceInterval, timelineInterval: clip.timelineInterval)
            }
            let now = Date()
            let copy = IOSProjectDocument(schemaVersion: IOSProjectSchema.current,
                id: UUID(), contentRevision: 1, title: original.title + " Copy",
                createdAt: now, updatedAt: now, preset: original.preset,
                canvas: original.canvas, assets: newAssets, clips: newClips,
                recognition: original.recognition?.duplicated(assetClips: clipMapping))
            return try commitNew(copy, stagedAt: staging)
        } catch {
            try? discardStaging(staging)
            throw error
        }
    }

    /// Explicit user deletion moves a *whole* project to recoverable Trash.
    /// Neither cache clearing nor pruning pending imports calls this.
    func moveToTrash(_ id: UUID) throws {
        _ = try open(id)
        let destination = try directory("Trash").appendingPathComponent(id.uuidString)
        guard !files.fileExists(atPath: destination.path) else {
            throw IOSProjectStoreError.duplicateProject(id)
        }
        try files.moveItem(at: projectDirectory(id), to: destination)
        let thumbnail = try thumbnailURL(id: id)
        try? files.removeItem(at: thumbnail)
    }

    func restoreFromTrash(_ id: UUID) throws {
        let source = try directory("Trash").appendingPathComponent(id.uuidString)
        let destination = try projectDirectory(id)
        guard !files.fileExists(atPath: destination.path) else {
            throw IOSProjectStoreError.duplicateProject(id)
        }
        guard files.fileExists(atPath: source.path) else {
            throw IOSProjectStoreError.missingProject(id)
        }
        try files.moveItem(at: source, to: destination)
        _ = try open(id)
    }

    /// Recover fully committed staging documents left between atomic JSON
    /// publication and the directory rename. Incomplete copies stay quarantined
    /// for explicit cleanup; nothing is silently deleted at startup.
    func recoverCommittedStaging() throws -> [UUID] {
        let pending = try directory("Pending")
        let entries = try files.contentsOfDirectory(at: pending, includingPropertiesForKeys: nil)
        var recovered: [UUID] = []
        for staging in entries where staging.hasDirectoryPath {
            guard UUID(uuidString: staging.lastPathComponent) != nil,
                  files.fileExists(atPath: documentURL(in: staging).path),
                  let document = try? read(documentURL(in: staging)),
                  (try? verifyOriginals(of: document, in: staging)) != nil else { continue }
            let destination = try projectDirectory(document.id)
            guard !files.fileExists(atPath: destination.path) else { continue }
            try files.moveItem(at: staging, to: destination)
            recovered.append(document.id)
        }
        return recovered
    }

    /// Explicitly discard incomplete imports by their staging UUID after
    /// showing the user's recoverable-space summary. Never touches Projects.
    func pendingStagingIDs() throws -> [UUID] {
        try files.contentsOfDirectory(at: directory("Pending"),
                                      includingPropertiesForKeys: nil)
            .compactMap { UUID(uuidString: $0.lastPathComponent) }
    }

    func discardPendingImport(id: UUID) throws {
        try discardStaging(try directory("Pending").appendingPathComponent(id.uuidString))
    }


    struct TrashedProject: Identifiable, Sendable {
        let id: UUID
        let title: String
    }

    func trashedProjects() throws -> [TrashedProject] {
        let trash = try directory("Trash")
        return try files.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)
            .compactMap { entry -> TrashedProject? in
                guard let id = UUID(uuidString: entry.lastPathComponent),
                      let document = try? read(documentURL(in: entry)),
                      document.id == id else { return nil }
                return TrashedProject(id: id, title: document.title)
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Explicitly destructive action, called only after user confirmation.
    func emptyTrash() throws {
        let trash = try directory("Trash")
        for child in try files.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil) {
            guard UUID(uuidString: child.lastPathComponent) != nil,
                  child.deletingLastPathComponent() == trash else { continue }
            try files.removeItem(at: child)
        }
    }

    /// Restore only byte-identical originals. Never silently replace a
    /// different media file or rewrite the document's source identities.
    func restoreMissingOriginal(
        projectID: UUID, assetID: UUID, from externalURL: URL
    ) throws {
        let document = try open(projectID)
        guard let source = document.assets.first(where: { $0.id == assetID }) else {
            throw IOSProjectStoreError.invalidDocument("Unknown media identity")
        }
        let destination = try IOSOwnedPath.secureURL(for: source.relativeOriginalPath,
                                                     base: "Originals",
                                                     in: projectDirectory(projectID))
        guard !files.fileExists(atPath: destination.path) else {
            throw IOSProjectStoreError.invalidDocument("The original still exists; it was not replaced")
        }
        guard externalURL.isFileURL else { throw IOSProjectStoreError.unsupportedURL }
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent("." + UUID().uuidString + ".relink")
        let granted = externalURL.startAccessingSecurityScopedResource()
        defer { if granted { externalURL.stopAccessingSecurityScopedResource() } }
        defer { try? files.removeItem(at: temp) }
        let fileManager = FileManager.default
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var outcome: Result<Void, Error>?
        coordinator.coordinate(readingItemAt: externalURL, options: [], error: &coordinationError) { readable in
            outcome = Result {
                let input = try FileHandle(forReadingFrom: readable)
                defer { try? input.close() }
                guard fileManager.createFile(atPath: temp.path, contents: nil) else {
                    throw IOSProjectStoreError.unavailableRoot
                }
                let output = try FileHandle(forWritingTo: temp)
                defer { try? output.close() }
                var bytes: Int64 = 0
                var hash = SHA256()
                while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                    try Task.checkCancellation()
                    let (newCount, overflow) = bytes.addingReportingOverflow(Int64(chunk.count))
                    guard !overflow, newCount <= source.byteCount else {
                        throw IOSProjectStoreError.invalidDocument("Replacement does not match original length")
                    }
                    bytes = newCount
                    hash.update(data: chunk)
                    try output.write(contentsOf: chunk)
                }
                let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
                guard bytes == source.byteCount, digest == source.sha256 else {
                    throw IOSProjectStoreError.invalidDocument(
                        "Selected file is not byte-identical to the original"
                    )
                }
                try output.synchronize()
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw IOSProjectStoreError.unavailableRoot }
        try outcome.get()
        try files.moveItem(at: temp, to: destination)
    }

    func thumbnailURL(id: UUID) throws -> URL {
        var cache = try directory("Cache").appendingPathComponent("Thumbnails", isDirectory: true)
        try files.createDirectory(at: cache, withIntermediateDirectories: true)
        var properties = URLResourceValues()
        properties.isExcludedFromBackup = true
        try? cache.setResourceValues(properties)
        return cache.appendingPathComponent(id.uuidString + ".jpg")
    }

    func purgeDerivedCache() throws {
        let cache = try directory("Cache")
        let items = try files.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
        for item in items { try files.removeItem(at: item) }
    }

    struct StorageUsage: Sendable {
        let projectBytes: Int64
        let cacheBytes: Int64
        let pendingBytes: Int64
        let trashBytes: Int64
    }

    func storageUsage() throws -> StorageUsage {
        StorageUsage(projectBytes: try folderSize(try directory("Projects")),
                     cacheBytes: try folderSize(try directory("Cache")),
                     pendingBytes: try folderSize(try directory("Pending")),
                     trashBytes: try folderSize(try directory("Trash")))
    }

    private func folderSize(_ root: URL) throws -> Int64 {
        guard let walker = files.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey],
                                           options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { walker.skipDescendants(); continue }
            if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
        }
        return total
    }

    private func originalsExist(of project: IOSProjectDocument, in folder: URL) throws -> Bool {
        for asset in project.assets {
            let url = try IOSOwnedPath.secureURL(for: asset.relativeOriginalPath,
                                                 base: "Originals", in: folder)
            guard files.fileExists(atPath: url.path) else { return false }
        }
        return true
    }

    private func verifyOriginals(of document: IOSProjectDocument, in folder: URL) throws {
        for asset in document.assets {
            let url = try IOSOwnedPath.secureURL(for: asset.relativeOriginalPath,
                                                 base: "Originals", in: folder)
            guard files.fileExists(atPath: url.path) else {
                throw IOSProjectStoreError.missingOriginal(asset.displayName)
            }
            let attributes = try files.attributesOfItem(atPath: url.path)
            guard (attributes[.size] as? NSNumber)?.int64Value == asset.byteCount else {
                throw IOSProjectStoreError.invalidDocument("Original media file size changed")
            }
        }
    }
}
