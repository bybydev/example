import Foundation

nonisolated enum ProjectItemGenerationState: String, Sendable, Equatable {
    case readyOffline
    case generating
    case waiting
    case notGenerated
    case needsAttention
}

nonisolated struct ProjectItemGenerationStatus: Sendable, Equatable {
    let state: ProjectItemGenerationState
    let audioBytes: Int64?

    static let notGenerated = ProjectItemGenerationStatus(
        state: .notGenerated,
        audioBytes: nil
    )
}

nonisolated struct ProjectGenerationStatusRequest: Sendable, Equatable {
    let itemID: UUID
    let generationKey: String
    let contentRevision: String
    let voiceID: String
    let speed: Double
}

nonisolated struct ProjectGenerationRequest: Sendable, Equatable {
    let itemID: UUID
    let generationKey: String
}
