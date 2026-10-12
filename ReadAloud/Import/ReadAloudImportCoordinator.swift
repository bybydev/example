import Foundation

nonisolated struct ReadAloudImportCoordinator: Sendable {
    private let projectStore: ProjectStore
    private let epubImporter: EPUBImportAdapter
    private let pdfImporter: PDFImportAdapter
    private let textImporter: TextDocumentImportAdapter
    private let pasteImporter: PasteImportAdapter
    private let articleImporter: WebArticleImportAdapter
    private let urlLoader: ArticleURLLoader

    init(projectStore: ProjectStore) {
        self.projectStore = projectStore
        self.epubImporter = EPUBImportAdapter()
        self.pdfImporter = PDFImportAdapter()
        self.textImporter = TextDocumentImportAdapter()
        self.pasteImporter = PasteImportAdapter()
        self.articleImporter = WebArticleImportAdapter()
        self.urlLoader = ArticleURLLoader()
    }

    func importSource(
        _ source: ReadAloudImportSource,
        progress: (@Sendable (ReadAloudImportProgress) -> Void)? = nil
    ) async throws -> ReadAloudImportResult {
        try Task.checkCancellation()
        progress?(
            ReadAloudImportProgress(
                stage: .preparing,
                fractionCompleted: 0
            )
        )

        switch source {
        case .file(let url):
            return try await importFile(
                url,
                progress: progress
            )
        case .pastedText(let text, let suggestedTitle):
            return try await importPaste(
                text,
                suggestedTitle: suggestedTitle,
                progress: progress
            )
        case .web(let url):
            return try await importWeb(url, progress: progress)
        }
    }

    private func importFile(
        _ externalURL: URL,
        progress: (@Sendable (ReadAloudImportProgress) -> Void)?
    ) async throws -> ReadAloudImportResult {
        let fileName = externalURL.lastPathComponent
        let fileExtension = externalURL.pathExtension.lowercased()
        guard !fileExtension.isEmpty else {
            throw ReadAloudImportError.unsupportedFileType(fileName)
        }

        let importer = try adapter(
            forExtension: fileExtension,
            fileName: fileName
        )

        let fileManager = FileManager.default
        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }

        let localURL = workspace.appending(
            path: fileName,
            directoryHint: .notDirectory
        )

        let didAccess = externalURL.startAccessingSecurityScopedResource()
        do {
            try Task.checkCancellation()
            try fileManager.copyItem(
                at: externalURL,
                to: localURL
            )
        } catch {
            if didAccess {
                externalURL.stopAccessingSecurityScopedResource()
            }
            if error is CancellationError {
                throw error
            }
            throw ReadAloudImportError.sourceUnavailable(
                String(describing: error)
            )
        }
        if didAccess {
            externalURL.stopAccessingSecurityScopedResource()
        }

        try Task.checkCancellation()
        let retainedRevision = try ProjectDigest.sha256(fileAt: localURL)
        try Task.checkCancellation()
        let normalized = try await importer.importDocument(
            from: localURL,
            progress: progress
        )
        try Task.checkCancellation()

        return try await persist(
            normalized: normalized,
            originalFileName: fileName,
            retainedExtension: fileExtension,
            retainedRevision: retainedRevision,
            retainedSource: .file(localURL),
            progress: progress
        )
    }

    private func importPaste(
        _ text: String,
        suggestedTitle: String?,
        progress: (@Sendable (ReadAloudImportProgress) -> Void)?
    ) async throws -> ReadAloudImportResult {
        try Task.checkCancellation()
        progress?(
            ReadAloudImportProgress(
                stage: .normalizing,
                fractionCompleted: 0
            )
        )

        let normalized = try pasteImporter.importDocument(
            text: text,
            suggestedTitle: suggestedTitle
        )
        try Task.checkCancellation()
        let sourceData = Data(text.utf8)

        return try await persist(
            normalized: normalized,
            originalFileName: "pasted-text.txt",
            retainedExtension: "txt",
            retainedRevision: ProjectDigest.sha256(sourceData),
            retainedSource: .data(sourceData),
            progress: progress
        )
    }

    private func importWeb(
        _ url: URL,
        progress: (@Sendable (ReadAloudImportProgress) -> Void)?
    ) async throws -> ReadAloudImportResult {
        try Task.checkCancellation()
        let fetched = try await urlLoader.fetch(url, progress: progress)
        try Task.checkCancellation()

        if fetched.fileExtension == "html" {
            let extracted = try articleImporter.importDocument(
                data: fetched.data,
                finalURL: fetched.finalURL,
                progress: progress
            )
            try Task.checkCancellation()
            return try await persist(
                normalized: extracted.document,
                originalFileName: "article.html",
                retainedExtension: "html",
                retainedRevision: ProjectDigest.sha256(fetched.data),
                retainedSource: .data(fetched.data),
                progress: progress,
                provenance: ProjectWebProvenance(
                    originalURL: url,
                    siteName: extracted.siteName,
                    language: extracted.language,
                    publishedTime: extracted.publishedTime
                )
            )
        }

        let fileExtension = fetched.fileExtension
        let fileName = "downloaded.\(fileExtension)"
        let importer = try adapter(
            forExtension: fileExtension,
            fileName: fileName
        )
        let fileManager = FileManager.default
        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        let localURL = workspace.appending(path: fileName)
        try fetched.data.write(to: localURL, options: .atomic)
        try Task.checkCancellation()
        let normalized = try await importer.importDocument(
            from: localURL,
            progress: progress
        )
        try Task.checkCancellation()
        return try await persist(
            normalized: normalized,
            originalFileName: fileName,
            retainedExtension: fileExtension,
            retainedRevision: ProjectDigest.sha256(fetched.data),
            retainedSource: .file(localURL),
            progress: progress,
            provenance: ProjectWebProvenance(originalURL: url)
        )
    }

    private func adapter(
        forExtension fileExtension: String,
        fileName: String
    ) throws -> any ReadAloudDocumentImporting {
        switch fileExtension {
        case "epub":
            return epubImporter
        case "pdf":
            return pdfImporter
        default:
            guard textImporter.supportedFileExtensions.contains(fileExtension) else {
                throw ReadAloudImportError.unsupportedFileType(fileName)
            }
            return textImporter
        }
    }

    private func persist(
        normalized: NormalizedImportDocument,
        originalFileName: String,
        retainedExtension: String,
        retainedRevision: String,
        retainedSource: ProjectRetainedSource,
        progress: (@Sendable (ReadAloudImportProgress) -> Void)?,
        provenance: ProjectWebProvenance? = nil
    ) async throws -> ReadAloudImportResult {
        try Task.checkCancellation()

        let content = try ReadAloudContentNormalizer.makeContent(
            from: normalized.items
        )
        try Task.checkCancellation()
        let projectID = UUID()
        let sourceID = UUID()
        let sourcePath = "source/\(ProjectPackagePaths.fileID(sourceID)).\(retainedExtension)"
        let artwork = normalized.artwork.map {
            ProjectArtwork(
                relativePath: "cache/artwork/cover.\(sanitizedExtension($0.fileExtension))"
            )
        }

        let now = Date()
        let project = ProjectDocument(
            id: projectID,
            title: normalized.title,
            author: normalized.author,
            source: ProjectSource(
                id: sourceID,
                type: projectSourceType(for: normalized.kind),
                originalFileName: originalFileName,
                relativePath: sourcePath,
                sourceRevision: retainedRevision,
                originalURL: provenance?.originalURL,
                siteName: provenance?.siteName,
                language: provenance?.language,
                publishedTime: provenance?.publishedTime
            ),
            artwork: artwork,
            createdAt: now,
            updatedAt: now
        )

        progress?(
            ReadAloudImportProgress(
                stage: .persisting,
                fractionCompleted: 0
            )
        )

        try Task.checkCancellation()
        try await projectStore.createPackage(
            project: project,
            manifest: content.manifest,
            items: content.items,
            retainedSource: retainedSource,
            retainedArtwork: normalized.artwork.map {
                ProjectRetainedArtwork(data: $0.data)
            }
        )

        let snapshot = ProjectSnapshot(project: project)
        progress?(
            ReadAloudImportProgress(
                stage: .finished,
                fractionCompleted: 1
            )
        )

        return ReadAloudImportResult(
            project: project,
            snapshot: snapshot,
            diagnostics: normalized.diagnostics
        )
    }

    private func makeWorkspace() throws -> URL {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appending(
                path: "ReadAloudImport",
                directoryHint: .isDirectory
            )
        let workspace = root.appending(
            path: UUID().uuidString.lowercased(),
            directoryHint: .isDirectory
        )

        do {
            try fileManager.createDirectory(
                at: workspace,
                withIntermediateDirectories: true
            )
            return workspace
        } catch {
            throw ReadAloudImportError.sourceUnavailable(
                String(describing: error)
            )
        }
    }

    private func projectSourceType(
        for kind: ReadAloudImportKind
    ) -> ProjectSourceType {
        switch kind {
        case .epub:
            return .epub
        case .pdf:
            return .pdf
        case .document:
            return .document
        case .paste:
            return .paste
        case .article:
            return .article
        }
    }

    private func sanitizedExtension(_ raw: String) -> String {
        let normalized = raw
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }

        return normalized.isEmpty ? "bin" : normalized
    }
}
