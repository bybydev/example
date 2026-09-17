import Foundation

enum InkribeAppDirectories {
    static func applicationSupportDirectory(
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw DirectoryError.applicationSupportUnavailable
        }

        let directory = base.appendingPathComponent("Inkribe", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    static func jobStoreURL(fileManager: FileManager = .default) throws -> URL {
        try applicationSupportDirectory(fileManager: fileManager)
            .appendingPathComponent("jobs.json", isDirectory: false)
    }

    enum DirectoryError: LocalizedError {
        case applicationSupportUnavailable

        var errorDescription: String? {
            "The application support directory is unavailable."
        }
    }
}
