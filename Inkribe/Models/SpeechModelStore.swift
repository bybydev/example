import CryptoKit
import Foundation
import InkribeModelAssets

struct SpeechModelLocation: Sendable {
    let descriptor: ModelAssetDescriptor
    let url: URL
}

struct SpeechModelInventory: Sendable {
    let bundled: Set<String>
    let cached: Set<String>
    let downloaded: Set<String>
    let cachedBytes: Int64
}

/// Sole owner of the iOS download directory. Never purged with thumbnails.
/// Leases prevent deleting a file while the native runtime holds it open.
actor SpeechModelStore {
    static let shared = SpeechModelStore()
    private var leases: [UUID: String] = [:]
    private var downloading: String?
    private var prepared = false

    private func root() throws -> URL {
        var root = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("InkribeIOSSpeechModels", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        if !prepared {
            // No background transfer/relaunch resume: discard only our abandoned staging files.
            for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                where file.pathExtension == "partial" {
                try FileManager.default.removeItem(at: file)
            }
            prepared = true
        }
        return root
    }

    private func cachedURL(_ model: ModelAssetDescriptor) throws -> URL {
        try root().appendingPathComponent(model.sha256 + ".bin")
    }

    func inventory() throws -> SpeechModelInventory {
        var bundled = Set<String>(), downloaded = Set<String>(), cached = Set<String>()
        var bytes: Int64 = 0
        for model in SpeechModelCatalog.all {
            if SpeechModelCatalog.bundledURL(model) != nil { bundled.insert(model.id) }
            let url = try cachedURL(model)
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                cached.insert(model.id)
                bytes += Int64(size)
                // Native load rechecks the full digest, even after a relaunch.
                if Int64(size) == model.byteCount { downloaded.insert(model.id) }
            }
        }
        return .init(bundled: bundled, cached: cached, downloaded: downloaded, cachedBytes: bytes)
    }

    func acquire(_ id: String, lease: UUID) throws -> SpeechModelLocation {
        let model = try SpeechModelCatalog.descriptor(id)
        let url: URL
        if let bundled = SpeechModelCatalog.bundledURL(model) {
            url = bundled
        } else {
            guard SpeechModelCatalog.downloadsEnabled else { throw ModelError.downloadsDisabled }
            let cached = try cachedURL(model)
            let size = try? cached.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard size.map(Int64.init) == model.byteCount else { throw ModelError.missing(model.displayName) }
            url = cached
        }
        leases[lease] = id
        return .init(descriptor: model, url: url)
    }

    func release(_ lease: UUID) { leases.removeValue(forKey: lease) }

    func remove(_ id: String) throws {
        guard !leases.values.contains(id) else { throw ModelError.inUse }
        guard downloading != id else { throw ModelError.busy }
        let url = try cachedURL(SpeechModelCatalog.descriptor(id))
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    func download(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard SpeechModelCatalog.downloadsEnabled else { throw ModelError.downloadsDisabled }
        guard downloading == nil else { throw ModelError.busy }
        let model = try SpeechModelCatalog.descriptor(id)
        let directory = try root()
        guard !leases.values.contains(id) else { throw ModelError.inUse }
        let free = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        if let free, free < model.byteCount + 64 * 1024 * 1024 { throw ModelError.insufficientSpace }
        downloading = id
        let partial = directory.appendingPathComponent(UUID().uuidString + ".partial")
        defer { downloading = nil; try? FileManager.default.removeItem(at: partial) }
        let transfer = ModelDownload()
        try await transfer.fetch(from: model.downloadURL, to: partial, expectedBytes: model.byteCount) {
            progress(min(0.95, Double($0) / Double(model.byteCount) * 0.95))
        }
        try Task.checkCancellation()
        // Bounded chunks and cancellation between reads; never load model-sized Data.
        let handle = try FileHandle(forReadingFrom: partial)
        defer { try? handle.close() }
        var hash = SHA256()
        var count: Int64 = 0
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            count += Int64(data.count)
            hash.update(data: data)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard count == model.byteCount, digest == model.sha256 else { throw ModelError.invalidDownload }
        try Task.checkCancellation()
        let final = try cachedURL(model)
        // Actor-serialized: acquire/remove cannot race this publication.
        guard !leases.values.contains(id) else { throw ModelError.inUse }
        if FileManager.default.fileExists(atPath: final.path) {
            _ = try FileManager.default.replaceItemAt(final, withItemAt: partial)
        } else {
            try FileManager.default.moveItem(at: partial, to: final)
        }
        progress(1)
    }
}
