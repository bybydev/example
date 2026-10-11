import Foundation

nonisolated enum ReadAloudNarrationCatalog {
    static let voices: [SpeechVoice] = SpeechVoice.all

    /// The same 0.5×–2.0×, 0.1-step range as Spokio iOS.
    static let speedRange: ClosedRange<Double> = 0.5...2.0
    static let speedStep = 0.1
    static let speedPresets: [Double] = [0.5, 1.0, 1.5, 2.0]
    static let synthesisSpeeds: [Double] = (5...20).map { Double($0) / 10 }

    static func isSupportedSpeed(_ value: Double) -> Bool {
        guard value.isFinite, speedRange.contains(value) else { return false }
        let tenths = value * 10
        return abs(tenths - tenths.rounded()) < 0.000_001
    }

    static func roundedSpeed(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        let bounded = min(max(value, speedRange.lowerBound), speedRange.upperBound)
        return (bounded * 10).rounded() / 10
    }
    static let freeDefaultVoiceID =
        "af_heart"

    static var appDefaultVoiceID: String {
        ReadAloudPreferences
            .defaultVoiceID
    }

    static var appDefaultSpeed: Double {
        ReadAloudPreferences
            .defaultSpeed
    }
    static let synthesisConfigVersion = 5

    static func voiceName(_ id: String) -> String {
        voices.first(where: { $0.id == id })?.name ?? id
    }
}

nonisolated struct ResolvedNarrationSettings: Equatable, Sendable {
    let voiceID: String
    let speed: Double
}

nonisolated enum NarrationSettingsResolver {
    static func resolveProject(
        _ project: ProjectNarrationSettings,
        hasPro: Bool = true
    ) -> ResolvedNarrationSettings {
        let requestedVoiceID =
            project.voiceID
            ?? ReadAloudNarrationCatalog
                .appDefaultVoiceID

        return ResolvedNarrationSettings(
            voiceID:
                ReadAloudAccessPolicy
                    .effectiveVoiceID(
                        requestedVoiceID,
                        hasPro: hasPro
                    ),
            speed:
                project.speed
                ?? ReadAloudNarrationCatalog
                    .appDefaultSpeed
        )
    }

    static func resolve(
        item: ItemNarrationSettings,
        project: ProjectNarrationSettings,
        hasPro: Bool = true
    ) throws -> ResolvedNarrationSettings {
        let projectResolved =
            resolveProject(
                project,
                hasPro: hasPro
            )

        let voiceID: String
        switch item.voice.mode {
        case .inherit:
            voiceID =
                projectResolved.voiceID
        case .custom:
            guard let custom =
                    item.voice.customValue,
                  !custom.isEmpty else {
                throw ProjectStoreError
                    .invalidData(
                        "Custom item voice requires a remembered voice."
                    )
            }
            voiceID =
                ReadAloudAccessPolicy
                    .effectiveVoiceID(
                        custom,
                        hasPro: hasPro
                    )
        }

        let speed: Double
        switch item.speed.mode {
        case .inherit:
            speed =
                projectResolved.speed
        case .custom:
            guard let custom =
                    item.speed.customValue,
                  custom.isFinite,
                  custom > 0 else {
                throw ProjectStoreError
                    .invalidData(
                        "Custom item speed requires a valid remembered speed."
                    )
            }
            speed = custom
        }

        return ResolvedNarrationSettings(
            voiceID: voiceID,
            speed: speed
        )
    }
}

nonisolated enum ReadAloudSynthesisContract {
    static func runtimeRevision() throws -> String {
        SpeechEngineKind.onnxINT8.runtimeRevisionOverride
    }

    static func generationKey(
        item: ProjectContentItem,
        resolved: ResolvedNarrationSettings
    ) throws -> String {
        try generationKey(
            item: item,
            resolved: resolved,
            runtimeRevision: runtimeRevision()
        )
    }

    static func generationKey(
        item: ProjectContentItem,
        resolved: ResolvedNarrationSettings,
        runtimeRevision: String
    ) throws -> String {
        try ProjectGenerationKey.make(
            GenerationKeyInput(
                contentRevision: item.contentRevision,
                resolvedVoiceID: resolved.voiceID,
                canonicalSpeed: resolved.speed,
                // Different modes can synthesize different audio for identical text.
                kokoroRuntimeRevision: runtimeRevision + "-g2p-"
                    + ReadAloudPreferences.pronunciationFallbackMode.rawValue,
                synthesisConfigVersion:
                    ReadAloudNarrationCatalog.synthesisConfigVersion
            )
        )
    }
}

