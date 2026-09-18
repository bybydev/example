import Foundation
import InkribeCore
import InkribeTranscription
import Testing
@testable import Inkribe

@MainActor
@Test func commerceCatalogUsesExpectedOrderAndPreferredPlan() {
    #expect(InkribeCommerce.productIDs == [
        "com.hoangbkit.inkribe.pro.monthly",
        "com.hoangbkit.inkribe.pro.yearly",
        "com.hoangbkit.inkribe.pro.lifetime"
    ])
    #expect(
        InkribeCommerce.configuration.preferredProductID
            == "com.hoangbkit.inkribe.pro.yearly"
    )
}

@MainActor
@Test func appStateStartupIsIdempotent() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let appState = InkribeAppState(
        queueStoreURLProvider: { directory.appendingPathComponent("jobs.json") },
        transcriptStoreURLProvider: { directory.appendingPathComponent("transcripts.json") },
        mediaDirectoryURLProvider: { directory.appendingPathComponent("Media", isDirectory: true) },
        executorFactory: { _, _ in StartupTestExecutor() }
    )
    try appState.start()

    let firstQueue = try #require(appState.transcriptionQueue)
    try appState.start()
    let secondQueue = try #require(appState.transcriptionQueue)

    #expect(firstQueue === secondQueue)
    #expect(appState.startupIssue == nil)
}

@MainActor
@Test func appStateRecoversRepairedQueueStorageWithoutRecreatingPipeline() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let queueURL = directory.appendingPathComponent("jobs.json")
    try Data("{ corrupt queue".utf8).write(to: queueURL, options: .atomic)

    let appState = InkribeAppState(
        queueStoreURLProvider: { queueURL },
        transcriptStoreURLProvider: { directory.appendingPathComponent("transcripts.json") },
        mediaDirectoryURLProvider: { directory.appendingPathComponent("Media", isDirectory: true) },
        executorFactory: { _, _ in StartupTestExecutor() }
    )

    do {
        try appState.start()
        Issue.record("Corrupt queue storage should fail startup")
    } catch {
        // Expected. The pipeline objects remain available for recovery.
    }

    let retainedQueue = try #require(appState.transcriptionQueue)
    #expect(appState.transcriptRepository != nil)
    #expect(appState.mediaStore != nil)
    #expect(appState.startupIssue != nil)

    try Data("[]".utf8).write(to: queueURL, options: .atomic)
    try appState.retryQueuePersistence()

    #expect(appState.transcriptionQueue === retainedQueue)
    #expect(appState.startupIssue == nil)
    #expect(retainedQueue.persistenceIssueDescription == nil)
}

@MainActor
@Test func resettingDamagedQueueStoragePreservesTranscriptDocuments() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let queueURL = directory.appendingPathComponent("jobs.json")
    try Data("{ corrupt queue".utf8).write(to: queueURL, options: .atomic)

    let appState = InkribeAppState(
        queueStoreURLProvider: { queueURL },
        transcriptStoreURLProvider: { directory.appendingPathComponent("transcripts.json") },
        mediaDirectoryURLProvider: { directory.appendingPathComponent("Media", isDirectory: true) },
        executorFactory: { _, _ in StartupTestExecutor() }
    )

    do {
        try appState.start()
        Issue.record("Corrupt queue storage should fail startup")
    } catch {
        // Expected.
    }

    let repository = try #require(appState.transcriptRepository)
    let transcript = Transcript(title: "Keep me", rawText: "durable")
    try await repository.save(transcript)

    try appState.resetQueuePersistence()

    let saved = try await appState.transcript(id: transcript.id)
    #expect(saved?.rawText == "durable")
    #expect(appState.transcriptionQueue?.recordCount == 0)
    #expect(appState.startupIssue == nil)
}

private struct StartupTestExecutor: TranscriptionJobExecuting {
    func execute(
        payload: TranscriptionJob.Payload,
        progress: @escaping TranscriptionProgressHandler
    ) async throws {
        await progress(1, "Complete")
    }
}

#if DEBUG
@MainActor
@Test func logStoreRemainsBounded() {
    let store = LogStore(maximumEntries: 2)
    store.append(LogEntry(level: .info, label: "test", message: "one", metadata: nil))
    store.append(LogEntry(level: .info, label: "test", message: "two", metadata: nil))
    store.append(LogEntry(level: .info, label: "test", message: "three", metadata: nil))

    #expect(store.entries.count == 2)
    #expect(store.entries.map(\.message) == ["two", "three"])
}
#endif
