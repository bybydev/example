import Foundation

/// Applies only to recoverable pronunciation failures, never ONNX inference errors.
nonisolated enum PronunciationFallbackMode: String, CaseIterable, Identifiable, Sendable {
    case adaptive
    case skip
    case stopWithError

    var id: String { rawValue }
    var title: String {
        switch self {
        case .adaptive: "Adaptive"
        case .skip: "Skip"
        case .stopWithError: "Stop with Error"
        }
    }
    var explanation: String {
        switch self {
        case .adaptive:
            "Spell unpronounceable English words where possible; skip unsupported tokens."
        case .skip:
            "Skip tokens that cannot be pronounced, then continue listening."
        case .stopWithError:
            "Stop listening or generation and show an error for an unpronounceable token."
        }
    }
}

nonisolated enum ReadAloudPreferences {
    enum Key {
        static let hasCompletedOnboarding =
            "com.hoangbkit.readaloud.onboarding-completed"
        static let defaultVoiceID =
            "com.hoangbkit.readaloud.default-voice"
        static let defaultSpeed =
            "com.hoangbkit.readaloud.default-speed"
        static let pronunciationFallbackMode =
            "com.hoangbkit.readaloud.pronunciation-fallback-mode"
        static let skipInterval =
            "com.hoangbkit.readaloud.skip-interval"
        static let continueToNextChapter =
            "com.hoangbkit.readaloud.continue-next-chapter"
        static let prefetchCount =
            "com.hoangbkit.readaloud.prefetch-count"
        static let generateWhileListening =
            "com.hoangbkit.readaloud.generate-while-listening"
        static let backgroundPrefetchPaused =
            "com.hoangbkit.readaloud.background-prefetch-paused"
        static let analyticsEnabled =
            "com.hoangbkit.readaloud.analytics-enabled"
    }

    static var pronunciationFallbackMode: PronunciationFallbackMode {
        guard let raw = UserDefaults.standard.string(
            forKey: Key.pronunciationFallbackMode
        ) else { return .adaptive }
        return PronunciationFallbackMode(rawValue: raw) ?? .adaptive
    }

    static let supportedSkipIntervals =
        [15, 30, 60]
    static let supportedPrefetchCounts =
        [0, 1, 2]

    // Ignore any persisted experimental Core ML selection from old builds.
    static var speechEngine: SpeechEngineKind { .onnxINT8 }

    static var defaultVoiceID: String {
        let value =
            UserDefaults.standard
                .string(
                    forKey:
                        Key.defaultVoiceID
                )
        guard let value,
              ReadAloudNarrationCatalog
                .voices
                .contains(
                    where: {
                        $0.id == value
                    }
                )
        else {
            return ReadAloudNarrationCatalog
                .freeDefaultVoiceID
        }
        return value
    }

    static var defaultSpeed: Double {
        let defaults =
            UserDefaults.standard
        guard defaults.object(
            forKey: Key.defaultSpeed
        ) != nil else {
            return 1.0
        }

        let value =
            defaults.double(
                forKey:
                    Key.defaultSpeed
            )
        guard ReadAloudNarrationCatalog
            .isSupportedSpeed(value)
        else {
            return 1.0
        }
        return value
    }

    static var skipInterval: Int {
        let value =
            UserDefaults.standard
                .integer(
                    forKey:
                        Key.skipInterval
                )
        return supportedSkipIntervals
            .contains(value)
            ? value
            : 15
    }

    static var continueToNextChapter:
        Bool
    {
        let defaults =
            UserDefaults.standard
        guard defaults.object(
            forKey:
                Key.continueToNextChapter
        ) != nil else {
            return true
        }

        return defaults.bool(
            forKey:
                Key.continueToNextChapter
        )
    }

    static var prefetchCount: Int {
        let defaults =
            UserDefaults.standard
        guard defaults.object(
            forKey: Key.prefetchCount
        ) != nil else {
            return 2
        }

        let value =
            defaults.integer(
                forKey:
                    Key.prefetchCount
            )
        return supportedPrefetchCounts
            .contains(value)
            ? value
            : 2
    }

    static var generateWhileListening:
        Bool
    {
        let defaults =
            UserDefaults.standard
        guard defaults.object(
            forKey:
                Key.generateWhileListening
        ) != nil else {
            return true
        }

        return defaults.bool(
            forKey:
                Key.generateWhileListening
        )
    }

    /// Pauses queued offline generation and future auto-prefetch, not playback.
    static var backgroundPrefetchPaused: Bool {
        UserDefaults.standard.bool(forKey: Key.backgroundPrefetchPaused)
    }

    static var analyticsEnabled: Bool {
        UserDefaults.standard.bool(
            forKey:
                Key.analyticsEnabled
        )
    }
}
