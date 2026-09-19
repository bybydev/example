import Foundation
import InkribeTranscription
import LLMRuntime
import Testing
@testable import Inkribe

@Suite("Inkribe preferences", .serialized)
@MainActor
struct InkribePreferencesTests {
    @Test func defaultsPersistAndNormalizeAcrossOwners() throws {
        let suiteName = "InkribePreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("unsupported", forKey: "Inkribe.preferences.defaultTranscriptionLanguage")
        defaults.set("   ", forKey: "Inkribe.preferences.defaultMicrophoneDeviceID")
        defaults.set("removed-model", forKey: "Inkribe.preferences.localAIModel")

        let first = InkribePreferences(defaults: defaults)
        #expect(first.defaultTranscriptionLanguage == TranscriptionLanguageCatalog.automaticCode)
        #expect(first.defaultMicrophoneDeviceID == nil)
        #expect(first.keepAIModelLoaded == false)
        #expect(first.localAIModel == .qwen3_0_6B)
        #expect(defaults.string(forKey: "Inkribe.preferences.defaultTranscriptionLanguage") == "auto")
        #expect(defaults.string(forKey: "Inkribe.preferences.localAIModel") == LLMModel.defaultModel.rawValue)
        #expect(defaults.object(forKey: "Inkribe.preferences.defaultMicrophoneDeviceID") == nil)

        first.defaultTranscriptionLanguage = "VI"
        first.defaultMicrophoneDeviceID = "  device-123  "
        first.keepAIModelLoaded = true
        first.localAIModel = .qwen3_1_7B

        #expect(first.defaultTranscriptionLanguage == "vi")
        #expect(first.defaultMicrophoneDeviceID == "device-123")
        #expect(defaults.string(forKey: "Inkribe.preferences.defaultMicrophoneDeviceID") == "device-123")

        let second = InkribePreferences(defaults: defaults)
        #expect(second.defaultTranscriptionLanguage == "vi")
        #expect(second.defaultMicrophoneDeviceID == "device-123")
        #expect(second.keepAIModelLoaded)
        #expect(second.localAIModel == .qwen3_1_7B)
    }

    @Test func resetRestoresSafeWorkflowDefaults() throws {
        let suiteName = "InkribePreferencesResetTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = InkribePreferences(defaults: defaults)
        preferences.defaultTranscriptionLanguage = "ja"
        preferences.defaultMicrophoneDeviceID = "external-mic"
        preferences.keepAIModelLoaded = true
        preferences.localAIModel = .qwen3_1_7B

        preferences.resetWorkflowDefaults()

        #expect(preferences.defaultTranscriptionLanguage == TranscriptionLanguageCatalog.automaticCode)
        #expect(preferences.defaultMicrophoneDeviceID == nil)
        #expect(preferences.keepAIModelLoaded == false)
        #expect(preferences.localAIModel == .qwen3_0_6B)
        #expect(defaults.string(forKey: "Inkribe.preferences.defaultTranscriptionLanguage") == "auto")
        #expect(defaults.object(forKey: "Inkribe.preferences.defaultMicrophoneDeviceID") == nil)
        #expect(defaults.bool(forKey: "Inkribe.preferences.keepAIModelLoaded") == false)
        #expect(defaults.string(forKey: "Inkribe.preferences.localAIModel") == LLMModel.defaultModel.rawValue)
    }
}
