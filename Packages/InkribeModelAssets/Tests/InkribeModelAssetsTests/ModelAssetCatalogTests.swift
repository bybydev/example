import Foundation
import Testing
@testable import InkribeModelAssets

@Suite("Model asset catalog")
struct ModelAssetCatalogTests {
    @Test func productionManifestHasOneAssetPerRuntime() throws {
        let manifest = try ModelAssetCatalog.bundledManifest()
        #expect(manifest.schemaVersion == 1)
        #expect(manifest.assets.count == ModelRuntime.allCases.count)
        #expect(try manifest.asset(runtime: .whisper).id == "whisper-small-multilingual")
        #expect(try manifest.asset(runtime: .llm).id == "qwen3-1.7b-q4-k-m")
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
        #expect(try manifest.asset(runtime: .llm).relativePath == "qwen/Qwen3-1.7B-Q4_K_M.gguf")
    }

    @Test func locatorUsesStableModelsRootAndRelativePath() throws {
        let root = URL(fileURLWithPath: "/tmp/InkribeResources", isDirectory: true)
        let locator = ModelAssetLocator(resourcesURL: root)
        let asset = try ModelAssetCatalog.bundledManifest().asset(runtime: .whisper)
        #expect(locator.url(for: asset).path == "/tmp/InkribeResources/Models/whisper/ggml-small.bin")
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
}
