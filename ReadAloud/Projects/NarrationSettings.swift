import Foundation

nonisolated struct NarrationVoice: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let name: String
}

nonisolated enum ReadAloudNarrationCatalog {
    static let voices: [NarrationVoice] = [
        NarrationVoice(id: "af_heart", name: "Heart"),
        NarrationVoice(id: "af_bella", name: "Bella"),
        NarrationVoice(id: "am_michael", name: "Michael"),
    ]

    static let synthesisSpeeds: [Double] = [0.8, 1.0, 1.2]
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
    static let synthesisConfigVersion = 4

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

        guard hasPro else {
            return projectResolved
        }

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
                        hasPro: true
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
                kokoroRuntimeRevision: runtimeRevision,
                synthesisConfigVersion:
                    ReadAloudNarrationCatalog.synthesisConfigVersion
            )
        )
    }
}

