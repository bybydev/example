import Foundation
import InkribeCore

public enum TranscriptAIProgressPhase: Equatable, Sendable {
    case preparing
    case transforming(chunk: Int, totalChunks: Int)
    case merging(pass: Int, chunk: Int, totalChunks: Int)
    case finishing
}

public struct TranscriptAIProgress: Equatable, Sendable {
    public let phase: TranscriptAIProgressPhase
    public let fraction: Double

    public init(phase: TranscriptAIProgressPhase, fraction: Double) {
        self.phase = phase
        self.fraction = min(max(fraction, 0), 1)
    }
}

public typealias TranscriptAIProgressHandler = @Sendable (TranscriptAIProgress) async -> Void

public struct TranscriptAIResult: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let action: TranscriptAIAction
    public let sourceRevision: Int
    public let content: String
    public let promptVersion: Int
    public let generatedAt: Date

    public init(
        id: UUID = UUID(),
        action: TranscriptAIAction,
        sourceRevision: Int,
        content: String,
        promptVersion: Int = TranscriptAIPromptTemplates.version,
        generatedAt: Date = .now
    ) {
        self.id = id
        self.action = action
        self.sourceRevision = sourceRevision
        self.content = content
        self.promptVersion = promptVersion
        self.generatedAt = generatedAt
    }

    public var derivedDocumentKind: DerivedDocumentKind {
        action.derivedDocumentKind
    }
}

public enum TranscriptAIApplyMode: Equatable, Sendable {
    case replaceEditedText
    case saveDerivedDocument
}

public enum TranscriptAIError: Error, Equatable, Sendable {
    case emptyInput
    case inputTooShort(minimumCharacters: Int)
    case emptyResult
    case unsupportedApplyMode
    case staleResult(expectedRevision: Int, currentRevision: Int)
}

extension TranscriptAIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            "There is no transcript text to process."
        case .inputTooShort(let minimumCharacters):
            "The transcript is too short for this AI action. Enter at least \(minimumCharacters) characters."
        case .emptyResult:
            "The local AI model returned an empty result."
        case .unsupportedApplyMode:
            "This AI result cannot be applied in the requested way."
        case .staleResult(let expectedRevision, let currentRevision):
            "The transcript changed while this AI result was being generated (revision \(expectedRevision) → \(currentRevision)). Generate a fresh result before applying it."
        }
    }
}
