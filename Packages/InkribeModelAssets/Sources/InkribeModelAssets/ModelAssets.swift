import CryptoKit
import Foundation

public enum ModelRuntime: String, Codable, CaseIterable, Hashable, Sendable {
    case whisper
    case llm
    case speakerSegmentation
    case speakerEmbedding
}

public struct ModelAssetDescriptor: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let runtime: ModelRuntime
    public let displayName: String
    public let relativePath: String
    public let sourceRepository: String
    public let revision: String
    public let downloadURL: URL
    public let sha256: String
    public let byteCount: Int64
    public let license: String

    public init(
        id: String,
        runtime: ModelRuntime,
        displayName: String,
        relativePath: String,
        sourceRepository: String,
        revision: String,
        downloadURL: URL,
        sha256: String,
        byteCount: Int64,
        license: String
    ) {
        self.id = id
        self.runtime = runtime
        self.displayName = displayName
        self.relativePath = relativePath
        self.sourceRepository = sourceRepository
        self.revision = revision
        self.downloadURL = downloadURL
        self.sha256 = sha256
        self.byteCount = byteCount
        self.license = license
    }

    public var directory: String { (relativePath as NSString).deletingLastPathComponent }
    public var fileName: String { (relativePath as NSString).lastPathComponent }
}

public struct ModelAssetManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let assets: [ModelAssetDescriptor]

    public init(schemaVersion: Int, assets: [ModelAssetDescriptor]) {
        self.schemaVersion = schemaVersion
        self.assets = assets
    }

    public func asset(id: String) throws -> ModelAssetDescriptor {
        guard let asset = assets.first(where: { $0.id == id }) else {
            throw ModelAssetError.unknownAsset(id)
        }
        return asset
    }

    public func assets(runtime: ModelRuntime) -> [ModelAssetDescriptor] {
        assets.filter { $0.runtime == runtime }
    }

    public func asset(runtime: ModelRuntime) throws -> ModelAssetDescriptor {
        let matches = assets(runtime: runtime)
        guard !matches.isEmpty else {
            throw ModelAssetError.missingRuntimeAsset(runtime)
        }
        guard matches.count == 1 else {
            throw ModelAssetError.ambiguousRuntimeAsset(runtime, count: matches.count)
        }
        return matches[0]
    }
}

public enum ModelAssetCatalog {
    public static let resourceRootName = "Models"

    public static func bundledManifest() throws -> ModelAssetManifest {
        guard let url = Bundle.module.url(forResource: "ModelAssets", withExtension: "json") else {
            throw ModelAssetError.missingManifest
        }
        let manifest = try JSONDecoder().decode(ModelAssetManifest.self, from: Data(contentsOf: url))
        try checkManifestShape(manifest)
        return manifest
    }

    private static func checkManifestShape(_ manifest: ModelAssetManifest) throws {
        guard manifest.schemaVersion == 1 else {
            throw ModelAssetError.unsupportedManifestSchema(manifest.schemaVersion)
        }

        var ids = Set<String>()
        var paths = Set<String>()
        var runtimeCounts: [ModelRuntime: Int] = [:]
        let lowercaseHex = CharacterSet(charactersIn: "0123456789abcdef")

        for asset in manifest.assets {
            guard ids.insert(asset.id).inserted else { throw ModelAssetError.duplicateAssetID(asset.id) }
            guard paths.insert(asset.relativePath).inserted else { throw ModelAssetError.duplicateRelativePath(asset.relativePath) }
            runtimeCounts[asset.runtime, default: 0] += 1

            guard !asset.id.isEmpty, !asset.displayName.isEmpty, !asset.sourceRepository.isEmpty, !asset.license.isEmpty else {
                throw ModelAssetError.incompleteMetadata(asset.id)
            }
            let pathComponents = asset.relativePath.split(separator: "/", omittingEmptySubsequences: false)
            guard !asset.relativePath.isEmpty,
                  !asset.relativePath.hasPrefix("/"),
                  !pathComponents.contains(""),
                  !pathComponents.contains("."),
                  !pathComponents.contains("..") else {
                throw ModelAssetError.invalidRelativePath(asset.relativePath)
            }
            guard asset.revision.count == 40,
                  asset.revision.unicodeScalars.allSatisfy({ lowercaseHex.contains($0) }) else {
                throw ModelAssetError.invalidRevision(asset.id)
            }
            guard asset.downloadURL.scheme == "https",
                  asset.downloadURL.absoluteString.contains("/\(asset.revision)/") else {
                throw ModelAssetError.unpinnedDownloadURL(asset.id)
            }
            guard asset.sha256.count == 64,
                  asset.sha256.unicodeScalars.allSatisfy({ lowercaseHex.contains($0) }) else {
                throw ModelAssetError.invalidDigest(asset.id)
            }
            guard asset.byteCount > 0 else { throw ModelAssetError.invalidByteCount(asset.id) }
        }

        for runtime in ModelRuntime.allCases {
            let count = runtimeCounts[runtime, default: 0]
            guard count > 0 else {
                throw ModelAssetError.missingRuntimeAsset(runtime)
            }
            if runtime != .llm, count > 1 {
                throw ModelAssetError.duplicateRuntimeAsset(runtime)
            }
        }
    }
}

public struct ModelAssetLocator: Sendable {
    public let resourcesURL: URL

    public init(resourcesURL: URL) {
        self.resourcesURL = resourcesURL
    }

    public init(bundle: Bundle) throws {
        guard let resourcesURL = bundle.resourceURL else { throw ModelAssetError.missingBundleResources }
        self.resourcesURL = resourcesURL
    }

    public func url(for asset: ModelAssetDescriptor) -> URL {
        resourcesURL
            .appendingPathComponent(ModelAssetCatalog.resourceRootName, isDirectory: true)
            .appendingPathComponent(asset.relativePath, isDirectory: false)
    }

    public func requireURL(for asset: ModelAssetDescriptor) throws -> URL {
        let candidate = url(for: asset)
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            throw ModelAssetError.missingAsset(asset.id, expectedURL: candidate)
        }
        return candidate
    }

    public func requireCheckedURL(for asset: ModelAssetDescriptor) throws -> URL {
        let candidate = try requireURL(for: asset)
        try ModelAssetIntegrityChecker.check(candidate, against: asset)
        return candidate
    }
}

public struct ModelAssetIntegrity: Equatable, Sendable {
    public let byteCount: Int64
    public let sha256: String
}

public enum ModelAssetIntegrityChecker {
    public static func inspect(_ url: URL) throws -> ModelAssetIntegrity {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let fileSize = values.fileSize else {
            throw ModelAssetError.notRegularFile(url)
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return ModelAssetIntegrity(byteCount: Int64(fileSize), sha256: digest)
    }

    public static func check(_ url: URL, against asset: ModelAssetDescriptor) throws {
        let integrity = try inspect(url)
        guard integrity.byteCount == asset.byteCount else {
            throw ModelAssetError.byteCountMismatch(asset.id, expected: asset.byteCount, actual: integrity.byteCount)
        }
        guard integrity.sha256 == asset.sha256 else {
            throw ModelAssetError.digestMismatch(asset.id, expected: asset.sha256, actual: integrity.sha256)
        }
    }
}

public enum ModelAssetError: Error, Equatable, Sendable {
    case missingManifest
    case unsupportedManifestSchema(Int)
    case unknownAsset(String)
    case missingRuntimeAsset(ModelRuntime)
    case duplicateAssetID(String)
    case duplicateRelativePath(String)
    case duplicateRuntimeAsset(ModelRuntime)
    case ambiguousRuntimeAsset(ModelRuntime, count: Int)
    case incompleteMetadata(String)
    case invalidRelativePath(String)
    case invalidRevision(String)
    case unpinnedDownloadURL(String)
    case invalidDigest(String)
    case invalidByteCount(String)
    case missingBundleResources
    case missingAsset(String, expectedURL: URL)
    case notRegularFile(URL)
    case byteCountMismatch(String, expected: Int64, actual: Int64)
    case digestMismatch(String, expected: String, actual: String)
}

extension ModelAssetError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingManifest: "Bundled model manifest is missing."
        case .unsupportedManifestSchema(let version): "Unsupported model manifest schema \(version)."
        case .unknownAsset(let id): "Unknown model asset: \(id)."
        case .missingRuntimeAsset(let runtime): "No model is configured for runtime \(runtime.rawValue)."
        case .duplicateAssetID(let id): "Duplicate model asset id: \(id)."
        case .duplicateRelativePath(let path): "Duplicate model relative path: \(path)."
        case .duplicateRuntimeAsset(let runtime): "More than one model is configured for runtime \(runtime.rawValue)."
        case .ambiguousRuntimeAsset(let runtime, let count): "Runtime \(runtime.rawValue) has \(count) configured models; select one by asset ID."
        case .incompleteMetadata(let id): "Model metadata is incomplete for \(id)."
        case .invalidRelativePath(let path): "Invalid model relative path: \(path)."
        case .invalidRevision(let id): "Model \(id) does not use a 40-character immutable revision."
        case .unpinnedDownloadURL(let id): "Model \(id) download URL is not pinned to its immutable revision."
        case .invalidDigest(let id): "Model \(id) has an invalid SHA-256 digest."
        case .invalidByteCount(let id): "Model \(id) has an invalid byte count."
        case .missingBundleResources: "The resource bundle has no resource directory."
        case .missingAsset(let id, let url): "Model \(id) is missing at \(url.path)."
        case .notRegularFile(let url): "Expected a regular model file at \(url.path)."
        case .byteCountMismatch(let id, let expected, let actual): "Model \(id) size mismatch: expected \(expected) bytes, found \(actual)."
        case .digestMismatch(let id, let expected, let actual): "Model \(id) SHA-256 mismatch: expected \(expected), found \(actual)."
        }
    }
}
