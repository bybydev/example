import Foundation

/// Synchronous bounded traversal. contentsOfDirectory reports failures directly;
/// totals never silently omit a subtree after an enumerator callback fails.
public enum ProjectStorageScanner {
    public static func forEachFile(
        at root: URL, rejectSymbolicLinks: Bool,
        _ consume: (URL, Int64) throws -> Void
    ) throws {
        let files = FileManager.default
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw ProjectStoreError.invalidPath(root.path)
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var pending = [root]
        while let directory = pending.popLast() {
            for entry in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) {
                let values = try entry.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true {
                    if rejectSymbolicLinks { throw ProjectStoreError.invalidPath(entry.path) }
                    continue
                }
                if values.isDirectory == true {
                    pending.append(entry)
                } else if values.isRegularFile == true {
                    guard let size = values.fileSize, size >= 0 else { throw ProjectStoreError.unavailableRoot }
                    try consume(entry, Int64(size))
                }
            }
        }
    }

    public static func byteCount(at root: URL) throws -> Int64 {
        var total: Int64 = 0
        try forEachFile(at: root, rejectSymbolicLinks: false) { _, bytes in
            let (sum, overflow) = total.addingReportingOverflow(bytes)
            guard !overflow else { throw ProjectStoreError.invalidDocument("Storage size overflow") }
            total = sum
        }
        return total
    }
}
