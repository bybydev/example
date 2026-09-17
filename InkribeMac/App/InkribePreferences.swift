import Foundation
import InkribeTranscription
import Observation

@MainActor
@Observable
final class InkribePreferences {
    static let shared = InkribePreferences()

    private enum Key {
        static let defaultTranscriptionLanguage = "Inkribe.preferences.defaultTranscriptionLanguage"
        static let defaultMicrophoneDeviceID = "Inkribe.preferences.defaultMicrophoneDeviceID"
        static let keepAIModelLoaded = "Inkribe.preferences.keepAIModelLoaded"
    }

    @ObservationIgnored private let defaults: UserDefaults
    private var storedDefaultTranscriptionLanguage: String
    private var storedDefaultMicrophoneDeviceID: String?
    private var storedKeepAIModelLoaded: Bool

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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.defaultTranscriptionLanguage: TranscriptionLanguageCatalog.automaticCode,
            Key.keepAIModelLoaded: false
        ])

        storedDefaultTranscriptionLanguage = TranscriptionLanguageCatalog.normalizedSelection(
            defaults.string(forKey: Key.defaultTranscriptionLanguage)
        )
        storedDefaultMicrophoneDeviceID = defaults
            .string(forKey: Key.defaultMicrophoneDeviceID)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        storedKeepAIModelLoaded = defaults.bool(forKey: Key.keepAIModelLoaded)

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
    }

    func resetWorkflowDefaults() {
        defaultTranscriptionLanguage = TranscriptionLanguageCatalog.automaticCode
        defaultMicrophoneDeviceID = nil
        keepAIModelLoaded = false
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
