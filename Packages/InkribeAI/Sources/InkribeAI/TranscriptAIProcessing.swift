import InkribeCore

public protocol TranscriptAIProcessing: Sendable {
    func generate(
        action: TranscriptAIAction,
        transcript: Transcript,
        progress: TranscriptAIProgressHandler?
    ) async throws -> TranscriptAIResult

    func unloadModel() async
}

extension TranscriptAIService: TranscriptAIProcessing {}
