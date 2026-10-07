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
    static let appDefaultVoiceID = "af_heart"
    static let appDefaultSpeed = 1.0
    static let synthesisConfigVersion = 1

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
        _ project: ProjectNarrationSettings
    ) -> ResolvedNarrationSettings {
        ResolvedNarrationSettings(
            voiceID: project.voiceID
                ?? ReadAloudNarrationCatalog.appDefaultVoiceID,
            speed: project.speed
                ?? ReadAloudNarrationCatalog.appDefaultSpeed
        )
    }

    static func resolve(
        item: ItemNarrationSettings,
        project: ProjectNarrationSettings
    ) throws -> ResolvedNarrationSettings {
        let projectResolved = resolveProject(project)

        let voiceID: String
        switch item.voice.mode {
        case .inherit:
            voiceID = projectResolved.voiceID
        case .custom:
            guard let custom = item.voice.customValue,
                  !custom.isEmpty else {
                throw ProjectStoreError.invalidData(
                    "Custom item voice requires a remembered voice."
                )
            }
            voiceID = custom
        }

        let speed: Double
        switch item.speed.mode {
        case .inherit:
            speed = projectResolved.speed
        case .custom:
            guard let custom = item.speed.customValue,
                  custom.isFinite,
                  custom > 0 else {
                throw ProjectStoreError.invalidData(
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
    private struct RuntimeManifest: Decodable {
        let sdkCommit: String

        enum CodingKeys: String, CodingKey {
            case sdkCommit = "sdk_commit"
        }
    }

    static func runtimeRevision() throws -> String {
        do {
            let data = try Data(contentsOf: KokoroResources.manifestURL())
            let manifest = try JSONDecoder().decode(
                RuntimeManifest.self,
                from: data
            )
            guard !manifest.sdkCommit.isEmpty else {
                throw ProjectStoreError.invalidData(
                    "Kokoro runtime revision is missing."
                )
            }
            return manifest.sdkCommit
        } catch let error as ProjectStoreError {
            throw error
        } catch {
            throw ProjectStoreError.io(
                "Unable to read Kokoro runtime identity: \(error)"
            )
        }
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
