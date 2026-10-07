import Foundation

enum KokoroResources {
    nonisolated enum ResourceMode: String, Sendable {
        case production
        case fixture
    }

    nonisolated private struct ResourceModeMarker: Decodable {
        let mode: String
    }

    nonisolated private struct ManifestShape: Decodable {
        let buckets: [Int]
    }

    nonisolated static let bundleSubdirectory = "Kokoro"
    nonisolated static let resourceModeMarker = "ReadAloudResourceMode.json"
    nonisolated static let voiceIDs = ["af_heart", "af_bella", "am_michael"]

    nonisolated static var resourceMode: ResourceMode {
        guard
            let root = try? rootURL(),
            let data = try? Data(
                contentsOf: root.appendingPathComponent(resourceModeMarker)
            ),
            let marker = try? JSONDecoder().decode(
                ResourceModeMarker.self,
                from: data
            ),
            let mode = ResourceMode(rawValue: marker.mode)
        else {
            // Missing/invalid staging metadata must fail closed to production
            // admission rather than enabling fixture assets accidentally.
            return .production
        }

        return mode
    }

    nonisolated static var buckets: [Int] {
        guard
            let data = try? Data(contentsOf: manifestURL()),
            let manifest = try? JSONDecoder().decode(ManifestShape.self, from: data),
            !manifest.buckets.isEmpty,
            manifest.buckets.allSatisfy({ $0 > 0 })
        else {
            return resourceMode == .fixture ? [15] : [3, 7, 10, 15, 30]
        }

        return manifest.buckets
    }

    nonisolated enum ResourceError: LocalizedError {
        case missingBundleResources
        case missingResource(String)
        case unsupportedBucket(Int)
        case unsupportedVoice(String)

        var errorDescription: String? {
            switch self {
            case .missingBundleResources:
                return "Kokoro resources are missing from the app bundle."
            case .missingResource(let path):
                return "Missing Kokoro resource: \(path)"
            case .unsupportedBucket(let bucket):
                return "Unsupported Kokoro bucket: \(bucket)s"
            case .unsupportedVoice(let voice):
                return "Unsupported Kokoro voice: \(voice)"
            }
        }
    }

    nonisolated static func rootURL(in bundle: Bundle = .main) throws -> URL {
        guard let resourceURL = bundle.resourceURL else {
            throw ResourceError.missingBundleResources
        }

        let root = resourceURL.appendingPathComponent(
            bundleSubdirectory,
            isDirectory: true
        )

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: root.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw ResourceError.missingBundleResources
        }

        return root
    }

    nonisolated static func manifestURL(in bundle: Bundle = .main) throws -> URL {
        try requiredURL(
            "KokoroRuntimeManifest.json",
            in: bundle,
            isDirectory: false
        )
    }

    nonisolated static func durationModelURL(in bundle: Bundle = .main) throws -> URL {
        try requiredURL(
            "coreml/kokoro_duration_t128.mlpackage",
            in: bundle,
            isDirectory: true
        )
    }

    nonisolated static func f0ModelURL(
        for bucket: Int,
        in bundle: Bundle = .main
    ) throws -> URL {
        try validate(bucket: bucket)
        return try requiredURL(
            "coreml/kokoro_f0ntrain_t\(bucket * 40).mlpackage",
            in: bundle,
            isDirectory: true
        )
    }

    nonisolated static func decoderPreModelURL(
        for bucket: Int,
        in bundle: Bundle = .main
    ) throws -> URL {
        try validate(bucket: bucket)
        return try requiredURL(
            "coreml/kokoro_decoder_pre_\(bucket)s.mlpackage",
            in: bundle,
            isDirectory: true
        )
    }

    nonisolated static func generatorModelURL(
        for bucket: Int,
        in bundle: Bundle = .main
    ) throws -> URL {
        try validate(bucket: bucket)
        return try requiredURL(
            "coreml/kokoro_decoder_har_post_\(bucket)s.mlpackage",
            in: bundle,
            isDirectory: true
        )
    }

    nonisolated static func voiceURL(
        for voiceID: String,
        in bundle: Bundle = .main
    ) throws -> URL {
        guard voiceIDs.contains(voiceID) else {
            throw ResourceError.unsupportedVoice(voiceID)
        }

        return try requiredURL(
            "voices/\(voiceID).bin",
            in: bundle,
            isDirectory: false
        )
    }

    nonisolated static func vocabularyURL(in bundle: Bundle = .main) throws -> URL {
        try requiredURL(
            "runtime/kokoro-vocab.json",
            in: bundle,
            isDirectory: false
        )
    }

    nonisolated static func hnsfWeightsURL(in bundle: Bundle = .main) throws -> URL {
        try requiredURL(
            "runtime/hnsf_weights.json",
            in: bundle,
            isDirectory: false
        )
    }

    nonisolated private static func validate(bucket: Int) throws {
        guard buckets.contains(bucket) else {
            throw ResourceError.unsupportedBucket(bucket)
        }
    }

    nonisolated private static func requiredURL(
        _ relativePath: String,
        in bundle: Bundle,
        isDirectory: Bool
    ) throws -> URL {
        let root = try rootURL(in: bundle)
        let url = root.appendingPathComponent(
            relativePath,
            isDirectory: isDirectory
        )

        var directoryFlag: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &directoryFlag
        )

        guard exists, directoryFlag.boolValue == isDirectory else {
            throw ResourceError.missingResource(relativePath)
        }

        return url
    }
}
