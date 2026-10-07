import Foundation

nonisolated enum ReadAloudProFeature:
    String,
    Sendable
{
    case unlimitedLibrary
    case advancedVoices
    case itemNarrationOverrides
    case bulkGeneration
    case automaticPrefetch
    case generateWhileListening
    case advancedRegeneration
    case premiumThemes

    var title: String {
        switch self {
        case .unlimitedLibrary:
            "Unlimited Library"
        case .advancedVoices:
            "All Voices"
        case .itemNarrationOverrides:
            "Per-Chapter Narration"
        case .bulkGeneration:
            "Bulk Offline Generation"
        case .automaticPrefetch:
            "Automatic Prefetch"
        case .generateWhileListening:
            "Generate While Listening"
        case .advancedRegeneration:
            "Advanced Regeneration"
        case .premiumThemes:
            "Premium Themes"
        }
    }
}

nonisolated enum ReadAloudAccessError:
    Error,
    LocalizedError,
    Equatable,
    Sendable
{
    case requiresPro(
        ReadAloudProFeature
    )
    case freeLibraryLimitReached(
        limit: Int
    )

    var errorDescription: String? {
        switch self {
        case .requiresPro(let feature):
            return "\(feature.title) requires ReadAloud Pro."
        case .freeLibraryLimitReached(
            let limit
        ):
            return "Free supports up to \(limit) projects. Upgrade to ReadAloud Pro for an unlimited Library."
        }
    }
}

nonisolated enum ReadAloudAccessPolicy {
    static let freeProjectLimit = 3

    static let freeVoiceIDs:
        Set<String> = [
            "af_heart",
        ]

    static func canCreateProject(
        existingProjectCount: Int,
        hasPro: Bool
    ) -> Bool {
        hasPro
            || existingProjectCount
                < freeProjectLimit
    }

    static func canUseVoice(
        _ voiceID: String,
        hasPro: Bool
    ) -> Bool {
        hasPro
            || freeVoiceIDs
                .contains(voiceID)
    }

    static func requirePro(
        _ feature:
            ReadAloudProFeature,
        hasPro: Bool
    ) throws {
        guard hasPro else {
            throw ReadAloudAccessError
                .requiresPro(feature)
        }
    }

    static func requireLibraryCapacity(
        existingProjectCount: Int,
        hasPro: Bool
    ) throws {
        guard canCreateProject(
            existingProjectCount:
                existingProjectCount,
            hasPro: hasPro
        ) else {
            throw ReadAloudAccessError
                .freeLibraryLimitReached(
                    limit:
                        freeProjectLimit
                )
        }
    }

    static func effectiveVoiceID(
        _ requestedVoiceID: String,
        hasPro: Bool
    ) -> String {
        canUseVoice(
            requestedVoiceID,
            hasPro: hasPro
        )
        ? requestedVoiceID
        : ReadAloudNarrationCatalog
            .freeDefaultVoiceID
    }
}
