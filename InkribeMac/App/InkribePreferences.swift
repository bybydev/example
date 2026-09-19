import Foundation
import InkribeTranscription
import LLMRuntime
import Observation

@MainActor
@Observable
final class InkribePreferences {
    static let shared = InkribePreferences()

    private enum Key {
        static let defaultTranscriptionLanguage = "Inkribe.preferences.defaultTranscriptionLanguage"
        static let defaultMicrophoneDeviceID = "Inkribe.preferences.defaultMicrophoneDeviceID"
        static let keepAIModelLoaded = "Inkribe.preferences.keepAIModelLoaded"
        static let localAIModel = "Inkribe.preferences.localAIModel"
    }

    @ObservationIgnored private let defaults: UserDefaults
    private var storedDefaultTranscriptionLanguage: String
    private var storedDefaultMicrophoneDeviceID: String?
    private var storedKeepAIModelLoaded: Bool
    private var storedLocalAIModel: LLMModel

    var defaultTranscriptionLanguage: String {
        get { storedDefaultTranscriptionLanguage }
        set {
            let normalized = TranscriptionLanguageCatalog.normalizedSelection(newValue)
            if storedDefaultTranscriptionLanguage != normalized {
                storedDefaultTranscriptionLanguage = normalized
            }
            defaults.set(normalized, forKey: Key.defaultTranscriptionLanguage)
        }
    }

    var defaultMicrophoneDeviceID: String? {
        get { storedDefaultMicrophoneDeviceID }
        set {
            let normalized = newValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
            if storedDefaultMicrophoneDeviceID != normalized {
                storedDefaultMicrophoneDeviceID = normalized
            }
            if let normalized {
                defaults.set(normalized, forKey: Key.defaultMicrophoneDeviceID)
            } else {
                defaults.removeObject(forKey: Key.defaultMicrophoneDeviceID)
            }
        }
    }

    var keepAIModelLoaded: Bool {
        get { storedKeepAIModelLoaded }
        set {
            if storedKeepAIModelLoaded != newValue {
                storedKeepAIModelLoaded = newValue
            }
            defaults.set(newValue, forKey: Key.keepAIModelLoaded)
        }
    }

    var localAIModel: LLMModel {
        get { storedLocalAIModel }
        set {
            if storedLocalAIModel != newValue {
                storedLocalAIModel = newValue
            }
            defaults.set(newValue.rawValue, forKey: Key.localAIModel)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.defaultTranscriptionLanguage: TranscriptionLanguageCatalog.automaticCode,
            Key.keepAIModelLoaded: false,
            Key.localAIModel: LLMModel.defaultModel.rawValue
        ])

        storedDefaultTranscriptionLanguage = TranscriptionLanguageCatalog.normalizedSelection(
            defaults.string(forKey: Key.defaultTranscriptionLanguage)
        )
        storedDefaultMicrophoneDeviceID = defaults
            .string(forKey: Key.defaultMicrophoneDeviceID)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        storedKeepAIModelLoaded = defaults.bool(forKey: Key.keepAIModelLoaded)
        storedLocalAIModel = LLMModel(
            rawValue: defaults.string(forKey: Key.localAIModel) ?? ""
        ) ?? .defaultModel

        defaults.set(
            storedDefaultTranscriptionLanguage,
            forKey: Key.defaultTranscriptionLanguage
        )
        if let storedDefaultMicrophoneDeviceID {
            defaults.set(storedDefaultMicrophoneDeviceID, forKey: Key.defaultMicrophoneDeviceID)
        } else {
            defaults.removeObject(forKey: Key.defaultMicrophoneDeviceID)
        }
        defaults.set(storedKeepAIModelLoaded, forKey: Key.keepAIModelLoaded)
        defaults.set(storedLocalAIModel.rawValue, forKey: Key.localAIModel)
    }

    func resetWorkflowDefaults() {
        defaultTranscriptionLanguage = TranscriptionLanguageCatalog.automaticCode
        defaultMicrophoneDeviceID = nil
        keepAIModelLoaded = false
        localAIModel = .defaultModel
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
