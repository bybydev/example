import Foundation
import InkribeAI
import InkribeCore

extension InkribeAppState {
    func applyTranscriptAIResult(
        transcriptID: TranscriptID,
        result: TranscriptAIResult,
        mode: TranscriptAIApplyMode
    ) async throws -> Transcript {
        guard let transcriptRepository else {
            throw AppStateError.pipelineUnavailable
        }
        guard var transcript = try await transcriptRepository.transcript(id: transcriptID) else {
            throw AppStateError.transcriptNotFound
        }
        guard transcript.revision == result.sourceRevision else {
            throw TranscriptAIError.staleResult(
                expectedRevision: result.sourceRevision,
                currentRevision: transcript.revision
            )
        }

        switch mode {
        case .replaceEditedText:
            guard result.action.supportsEditedTextReplacement else {
                throw TranscriptAIError.unsupportedApplyMode
            }
            guard transcript.editedText != result.content else { return transcript }
            transcript.editedText = result.content
            transcript.revision += 1
            transcript.updatedAt = .now

        case .saveDerivedDocument:
            let isDuplicate = transcript.derivedDocuments.contains {
                $0.kind == result.derivedDocumentKind
                    && $0.sourceRevision == result.sourceRevision
                    && $0.content == result.content
            }
            guard !isDuplicate else { return transcript }

            transcript.derivedDocuments.append(
                DerivedDocument(
                    kind: result.derivedDocumentKind,
                    content: result.content,
                    sourceRevision: result.sourceRevision
                )
            )
            transcript.updatedAt = .now
        }

        try await transcriptRepository.save(transcript)
        return transcript
    }
}
