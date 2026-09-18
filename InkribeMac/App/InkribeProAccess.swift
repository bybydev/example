import MacAppFoundation

enum InkribeProCapability: String, CaseIterable, Identifiable {
    case localAI = "local-ai"
    case batchImport = "batch-import"
    case subtitleExport = "subtitle-export"

    var id: String { rawValue }

    var premiumFeature: PremiumFeature {
        PremiumFeature(id: rawValue, title: title)
    }

    var purchaseFeature: PurchaseFeature {
        switch self {
        case .localAI:
            PurchaseFeature(
                id: rawValue,
                systemImage: "sparkles",
                title: "Local AI Tools",
                message: "Clean, polish, summarize, create notes, and extract action items with the bundled local model.",
                freeValue: "Transcript editing",
                proValue: "All local AI tools"
            )
        case .batchImport:
            PurchaseFeature(
                id: rawValue,
                systemImage: "square.stack.3d.up",
                title: "Batch Transcription",
                message: "Import multiple audio or video files together and process them through the persistent local queue.",
                freeValue: "One file at a time",
                proValue: "Multi-file import"
            )
        case .subtitleExport:
            PurchaseFeature(
                id: rawValue,
                systemImage: "captions.bubble",
                title: "Subtitle Export",
                message: "Export timestamped transcript segments as SRT or WebVTT subtitle files.",
                freeValue: "TXT + Markdown",
                proValue: "SRT + WebVTT"
            )
        }
    }

    var title: String {
        purchaseFeature.title
    }

    var upsellTitle: String {
        switch self {
        case .localAI: "Unlock Local AI"
        case .batchImport: "Unlock Batch Transcription"
        case .subtitleExport: "Unlock Subtitle Export"
        }
    }

    var upsellMessage: String {
        switch self {
        case .localAI:
            "Inkribe Pro unlocks every bundled local AI action while keeping transcript processing on this Mac."
        case .batchImport:
            "Inkribe Pro lets you select and queue multiple media files in one batch. Single-file transcription stays available on Free."
        case .subtitleExport:
            "Inkribe Pro adds timestamped SRT and WebVTT export. Copy, TXT, and Markdown remain available on Free."
        }
    }

    static let policy = PremiumAccessPolicy(existingContentRemainsAccessible: true)

    func decision(hasPro: Bool, isExistingContent: Bool = false) -> PremiumAccessDecision {
        Self.policy.decision(
            for: premiumFeature,
            requirement: .pro,
            hasPro: hasPro,
            isExistingContent: isExistingContent
        )
    }

    func importDecision(
        requestedFileCount: Int,
        hasActiveQueueWork: Bool,
        hasPro: Bool
    ) -> PremiumAccessDecision {
        precondition(self == .batchImport, "Import policy is only valid for batchImport.")

        if requestedFileCount <= 1, !hasActiveQueueWork {
            return .allowed
        }

        return decision(hasPro: hasPro)
    }
}
