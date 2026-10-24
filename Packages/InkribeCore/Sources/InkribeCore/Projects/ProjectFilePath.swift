import Foundation

/// Resolve the existing owner once, then append validated components. A new
/// sidecar is allowed to be absent; resolving that nonexistent leaf separately
/// can produce a different sandbox alias on Darwin (/var versus /private/var).
public enum ProjectFilePath {
    public static func url(for relativePath: String, in directory: URL) throws -> URL {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard directory.isFileURL, !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." &&
                  !$0.contains("\\") && !$0.contains(":") &&
                  !$0.contains("\0") && !$0.contains("%") }) else {
            throw ProjectStoreError.invalidPath(relativePath)
        }
        let files = FileManager.default
        let attributes = try files.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw ProjectStoreError.invalidPath(directory.path)
        }
        var result = directory.resolvingSymlinksInPath().standardizedFileURL
        for (index, part) in parts.enumerated() {
            result.appendPathComponent(String(part))
            do {
                let attributes = try files.attributesOfItem(atPath: result.path)
                let type = attributes[.type] as? FileAttributeType
                // Reject even a dangling link. Intermediate components must
                // be directories; a regular file cannot own a child path.
                guard type != .typeSymbolicLink,
                      index == parts.count - 1 || type == .typeDirectory else {
                    throw ProjectStoreError.invalidPath(relativePath)
                }
            } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
                (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
                // A valid prospective file/directory remains inside its owner
                // by construction. Never canonicalize a missing descendant.
                continue
            }
        }
        return result
    }
}
