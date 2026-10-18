import Foundation

nonisolated struct ProjectPackagePaths: Sendable {
    let packageURL: URL

    var projectJSON: URL {
        packageURL.appending(path: "project.json")
    }

    var sourceDirectory: URL {
        packageURL.appending(path: "source", directoryHint: .isDirectory)
    }

    var contentDirectory: URL {
        packageURL.appending(path: "content", directoryHint: .isDirectory)
    }

    var contentManifest: URL {
        contentDirectory.appending(path: "manifest.json")
    }

    var contentItemsDirectory: URL {
        contentDirectory.appending(path: "items", directoryHint: .isDirectory)
    }

    var queueDirectory: URL {
        packageURL.appending(path: "queue", directoryHint: .isDirectory)
    }

    var queueJobs: URL {
        queueDirectory.appending(path: "jobs.json")
    }

    var cacheDirectory: URL {
        packageURL.appending(path: "cache", directoryHint: .isDirectory)
    }

    var chunkCacheDirectory: URL {
        cacheDirectory.appending(path: "chunks", directoryHint: .isDirectory)
    }

    var parsedOutputCache: URL {
        cacheDirectory.appending(path: "parsed/blocks.json")
    }

    var paragraphCacheDirectory: URL {
        cacheDirectory.appending(path: "paragraphs", directoryHint: .isDirectory)
    }

    var artworkCacheDirectory: URL {
        cacheDirectory.appending(path: "artwork", directoryHint: .isDirectory)
    }

    var audioDirectory: URL {
        packageURL.appending(path: "audio", directoryHint: .isDirectory)
    }

    var assetsDirectory: URL {
        packageURL.appending(path: "assets", directoryHint: .isDirectory)
    }

    var tempDirectory: URL {
        packageURL.appending(path: "temp", directoryHint: .isDirectory)
    }

    func itemJSON(_ itemID: UUID) -> URL {
        contentItemsDirectory.appending(
            path: "\(Self.fileID(itemID)).json"
        )
    }

    func audioWAV(_ itemID: UUID) -> URL {
        audioDirectory.appending(
            path: "\(Self.fileID(itemID)).wav"
        )
    }

    func audioMetadata(_ itemID: UUID) -> URL {
        audioDirectory.appending(
            path: "\(Self.fileID(itemID)).metadata.json"
        )
    }

    static func fileID(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }

    static func packageName(_ id: UUID) -> String {
        "\(fileID(id)).\(ProjectSchema.packageExtension)"
    }

    static func projectsRoot(
        fileManager: FileManager = .default
    ) throws -> URL {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let root = support
            .appending(path: "ReadAloud", directoryHint: .isDirectory)
            .appending(path: "Projects", directoryHint: .isDirectory)

        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        return root
    }

    static func packageURL(
        projectID: UUID,
        rootURL: URL
    ) -> URL {
        rootURL.appending(
            path: packageName(projectID),
            directoryHint: .isDirectory
        )
    }

    static func relativeItemPath(_ itemID: UUID) -> String {
        "content/items/\(fileID(itemID)).json"
    }

    static func relativeAudioMetadataPath(_ itemID: UUID) -> String {
        "audio/\(fileID(itemID)).metadata.json"
    }
}
