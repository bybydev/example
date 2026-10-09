import CryptoKit
import Foundation

/// Immutable, offline resources supplied with every ReadAloud build.
nonisolated enum ONNXResource: String, CaseIterable, Identifiable, Sendable {
    case kokoroModel, g2pModel, g2pLexicon, heart, bella, michael

    var id: String { rawValue }

    static func voice(_ id: String) -> ONNXResource? {
        switch id {
        case "af_heart": .heart
        case "af_bella": .bella
        case "am_michael": .michael
        default: nil
        }
    }

    var name: String {
        switch self {
        case .kokoroModel: "Kokoro INT8 Model"
        case .g2pModel: "G2P ONNX Model"
        case .g2pLexicon: "G2P Dictionary"
        case .heart: "Voice · Heart"
        case .bella: "Voice · Bella"
        case .michael: "Voice · Michael"
        }
    }

    var filename: String {
        switch self {
        case .kokoroModel: "model_quantized.onnx"
        case .g2pModel: "misaki-en_us-g2p.onnx"
        case .g2pLexicon: "misaki-en_us-g2p.json"
        case .heart: "af_heart.bin"
        case .bella: "af_bella.bin"
        case .michael: "am_michael.bin"
        }
    }

    var expectedSize: UInt64? {
        switch self {
        case .kokoroModel: nil // Exact digest guards the model.
        case .g2pModel: 3_438_244
        case .g2pLexicon: 5_724_857
        case .heart, .bella, .michael: 510 * 256 * 4
        }
    }

    var minimumSize: UInt64 {
        switch self {
        case .kokoroModel: 90_000_000
        case .g2pModel: 3_438_244
        case .g2pLexicon: 5_724_857
        case .heart, .bella, .michael: 510 * 256 * 4
        }
    }

    var expectedSHA256: String? {
        switch self {
        case .kokoroModel:
            "fbae9257e1e05ffc727e951ef9b9c98418e6d79f1c9b6b13bd59f5c9028a1478"
        case .g2pModel:
            "757759c3e3ccb0bf59c379b1671c9834a27543ceaefd6846850823633b9665a1"
        case .g2pLexicon:
            "8a8e3350713b0a00102425a5d5bd6b58b34854c74a3e8d837589f55212c51658"
        case .heart, .bella, .michael: nil
        }
    }

    var subdirectory: String {
        switch self {
        case .g2pModel, .g2pLexicon: "ONNXG2P"
        default: "KokoroONNX"
        }
    }
}

nonisolated enum ONNXResourceStatus: Equatable, Sendable {
    case missing, invalid, ready
}

nonisolated enum ONNXResourceError: LocalizedError {
    case missing(String), invalid(String)

    var errorDescription: String? {
        switch self {
        case .missing(let name):
            "Bundled ONNX resource is missing: \(name). Reinstall ReadAloud."
        case .invalid(let name):
            "Bundled ONNX resource failed integrity validation: \(name). Reinstall ReadAloud."
        }
    }
}

/// Build and release validate the full resource bundle. Runtime performs a
/// once-per-process integrity check, without network I/O or user downloads.
actor ONNXResourceStore {
    static let shared = ONNXResourceStore()
    private var verified: Set<ONNXResource> = []
    private var didCleanLegacyDownloads = false

    /// Older experimental versions put manually downloaded model copies into
    /// Application Support or Caches. These are not user projects or audio.
    /// Reclaim them after moving to bundled-only resources.
    private func cleanupLegacyDownloads() {
        guard !didCleanLegacyDownloads else { return }
        didCleanLegacyDownloads = true
        let manager = FileManager.default
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let cache = manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        for resource in ONNXResource.allCases {
            let oldSupport = support
                .appendingPathComponent(resource.subdirectory, isDirectory: true)
                .appendingPathComponent(resource.filename)
            try? manager.removeItem(at: oldSupport)
            let oldBenchmark = cache
                .appendingPathComponent("KokoroONNXBenchmark", isDirectory: true)
                .appendingPathComponent(resource.filename)
            try? manager.removeItem(at: oldBenchmark)
        }
    }

    private func destination(_ item: ONNXResource) throws -> URL {
        guard let root = Bundle.main.resourceURL else {
            throw ONNXResourceError.missing(item.name)
        }
        return root.appendingPathComponent("ONNX", isDirectory: true)
            .appendingPathComponent(item.subdirectory, isDirectory: true)
            .appendingPathComponent(item.filename)
    }

    func status(_ item: ONNXResource) throws -> ONNXResourceStatus {
        cleanupLegacyDownloads()
        let url = try destination(item)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        return try validate(url, item: item) ? .ready : .invalid
    }

    func installedURL(_ item: ONNXResource) throws -> URL {
        switch try status(item) {
        case .ready: return try destination(item)
        case .missing: throw ONNXResourceError.missing(item.name)
        case .invalid: throw ONNXResourceError.invalid(item.name)
        }
    }

    func require(_ items: [ONNXResource]) throws {
        for item in items { _ = try installedURL(item) }
    }

    private func validate(_ url: URL, item: ONNXResource) throws -> Bool {
        if verified.contains(item) { return true }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSize = attributes[.size] as? NSNumber else { return false }
        let size = fileSize.uint64Value
        guard size >= item.minimumSize,
              item.expectedSize == nil || size == item.expectedSize else { return false }

        if let digest = item.expectedSHA256 {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var hash = SHA256()
            while true {
                try Task.checkCancellation()
                let bytes = try file.read(upToCount: 1_048_576) ?? Data()
                if bytes.isEmpty { break }
                hash.update(data: bytes)
            }
            let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == digest else { return false }
        }
        verified.insert(item)
        return true
    }
}
