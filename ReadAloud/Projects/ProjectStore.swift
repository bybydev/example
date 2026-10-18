import Foundation
import PDFKitAudio

nonisolated enum ProjectStoreError: Error, LocalizedError, Equatable, Sendable {
    case projectNotFound(UUID)
    case projectAlreadyExists(UUID)
    case invalidPackage(String)
    case identityMismatch(expected: UUID, found: UUID)
    case unsupportedFutureSchema(relativePath: String, found: Int, current: Int)
    case unsupportedLegacySchema(relativePath: String, found: Int)
    case corruptDocument(relativePath: String, reason: String)
    case invalidData(String)
    case unsafeRelativePath(String)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .projectNotFound(let id):
            return "ReadAloud project not found: \(id.uuidString.lowercased())"
        case .projectAlreadyExists(let id):
            return "ReadAloud project already exists: \(id.uuidString.lowercased())"
        case .invalidPackage(let reason):
            return "Invalid ReadAloud project package: \(reason)"
        case .identityMismatch(let expected, let found):
            return "Project identity mismatch. Expected \(expected), found \(found)."
        case .unsupportedFutureSchema(let path, let found, let current):
            return "\(path) uses schema \(found), newer than supported schema \(current)."
        case .unsupportedLegacySchema(let path, let found):
            return "\(path) uses unsupported legacy schema \(found)."
        case .corruptDocument(let path, let reason):
            return "Corrupt ReadAloud document \(path): \(reason)"
        case .invalidData(let reason):
            return "Invalid ReadAloud project data: \(reason)"
        case .unsafeRelativePath(let path):
            return "Unsafe ReadAloud relative path: \(path)"
        case .io(let reason):
            return "ReadAloud project I/O failed: \(reason)"
        }
    }
}

nonisolated enum ProjectAtomicWriter {
    static func write<T: Encodable>(
        _ value: T,
        to destination: URL,
        temporaryDirectory: URL,
        fileManager: FileManager
    ) throws {
        let data = try ProjectJSONCodec.encode(value)
        try write(
            data,
            to: destination,
            temporaryDirectory: temporaryDirectory,
            fileManager: fileManager
        )
    }

    static func write(
        _ data: Data,
        to destination: URL,
        temporaryDirectory: URL,
        fileManager: FileManager
    ) throws {
        do {
            try fileManager.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let staged = temporaryDirectory.appending(
                path: "write-\(UUID().uuidString.lowercased()).tmp"
            )
            try data.write(to: staged, options: .atomic)
            defer {
                if fileManager.fileExists(atPath: staged.path) {
                    try? fileManager.removeItem(at: staged)
                }
            }

            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(
                    destination,
                    withItemAt: staged,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(
                    at: staged,
                    to: destination
                )
            }
        } catch let error as ProjectStoreError {
            throw error
        } catch {
            throw ProjectStoreError.io(String(describing: error))
        }
    }
}

nonisolated enum ProjectRetainedSource: Sendable {
    case file(URL)
    case data(Data)
}

nonisolated struct ProjectRetainedArtwork: Sendable {
    let data: Data

    init(data: Data) {
        self.data = data
    }
}

actor ProjectStore {
    nonisolated let rootURL: URL
    private let fileManager: FileManager
    // One bounded derived-text cache avoids decoding a book's blocks for every
    // audio/status/checkpoint operation. Parser output remains owned by disk or
    // the active runtime; switching projects replaces this entry.
    private var readingProjection: (
        projectID: UUID, source: ProjectSource, policy: PdfReadingPolicy,
        projection: PDFReadingProjection
    )?

    init(
        rootURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        self.fileManager = fileManager

        do {
            if let rootURL {
                self.rootURL = rootURL.standardizedFileURL
                try fileManager.createDirectory(
                    at: self.rootURL,
                    withIntermediateDirectories: true
                )
            } else {
                self.rootURL = try ProjectPackagePaths.projectsRoot(
                    fileManager: fileManager
                )
            }
        } catch let error as ProjectStoreError {
            throw error
        } catch {
            throw ProjectStoreError.io(String(describing: error))
        }

        Self.cleanupStaleCreatingDirectories(
            rootURL: self.rootURL,
            fileManager: fileManager
        )
        // Finish rolling back any PDF content swap interrupted by an app kill.
        try Self.recoverPDFReadingTransactions(
            rootURL: self.rootURL,
            fileManager: fileManager
        )
    }

    @discardableResult
    func createProject(
        title: String,
        author: String? = nil,
        source: ProjectSource,
        settings: ProjectNarrationSettings = ProjectNarrationSettings(),
        id: UUID = UUID(),
        now: Date = .now
    ) throws -> ProjectDocument {
        let project = ProjectDocument(
            id: id,
            title: title,
            author: author,
            source: source,
            settings: settings,
            createdAt: now,
            updatedAt: now
        )

        try createPackage(
            project: project,
            manifest: .empty(),
            items: [],
            queue: ProjectQueueDocument()
        )
        return project
    }

    func createPackage(
        project: ProjectDocument,
        manifest: ProjectContentManifest,
        items: [ProjectContentItem],
        queue: ProjectQueueDocument = ProjectQueueDocument(),
        retainedSource: ProjectRetainedSource? = nil,
        retainedArtwork: ProjectRetainedArtwork? = nil,
        parsedCache: ParsedImportCache? = nil
    ) throws {
        try Task.checkCancellation()
        try ProjectValidation.validate(project)
        try ProjectValidation.validate(manifest)
        try ProjectValidation.validate(queue)
        try validateContentBundle(
            manifest: manifest,
            items: items
        )
        if let parsedCache {
            try requireParsedCacheCompatibility(parsedCache, source: project.source)
            guard Set(parsedCache.itemMappings.map(\.itemID)) == Set(items.map(\.id)) else {
                throw ProjectStoreError.invalidData("Parsed output does not match imported item identities.")
            }
        }
        try requireQueueOwnership(
            queue,
            projectID: project.id,
            itemIDs: Set(items.map(\.id))
        )

        try Task.checkCancellation()
        let finalURL = packageURL(for: project.id)
        guard !fileManager.fileExists(atPath: finalURL.path) else {
            throw ProjectStoreError.projectAlreadyExists(project.id)
        }

        let stagingURL = rootURL.appending(
            path: ".creating-\(ProjectPackagePaths.fileID(project.id))-\(UUID().uuidString.lowercased())",
            directoryHint: .isDirectory
        )
        let paths = ProjectPackagePaths(packageURL: stagingURL)

        do {
            try createPackageDirectories(paths)
            if let retainedSource {
                try retainSource(
                    retainedSource,
                    project: project,
                    paths: paths
                )
            }
            try Task.checkCancellation()
            try retainArtwork(
                retainedArtwork,
                project: project,
                paths: paths
            )
            if let parsedCache {
                try writeParsedCache(parsedCache, paths: paths)
            }
            try ProjectAtomicWriter.write(
                project,
                to: paths.projectJSON,
                temporaryDirectory: paths.tempDirectory,
                fileManager: fileManager
            )
            for item in items {
                try Task.checkCancellation()
                try ProjectAtomicWriter.write(
                    item,
                    to: paths.itemJSON(item.id),
                    temporaryDirectory: paths.tempDirectory,
                    fileManager: fileManager
                )
            }
            try ProjectAtomicWriter.write(
                manifest,
                to: paths.contentManifest,
                temporaryDirectory: paths.tempDirectory,
                fileManager: fileManager
            )
            try ProjectAtomicWriter.write(
                queue,
                to: paths.queueJobs,
                temporaryDirectory: paths.tempDirectory,
                fileManager: fileManager
            )
            // The move is the commit point. Cancellation before it rolls back
            // staging; cancellation after it must not delete a completed project.
            try Task.checkCancellation()
            try fileManager.moveItem(at: stagingURL, to: finalURL)
        } catch {
            if fileManager.fileExists(atPath: stagingURL.path) {
                try? fileManager.removeItem(at: stagingURL)
            }
            if error is CancellationError {
                throw error
            }
            if let typed = error as? ProjectStoreError {
                throw typed
            }
            throw ProjectStoreError.io(String(describing: error))
        }
    }

    func catalog() throws -> ProjectCatalog {
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw ProjectStoreError.io(String(describing: error))
        }

        var projects: [ProjectSnapshot] = []
        var issues: [ProjectCatalogIssue] = []

        for url in urls where url.pathExtension == ProjectSchema.packageExtension {
            do {
                try requirePackageDirectory(url)
                let project = try loadProjectDocument(at: url)
                try requirePackageIdentity(
                    project: project,
                    packageURL: url
                )
                projects.append(ProjectSnapshot(project: project))
            } catch {
                issues.append(
                    ProjectCatalogIssue(
                        packageName: url.lastPathComponent,
                        kind: catalogIssueKind(for: error),
                        message: Self.message(for: error)
                    )
                )
            }
        }

        projects.sort {
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt > $1.updatedAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
        issues.sort { $0.packageName < $1.packageName }

        return ProjectCatalog(
            projects: projects,
            issues: issues
        )
    }

    func storageSummary()
        throws -> ReadAloudStorageSummary
    {
        let catalog = try catalog()
        var projects:
            [ProjectStorageBreakdown] = []
        projects.reserveCapacity(
            catalog.projects.count
        )

        for snapshot in catalog.projects {
            projects.append(
                try storageBreakdown(
                    projectID: snapshot.id
                )
            )
        }

        projects.sort {
            if $0.totalBytes
                != $1.totalBytes
            {
                return $0.totalBytes
                    > $1.totalBytes
            }
            return $0.title
                .localizedStandardCompare(
                    $1.title
                ) == .orderedAscending
        }

        let totalBytes =
            try byteCount(
                at: rootURL
            )
        let attributed =
            projects.reduce(Int64(0)) {
                $0 + $1.totalBytes
            }

        return ReadAloudStorageSummary(
            totalBytes: totalBytes,
            projects: projects,
            unattributedBytes:
                max(
                    0,
                    totalBytes
                        - attributed
                )
        )
    }

    func storageBreakdown(
        projectID: UUID
    ) throws -> ProjectStorageBreakdown {
        let project =
            try loadProjectMetadata(
                projectID: projectID
            )
        let paths =
            try pathsForExistingProject(
                projectID
            )

        let totalBytes =
            try byteCount(
                at: paths.packageURL
            )
        let sourceBytes =
            try byteCount(
                at:
                    paths.sourceDirectory
            )
        let generatedAudioBytes =
            try byteCount(
                at:
                    paths.audioDirectory
            )
        let temporaryCacheBytes =
            try byteCount(
                at:
                    paths
                        .paragraphCacheDirectory
            )
        let artworkBytes =
            try byteCount(
                at:
                    paths
                        .artworkCacheDirectory
            )
        let workingBytes =
            try byteCount(
                at:
                    paths.tempDirectory
            )

        let categorized =
            sourceBytes
            + generatedAudioBytes
            + temporaryCacheBytes
            + artworkBytes
            + workingBytes

        return ProjectStorageBreakdown(
            projectID: projectID,
            title: project.title,
            totalBytes: totalBytes,
            sourceBytes: sourceBytes,
            generatedAudioBytes:
                generatedAudioBytes,
            temporaryCacheBytes:
                temporaryCacheBytes,
            artworkBytes: artworkBytes,
            workingBytes: workingBytes,
            projectDataBytes:
                max(
                    0,
                    totalBytes
                        - categorized
                )
        )
    }

    @discardableResult
    func clearTemporaryCache(
        projectID: UUID
    ) throws -> Int64 {
        let paths =
            try pathsForExistingProject(
                projectID
            )
        let before =
            try byteCount(
                at:
                    paths
                        .paragraphCacheDirectory
            )

        try clearDirectoryContents(
            paths
                .paragraphCacheDirectory
        )

        return before
    }

    func loadSnapshot(projectID: UUID) throws -> ProjectSnapshot {
        ProjectSnapshot(project: try loadProjectMetadata(projectID: projectID))
    }

    /// Disk lookup only. A miss never starts parsing or schedules background work.
    func loadParsedOutput(projectID: UUID) throws -> ParsedImportCache? {
        try Task.checkCancellation()
        let source = try loadProjectMetadata(projectID: projectID).source
        let paths = try pathsForExistingProject(projectID)
        guard fileManager.fileExists(atPath: paths.parsedOutputCache.path) else { return nil }
        do {
            let size = try paths.parsedOutputCache.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= ParsedImportCache.maximumBytes else { return nil }
            let data = try Data(contentsOf: paths.parsedOutputCache, options: .mappedIfSafe)
            let cached = try ProjectJSONCodec.decode(
                ParsedImportCache.self, from: data, relativePath: "cache/parsed/blocks.json"
            )
            try Task.checkCancellation()
            return cached.matches(source) ? cached : nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // This sidecar is optional. Saved text/source stay usable when it is
            // corrupt, unreadable or from an incompatible producer/schema.
            try Task.checkCancellation()
            return nil
        }
    }

    /// Saves already parsed output. It intentionally has no parser dependency.
    func saveParsedOutput(projectID: UUID, cache: ParsedImportCache) throws {
        try Task.checkCancellation()
        let source = try loadProjectMetadata(projectID: projectID).source
        try requireParsedCacheCompatibility(cache, source: source)
        let paths = try pathsForExistingProject(projectID)
        try writeParsedCache(cache, paths: paths)
        invalidateReadingProjection(projectID)
    }

    private func invalidateReadingProjection(_ projectID: UUID) {
        if readingProjection?.projectID == projectID { readingProjection = nil }
    }

    private func effectivePDFProjection(
        project: ProjectDocument, storedItems: [ProjectContentItem]? = nil,
        suppliedCache: ParsedImportCache? = nil
    ) throws -> PDFReadingProjection? {
        guard project.source.type == .pdf else { return nil }
        let policy = project.pdfReadingPolicy ?? .listening
        if let cached = readingProjection,
           cached.projectID == project.id, cached.source == project.source, cached.policy == policy {
            if let storedItems {
                let stored = Dictionary(uniqueKeysWithValues: storedItems.map { ($0.id, $0) })
                let projected = Dictionary(uniqueKeysWithValues: cached.projection.items.map { ($0.id, $0) })
                if storedItems.allSatisfy({ item in
                    projected[item.id]?.sourceLocator == item.sourceLocator
                }) {
                    let items = cached.projection.items.map { item in
                        var result = item
                        if let original = stored[item.id] {
                            result.title = original.title
                            result.settings = original.settings
                        }
                        return result
                    }
                    let projection = PDFReadingProjection(
                        items: items, textByItemID: cached.projection.textByItemID, paragraphsByItemID: [:]
                    )
                    readingProjection = (project.id, project.source, policy, projection)
                    return projection
                }
            } else {
                return cached.projection
            }
            invalidateReadingProjection(project.id)
        }
        let available = try suppliedCache ?? loadParsedOutput(projectID: project.id)
        guard let cache = available, cache.matches(project.source) else { return nil }
        let items: [ProjectContentItem]
        if let storedItems {
            items = storedItems
        } else {
            let paths = try pathsForExistingProject(project.id)
            let manifest = try loadContentManifest(paths: paths)
            items = try manifest.items.map { try loadContentItem(projectID: project.id, itemID: $0.id) }
        }
        let projection: PDFReadingProjection?
        do {
            projection = try PDFReadingProjection.cached(cache, items: items, projectID: project.id, policy: policy)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Invalid mappings are a cache miss, never an instruction to parse.
            return nil
        }
        if let projection {
            readingProjection = (project.id, project.source, policy, projection)
        }
        return projection
    }

    private func effectiveContentItem(projectID: UUID, itemID: UUID) throws -> ProjectContentItem {
        let project = try loadProjectMetadata(projectID: projectID)
        if let projection = try effectivePDFProjection(project: project) {
            guard let item = projection.items.first(where: { $0.id == itemID }) else {
                throw ProjectStoreError.invalidData("Chapter is not in the active reading projection.")
            }
            return item
        }
        let paths = try pathsForExistingProject(projectID)
        let manifest = try loadContentManifest(paths: paths)
        guard manifest.items.contains(where: { $0.id == itemID }) else {
            throw ProjectStoreError.invalidData("Chapter is not represented by the content manifest.")
        }
        return try loadContentItem(projectID: projectID, itemID: itemID)
    }

    private func readingItemIDs(
        paths: ProjectPackagePaths, manifest: ProjectContentManifest, requiredIDs: Set<UUID>
    ) throws -> Set<UUID> {
        let storedIDs = Set(manifest.items.map(\.id))
        // Catalog/queue summaries must stay lightweight for dormant books.
        if requiredIDs.isSubset(of: storedIDs) { return storedIDs }
        let project = try loadProjectDocument(at: paths.packageURL)
        if let projection = try effectivePDFProjection(project: project) {
            return Set(projection.items.map(\.id))
        }
        return storedIDs
    }

    private func requireParsedCacheCompatibility(
        _ cache: ParsedImportCache, source: ProjectSource
    ) throws {
        guard cache.matches(source) else {
            throw ProjectStoreError.invalidData("Parsed output does not match the retained source.")
        }
    }

    private func writeParsedCache(_ cache: ParsedImportCache, paths: ProjectPackagePaths) throws {
        let data = try ProjectJSONCodec.encode(cache)
        guard data.count <= ParsedImportCache.maximumBytes else {
            throw ProjectStoreError.invalidData("Parsed output exceeds safe cache loading limits.")
        }
        try Task.checkCancellation()
        try ProjectAtomicWriter.write(
            data, to: paths.parsedOutputCache,
            temporaryDirectory: paths.tempDirectory, fileManager: fileManager
        )
    }

    func loadProjectMetadata(projectID: UUID) throws -> ProjectDocument {
        let url = try existingPackageURL(for: projectID)
        let project = try loadProjectDocument(at: url)
        try requirePackageIdentity(project: project, packageURL: url)
        guard project.id == projectID else {
            throw ProjectStoreError.identityMismatch(
                expected: projectID,
                found: project.id
            )
        }
        return project
    }

    /// A validated URL for the original PDF retained inside the project package.
    /// Reader sessions can reopen this file without a file-importer security scope.
    func retainedPDFSourceURL(projectID: UUID) throws -> URL {
        let packageRootURL = try existingPackageURL(for: projectID)
        let project = try loadProjectMetadata(projectID: projectID)
        guard project.source.type == .pdf else {
            throw ProjectStoreError.invalidData("This project is not a PDF.")
        }
        try requireRetainedSourceCompatibility(
            project: project,
            packageRootURL: packageRootURL
        )
        return try packageURL(
            forRelativePath: project.source.relativePath,
            in: packageRootURL
        )
    }

    /// Validate retained bytes only for an explicitly started preparation.
    func parsedOutputSource(projectID: UUID) throws -> ParsedOutputSource {
        try Task.checkCancellation()
        let project = try loadProjectMetadata(projectID: projectID)
        let paths = try pathsForExistingProject(projectID)
        try requireRetainedSourceCompatibility(project: project, packageRootURL: paths.packageURL)
        let url = try packageURL(forRelativePath: project.source.relativePath, in: paths.packageURL)
        let manifest = try loadContentManifest(paths: paths)
        let items = try manifest.items.sorted { $0.order < $1.order }.map {
            try loadContentItem(projectID: projectID, itemID: $0.id)
        }
        return ParsedOutputSource(project: project, fileURL: url, items: items)
    }

    func loadProject(
        projectID: UUID,
        verifyRetainedSource: Bool = true
    ) throws -> LoadedProject {
        try ReadAloudSafety.requireMemoryHeadroom()
        let packageURL = try existingPackageURL(for: projectID)
        let paths = ProjectPackagePaths(packageURL: packageURL)

        let project = try loadProjectMetadata(projectID: projectID)
        if verifyRetainedSource {
            try requireRetainedSourceCompatibility(
                project: project,
                packageRootURL: packageURL
            )
        }

        let manifest: ProjectContentManifest = try readDocument(
            ProjectContentManifest.self,
            at: paths.contentManifest,
            relativePath: "content/manifest.json"
        )
        try ProjectValidation.validate(manifest)

        guard manifest.items.count <= 20_000 else {
            throw ProjectStoreError.invalidData("This project has too many sections to open safely.")
        }
        var contentBytes = 0
        for entry in manifest.items {
            let size = try paths.itemJSON(entry.id).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= ReadAloudSafety.maximumDocumentBytes,
                  contentBytes <= ReadAloudSafety.maximumProjectBytes - size else {
                throw ProjectStoreError.invalidData("This project is too large to open safely on this device. The original project is preserved.")
            }
            contentBytes += size
        }
        var items: [ProjectContentItem] = []
        items.reserveCapacity(manifest.items.count)

        for entry in manifest.items.sorted(by: { $0.order < $1.order }) {
            try Task.checkCancellation()
            let item: ProjectContentItem = try readDocument(
                ProjectContentItem.self,
                at: paths.itemJSON(entry.id),
                relativePath: entry.relativePath
            )
            try ProjectValidation.validate(item)

            guard item.id == entry.id else {
                throw ProjectStoreError.identityMismatch(
                    expected: entry.id,
                    found: item.id
                )
            }
            guard item.order == entry.order else {
                throw ProjectStoreError.invalidData(
                    "Item \(entry.id) order does not match manifest"
                )
            }
            items.append(item)
        }

        try validateContentBundle(
            manifest: manifest,
            items: items
        )

        let projection = try effectivePDFProjection(project: project, storedItems: items)
        let activeItems = projection?.items ?? items
        let activeEntries = activeItems.map {
            ContentManifestItem(id: $0.id, order: $0.order, relativePath: ProjectPackagePaths.relativeItemPath($0.id))
        }
        let activeManifest = try projection.map { _ in
            ProjectContentManifest(
                contentRevision: try ProjectContentRevision.project(manifestItems: activeEntries, items: activeItems),
                items: activeEntries
            )
        } ?? manifest

        let queue: ProjectQueueDocument = try readDocument(
            ProjectQueueDocument.self,
            at: paths.queueJobs,
            relativePath: "queue/jobs.json"
        )
        try ProjectValidation.validate(queue)
        try requireQueueOwnership(
            queue,
            projectID: projectID,
            itemIDs: Set(activeItems.map(\.id))
        )

        return LoadedProject(
            project: project,
            manifest: activeManifest,
            items: activeItems,
            queue: queue,
            hasParsedPDFOutput: projection != nil
        )
    }

    func saveProjectMetadata(_ project: ProjectDocument) throws {
        try ProjectValidation.validate(project)
        let url = try existingPackageURL(for: project.id)
        try requirePackageIdentity(
            project: loadProjectDocument(at: url),
            packageURL: url
        )
        try writeProjectDocument(project, packageURL: url)
    }

    @discardableResult
    func renameProject(
        projectID: UUID,
        to rawTitle: String,
        now: Date = .now
    ) throws -> ProjectDocument {
        var project = try loadProjectMetadata(projectID: projectID)
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw ProjectStoreError.invalidData(
                "Project title must not be empty"
            )
        }

        project.title = title
        project.updatedAt = now
        try writeProjectDocument(
            project,
            packageURL: packageURL(for: projectID)
        )
        return project
    }

    @discardableResult
    func updateSettings(
        projectID: UUID,
        settings: ProjectNarrationSettings,
        now: Date = .now
    ) throws -> ProjectDocument {
        var project = try loadProjectMetadata(projectID: projectID)

        if let currentItemID = project.playback?.currentItemID {
            let item = try loadContentItem(
                projectID: projectID,
                itemID: currentItemID
            )
            let oldResolved = try NarrationSettingsResolver.resolve(
                item: item.settings,
                project: project.settings
            )
            let newResolved = try NarrationSettingsResolver.resolve(
                item: item.settings,
                project: settings
            )
            if oldResolved != newResolved {
                project.playback?.audioPosition = nil
            }
        }

        project.settings = settings
        project.updatedAt = now
        try ProjectValidation.validate(project)
        try writeProjectDocument(
            project,
            packageURL: packageURL(for: projectID)
        )
        return project
    }

    /// Persist one PDF project's listening policy without touching its source,
    /// chapter text, synthesis caches, or unrelated narration settings.
    @discardableResult
    func updatePDFReadingPolicy(
        projectID: UUID,
        policy: PdfReadingPolicy,
        parsedCache: ParsedImportCache? = nil,
        now: Date = .now
    ) throws -> ProjectDocument {
        var project = try loadProjectMetadata(projectID: projectID)
        guard project.source.type == .pdf else {
            throw ProjectStoreError.invalidData("Listening filters require a PDF project.")
        }
        if let parsedCache { try requireParsedCacheCompatibility(parsedCache, source: project.source) }
        let previous = try effectivePDFProjection(project: project, suppliedCache: parsedCache)
        project.pdfReadingPolicy = policy
        let next = try effectivePDFProjection(project: project, suppliedCache: parsedCache)
        if let currentID = project.playback?.currentItemID,
           let nextItem = next?.items.first(where: { $0.id == currentID }),
           previous?.items.first(where: { $0.id == currentID })?.contentRevision != nextItem.contentRevision {
            project.playback?.contentBookmark = ProjectContentBookmark(
                contentRevision: nextItem.contentRevision, textOffsetUTF16: 0
            )
            project.playback?.audioPosition = nil
            project.playback?.projectProgress = 0
        }
        project.updatedAt = now
        try writeProjectDocument(
            project,
            packageURL: packageURL(for: projectID)
        )
        return project
    }

    /// Legacy explicit content replacement. Listening-option changes use
    /// updatePDFReadingPolicy and a cached in-memory projection instead.
    @discardableResult
    func replacePDFReadingContent(
        projectID: UUID,
        policy: PdfReadingPolicy,
        items: [ProjectContentItem],
        now: Date = .now
    ) throws -> ProjectDocument {
        try Task.checkCancellation()
        // The PDF was already validated and parsed when opening its session;
        // a lightweight policy toggle must not rehash the entire source PDF.
        let loaded = try loadProject(
            projectID: projectID,
            verifyRetainedSource: false
        )
        guard loaded.project.source.type == .pdf else {
            throw ProjectStoreError.invalidData(
                "Listening policy content changes require a PDF."
            )
        }
        guard !items.isEmpty, items.count <= 20_000 else {
            throw ProjectStoreError.invalidData(
                "PDF listening content has an invalid chapter count."
            )
        }
        let oldEntries = Dictionary(
            uniqueKeysWithValues: loaded.manifest.items.map { ($0.id, $0) }
        )
        var ordered = items.sorted { $0.order < $1.order }
        let storedByID = Dictionary(
            uniqueKeysWithValues: loaded.items.map { ($0.id, $0) }
        )
        // Preserve any narration/title edits made after the asynchronous
        // PDF projection was prepared, without overwriting selected text.
        for index in ordered.indices {
            if let stored = storedByID[ordered[index].id] {
                ordered[index].settings = stored.settings
                ordered[index].title = stored.title
            }
        }
        let entries = ordered.map { item in
            ContentManifestItem(
                id: item.id,
                order: item.order,
                relativePath: ProjectPackagePaths.relativeItemPath(item.id),
                parentID: oldEntries[item.id]?.parentID
            )
        }
        let manifest = ProjectContentManifest(
            contentRevision: try ProjectContentRevision.project(
                manifestItems: entries,
                items: ordered
            ),
            items: entries
        )
        try validateContentBundle(manifest: manifest, items: ordered)

        let oldByID = Dictionary(
            uniqueKeysWithValues: loaded.items.map { ($0.id, $0) }
        )
        let newByID = Dictionary(
            uniqueKeysWithValues: ordered.map { ($0.id, $0) }
        )
        let changedIDs = Set(oldByID.keys).union(newByID.keys).filter { id in
            oldByID[id]?.contentRevision != newByID[id]?.contentRevision
        }
        let oldOrder = loaded.manifest.items.sorted { $0.order < $1.order }
            .map(\.id)
        let newOrder = entries.map(\.id)
        var project = loaded.project
        project.pdfReadingPolicy = policy
        if !changedIDs.isEmpty || oldOrder != newOrder {
            // A source offset is meaningful only for its exact text revision.
            // If the current chapter survived unchanged, preserve its position
            // and recompute the project-wide percentage for the new order.
            if let currentID = project.playback?.currentItemID,
               let bookmark = project.playback?.contentBookmark,
               let current = newByID[currentID],
               bookmark.contentRevision == current.contentRevision,
               bookmark.textOffsetUTF16 >= 0,
               bookmark.textOffsetUTF16 <= current.text.utf16.count {
                let total = ordered.reduce(0) {
                    $0 + max(1, $1.text.utf16.count)
                }
                let prefix = ordered.prefix {
                    $0.id != currentID
                }.reduce(0) {
                    $0 + max(1, $1.text.utf16.count)
                }
                let offset = min(bookmark.textOffsetUTF16, current.text.utf16.count)
                project.playback?.projectProgress = Double(prefix + offset)
                    / Double(max(1, total))
            } else {
                project.playback?.contentBookmark = nil
                project.playback?.projectProgress = 0
                if let currentID = project.playback?.currentItemID,
                   newByID[currentID] == nil {
                    project.playback?.currentItemID = ordered.first?.id
                }
            }
            // Saved final-audio seconds have no meaningful project-wide
            // mapping after any reading-order or text transition.
            project.playback?.audioPosition = nil
        }
        project.updatedAt = now
        try ProjectValidation.validate(project)

        // Durable jobs for changed or removed chapter text cannot synthesize
        // or finish under their former generation key after the swap.
        var queue = loaded.queue
        queue.jobs.removeAll { job in
            changedIDs.contains(job.itemID) || newByID[job.itemID] == nil
        }
        try ProjectValidation.validate(queue)
        try requireQueueOwnership(
            queue, projectID: projectID,
            itemIDs: Set(entries.map(\.id))
        )

        let paths = try pathsForExistingProject(projectID)
        let transaction = paths.tempDirectory.appending(
            path: "pdf-reading-transaction", directoryHint: .isDirectory
        )
        guard !fileManager.fileExists(atPath: transaction.path) else {
            throw ProjectStoreError.invalidData(
                "A PDF content transition requires recovery before retry."
            )
        }
        let staging = transaction.appending(path: "staged", directoryHint: .isDirectory)
        let stagedContent = staging.appending(path: "content", directoryHint: .isDirectory)
        let stagedProject = staging.appending(path: "project.json")
        let stagedQueue = staging.appending(path: "jobs.json")
        let backup = transaction.appending(path: "backup", directoryHint: .isDirectory)

        do {
            try fileManager.createDirectory(
                at: staging, withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: backup, withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: paths.contentDirectory, to: stagedContent)
            // Remove the stale source content snapshots; each variant is
            // represented by exactly the new manifest's items.
            let stagedItems = stagedContent.appending(
                path: "items", directoryHint: .isDirectory
            )
            if fileManager.fileExists(atPath: stagedItems.path) {
                try fileManager.removeItem(at: stagedItems)
            }
            try fileManager.createDirectory(
                at: stagedItems, withIntermediateDirectories: true
            )
            for item in ordered {
                try Task.checkCancellation()
                try ProjectAtomicWriter.write(
                    item,
                    to: stagedItems.appending(
                        path: "\(ProjectPackagePaths.fileID(item.id)).json"
                    ),
                    temporaryDirectory: staging,
                    fileManager: fileManager
                )
            }
            try ProjectAtomicWriter.write(
                manifest,
                to: stagedContent.appending(path: "manifest.json"),
                temporaryDirectory: staging,
                fileManager: fileManager
            )
            try ProjectAtomicWriter.write(
                queue, to: stagedQueue,
                temporaryDirectory: staging, fileManager: fileManager
            )
            try ProjectAtomicWriter.write(
                project, to: stagedProject,
                temporaryDirectory: staging, fileManager: fileManager
            )
            try Task.checkCancellation()
            // After this marker, swaps and rollback ignore cancellation.
            // Crash recovery restores backups if any part of the swap began.
            try Data("ready".utf8).write(
                to: transaction.appending(path: "ready"), options: .atomic
            )

            let slots: [(URL, URL, URL)] = [
                (paths.contentDirectory, stagedContent,
                 backup.appending(path: "content")),
                (paths.queueJobs, stagedQueue,
                 backup.appending(path: "jobs.json")),
                (paths.projectJSON, stagedProject,
                 backup.appending(path: "project.json"))
            ]
            for (active, next, previous) in slots {
                try fileManager.moveItem(at: active, to: previous)
                try fileManager.moveItem(at: next, to: active)
            }
            // The commit marker comes after all three swaps. A crash before
            // it rolls back; a crash after it retains the new projection.
            try Data("committed".utf8).write(
                to: transaction.appending(path: "committed"), options: .atomic
            )
            try? fileManager.removeItem(at: transaction)
            return project
        } catch {
            do {
                try Self.rollbackPDFReadingTransaction(
                    paths: paths, fileManager: fileManager
                )
            } catch {
                throw ProjectStoreError.io(
                    "PDF content transaction failed and recovery is required: \(error)"
                )
            }
            if error is CancellationError { throw CancellationError() }
            throw ProjectStoreError.io(
                "Unable to save PDF listening content: \(error)"
            )
        }
    }

    private static func rollbackPDFReadingTransaction(
        paths: ProjectPackagePaths,
        fileManager: FileManager
    ) throws {
        let transaction = paths.tempDirectory.appending(
            path: "pdf-reading-transaction", directoryHint: .isDirectory
        )
        guard fileManager.fileExists(atPath: transaction.path) else { return }
        if fileManager.fileExists(
            atPath: transaction.appending(path: "committed").path
        ) {
            try fileManager.removeItem(at: transaction)
            return
        }
        let backup = transaction.appending(path: "backup", directoryHint: .isDirectory)
        // Restore in reverse order: the original project.json becomes active
        // again before original content is restored.
        let slots: [(URL, URL)] = [
            (paths.projectJSON, backup.appending(path: "project.json")),
            (paths.queueJobs, backup.appending(path: "jobs.json")),
            (paths.contentDirectory, backup.appending(path: "content"))
        ]
        for (active, previous) in slots {
            guard fileManager.fileExists(atPath: previous.path) else { continue }
            if fileManager.fileExists(atPath: active.path) {
                try fileManager.removeItem(at: active)
            }
            try fileManager.moveItem(at: previous, to: active)
        }
        try fileManager.removeItem(at: transaction)
    }

    private static func recoverPDFReadingTransactions(
        rootURL: URL,
        fileManager: FileManager
    ) throws {
        let candidates = try fileManager.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for packageURL in candidates where
            packageURL.pathExtension == ProjectSchema.packageExtension {
            try rollbackPDFReadingTransaction(
                paths: ProjectPackagePaths(packageURL: packageURL),
                fileManager: fileManager
            )
        }
    }

    @discardableResult
    func updatePlayback(
        projectID: UUID,
        playback: ProjectPlaybackState?,
        now: Date = .now
    ) throws -> ProjectDocument {
        var project = try loadProjectMetadata(projectID: projectID)
        if let itemID = playback?.currentItemID {
            // The item itself must still exist in the active projection,
            // even when the incoming checkpoint omits both optional offsets.
            let item = try effectiveContentItem(
                projectID: projectID, itemID: itemID
            )
            if let bookmark = playback?.contentBookmark {
                guard bookmark.contentRevision == item.contentRevision,
                      bookmark.textOffsetUTF16 >= 0,
                      bookmark.textOffsetUTF16 <= item.text.utf16.count else {
                    throw ProjectStoreError.invalidData(
                        "Playback checkpoint does not match the active chapter."
                    )
                }
            }
            if let audio = playback?.audioPosition {
                // An audio-only checkpoint has no bookmark text revision.
                // Bind it to the actual validated final-audio metadata so
                // a cancelled old playback cannot overwrite the new position.
                let paths = try pathsForExistingProject(projectID)
                let metadata: GeneratedAudioMetadata = try readDocument(
                    GeneratedAudioMetadata.self,
                    at: paths.audioMetadata(itemID),
                    relativePath: ProjectPackagePaths.relativeAudioMetadataPath(itemID)
                )
                try ProjectValidation.validate(metadata)
                try requireAudioMetadataCompatibility(metadata, in: paths)
                guard audio.generationKey == metadata.generationKey,
                      audio.audioRevision == metadata.audioRevision else {
                    throw ProjectStoreError.invalidData(
                        "Audio position belongs to a previous listening projection."
                    )
                }
            }
        }
        project.playback = playback
        project.updatedAt = now
        try ProjectValidation.validate(project)
        try writeProjectDocument(
            project,
            packageURL: packageURL(for: projectID)
        )
        return project
    }

    func saveContentManifest(
        projectID: UUID,
        manifest: ProjectContentManifest
    ) throws {
        try ProjectValidation.validate(manifest)
        let paths = try pathsForExistingProject(projectID)

        var items: [ProjectContentItem] = []
        items.reserveCapacity(manifest.items.count)
        for entry in manifest.items {
            let item: ProjectContentItem = try readDocument(
                ProjectContentItem.self,
                at: paths.itemJSON(entry.id),
                relativePath: entry.relativePath
            )
            try ProjectValidation.validate(item)
            items.append(item)
        }

        try validateContentBundle(
            manifest: manifest,
            items: items
        )
        try ProjectAtomicWriter.write(
            manifest,
            to: paths.contentManifest,
            temporaryDirectory: paths.tempDirectory,
            fileManager: fileManager
        )
        invalidateReadingProjection(projectID)
    }

    func saveContentItem(
        projectID: UUID,
        item: ProjectContentItem
    ) throws {
        try ProjectValidation.validate(item)
        let paths = try pathsForExistingProject(projectID)
        let manifest: ProjectContentManifest = try readDocument(
            ProjectContentManifest.self,
            at: paths.contentManifest,
            relativePath: "content/manifest.json"
        )
        try ProjectValidation.validate(manifest)

        guard let entry = manifest.items.first(where: { $0.id == item.id }),
              entry.order == item.order else {
            throw ProjectStoreError.invalidData(
                "Content item is not represented by the current manifest"
            )
        }

        let itemURL = paths.itemJSON(item.id)
        if fileManager.fileExists(atPath: itemURL.path) {
            let existing: ProjectContentItem = try readDocument(
                ProjectContentItem.self,
                at: itemURL,
                relativePath: entry.relativePath
            )
            guard existing.contentRevision == item.contentRevision,
                  existing.text == item.text else {
                throw ProjectStoreError.invalidData(
                    "Changing normalized content requires a transactional content replacement"
                )
            }
        }

        try ProjectAtomicWriter.write(
            item,
            to: itemURL,
            temporaryDirectory: paths.tempDirectory,
            fileManager: fileManager
        )
        invalidateReadingProjection(projectID)
    }

    func loadContentItem(
        projectID: UUID,
        itemID: UUID
    ) throws -> ProjectContentItem {
        let paths = try pathsForExistingProject(projectID)
        let relativePath = ProjectPackagePaths.relativeItemPath(itemID)
        let item: ProjectContentItem = try readDocument(
            ProjectContentItem.self,
            at: paths.itemJSON(itemID),
            relativePath: relativePath
        )
        try ProjectValidation.validate(item)
        guard item.id == itemID else {
            throw ProjectStoreError.identityMismatch(
                expected: itemID,
                found: item.id
            )
        }
        return item
    }

    @discardableResult
    func updateContentItemSettings(
        projectID: UUID,
        itemID: UUID,
        settings: ItemNarrationSettings,
        now: Date = .now
    ) throws -> ProjectContentItem {
        var project = try loadProjectMetadata(projectID: projectID)
        var item = try loadContentItem(
            projectID: projectID,
            itemID: itemID
        )

        let oldResolved = try NarrationSettingsResolver.resolve(
            item: item.settings,
            project: project.settings
        )
        let newResolved = try NarrationSettingsResolver.resolve(
            item: settings,
            project: project.settings
        )

        item.settings = settings
        try saveContentItem(
            projectID: projectID,
            item: item
        )

        if project.playback?.currentItemID == itemID,
           oldResolved != newResolved {
            project.playback?.audioPosition = nil
        }
        project.updatedAt = now
        try writeProjectDocument(
            project,
            packageURL: packageURL(for: projectID)
        )
        return item
    }

    func saveQueue(
        projectID: UUID,
        queue: ProjectQueueDocument
    ) throws {
        try ProjectValidation.validate(queue)
        let paths = try pathsForExistingProject(projectID)
        let manifest = try loadContentManifest(paths: paths)
        try requireQueueOwnership(
            queue,
            projectID: projectID,
            itemIDs: try readingItemIDs(paths: paths, manifest: manifest, requiredIDs: Set(queue.jobs.map(\.itemID)))
        )
        try ProjectAtomicWriter.write(
            queue,
            to: paths.queueJobs,
            temporaryDirectory: paths.tempDirectory,
            fileManager: fileManager
        )
    }

    /// Read actual durable queue files for library summaries without loading
    /// chapter contents or starting TTS engines for idle projects.
    func generationQueueCounts(projectIDs: [UUID]) -> [UUID: ProjectGenerationQueueCounts] {
        var result: [UUID: ProjectGenerationQueueCounts] = [:]
        for id in projectIDs {
            guard let queue = try? loadQueue(projectID: id) else { continue }
            result[id] = ProjectGenerationQueueCounts(
                queue: queue,
                runtimeIsActive: false
            )
        }
        return result
    }

    func loadQueue(projectID: UUID) throws -> ProjectQueueDocument {
        let paths = try pathsForExistingProject(projectID)
        let queue: ProjectQueueDocument = try readDocument(
            ProjectQueueDocument.self,
            at: paths.queueJobs,
            relativePath: "queue/jobs.json"
        )
        try ProjectValidation.validate(queue)
        let manifest = try loadContentManifest(paths: paths)
        try requireQueueOwnership(
            queue,
            projectID: projectID,
            itemIDs: try readingItemIDs(paths: paths, manifest: manifest, requiredIDs: Set(queue.jobs.map(\.itemID)))
        )
        return queue
    }

    func saveAudioMetadata(
        projectID: UUID,
        metadata: GeneratedAudioMetadata
    ) throws {
        try ProjectValidation.validate(metadata)
        let paths = try pathsForExistingProject(projectID)
        try requireAudioMetadataCompatibility(
            metadata,
            in: paths
        )
        try ProjectAtomicWriter.write(
            metadata,
            to: paths.audioMetadata(metadata.itemID),
            temporaryDirectory: paths.tempDirectory,
            fileManager: fileManager
        )
    }

    func loadAudioMetadata(
        projectID: UUID,
        itemID: UUID
    ) throws -> GeneratedAudioMetadata {
        let paths = try pathsForExistingProject(projectID)
        let relativePath = ProjectPackagePaths.relativeAudioMetadataPath(itemID)
        let metadata: GeneratedAudioMetadata = try readDocument(
            GeneratedAudioMetadata.self,
            at: paths.audioMetadata(itemID),
            relativePath: relativePath
        )
        try ProjectValidation.validate(metadata)
        guard metadata.itemID == itemID else {
            throw ProjectStoreError.identityMismatch(
                expected: itemID,
                found: metadata.itemID
            )
        }
        try requireAudioMetadataCompatibility(
            metadata,
            in: paths
        )
        return metadata
    }

    func loadCompatibleFinalAudio(
        projectID: UUID,
        request: ProjectGenerationStatusRequest
    ) throws -> ProjectFinalAudioAsset? {
        let paths =
            try pathsForExistingProject(
                projectID
            )
        let wavURL =
            paths.audioWAV(
                request.itemID
            )
        let metadataURL =
            paths.audioMetadata(
                request.itemID
            )

        guard fileManager.fileExists(
            atPath: wavURL.path
        ),
        fileManager.fileExists(
            atPath: metadataURL.path
        ) else {
            return nil
        }

        do {
            let metadata:
                GeneratedAudioMetadata =
                    try readDocument(
                        GeneratedAudioMetadata.self,
                        at: metadataURL,
                        relativePath:
                            ProjectPackagePaths
                                .relativeAudioMetadataPath(
                                    request.itemID
                                )
                    )
            try ProjectValidation.validate(
                metadata
            )
            try requireAudioMetadataCompatibility(
                metadata,
                in: paths
            )

            guard metadata.itemID
                    == request.itemID,
                  metadata.generationKey
                    == request.generationKey,
                  metadata.contentRevision
                    == request.contentRevision,
                  metadata.voiceID
                    == request.voiceID,
                  metadata.speed
                    == request.speed else {
                return nil
            }

            try Task.checkCancellation()
            guard try ProjectDigest.sha256(fileAt: wavURL) == metadata.audioRevision else {
                return nil
            }
            let info = try ProjectWAVCodec.inspect(fileAt: wavURL)
            let duration = info.durationSeconds
            let tolerance = 1.0 / Double(ProjectWAVCodec.requiredSampleRate)

            guard abs(
                metadata.durationSeconds
                    - duration
            ) <= tolerance else {
                return nil
            }

            return ProjectFinalAudioAsset(
                metadata: metadata,
                wavURL: wavURL
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    /// Called only while SharedChunkAudioCache owns the item's reclamation
    /// reservation. Validation and deletion share this actor turn with no await,
    /// so clearing/replacing final audio cannot interleave between them.
    @discardableResult
    func reclaimFinalizedChunks(
        projectID: UUID, request: ProjectGenerationStatusRequest,
        expectedAudioRevision: String, chunks: [ChunkAudioRequest]
    ) throws -> Int {
        try Task.checkCancellation()
        guard !chunks.isEmpty,
              chunks.allSatisfy({
                  $0.itemID == request.itemID && $0.generationKey == request.generationKey
                      && $0.resolved.voiceID == request.voiceID && $0.resolved.speed == request.speed
              }),
              let asset = try loadCompatibleFinalAudio(projectID: projectID, request: request),
              asset.metadata.audioRevision == expectedAudioRevision,
              chunks.allSatisfy({
                  $0.synthesisConfigVersion == asset.metadata.synthesisConfigVersion
              }) else { return 0 }
        let paths = try pathsForExistingProject(projectID)
        var removed = 0
        for chunk in chunks {
            try Task.checkCancellation()
            let key = chunk.cacheKey
            let json = paths.chunkCacheDirectory.appending(path: "\(key).json")
            let wav = paths.chunkCacheDirectory.appending(path: "\(key).wav")
            // Do not scavenge unknown files, other generations, or malformed
            // metadata. Only these exact, owned redundant pairs are eligible.
            guard let size = try? json.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0, size <= 16_384,
                  let bytes = try? Data(contentsOf: json),
                  let metadata = try? ProjectJSONCodec.decode(
                    ChunkAudioMetadata.self, from: bytes,
                    relativePath: "cache/chunks/\(key).json"
                  ),
                  metadata.schemaVersion == ProjectSchema.currentVersion,
                  metadata.cacheKey == key, metadata.itemID == request.itemID,
                  metadata.sourceRange == chunk.chunk.sourceRange else { continue }
            if fileManager.fileExists(atPath: wav.path) { try fileManager.removeItem(at: wav) }
            try fileManager.removeItem(at: json)
            removed += 1
        }
        return removed
    }

    func commitGeneratedAudio(
        projectID: UUID,
        wavURL: URL,
        metadata: GeneratedAudioMetadata,
        now: Date = .now
    ) throws {
        try ProjectValidation.validate(
            metadata
        )

        let paths =
            try pathsForExistingProject(
                projectID
            )
        try requireAudioMetadataCompatibility(
            metadata,
            in: paths
        )

        try Task.checkCancellation()
        guard try ProjectDigest.sha256(fileAt: wavURL) == metadata.audioRevision else {
            throw ProjectStoreError.invalidData("Final WAV bytes do not match audioRevision.")
        }
        let info = try ProjectWAVCodec.inspect(fileAt: wavURL)
        let duration = info.durationSeconds
        let tolerance = 1.0 / Double(ProjectWAVCodec.requiredSampleRate)

        guard abs(
            metadata.durationSeconds
                - duration
        ) <= tolerance else {
            throw ProjectStoreError.invalidData(
                "Final WAV duration does not match metadata."
            )
        }

        let transactionDirectory =
            paths.tempDirectory.appending(
                path:
                    "audio-commit-\(UUID().uuidString.lowercased())",
                directoryHint: .isDirectory
            )

        do {
            try fileManager.createDirectory(
                at: transactionDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw ProjectStoreError.io(
                "Unable to create audio transaction directory: \(error)"
            )
        }

        defer {
            try? fileManager.removeItem(
                at: transactionDirectory
            )
        }

        let stagedWAV =
            transactionDirectory.appending(
                path: "staged.wav"
            )
        let stagedMetadata =
            transactionDirectory.appending(
                path: "staged.metadata.json"
            )
        let backupWAV =
            transactionDirectory.appending(
                path: "previous.wav"
            )
        let backupMetadata =
            transactionDirectory.appending(
                path: "previous.metadata.json"
            )

        let destinationWAV =
            paths.audioWAV(
                metadata.itemID
            )
        let destinationMetadata =
            paths.audioMetadata(
                metadata.itemID
            )

        let hadWAV =
            fileManager.fileExists(
                atPath:
                    destinationWAV.path
            )
        let hadMetadata =
            fileManager.fileExists(
                atPath:
                    destinationMetadata.path
            )

        do {
            try fileManager.copyItem(at: wavURL, to: stagedWAV)
            try Task.checkCancellation()
            let metadataData =
                try ProjectJSONCodec.encode(
                    metadata
                )
            try metadataData.write(
                to: stagedMetadata,
                options: .atomic
            )

            if hadWAV {
                try fileManager.copyItem(
                    at: destinationWAV,
                    to: backupWAV
                )
            }
            if hadMetadata {
                try fileManager.copyItem(
                    at: destinationMetadata,
                    to: backupMetadata
                )
            }

            try replaceStagedFile(
                stagedWAV,
                destination:
                    destinationWAV
            )
            try replaceStagedFile(
                stagedMetadata,
                destination:
                    destinationMetadata
            )

            guard try ProjectDigest.sha256(
                fileAt: destinationWAV
            ) == metadata.audioRevision else {
                throw ProjectStoreError.invalidData(
                    "Committed WAV failed revision verification."
                )
            }

            let committed:
                GeneratedAudioMetadata =
                    try readDocument(
                        GeneratedAudioMetadata.self,
                        at:
                            destinationMetadata,
                        relativePath:
                            ProjectPackagePaths
                                .relativeAudioMetadataPath(
                                    metadata.itemID
                                )
                    )
            guard committed == metadata else {
                throw ProjectStoreError.invalidData(
                    "Committed audio metadata failed verification."
                )
            }
        } catch {
            restoreFinalAudioPair(
                destinationWAV:
                    destinationWAV,
                destinationMetadata:
                    destinationMetadata,
                backupWAV: backupWAV,
                backupMetadata:
                    backupMetadata,
                hadWAV: hadWAV,
                hadMetadata:
                    hadMetadata
            )

            if let storeError =
                error as? ProjectStoreError {
                throw storeError
            }
            throw ProjectStoreError.io(
                "Unable to commit generated audio: \(error)"
            )
        }

        var queue =
            try loadQueue(
                projectID: projectID
            )
        var queueChanged = false

        for index in queue.jobs.indices {
            guard queue.jobs[index]
                    .itemID
                    == metadata.itemID,
                  queue.jobs[index]
                    .generationKey
                    == metadata.generationKey
            else {
                continue
            }

            if queue.jobs[index].state
                == .queued
                || queue.jobs[index].state
                    == .generating
            {
                queue.jobs[index].state =
                    .completed
                queue.jobs[index].updatedAt =
                    now
                queue.jobs[index].lastError =
                    nil
                queueChanged = true
            }
        }

        if queueChanged {
            try? saveQueue(
                projectID: projectID,
                queue: queue
            )
        }
        try? touchProject(
            projectID: projectID,
            at: now
        )
    }

    func generationStatuses(
        projectID: UUID,
        requests: [ProjectGenerationStatusRequest]
    ) throws -> [UUID: ProjectItemGenerationStatus] {
        try generationState(projectID: projectID, requests: requests).statuses
    }

    // Queue/status changes do not require hydrating the source and every
    // chapter again while the Reader and speech engine retain the open book.
    func generationState(
        projectID: UUID,
        requests: [ProjectGenerationStatusRequest]
    ) throws -> (queue: ProjectQueueDocument, statuses: [UUID: ProjectItemGenerationStatus]) {
        let paths =
            try pathsForExistingProject(
                projectID
            )
        let queue =
            try loadQueue(
                projectID: projectID
            )
        var result:
            [UUID: ProjectItemGenerationStatus] = [:]
        result.reserveCapacity(
            requests.count
        )

        for request in requests {
            let matchingJobs =
                queue.jobs
                    .filter {
                        $0.itemID
                            == request.itemID
                            && $0.generationKey
                                == request.generationKey
                    }
                    .sorted {
                        $0.updatedAt
                            > $1.updatedAt
                    }

            let audioURL =
                paths.audioWAV(
                    request.itemID
                )
            let metadataURL =
                paths.audioMetadata(
                    request.itemID
                )
            let hasAudio =
                fileManager.fileExists(
                    atPath:
                        audioURL.path
                )
            let hasMetadata =
                fileManager.fileExists(
                    atPath:
                        metadataURL.path
                )

            if hasAudio && hasMetadata {
                do {
                    let metadata:
                        GeneratedAudioMetadata =
                            try readDocument(
                                GeneratedAudioMetadata.self,
                                at:
                                    metadataURL,
                                relativePath:
                                    ProjectPackagePaths
                                        .relativeAudioMetadataPath(
                                            request.itemID
                                        )
                            )
                    try ProjectValidation
                        .validate(
                            metadata
                        )
                    try requireAudioMetadataCompatibility(
                        metadata,
                        in: paths
                    )

                    let audioBytes =
                        audioByteCount(
                            at: audioURL
                        )
                    let audioRevision =
                        try ProjectDigest
                            .sha256(
                                fileAt:
                                    audioURL
                            )

                    if metadata.generationKey
                            == request.generationKey,
                       metadata.audioRevision
                            == audioRevision,
                       metadata.contentRevision
                            == request.contentRevision,
                       metadata.voiceID
                            == request.voiceID,
                       metadata.speed
                            == request.speed,
                       let audioBytes,
                       audioBytes > 0 {
                        result[
                            request.itemID
                        ] =
                            ProjectItemGenerationStatus(
                                state:
                                    .readyOffline,
                                audioBytes:
                                    audioBytes
                            )
                        continue
                    }
                } catch {
                    // Valid matching final audio is the only
                    // path that can become Ready Offline.
                }
            }

            if matchingJobs.contains(
                where: {
                    $0.state
                        == .generating
                }
            ) {
                result[
                    request.itemID
                ] =
                    ProjectItemGenerationStatus(
                        state:
                            .generating,
                        audioBytes:
                            audioByteCount(
                                at:
                                    audioURL
                            )
                    )
                continue
            }

            if matchingJobs.contains(
                where: {
                    $0.state
                        == .queued
                }
            ) {
                result[
                    request.itemID
                ] =
                    ProjectItemGenerationStatus(
                        state:
                            .waiting,
                        audioBytes:
                            audioByteCount(
                                at:
                                    audioURL
                            )
                    )
                continue
            }

            if hasAudio
                || hasMetadata
                || matchingJobs.contains(
                    where: {
                        $0.state
                            == .failed
                            || $0.state
                                == .completed
                    }
                )
            {
                result[
                    request.itemID
                ] =
                    ProjectItemGenerationStatus(
                        state:
                            .needsAttention,
                        audioBytes:
                            audioByteCount(
                                at:
                                    audioURL
                            )
                    )
                continue
            }

            result[
                request.itemID
            ] = .notGenerated
        }

        return (queue, result)
    }

    @discardableResult
    func recoverGenerationQueue(
        projectID: UUID,
        generationKeys: [UUID: String]? = nil,
        readyOfflineItemIDs: Set<UUID> = [],
        now: Date = .now
    ) throws -> ProjectQueueDocument {
        var queue = try loadQueue(
            projectID: projectID
        )
        var changed = false

        for index in queue.jobs.indices {
            let job = queue.jobs[index]
            guard job.state == .queued || job.state == .generating else { continue }
            let state: GenerationJobState
            let error: String?
            if let generationKeys, generationKeys[job.itemID] != job.generationKey {
                state = .failed
                error = "Narration settings changed. Generate offline audio again to use the current settings."
            } else if generationKeys != nil, readyOfflineItemIDs.contains(job.itemID) {
                state = .completed
                error = nil
            } else {
                state = .queued
                error = nil
            }
            guard job.state != state || job.lastError != error else { continue }
            queue.jobs[index].state = state
            queue.jobs[index].updatedAt = now
            queue.jobs[index].lastError = error
            changed = true
        }

        if changed {
            try saveQueue(
                projectID: projectID,
                queue: queue
            )
        }

        return queue
    }

    @discardableResult
    func updateGenerationJob(
        projectID: UUID,
        jobID: UUID,
        state: GenerationJobState,
        incrementAttempt: Bool = false,
        errorMessage: String? = nil,
        now: Date = .now
    ) throws -> ProjectQueueDocument {
        var queue = try loadQueue(
            projectID: projectID
        )

        guard let index =
            queue.jobs.firstIndex(
                where: { $0.id == jobID }
            )
        else {
            return queue
        }

        // A late executor pause/failure event cannot undo a durable final
        // asset commit. Explicit regeneration creates a new job identity.
        guard queue.jobs[index].state != .completed || state == .completed else { return queue }
        queue.jobs[index].state = state
        queue.jobs[index].updatedAt = now
        queue.jobs[index].lastError =
            errorMessage

        if incrementAttempt {
            queue.jobs[index].attempt += 1
        }

        try saveQueue(
            projectID: projectID,
            queue: queue
        )
        return queue
    }

    @discardableResult
    func removeGenerationJobs(
        projectID: UUID,
        itemIDs: Set<UUID>,
        states: Set<GenerationJobState>? = nil
    ) throws -> ProjectQueueDocument {
        guard !itemIDs.isEmpty else {
            return try loadQueue(
                projectID: projectID
            )
        }

        var queue = try loadQueue(
            projectID: projectID
        )
        queue.jobs.removeAll { job in
            guard itemIDs.contains(
                job.itemID
            ) else {
                return false
            }

            if let states {
                return states.contains(
                    job.state
                )
            }

            return true
        }

        try saveQueue(
            projectID: projectID,
            queue: queue
        )
        return queue
    }

    func enqueueGeneration(
        projectID: UUID,
        requests: [ProjectGenerationRequest],
        replaceExisting: Bool,
        now: Date = .now
    ) throws {
        guard !requests.isEmpty else { return }

        let paths = try pathsForExistingProject(projectID)
        let manifest = try loadContentManifest(paths: paths)
        let validItemIDs = try readingItemIDs(paths: paths, manifest: manifest, requiredIDs: Set(requests.map(\.itemID)))
        var queue = try loadQueue(projectID: projectID)

        for request in requests {
            guard validItemIDs.contains(request.itemID) else {
                throw ProjectStoreError.invalidData(
                    "Generation request item is not in the project."
                )
            }
            guard ProjectDigest.isSHA256(request.generationKey) else {
                throw ProjectStoreError.invalidData(
                    "Generation request key must be SHA-256."
                )
            }

            if !replaceExisting,
               queue.jobs.contains(where: {
                   $0.itemID == request.itemID
                       && $0.generationKey == request.generationKey
                       && ($0.state == .queued || $0.state == .generating)
               }) {
                continue
            }

            if replaceExisting {
                queue.jobs.removeAll { $0.itemID == request.itemID }
            } else {
                queue.jobs.removeAll {
                    $0.itemID == request.itemID
                        && ($0.state == .queued || $0.state == .generating)
                }
            }

            queue.jobs.append(
                GenerationJobRecord(
                    id: UUID(),
                    projectID: projectID,
                    itemID: request.itemID,
                    operation: .generate,
                    generationKey: request.generationKey,
                    state: .queued,
                    createdAt: now,
                    updatedAt: now,
                    attempt: 0,
                    lastError: nil
                )
            )
        }

        try saveQueue(projectID: projectID, queue: queue)
        try touchProject(projectID: projectID, at: now)
    }

    func clearGeneratedAudio(
        projectID: UUID,
        itemIDs: Set<UUID>,
        now: Date = .now
    ) throws {
        guard !itemIDs.isEmpty else { return }

        var project = try loadProjectMetadata(projectID: projectID)
        let loaded = try loadProject(projectID: projectID)
        let validItemIDs = Set(loaded.items.map(\.id))
        guard itemIDs.isSubset(of: validItemIDs) else {
            throw ProjectStoreError.invalidData(
                "Cannot clear audio for an item outside the project."
            )
        }

        var queue = loaded.queue
        queue.jobs.removeAll { itemIDs.contains($0.itemID) }
        try saveQueue(projectID: projectID, queue: queue)

        let paths = ProjectPackagePaths(
            packageURL: packageURL(for: projectID)
        )
        for itemID in itemIDs {
            for url in [
                paths.audioWAV(itemID),
                paths.audioMetadata(itemID),
            ] where fileManager.fileExists(atPath: url.path) {
                do {
                    try fileManager.removeItem(at: url)
                } catch {
                    throw ProjectStoreError.io(
                        "Unable to clear generated audio: \(error)"
                    )
                }
            }
        }

        if let currentItemID = project.playback?.currentItemID,
           itemIDs.contains(currentItemID) {
            project.playback?.audioPosition = nil
        }
        project.updatedAt = now
        try writeProjectDocument(
            project,
            packageURL: packageURL(for: projectID)
        )
    }

    func deleteProject(projectID: UUID) throws {
        let url = try existingPackageURL(for: projectID)
        let project = try loadProjectDocument(at: url)
        try requirePackageIdentity(project: project, packageURL: url)

        guard project.id == projectID else {
            throw ProjectStoreError.identityMismatch(
                expected: projectID,
                found: project.id
            )
        }

        do {
            try fileManager.removeItem(at: url)
            invalidateReadingProjection(projectID)
        } catch {
            throw ProjectStoreError.io(String(describing: error))
        }
    }

    func packageURL(for projectID: UUID) -> URL {
        ProjectPackagePaths.packageURL(
            projectID: projectID,
            rootURL: rootURL
        )
    }

    private func byteCount(
        at url: URL
    ) throws -> Int64 {
        var isDirectory:
            ObjCBool = false

        guard fileManager
            .fileExists(
                atPath: url.path,
                isDirectory:
                    &isDirectory
            )
        else {
            return 0
        }

        if !isDirectory.boolValue {
            do {
                let values =
                    try url
                        .resourceValues(
                            forKeys: [
                                .fileSizeKey,
                                .isRegularFileKey,
                            ]
                        )
                guard values
                    .isRegularFile
                    == true
                else {
                    return 0
                }
                return Int64(
                    values.fileSize
                        ?? 0
                )
            } catch {
                throw ProjectStoreError.io(
                    "Unable to measure storage: \(error)"
                )
            }
        }

        guard let enumerator =
            fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [
                    .fileSizeKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ],
                options: [
                    .skipsHiddenFiles,
                ]
            )
        else {
            throw ProjectStoreError.io(
                "Unable to enumerate storage at \(url.lastPathComponent)."
            )
        }

        var total: Int64 = 0

        while let entry =
            enumerator.nextObject()
                as? URL
        {
            do {
                let values =
                    try entry
                        .resourceValues(
                            forKeys: [
                                .fileSizeKey,
                                .isRegularFileKey,
                                .isSymbolicLinkKey,
                            ]
                        )

                if values
                    .isSymbolicLink
                    == true
                {
                    enumerator
                        .skipDescendants()
                    continue
                }

                guard values
                    .isRegularFile
                    == true
                else {
                    continue
                }

                total += Int64(
                    values.fileSize
                        ?? 0
                )
            } catch {
                throw ProjectStoreError.io(
                    "Unable to measure project storage: \(error)"
                )
            }
        }

        return total
    }

    private func clearDirectoryContents(
        _ directory: URL
    ) throws {
        do {
            try fileManager
                .createDirectory(
                    at: directory,
                    withIntermediateDirectories:
                        true
                )

            let entries =
                try fileManager
                    .contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys:
                            [.isSymbolicLinkKey],
                        options: []
                    )

            for entry in entries {
                let values =
                    try entry
                        .resourceValues(
                            forKeys: [
                                .isSymbolicLinkKey,
                            ]
                        )
                guard values
                    .isSymbolicLink
                    != true
                else {
                    try fileManager
                        .removeItem(
                            at: entry
                        )
                    continue
                }

                try fileManager
                    .removeItem(
                        at: entry
                    )
            }
        } catch {
            if let storeError =
                error
                as? ProjectStoreError
            {
                throw storeError
            }
            throw ProjectStoreError.io(
                "Unable to clear temporary cache: \(error)"
            )
        }
    }

    private static func cleanupStaleCreatingDirectories(
        rootURL: URL,
        fileManager: FileManager,
        now: Date = .now
    ) {
        let cutoff = now.addingTimeInterval(
            -6 * 60 * 60
        )

        guard let entries =
                try? fileManager.contentsOfDirectory(
                    at: rootURL,
                    includingPropertiesForKeys: [
                        .contentModificationDateKey,
                        .isDirectoryKey,
                        .isSymbolicLinkKey,
                    ],
                    options: []
                )
        else {
            return
        }

        for entry in entries
            where entry.lastPathComponent
                .hasPrefix(".creating-")
        {
            guard let values =
                    try? entry.resourceValues(
                        forKeys: [
                            .contentModificationDateKey,
                            .isDirectoryKey,
                            .isSymbolicLinkKey,
                        ]
                    ),
                  values.isDirectory == true,
                  values.isSymbolicLink != true,
                  let modified =
                    values.contentModificationDate,
                  modified < cutoff
            else {
                continue
            }

            try? fileManager.removeItem(
                at: entry
            )
        }
    }

    private func requireRetainedSourceCompatibility(
        project: ProjectDocument,
        packageRootURL: URL
    ) throws {
        let sourceURL = try packageURL(
            forRelativePath:
                project.source.relativePath,
            in: packageRootURL
        )

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: sourceURL.path,
            isDirectory: &isDirectory
        ),
        !isDirectory.boolValue
        else {
            throw ProjectStoreError.invalidData(
                "Retained source file is missing."
            )
        }

        let revision = try ProjectDigest.sha256(
            fileAt: sourceURL
        )
        guard revision
                == project.source.sourceRevision
        else {
            throw ProjectStoreError.invalidData(
                "Retained source bytes do not match sourceRevision."
            )
        }
    }

    private func replaceStagedFile(
        _ staged: URL,
        destination: URL
    ) throws {
        try fileManager.createDirectory(
            at:
                destination
                    .deletingLastPathComponent(),
            withIntermediateDirectories:
                true
        )

        if fileManager.fileExists(
            atPath: destination.path
        ) {
            _ = try fileManager
                .replaceItemAt(
                    destination,
                    withItemAt: staged,
                    backupItemName: nil,
                    options: []
                )
        } else {
            try fileManager.moveItem(
                at: staged,
                to: destination
            )
        }
    }

    private func restoreFinalAudioPair(
        destinationWAV: URL,
        destinationMetadata: URL,
        backupWAV: URL,
        backupMetadata: URL,
        hadWAV: Bool,
        hadMetadata: Bool
    ) {
        restoreFile(
            destination: destinationWAV,
            backup: backupWAV,
            hadPrevious: hadWAV
        )
        restoreFile(
            destination:
                destinationMetadata,
            backup: backupMetadata,
            hadPrevious: hadMetadata
        )
    }

    private func restoreFile(
        destination: URL,
        backup: URL,
        hadPrevious: Bool
    ) {
        if hadPrevious {
            guard fileManager.fileExists(
                atPath: backup.path
            ) else {
                // Backup creation may have failed before any replacement.
                // In that case the safest action is to leave the existing
                // destination untouched.
                return
            }

            if fileManager.fileExists(
                atPath: destination.path
            ) {
                try? fileManager.removeItem(
                    at: destination
                )
            }

            try? fileManager.copyItem(
                at: backup,
                to: destination
            )
            return
        }

        if fileManager.fileExists(
            atPath: destination.path
        ) {
            try? fileManager.removeItem(
                at: destination
            )
        }
    }

    private func pathsForExistingProject(
        _ projectID: UUID
    ) throws -> ProjectPackagePaths {
        ProjectPackagePaths(
            packageURL: try existingPackageURL(for: projectID)
        )
    }

    private func existingPackageURL(
        for projectID: UUID
    ) throws -> URL {
        let url = packageURL(for: projectID)
        guard fileManager.fileExists(atPath: url.path) else {
            throw ProjectStoreError.projectNotFound(projectID)
        }
        try requirePackageDirectory(url)
        return url
    }

    private func loadProjectDocument(
        at packageURL: URL
    ) throws -> ProjectDocument {
        let path = ProjectPackagePaths(packageURL: packageURL)
        let project: ProjectDocument = try readDocument(
            ProjectDocument.self,
            at: path.projectJSON,
            relativePath: "project.json"
        )
        try ProjectValidation.validate(project)
        return project
    }

    private func writeProjectDocument(
        _ project: ProjectDocument,
        packageURL: URL
    ) throws {
        try ProjectValidation.validate(project)
        let paths = ProjectPackagePaths(packageURL: packageURL)
        try ProjectAtomicWriter.write(
            project,
            to: paths.projectJSON,
            temporaryDirectory: paths.tempDirectory,
            fileManager: fileManager
        )
    }

    private func readDocument<T: Decodable>(
        _ type: T.Type,
        at url: URL,
        relativePath: String
    ) throws -> T {
        let data: Data
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= ReadAloudSafety.maximumDocumentBytes else {
                throw ProjectStoreError.invalidData("Project document exceeds safe loading limits.")
            }
            data = try Data(contentsOf: url)
        } catch {
            throw ProjectStoreError.corruptDocument(
                relativePath: relativePath,
                reason: String(describing: error)
            )
        }
        return try ProjectJSONCodec.decode(
            type,
            from: data,
            relativePath: relativePath
        )
    }

    private func retainSource(
        _ source: ProjectRetainedSource,
        project: ProjectDocument,
        paths: ProjectPackagePaths
    ) throws {
        let destination = try packageURL(
            forRelativePath: project.source.relativePath,
            in: paths.packageURL
        )

        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            switch source {
            case .file(let sourceURL):
                try fileManager.copyItem(at: sourceURL, to: destination)
            case .data(let data):
                try data.write(to: destination, options: .atomic)
            }
        } catch {
            throw ProjectStoreError.io(
                "Unable to retain original source: \(error)"
            )
        }

        let revision = try ProjectDigest.sha256(fileAt: destination)
        guard revision == project.source.sourceRevision else {
            throw ProjectStoreError.invalidData(
                "Retained source bytes do not match sourceRevision"
            )
        }
    }

    private func retainArtwork(
        _ artwork: ProjectRetainedArtwork?,
        project: ProjectDocument,
        paths: ProjectPackagePaths
    ) throws {
        switch (project.artwork, artwork) {
        case (nil, nil):
            return
        case (.some, nil), (nil, .some):
            throw ProjectStoreError.invalidData(
                "Project artwork metadata and retained artwork must agree"
            )
        case (.some(let metadata), .some(let artwork)):
            let destination = try packageURL(
                forRelativePath: metadata.relativePath,
                in: paths.packageURL
            )
            do {
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try artwork.data.write(to: destination, options: .atomic)
            } catch {
                throw ProjectStoreError.io(
                    "Unable to retain project artwork: \(error)"
                )
            }
        }
    }

    private func packageURL(
        forRelativePath relativePath: String,
        in packageURL: URL
    ) throws -> URL {
        try ProjectValidation.requireSafeRelativePath(relativePath)

        var result = packageURL
        for component in relativePath.split(separator: "/") {
            result.append(
                path: String(component),
                directoryHint: .inferFromPath
            )
        }

        let root = packageURL.standardizedFileURL.path
        let target = result.standardizedFileURL.path
        guard target.hasPrefix("\(root)/") else {
            throw ProjectStoreError.unsafeRelativePath(relativePath)
        }
        return result
    }

    private func loadContentManifest(
        paths: ProjectPackagePaths
    ) throws -> ProjectContentManifest {
        let manifest: ProjectContentManifest = try readDocument(
            ProjectContentManifest.self,
            at: paths.contentManifest,
            relativePath: "content/manifest.json"
        )
        try ProjectValidation.validate(manifest)
        return manifest
    }

    private func requireQueueOwnership(
        _ queue: ProjectQueueDocument,
        projectID: UUID,
        itemIDs: Set<UUID>
    ) throws {
        for job in queue.jobs {
            guard job.projectID == projectID else {
                throw ProjectStoreError.invalidData(
                    "Queue job projectID does not match its project package"
                )
            }
            guard itemIDs.contains(job.itemID) else {
                throw ProjectStoreError.invalidData(
                    "Queue job itemID is not represented by the content manifest"
                )
            }
        }
    }

    private func requireAudioMetadataCompatibility(
        _ metadata: GeneratedAudioMetadata,
        in paths: ProjectPackagePaths
    ) throws {
        let project = try loadProjectDocument(at: paths.packageURL)
        let item = try effectiveContentItem(
            projectID: project.id, itemID: metadata.itemID
        )

        guard item.id == metadata.itemID,
              item.contentRevision == metadata.contentRevision else {
            throw ProjectStoreError.invalidData(
                "Audio metadata content revision does not match its item"
            )
        }

        let textLength = item.text.utf16.count
        guard metadata.segments.allSatisfy({
            $0.sourceRange.endUTF16 <= textLength
        }) else {
            throw ProjectStoreError.invalidData(
                "Audio metadata source range exceeds normalized item text"
            )
        }
    }

    private func validateContentBundle(
        manifest: ProjectContentManifest,
        items: [ProjectContentItem]
    ) throws {
        try ProjectValidation.validate(manifest)

        var itemByID: [UUID: ProjectContentItem] = [:]
        for item in items {
            guard itemByID[item.id] == nil else {
                throw ProjectStoreError.invalidData(
                    "Content bundle contains duplicate item IDs"
                )
            }
            itemByID[item.id] = item
        }
        guard itemByID.count == manifest.items.count else {
            throw ProjectStoreError.invalidData(
                "Manifest and content items must have identical unique IDs"
            )
        }

        for entry in manifest.items {
            guard let item = itemByID[entry.id] else {
                throw ProjectStoreError.invalidData(
                    "Manifest references a missing content item"
                )
            }
            try ProjectValidation.validate(item)
            guard item.order == entry.order else {
                throw ProjectStoreError.invalidData(
                    "Content item order does not match manifest"
                )
            }
        }

        let revision = try ProjectContentRevision.project(
            manifestItems: manifest.items,
            items: items
        )
        guard revision == manifest.contentRevision else {
            throw ProjectStoreError.invalidData(
                "Project contentRevision does not match ordered content"
            )
        }
    }

    private func touchProject(
        projectID: UUID,
        at date: Date
    ) throws {
        var project = try loadProjectMetadata(projectID: projectID)
        project.updatedAt = date
        try writeProjectDocument(
            project,
            packageURL: packageURL(for: projectID)
        )
    }

    private func audioByteCount(at url: URL) -> Int64? {
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard let size = values.fileSize else { return nil }
            return Int64(size)
        } catch {
            return nil
        }
    }

    private func createPackageDirectories(
        _ paths: ProjectPackagePaths
    ) throws {
        let directories = [
            paths.packageURL,
            paths.sourceDirectory,
            paths.contentDirectory,
            paths.contentItemsDirectory,
            paths.queueDirectory,
            paths.cacheDirectory,
            paths.paragraphCacheDirectory,
            paths.artworkCacheDirectory,
            paths.audioDirectory,
            paths.assetsDirectory,
            paths.tempDirectory,
        ]

        do {
            for directory in directories {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
            }
        } catch {
            throw ProjectStoreError.io(String(describing: error))
        }
    }

    private func requirePackageDirectory(_ url: URL) throws {
        let root = rootURL.standardizedFileURL.path
        let target = url.standardizedFileURL.path

        guard target.hasPrefix("\(root)/"),
              url.pathExtension == ProjectSchema.packageExtension else {
            throw ProjectStoreError.invalidPackage(
                "Package path is outside the project root"
            )
        }

        do {
            let values = try url.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true,
                  values.isSymbolicLink != true else {
                throw ProjectStoreError.invalidPackage(
                    "Package must be a non-symlink directory"
                )
            }
        } catch let error as ProjectStoreError {
            throw error
        } catch {
            throw ProjectStoreError.invalidPackage(
                String(describing: error)
            )
        }
    }

    private func requirePackageIdentity(
        project: ProjectDocument,
        packageURL: URL
    ) throws {
        let expected = ProjectPackagePaths.packageName(project.id)
        guard packageURL.lastPathComponent == expected else {
            throw ProjectStoreError.invalidPackage(
                "Package filename must match project ID \(expected)"
            )
        }
    }

    private func catalogIssueKind(
        for error: Error
    ) -> ProjectCatalogIssueKind {
        guard let error = error as? ProjectStoreError else {
            return .unreadable
        }

        switch error {
        case .unsupportedFutureSchema,
             .unsupportedLegacySchema:
            return .unsupportedSchema
        case .invalidPackage,
             .identityMismatch,
             .unsafeRelativePath:
            return .invalidPackage
        case .corruptDocument,
             .invalidData:
            return .corrupt
        case .projectNotFound,
             .projectAlreadyExists,
             .io:
            return .unreadable
        }
    }

    nonisolated private static func message(
        for error: Error
    ) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}


