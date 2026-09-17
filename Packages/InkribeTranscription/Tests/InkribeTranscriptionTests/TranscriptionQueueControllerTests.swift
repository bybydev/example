import Foundation
import Testing
@testable import InkribeTranscription

@MainActor
@Test func emptyQueueStartsWithNoRecords() throws {
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("json")
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let controller = TranscriptionQueueController(storeURL: fileURL)
    try controller.start()

    #expect(controller.state == .idle)
    #expect(controller.recordCount == 0)
}
