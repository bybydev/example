import Foundation

public struct DurableMediaLocation: Equatable, Sendable {
    public let reference: DurableMediaReference
    public let url: URL

    public init(reference: DurableMediaReference, url: URL) {
        self.reference = reference
        self.url = url
    }
}

public actor DurableMediaStore {
    public enum StoreError: LocalizedError, Equatable, Sendable {
        case invalidRelativePath(String)
        case nonFileSource(String)
        case sourceMissing(String)

        public var errorDescription: String? {
            switch self {
            case .invalidRelativePath(let path):
                "Media path \(path) is outside Inkribe's media store."
            case .nonFileSource(let source):
                "Media source \(source) is not a local file URL."
            case .sourceMissing(let path):
                "The source media file is unavailable at \(path)."
            }
        }
    }

    private let rootDirectoryURL: URL
    private let fileManager: FileManager

    public init(rootDirectoryURL: URL, fileManager: FileManager = .default) {
        self.rootDirectoryURL = rootDirectoryURL.standardizedFileURL
        self.fileManager = fileManager
    }

    public func ingest(sourceURL: URL) throws -> DurableMediaReference {
        guard sourceURL.isFileURL else {
            throw StoreError.nonFileSource(sourceURL.absoluteString)
        }

        // Resolve aliases in the filesystem before copying so Inkribe owns the
        // source bytes rather than persisting a symlink that still points outside
        // the app-owned media root.
        let resolvedSource = sourceURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard fileManager.fileExists(atPath: resolvedSource.path) else {
            throw StoreError.sourceMissing(resolvedSource.path)
        }

        let extensionComponent = sanitizedExtension(resolvedSource.pathExtension)
        let filename = UUID().uuidString + (extensionComponent.isEmpty ? "" : ".\(extensionComponent)")
        let relativePath = "Sources/\(filename)"
        let destination = try resolvedURL(relativePath: relativePath)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let temporaryURL = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(filename).partial")
        try? fileManager.removeItem(at: temporaryURL)
        do {
            try fileManager.copyItem(at: resolvedSource, to: temporaryURL)
            try fileManager.moveItem(at: temporaryURL, to: destination)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }

        return DurableMediaReference(relativePath: relativePath)
    }

    public func makeRecordingDestination(fileExtension: String = "caf") throws -> DurableMediaLocation {
        let ext = sanitizedExtension(fileExtension)
        let filename = UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)")
        let relativePath = "Recordings/\(filename)"
        let url = try resolvedURL(relativePath: relativePath)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return DurableMediaLocation(
            reference: DurableMediaReference(relativePath: relativePath),
            url: url
        )
    }

    public func url(for reference: DurableMediaReference) throws -> URL {
        try resolvedURL(relativePath: reference.relativePath)
    }

    public func remove(_ reference: DurableMediaReference) throws {
        let url = try resolvedURL(relativePath: reference.relativePath)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func resolvedURL(relativePath: String) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..") else {
            throw StoreError.invalidRelativePath(relativePath)
        }

        let root = rootDirectoryURL.standardizedFileURL
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPrefix) else {
            throw StoreError.invalidRelativePath(relativePath)
        }
        return candidate
    }

    private func sanitizedExtension(_ value: String) -> String {
        let allowed = value.lowercased().filter { $0.isLetter || $0.isNumber }
        return String(allowed.prefix(12))
    }
}
