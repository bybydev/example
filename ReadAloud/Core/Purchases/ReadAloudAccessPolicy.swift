import Foundation

// Voices and themes are the only paid features in the current release.
nonisolated enum ReadAloudProFeature: String, Sendable {
    case advancedVoices
    case premiumThemes

    var title: String {
        switch self {
        case .advancedVoices: "All Voices"
        case .premiumThemes: "Premium Themes"
        }
    }
}

nonisolated enum ReadAloudAccessError: Error, LocalizedError, Equatable, Sendable {
    case requiresPro(ReadAloudProFeature)

    var errorDescription: String? {
        switch self {
        case .requiresPro(let feature):
            "\(feature.title) requires ReadAloud Pro."
        }
    }
}

nonisolated enum ReadAloudAccessPolicy {
    static let freeVoiceIDs: Set<String> = ["af_heart"]

    static func canUseVoice(_ voiceID: String, hasPro: Bool) -> Bool {
        SpeechVoice.all.contains(where: { $0.id == voiceID })
            && (hasPro || freeVoiceIDs.contains(voiceID))
    }

    static func requirePro(_ feature: ReadAloudProFeature, hasPro: Bool) throws {
        guard hasPro else {
            throw ReadAloudAccessError.requiresPro(feature)
        }
    }

    static func effectiveVoiceID(_ requestedVoiceID: String, hasPro: Bool) -> String {
        canUseVoice(requestedVoiceID, hasPro: hasPro)
            ? requestedVoiceID
            : ReadAloudNarrationCatalog.freeDefaultVoiceID
    }
}
