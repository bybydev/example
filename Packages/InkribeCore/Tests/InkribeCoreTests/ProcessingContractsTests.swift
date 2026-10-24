import Foundation
import Testing
@testable import InkribeCore

struct ProcessingContractsTests {
    @Test func prePickerSpeechPayloadStillDecodesWithoutOptionalBindings() throws {
        let id = UUID()
        let bytes = Data("""
        {"projectID":"\(id)","expectedRevision":7,"languageCode":"vi"}
        """.utf8)
        let request = try JSONDecoder().decode(TranscriptionRequest.self, from: bytes)
        #expect(request.projectID == id)
        #expect(request.expectedRevision == 7)
        #expect(request.languageCode == "vi")
        #expect(request.modelID == nil)
        #expect(request.requiresAllowance == nil)
        #expect(request.windowIndices == nil)
        #expect(request.projectTitle == nil)
    }

    @Test func oldExportPayloadKeepsProfileWireValues() throws {
        let id = UUID()
        let bytes = Data("""
        {"projectID":"\(id)","profile":{"format":"mp4","resolution":1080}}
        """.utf8)
        let request = try JSONDecoder().decode(ExportRequest.self, from: bytes)
        #expect(request.projectID == id)
        #expect(request.profile == ExportProfile(format: .mp4, resolution: .fullHD))
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        let profile = encoded?["profile"] as? [String: Any]
        #expect(profile?["format"] as? String == "mp4")
        #expect(profile?["resolution"] as? Int == 1080)
    }

    @Test func targetedRetryPreservesCapturedBindings() throws {
        let request = TranscriptionRequest(projectID: UUID(), expectedRevision: 12,
            languageCode: "en", modelID: "captured-model", requiresAllowance: false,
            windowIndices: [1, 4], projectTitle: "Saved title")
        let restored = try JSONDecoder().decode(TranscriptionRequest.self, from: JSONEncoder().encode(request))
        #expect(restored.modelID == request.modelID)
        #expect(restored.requiresAllowance == false)
        #expect(restored.windowIndices == [1, 4])
        #expect(restored.projectTitle == "Saved title")
    }
}

private actor ProcessingLatch {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        signalled = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }
}

private actor ProcessingProbe {
    private var active = 0
    private(set) var maximum = 0
    private(set) var finished = 0
    func enter() { active += 1; maximum = max(maximum, active) }
    func leave() { active -= 1; finished += 1 }
}

struct ProcessingWorkGateTests {
    @Test func concurrentQueuesNeverOverlapHeavyWork() async throws {
        let gate = ProcessingWorkGate()
        let probe = ProcessingProbe()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    try await gate.withPermit {
                        await probe.enter()
                        await Task.yield()
                        await probe.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        let maximum = await probe.maximum
        let finished = await probe.finished
        #expect(maximum == 1)
        #expect(finished == 16)
    }

    @Test func cancellingWaiterDoesNotConsumeOrReleaseOwnersPermit() async throws {
        let gate = ProcessingWorkGate()
        let entered = ProcessingLatch()
        let release = ProcessingLatch()
        let waiterStarted = ProcessingLatch()
        let probe = ProcessingProbe()
        let owner = Task {
            try await gate.withPermit {
                await probe.enter()
                await entered.signal()
                await release.wait()
                await probe.leave()
            }
        }
        await entered.wait()
        let waiter = Task {
            await waiterStarted.signal()
            try await gate.withPermit { await probe.enter(); await probe.leave() }
        }
        await waiterStarted.wait()
        waiter.cancel()
        do { try await waiter.value; Issue.record("A cancelled waiter entered heavy work") }
        catch is CancellationError { }
        catch { Issue.record("Unexpected error: \(error)") }
        await release.signal()
        try await owner.value
        // A subsequent request must acquire normally after the owner leaves.
        let value = try await gate.withPermit { 42 }
        #expect(value == 42)
        let maximum = await probe.maximum
        let finished = await probe.finished
        #expect(maximum == 1)
        #expect(finished == 1)
    }

    @Test func failedOperationReleasesCapacity() async throws {
        enum Expected: Error { case failure }
        let gate = ProcessingWorkGate()
        do { let _: Void = try await gate.withPermit { throw Expected.failure } }
        catch Expected.failure { }
        let value = try await gate.withPermit { "next job" }
        #expect(value == "next job")
    }
}
