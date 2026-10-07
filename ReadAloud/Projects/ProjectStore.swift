import Foundation

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
    let rootURL: URL
    private let fileManager: FileManager

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
        retainedArtwork: ProjectRetainedArtwork? = nil
    ) throws {
        try ProjectValidation.validate(project)
        try ProjectValidation.validate(manifest)
        try ProjectValidation.validate(queue)
        try validateContentBundle(
            manifest: manifest,
            items: items
        )
        try requireQueueOwnership(
            queue,
            projectID: project.id,
            itemIDs: Set(items.map(\.id))
        )

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
            try retainArtwork(
                retainedArtwork,
                project: project,
                paths: paths
            )
            try ProjectAtomicWriter.write(
                project,
                to: paths.projectJSON,
                temporaryDirectory: paths.tempDirectory,
                fileManager: fileManager
            )
            for item in items {
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
            try fileManager.moveItem(at: stagingURL, to: finalURL)
        } catch {
            if fileManager.fileExists(atPath: stagingURL.path) {
                try? fileManager.removeItem(at: stagingURL)
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

    func loadSnapshot(projectID: UUID) throws -> ProjectSnapshot {
        ProjectSnapshot(project: try loadProjectMetadata(projectID: projectID))
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

    func loadProject(projectID: UUID) throws -> LoadedProject {
        let packageURL = try existingPackageURL(for: projectID)
        let paths = ProjectPackagePaths(packageURL: packageURL)

        let project = try loadProjectMetadata(projectID: projectID)
        let manifest: ProjectContentManifest = try readDocument(
            ProjectContentManifest.self,
            at: paths.contentManifest,
            relativePath: "content/manifest.json"
        )
        try ProjectValidation.validate(manifest)

        var items: [ProjectContentItem] = []
        items.reserveCapacity(manifest.items.count)

        for entry in manifest.items.sorted(by: { $0.order < $1.order }) {
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

        let queue: ProjectQueueDocument = try readDocument(
            ProjectQueueDocument.self,
            at: paths.queueJobs,
            relativePath: "queue/jobs.json"
        )
        try ProjectValidation.validate(queue)
        try requireQueueOwnership(
            queue,
            projectID: projectID,
            itemIDs: Set(manifest.items.map(\.id))
        )

        return LoadedProject(
            project: project,
            manifest: manifest,
            items: items,
            queue: queue
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
        project.settings = settings
        project.updatedAt = now
        try ProjectValidation.validate(project)
        try writeProjectDocument(
            project,
            packageURL: packageURL(for: projectID)
        )
        return project
    }

    @discardableResult
    func updatePlayback(
        projectID: UUID,
        playback: ProjectPlaybackState?,
        now: Date = .now
    ) throws -> ProjectDocument {
        var project = try loadProjectMetadata(projectID: projectID)
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
            itemIDs: Set(manifest.items.map(\.id))
        )
        try ProjectAtomicWriter.write(
            queue,
            to: paths.queueJobs,
            temporaryDirectory: paths.tempDirectory,
            fileManager: fileManager
        )
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
            itemIDs: Set(manifest.items.map(\.id))
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
        let manifest = try loadContentManifest(paths: paths)
        guard manifest.items.contains(where: { $0.id == metadata.itemID }) else {
            throw ProjectStoreError.invalidData(
                "Audio metadata item is not represented by the content manifest"
            )
        }

        let item: ProjectContentItem = try readDocument(
            ProjectContentItem.self,
            at: paths.itemJSON(metadata.itemID),
            relativePath: ProjectPackagePaths.relativeItemPath(metadata.itemID)
        )
        try ProjectValidation.validate(item)

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
