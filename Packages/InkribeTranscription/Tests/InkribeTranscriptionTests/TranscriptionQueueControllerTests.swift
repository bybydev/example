import Foundation
import InkribeAudio
import InkribeCore
import InkribePersistence
import Testing
import WhisperRuntime
@testable import InkribeTranscription

@Suite("Transcription pipeline", .serialized)
@MainActor
struct TranscriptionQueueControllerTests {
    @Test func queueRegistersPersistentJobBeforeStartAndRestoresPayload() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queueURL = directory.appendingPathComponent("jobs.json")
        let transcriptID = TranscriptID()

        let first = TranscriptionQueueController(
            storeURL: queueURL,
            executor: ImmediateExecutor()
        )
        try first.start()
        try first.pause()
        let jobID = try first.enqueue(
            transcriptID: transcriptID,
            sourceMediaRelativePath: "Sources/source.wav",
            requestedLanguage: "vi"
        )

        #expect(first.items.first?.id == jobID)
        #expect(first.items.first?.transcriptID == transcriptID)
        #expect(first.items.first?.state == .waiting)

        let restored = TranscriptionQueueController(
            storeURL: queueURL,
            executor: ImmediateExecutor()
        )
        try restored.start()
        try await waitUntil {
            restored.items.first(where: { $0.id == jobID })?.state == .complete
        }
        #expect(restored.recordCount == 1)
        #expect(restored.items.first?.transcriptID == transcriptID)
    }

    @Test func jobPayloadContainsOnlyStableIdentifiersAndLanguage() throws {
        let job = TranscriptionJob(
            id: UUID(),
            payload: .init(
                transcriptID: UUID(),
                sourceMediaRelativePath: "Sources/source.wav",
                requestedLanguage: "en"
            )
        )

        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any]
        )
        let payload = try #require(object["payload"] as? [String: Any])

        #expect(Set(payload.keys) == ["transcriptID", "sourceMediaRelativePath", "requestedLanguage"])
        #expect(payload["sourceMediaRelativePath"] as? String == "Sources/source.wav")
        #expect(payload["requestedLanguage"] as? String == "en")
        #expect(TranscriptionJob.maxConcurrentExecutions == 1)
    }

    @Test func transcriptionJobCodableRoundTripPreservesStablePayload() throws {
        let job = TranscriptionJob(
            id: UUID(),
            payload: .init(
                transcriptID: UUID(),
                sourceMediaRelativePath: "Sources/round-trip.wav",
                requestedLanguage: "ja"
            )
        )

        let data = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(TranscriptionJob.self, from: data)

        #expect(decoded.id == job.id)
        #expect(decoded.payload == job.payload)
    }

    @Test func corruptQueueStoreCanRecoverAfterRepair() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let queueURL = directory.appendingPathComponent("jobs.json")
        try Data("{ corrupt queue".utf8).write(to: queueURL, options: .atomic)

        let controller = TranscriptionQueueController(
            storeURL: queueURL,
            executor: ImmediateExecutor()
        )
        var events: [TranscriptionQueueEvent] = []
        controller.eventHandler = { events.append($0) }

        do {
            try controller.start()
            Issue.record("Corrupt queue storage should fail startup")
        } catch {
            // Expected: persisted queue state is not silently discarded.
        }

        #expect(controller.startupErrorDescription != nil)
        #expect(controller.persistenceIssueDescription != nil)
        #expect(events.contains(.persistenceFailed))
        #expect(controller.recordCount == 0)

        try Data("[]".utf8).write(to: queueURL, options: .atomic)
        try controller.retryPersistence()

        #expect(controller.startupErrorDescription == nil)
        #expect(controller.persistenceIssueDescription == nil)
        #expect(controller.recordCount == 0)
    }

    @Test func successfulJobPersistsWhisperResultBeforeQueueCompletes() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let mediaStore = DurableMediaStore(
            rootDirectoryURL: directory.appendingPathComponent("Media", isDirectory: true)
        )
        let sourceURL = directory.appendingPathComponent("input.wav")
        try makePCM16Wave(sampleRate: 16_000, frames: Array(repeating: 2_000, count: 1_600))
            .write(to: sourceURL)
        let mediaReference = try await mediaStore.ingest(sourceURL: sourceURL)

        let repository = JSONTranscriptRepository(
            fileURL: directory.appendingPathComponent("transcripts.json")
        )
        let transcript = Transcript(
            title: "Interview",
            sourceMediaRelativePath: mediaReference.relativePath
        )
        try await repository.save(transcript)

        let executor = DefaultTranscriptionJobExecutor(
            mediaStore: mediaStore,
            whisperRuntime: FakeWhisperRuntime(
                result: .init(
                    detectedLanguageCode: "vi",
                    segments: [
                        .init(startTime: 0, endTime: 0.05, text: "Xin chào"),
                        .init(startTime: 0.05, endTime: 0.1, text: " thế giới")
                    ]
                )
            ),
            transcriptRepository: repository
        )
        let controller = TranscriptionQueueController(
            storeURL: directory.appendingPathComponent("jobs.json"),
            executor: executor
        )
        try controller.start()
        let jobID = try controller.enqueue(
            transcriptID: transcript.id,
            sourceMediaRelativePath: mediaReference.relativePath
        )

        try await waitUntil {
            controller.items.first(where: { $0.id == jobID })?.state == .complete
        }

        let fetched = try await repository.transcript(id: transcript.id)
        let saved = try #require(fetched)
        #expect(saved.rawText == "Xin chào thế giới")
        #expect(saved.editedText == "Xin chào thế giới")
        #expect(saved.languageCode == "vi")
        #expect(saved.segments.count == 2)
        #expect(saved.duration > 0)
        #expect(saved.revision == 1)
    }

    @Test func retryDoesNotOverwriteUserEditedText() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let mediaStore = DurableMediaStore(
            rootDirectoryURL: directory.appendingPathComponent("Media", isDirectory: true)
        )
        let sourceURL = directory.appendingPathComponent("input.wav")
        try makePCM16Wave(sampleRate: 16_000, frames: Array(repeating: 1_000, count: 800))
            .write(to: sourceURL)
        let mediaReference = try await mediaStore.ingest(sourceURL: sourceURL)

        let repository = JSONTranscriptRepository(
            fileURL: directory.appendingPathComponent("transcripts.json")
        )
        let transcript = Transcript(
            title: "Edited",
            sourceMediaRelativePath: mediaReference.relativePath,
            rawText: "old raw",
            editedText: "my manual edit",
            revision: 3
        )
        try await repository.save(transcript)

        let executor = DefaultTranscriptionJobExecutor(
            mediaStore: mediaStore,
            whisperRuntime: FakeWhisperRuntime(
                result: .init(
                    detectedLanguageCode: "en",
                    segments: [.init(startTime: 0, endTime: 0.05, text: "new raw")]
                )
            ),
            transcriptRepository: repository
        )
        let controller = TranscriptionQueueController(
            storeURL: directory.appendingPathComponent("jobs.json"),
            executor: executor
        )
        try controller.start()
        let jobID = try controller.enqueue(
            transcriptID: transcript.id,
            sourceMediaRelativePath: mediaReference.relativePath,
            requestedLanguage: "en"
        )
        try await waitUntil {
            controller.items.first(where: { $0.id == jobID })?.state == .complete
        }

        let fetched = try await repository.transcript(id: transcript.id)
        let saved = try #require(fetched)
        #expect(saved.rawText == "new raw")
        #expect(saved.editedText == "my manual edit")
        #expect(saved.revision == 3)
    }

    @Test func cancellationFlowsThroughQueueToExecutor() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let controller = TranscriptionQueueController(
            storeURL: directory.appendingPathComponent("jobs.json"),
            executor: BlockingExecutor()
        )
        try controller.start()
        let jobID = try controller.enqueue(
            transcriptID: TranscriptID(),
            sourceMediaRelativePath: "Sources/source.wav"
        )

        try await waitUntil {
            controller.items.first(where: { $0.id == jobID })?.state == .transcribing
        }
        try controller.cancel(id: jobID)
        try await waitUntil {
            controller.items.first(where: { $0.id == jobID })?.state == .cancelled
        }
    }

    @Test func failedJobCanRetryToCompletionAndEmitsSafeLifecycleEvents() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let executor = FailOnceExecutor()
        let controller = TranscriptionQueueController(
            storeURL: directory.appendingPathComponent("jobs.json"),
            executor: executor
        )
        var events: [TranscriptionQueueEvent] = []
        controller.eventHandler = { events.append($0) }
        try controller.start()

        let jobID = try controller.enqueue(
            transcriptID: TranscriptID(),
            sourceMediaRelativePath: "Sources/source.wav"
        )
        try await waitUntil {
            controller.items.first(where: { $0.id == jobID })?.state == .failed
        }
        #expect(events.contains(.failed(jobID)))

        try controller.retry(id: jobID)
        try await waitUntil {
            controller.items.first(where: { $0.id == jobID })?.state == .complete
        }
        #expect(events.contains(.completed(jobID)))
        let attempts = await executor.attemptCount
        #expect(attempts == 2)
    }

    @Test func processingRecordRecoversAfterRelaunchAndCompletesOnce() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let queueURL = directory.appendingPathComponent("jobs.json")
        let first = TranscriptionQueueController(
            storeURL: queueURL,
            executor: BlockingExecutor()
        )
        try first.start()
        let transcriptID = TranscriptID()
        let jobID = try first.enqueue(
            transcriptID: transcriptID,
            sourceMediaRelativePath: "Sources/source.wav"
        )
        try await waitUntil {
            first.items.first(where: { $0.id == jobID })?.state == .transcribing
        }

        let restoredDirectory = directory.appendingPathComponent("Restored", isDirectory: true)
        try FileManager.default.createDirectory(
            at: restoredDirectory,
            withIntermediateDirectories: true
        )
        let restoredURL = restoredDirectory.appendingPathComponent("jobs.json")
        try FileManager.default.copyItem(at: queueURL, to: restoredURL)

        try first.cancel(id: jobID)
        try await waitUntil {
            first.items.first(where: { $0.id == jobID })?.state == .cancelled
        }

        let restored = TranscriptionQueueController(
            storeURL: restoredURL,
            executor: ImmediateExecutor()
        )
        try restored.start()
        try await waitUntil {
            restored.items.first(where: { $0.id == jobID })?.state == .complete
        }

        #expect(restored.recordCount == 1)
        #expect(restored.items.first?.transcriptID == transcriptID)
    }

    @Test func missingDurableMediaFailsRetryWithoutDuplicatingTranscript() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let mediaStore = DurableMediaStore(
            rootDirectoryURL: directory.appendingPathComponent("Media", isDirectory: true)
        )
        let repository = JSONTranscriptRepository(
            fileURL: directory.appendingPathComponent("transcripts.json")
        )
        let transcript = Transcript(
            title: "Missing source",
            sourceMediaRelativePath: "Sources/missing.wav",
            rawText: "Keep me",
            editedText: "Keep me"
        )
        try await repository.save(transcript)

        let executor = DefaultTranscriptionJobExecutor(
            mediaStore: mediaStore,
            whisperRuntime: FakeWhisperRuntime(
                result: .init(detectedLanguageCode: "en", segments: [])
            ),
            transcriptRepository: repository
        )
        let controller = TranscriptionQueueController(
            storeURL: directory.appendingPathComponent("jobs.json"),
            executor: executor
        )
        try controller.start()
        let jobID = try controller.enqueue(
            transcriptID: transcript.id,
            sourceMediaRelativePath: "Sources/missing.wav"
        )

        try await waitUntil {
            controller.items.first(where: { $0.id == jobID })?.state == .failed
        }
        #expect(controller.recordCount == 1)

        try controller.retry(id: jobID)
        try await waitUntil {
            controller.items.first(where: { $0.id == jobID })?.state == .failed
        }

        let all = try await repository.transcripts()
        #expect(controller.recordCount == 1)
        #expect(all.count == 1)
        #expect(all.first?.id == transcript.id)
        #expect(all.first?.rawText == "Keep me")
        #expect(all.first?.editedText == "Keep me")
    }

    @Test func multipleJobsStayFIFOAndSingleConcurrency() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let executor = SerialProbeExecutor()
        let controller = TranscriptionQueueController(
            storeURL: directory.appendingPathComponent("jobs.json"),
            executor: executor
        )
        try controller.start()

        let transcriptIDs = [TranscriptID(), TranscriptID(), TranscriptID()]
        let jobIDs = try transcriptIDs.map {
            try controller.enqueue(
                transcriptID: $0,
                sourceMediaRelativePath: "Sources/\($0.rawValue.uuidString).wav"
            )
        }

        try await waitUntil(attempts: 200) {
            jobIDs.allSatisfy { id in
                controller.items.first(where: { $0.id == id })?.state == .complete
            }
        }

        let snapshot = await executor.snapshot()
        #expect(snapshot.maximumActive == 1)
        #expect(snapshot.starts == transcriptIDs.map(\.rawValue))
    }

    private func waitUntil(
        attempts: Int = 100,
        condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TestError.timedOut
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func makePCM16Wave(sampleRate: UInt32, frames: [Int16]) -> Data {
        var payload = Data()
        for sample in frames {
            append(UInt16(bitPattern: sample), to: &payload)
        }

        var data = Data("RIFF".utf8)
        append(UInt32(36 + payload.count), to: &data)
        data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8))
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(UInt16(1), to: &data)
        append(sampleRate, to: &data)
        append(sampleRate * 2, to: &data)
        append(UInt16(2), to: &data)
        append(UInt16(16), to: &data)
        data.append(Data("data".utf8))
        append(UInt32(payload.count), to: &data)
        data.append(payload)
        return data
    }

    private func append(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private func append(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private enum TestError: Error {
        case timedOut
    }
}

private struct ImmediateExecutor: TranscriptionJobExecuting {
    func execute(
        payload: TranscriptionJob.Payload,
        progress: @escaping TranscriptionProgressHandler
    ) async throws {
        await progress(1, "Complete")
    }
}

private struct BlockingExecutor: TranscriptionJobExecuting {
    func execute(
        payload: TranscriptionJob.Payload,
        progress: @escaping TranscriptionProgressHandler
    ) async throws {
        await progress(0.1, "Working")
        while true {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private actor FailOnceExecutor: TranscriptionJobExecuting {
    enum Failure: Error { case firstAttempt }

    private(set) var attemptCount = 0

    func execute(
        payload: TranscriptionJob.Payload,
        progress: @escaping TranscriptionProgressHandler
    ) async throws {
        attemptCount += 1
        if attemptCount == 1 {
            throw Failure.firstAttempt
        }
        await progress(1, "Complete")
    }
}

private actor FakeWhisperRuntime: WhisperRuntimeProtocol {
    enum FakeError: Error { case invalidBuffer }

    let result: WhisperTranscriptionResult

    init(result: WhisperTranscriptionResult) {
        self.result = result
    }

    func loadModel() async throws {}
    func unloadModel() async {}

    func transcribe(
        mediaURL: URL,
        requestedLanguageCode: String?,
        progress: WhisperProgressHandler?
    ) async throws -> WhisperTranscriptionResult {
        progress?(1)
        return result
    }

    func transcribe(
        buffer: WhisperAudioBuffer,
        requestedLanguageCode: String?,
        progress: WhisperProgressHandler?
    ) async throws -> WhisperTranscriptionResult {
        guard buffer.sampleRate == 16_000, !buffer.samples.isEmpty else {
            throw FakeError.invalidBuffer
        }
        progress?(0.5)
        progress?(1)
        return result
    }
}

private actor SerialProbeExecutor: TranscriptionJobExecuting {
    private var starts: [UUID] = []
    private var active = 0
    private var maximumActive = 0

    func execute(
        payload: TranscriptionJob.Payload,
        progress: @escaping TranscriptionProgressHandler
    ) async throws {
        active += 1
        maximumActive = max(maximumActive, active)
        starts.append(payload.transcriptID)
        defer { active -= 1 }

        await progress(0.25, "Working")
        try await Task.sleep(for: .milliseconds(30))
        await progress(1, "Complete")
    }

    func snapshot() -> (starts: [UUID], maximumActive: Int) {
        (starts, maximumActive)
    }
}
