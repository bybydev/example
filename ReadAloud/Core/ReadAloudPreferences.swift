import Foundation

nonisolated enum ReadAloudPreferences {
    enum Key {
        static let defaultVoiceID =
            "com.hoangbkit.readaloud.default-voice"
        static let defaultSpeed =
            "com.hoangbkit.readaloud.default-speed"
        static let skipInterval =
            "com.hoangbkit.readaloud.skip-interval"
        static let continueToNextChapter =
            "com.hoangbkit.readaloud.continue-next-chapter"
        static let prefetchCount =
            "com.hoangbkit.readaloud.prefetch-count"
        static let generateWhileListening =
            "com.hoangbkit.readaloud.generate-while-listening"
        static let analyticsEnabled =
            "com.hoangbkit.readaloud.analytics-enabled"
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
            .synthesisSpeeds
            .contains(value)
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

    static var analyticsEnabled: Bool {
        UserDefaults.standard.bool(
            forKey:
                Key.analyticsEnabled
        )
    }
}
