import Foundation
import Testing
@testable import Inkribe

@MainActor
@Suite("Shell state")
struct ShellStateTests {
    @Test func sidebarDefaultsExpandedAtConfiguredWidth() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = InkribeShellState(defaults: defaults)

        #expect(state.isSidebarExpanded)
        #expect(state.sidebarWidth == InkribeShellMetrics.expandedSidebarWidth)
    }

    @Test func sidebarCollapsesToZeroAndPersistsAcrossStateOwners() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = InkribeShellState(defaults: defaults)
        first.setSidebarExpanded(false)

        let restored = InkribeShellState(defaults: defaults)
        #expect(!restored.isSidebarExpanded)
        #expect(restored.sidebarWidth == 0)
        #expect(InkribeShellMetrics.collapsedSidebarWidth == 0)
    }

    @Test func transcriptIsMainDetailRouteNotSidebarDestination() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = InkribeShellState(defaults: defaults)
        let id = TranscriptID()
        state.openTranscript(id)

        #expect(state.route.sidebarDestination == nil)
        #expect(state.route.title == "Transcript")
        #expect(state.activeTranscriptID == id)

        state.select(.library)
        #expect(state.activeTranscriptID == nil)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "InkribeShellStateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
