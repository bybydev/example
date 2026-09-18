import Foundation
import Testing

@Suite("Release configuration")
struct ReleaseHardeningTests {
    @Test func releaseAppKeepsOfflineSandboxBoundary() throws {
        let root = repositoryRoot()
        let project = try String(
            contentsOf: root.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        let entitlements = try String(
            contentsOf: root.appendingPathComponent("InkribeMac/Resources/Inkribe.entitlements"),
            encoding: .utf8
        )

        #expect(project.contains("ENABLE_APP_SANDBOX: YES"))
        #expect(project.contains("ENABLE_HARDENED_RUNTIME: YES"))
        #expect(project.contains("ENABLE_INCOMING_NETWORK_CONNECTIONS: NO"))
        #expect(project.contains("ENABLE_OUTGOING_NETWORK_CONNECTIONS: NO"))
        #expect(!project.contains("ENABLE_OUTGOING_NETWORK_CONNECTIONS: YES"))

        #expect(entitlements.contains("com.apple.security.app-sandbox"))
        #expect(entitlements.contains("com.apple.security.device.audio-input"))
        #expect(entitlements.contains("com.apple.security.files.user-selected.read-write"))
        #expect(!entitlements.contains("com.apple.security.network.client"))
        #expect(!entitlements.contains("com.apple.security.network.server"))
    }

    @Test func releaseIdentityAndPrivacyDescriptionStayPinned() throws {
        let project = try String(
            contentsOf: repositoryRoot().appendingPathComponent("project.yml"),
            encoding: .utf8
        )

        #expect(project.contains("PRODUCT_BUNDLE_IDENTIFIER: com.hoangbkit.inkribe"))
        #expect(project.contains("MARKETING_VERSION: \"1.0\""))
        #expect(project.contains("INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO"))
        #expect(project.contains("INFOPLIST_KEY_NSMicrophoneUsageDescription:"))
    }


    @Test func shippingSourcesDoNotContainDirectNetworkClients() throws {
        let root = repositoryRoot()
        let sourceDirectories = [
            "InkribeMac",
            "Packages/InkribeCore/Sources/InkribeCore",
            "Packages/InkribeAudio/Sources/InkribeAudio",
            "Packages/InkribeTranscription/Sources/InkribeTranscription",
            "Packages/InkribeAI/Sources/InkribeAI",
            "Packages/InkribePersistence/Sources/InkribePersistence",
            "Packages/InkribeExport/Sources/InkribeExport",
            "Packages/InkribeModelAssets/Sources/InkribeModelAssets",
            "Packages/WhisperRuntime/Sources/WhisperRuntime",
            "Packages/LLMRuntime/Sources/LLMRuntime"
        ]
        let forbiddenAPIs = [
            "URLSession",
            "NWConnection",
            "NWPathMonitor",
            "WKWebView",
            "CFNetwork"
        ]

        for relativeDirectory in sourceDirectories {
            let directory = root.appendingPathComponent(relativeDirectory, isDirectory: true)
            let enumerator = try #require(
                FileManager.default.enumerator(
                    at: directory,
                    includingPropertiesForKeys: nil
                )
            )
            for case let fileURL as URL in enumerator
            where fileURL.pathExtension == "swift" {
                let source = try String(contentsOf: fileURL, encoding: .utf8)
                for forbiddenAPI in forbiddenAPIs {
                    #expect(
                        !source.contains(forbiddenAPI),
                        "Shipping source \(fileURL.lastPathComponent) uses \(forbiddenAPI)"
                    )
                }
            }
        }
    }

    @Test func thirdPartyNoticeInventoryPinsReleaseDependencies() throws {
        let notices = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("InkribeMac/Resources/ThirdPartyNotices.txt"),
            encoding: .utf8
        )

        #expect(notices.contains("JobQueue 1.0.0"))
        #expect(notices.contains("SwiftLog 1.11.0"))
        #expect(notices.contains("whisper.cpp 1.9.4 / b5130"))
        #expect(notices.contains("llama.cpp 0.4.1 / b10964"))
        #expect(notices.contains("90a64d80ea254cf67575b41a5971f972c79f7b45"))
        #expect(notices.contains("daeb8e2d528a760970442092f6bf1e55c3b659eb"))
        #expect(notices.contains("License declared by upstream model repository: MIT"))
        #expect(notices.contains("License declared by upstream model repository: Apache-2.0"))
        #expect(notices.contains("The SwiftLog Project"))
        #expect(notices.contains("Apache License"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
