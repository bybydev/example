import Foundation
import InkribeTranscription
import Testing

@Suite("Transcription runtime resources", .serialized)
@MainActor
struct RuntimeResourceTests {
    @Test func idleQueueCanReleaseManagedRuntimeResources() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let executor = RuntimeManagingTestExecutor()
        let queue = TranscriptionQueueController(
            storeURL: directory.appendingPathComponent("jobs.json"),
            executor: executor
        )

        let released = await queue.releaseIdleRuntimeResources()
        let unloadCount = await executor.unloadCount()

        #expect(released)
        #expect(unloadCount == 1)
    }
}

private actor RuntimeManagingTestExecutor: TranscriptionJobExecuting, TranscriptionRuntimeManaging {
    private var numberOfUnloads = 0

    func execute(
        payload: TranscriptionJob.Payload,
        progress: @escaping TranscriptionProgressHandler
    ) async throws {
        await progress(1, "Complete")
    }

    func unloadTranscriptionModel() async {
        numberOfUnloads += 1
    }

    func unloadCount() -> Int {
        numberOfUnloads
    }
}
