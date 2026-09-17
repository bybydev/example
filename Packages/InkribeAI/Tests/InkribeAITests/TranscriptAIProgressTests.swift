import Foundation
import InkribeAI
import InkribeCore
import LLMRuntime
import Testing

@Test func generationReportsTransformMergeAndFinishProgress() async throws {
    let runtime = ProgressTestRuntime(
        responses: ["one", "two", "three", "one two", "final"]
    )
    let recorder = AIProgressRecorder()
    let service = TranscriptAIService(
        runtime: runtime,
        chunker: TranscriptAIChunker(maximumCharacters: 256)
    )
    let transcript = Transcript(
        title: "Progress",
        rawText: String(repeating: "P", count: 600),
        revision: 2
    )

    _ = try await service.generate(
        action: .summarize,
        transcript: transcript,
        progress: { value in
            await recorder.append(value)
        }
    )

    let values = await recorder.values()
    let phases = values.map(\.phase)

    #expect(phases.first == .preparing)
    #expect(phases.contains { phase in
        if case .transforming = phase { return true }
        return false
    })
    #expect(phases.contains { phase in
        if case .merging = phase { return true }
        return false
    })
    #expect(phases.last == .finishing)
    #expect(values.last?.fraction == 1)
}

@Test func generationCancellationPropagatesToRuntime() async throws {
    let runtime = SlowCancellationRuntime()
    let service = TranscriptAIService(runtime: runtime)
    let transcript = Transcript(
        title: "Cancel",
        rawText: "This transcript is long enough to start local generation.",
        revision: 1
    )

    let task = Task {
        try await service.generate(action: .clean, transcript: transcript)
    }

    try await Task.sleep(for: .milliseconds(20))
    task.cancel()

    do {
        _ = try await task.value
        Issue.record("Cancelling local AI generation should propagate cancellation")
    } catch is CancellationError {
        // Expected.
    }

    let didObserveCancellation = await runtime.didObserveCancellation()
    #expect(didObserveCancellation)
}

private actor AIProgressRecorder {
    private var recorded: [TranscriptAIProgress] = []

    func append(_ value: TranscriptAIProgress) {
        recorded.append(value)
    }

    func values() -> [TranscriptAIProgress] {
        recorded
    }
}

private actor ProgressTestRuntime: LLMRuntimeProtocol {
    private var responses: [String]

    init(responses: [String]) {
        self.responses = responses
    }

    func loadModel() async throws {}

    func unloadModel() async {}

    func generate(
        _ request: LLMGenerationRequest,
        onToken: LLMTokenHandler?
    ) async throws -> String {
        guard !responses.isEmpty else { throw TestError.missingResponse }
        let response = responses.removeFirst()
        onToken?(response)
        return response
    }

    enum TestError: Error {
        case missingResponse
    }
}

private actor SlowCancellationRuntime: LLMRuntimeProtocol {
    private var observedCancellation = false

    func loadModel() async throws {}

    func unloadModel() async {}

    func generate(
        _ request: LLMGenerationRequest,
        onToken: LLMTokenHandler?
    ) async throws -> String {
        do {
            try await Task.sleep(for: .seconds(5))
            return "unexpected"
        } catch is CancellationError {
            observedCancellation = true
            throw CancellationError()
        }
    }

    func didObserveCancellation() -> Bool {
        observedCancellation
    }
}
