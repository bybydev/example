import InkribeAI
import InkribeCore
import Testing
@testable import Inkribe

@Suite("Local AI retention", .serialized)
@MainActor
struct TranscriptLocalAIControllerTests {
    @Test func defaultMemoryPolicyReleasesModelAfterGeneration() async throws {
        let service = RetentionTestAIService()
        let controller = TranscriptLocalAIController(
            serviceFactory: { service },
            keepModelLoadedProvider: { false }
        )
        let transcript = Transcript(
            title: "Retention",
            rawText: "source transcript",
            editedText: "source transcript",
            revision: 3
        )

        _ = try await controller.generate(action: .summarize, transcript: transcript)

        let unloadCount = await service.unloadCount()
        #expect(unloadCount == 1)
    }

    @Test func keepLoadedPolicyRetainsModelUntilExplicitUnload() async throws {
        let service = RetentionTestAIService()
        let controller = TranscriptLocalAIController(
            serviceFactory: { service },
            keepModelLoadedProvider: { true }
        )
        let transcript = Transcript(
            title: "Retention",
            rawText: "source transcript",
            editedText: "source transcript",
            revision: 2
        )

        _ = try await controller.generate(action: .notes, transcript: transcript)
        let retainedUnloadCount = await service.unloadCount()
        #expect(retainedUnloadCount == 0)

        await controller.unloadModel()
        let explicitUnloadCount = await service.unloadCount()
        #expect(explicitUnloadCount == 1)
    }
}

private actor RetentionTestAIService: TranscriptAIProcessing {
    private var numberOfUnloads = 0

    func generate(
        action: TranscriptAIAction,
        transcript: Transcript,
        progress: TranscriptAIProgressHandler?
    ) async throws -> TranscriptAIResult {
        if let progress {
            await progress(.init(phase: .finishing, fraction: 1))
        }
        return TranscriptAIResult(
            action: action,
            sourceRevision: transcript.revision,
            content: "generated"
        )
    }

    func unloadModel() async {
        numberOfUnloads += 1
    }

    func unloadCount() -> Int {
        numberOfUnloads
    }
}
