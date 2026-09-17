import Foundation
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
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("json")
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let appState = InkribeAppState(queueStoreURLProvider: { fileURL })
    try appState.start()

    let firstQueue = try #require(appState.transcriptionQueue)
    try appState.start()
    let secondQueue = try #require(appState.transcriptionQueue)

    #expect(firstQueue === secondQueue)
    #expect(appState.startupIssue == nil)
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
