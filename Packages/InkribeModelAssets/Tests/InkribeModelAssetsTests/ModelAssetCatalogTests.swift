import Foundation
import Testing
@testable import InkribeModelAssets

@Suite("Model asset catalog")
struct ModelAssetCatalogTests {
    @Test func productionManifestSupportsMultipleLLMAssets() throws {
        let manifest = try ModelAssetCatalog.bundledManifest()
        #expect(manifest.schemaVersion == 1)
        #expect(manifest.assets.count == 5)
        #expect(try manifest.asset(runtime: .whisper).id == "whisper-small-multilingual")
        #expect(manifest.assets(runtime: .llm).map(\.id) == [
            "qwen3-0.6b-q4-k-m",
            "qwen3-1.7b-q4-k-m"
        ])
    }

    @Test func productionAssetsArePinnedToImmutableRevisions() throws {
        let manifest = try ModelAssetCatalog.bundledManifest()
        for asset in manifest.assets {
            #expect(asset.revision.count == 40)
            #expect(asset.downloadURL.scheme == "https")
            #expect(asset.downloadURL.absoluteString.contains("/\(asset.revision)/"))
            #expect(asset.sha256.count == 64)
            #expect(asset.byteCount > 0)
        }
    }

    @Test func productionPathsStayStable() throws {
        let manifest = try ModelAssetCatalog.bundledManifest()
        #expect(try manifest.asset(runtime: .whisper).relativePath == "whisper/ggml-small.bin")
        #expect(try manifest.asset(id: "qwen3-0.6b-q4-k-m").relativePath == "qwen/Qwen3-0.6B-Q4_K_M.gguf")
        #expect(try manifest.asset(id: "qwen3-1.7b-q4-k-m").relativePath == "qwen/Qwen3-1.7B-Q4_K_M.gguf")
        #expect(try manifest.asset(runtime: .speakerSegmentation).relativePath == "diarization/pyannote-segmentation-3.0.onnx")
        #expect(try manifest.asset(runtime: .speakerEmbedding).relativePath == "diarization/3dspeaker-eres2net-base.onnx")
    }

    @Test func locatorUsesStableModelsRootAndRelativePath() throws {
        let root = URL(fileURLWithPath: "/tmp/InkribeResources", isDirectory: true)
        let locator = ModelAssetLocator(resourcesURL: root)
        let asset = try ModelAssetCatalog.bundledManifest().asset(runtime: .whisper)
        #expect(locator.url(for: asset).path == "/tmp/InkribeResources/Models/whisper/ggml-small.bin")
    }

    @Test func committedFixturesUseProductionRelativePaths() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtureResources = repositoryRoot
            .appendingPathComponent("testfixtures", isDirectory: true)
        let locator = ModelAssetLocator(resourcesURL: fixtureResources)
        let manifest = try ModelAssetCatalog.bundledManifest()

        for asset in manifest.assets {
            let located = try locator.requireURL(for: asset)
            #expect(located.path.hasSuffix("/Models/\(asset.relativePath)"))

            do {
                _ = try locator.requireCheckedURL(for: asset)
                Issue.record("Tiny path fixtures must not impersonate production model weights")
            } catch let error as ModelAssetError {
                switch error {
                case .byteCountMismatch, .digestMismatch:
                    break
                default:
                    Issue.record("Unexpected fixture integrity error: \(error)")
                }
            }
        }
    }

    @Test func integrityInspectionReportsDigestAndSize() throws {
        let bytes = Data("inkribe-model-fixture\n".utf8)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try ModelAssetIntegrityChecker.inspect(url)
        #expect(result.byteCount == Int64(bytes.count))
        #expect(result.sha256.count == 64)
    }
    @Test func productionLicensesAreExplicit() throws {
        let manifest = try ModelAssetCatalog.bundledManifest()
        #expect(try manifest.asset(runtime: .whisper).license == "MIT")
        #expect(try manifest.asset(id: "qwen3-0.6b-q4-k-m").license == "Apache-2.0")
        #expect(try manifest.asset(id: "qwen3-1.7b-q4-k-m").license == "Apache-2.0")
        #expect(try manifest.asset(runtime: .speakerSegmentation).license == "MIT")
        #expect(try manifest.asset(runtime: .speakerEmbedding).license == "Apache-2.0")
    }

    @Test func locatorReportsMissingAssetAtExpectedPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let locator = ModelAssetLocator(resourcesURL: root)
        let asset = try ModelAssetCatalog.bundledManifest().asset(runtime: .whisper)
        let expected = locator.url(for: asset)

        do {
            _ = try locator.requireURL(for: asset)
            Issue.record("Missing model assets must fail")
        } catch let error as ModelAssetError {
            #expect(error == .missingAsset(asset.id, expectedURL: expected))
        }
    }

    @Test func integrityCheckerRejectsDirectoryAndSizeMismatch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        do {
            _ = try ModelAssetIntegrityChecker.inspect(root)
            Issue.record("Directories must not be accepted as model files")
        } catch let error as ModelAssetError {
            #expect(error == .notRegularFile(root))
        }

        let bytes = Data("wrong-size".utf8)
        let url = root.appendingPathComponent("model.bin")
        try bytes.write(to: url)
        let descriptor = ModelAssetDescriptor(
            id: "fixture",
            runtime: .whisper,
            displayName: "Fixture",
            relativePath: "whisper/model.bin",
            sourceRepository: "example/repo",
            revision: String(repeating: "a", count: 40),
            downloadURL: try #require(URL(string: "https://example.com/" + String(repeating: "a", count: 40) + "/model.bin")),
            sha256: String(repeating: "0", count: 64),
            byteCount: Int64(bytes.count + 1),
            license: "MIT"
        )

        do {
            try ModelAssetIntegrityChecker.check(url, against: descriptor)
            Issue.record("Wrong model byte count must fail")
        } catch let error as ModelAssetError {
            #expect(
                error == .byteCountMismatch(
                    "fixture",
                    expected: Int64(bytes.count + 1),
                    actual: Int64(bytes.count)
                )
            )
        }
    }

    @Test func integrityCheckerRejectsDigestMismatchAfterSizeMatches() throws {
        let bytes = Data("same-size-wrong-digest".utf8)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let descriptor = ModelAssetDescriptor(
            id: "fixture",
            runtime: .llm,
            displayName: "Fixture",
            relativePath: "qwen/model.gguf",
            sourceRepository: "example/repo",
            revision: String(repeating: "b", count: 40),
            downloadURL: try #require(URL(string: "https://example.com/" + String(repeating: "b", count: 40) + "/model.gguf")),
            sha256: String(repeating: "0", count: 64),
            byteCount: Int64(bytes.count),
            license: "Apache-2.0"
        )

        do {
            try ModelAssetIntegrityChecker.check(url, against: descriptor)
            Issue.record("Wrong model digest must fail")
        } catch let error as ModelAssetError {
            guard case .digestMismatch(let id, let expected, let actual) = error else {
                Issue.record("Expected digest mismatch, got \(error)")
                return
            }
            #expect(id == "fixture")
            #expect(expected == String(repeating: "0", count: 64))
            #expect(actual.count == 64)
            #expect(actual != expected)
        }
    }

}
