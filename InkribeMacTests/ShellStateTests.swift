import Foundation
import Testing
@testable import Inkribe

@MainActor
@Suite("Shell state")
struct ShellStateTests {
    @Test func sidebarDefaultsExpandedAndUsesSharedDividerGeometry() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = InkribeShellState(defaults: defaults)

        #expect(state.isSidebarExpanded)
        #expect(state.sidebarWidth == InkribeShellMetrics.expandedSidebarWidth)
        #expect(state.dividerX == state.sidebarToggleCenterX)
    }

    @Test func sidebarVisibilityPersistsAcrossStateOwners() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = InkribeShellState(defaults: defaults)
        first.setSidebarExpanded(false)

        let restored = InkribeShellState(defaults: defaults)
        #expect(!restored.isSidebarExpanded)
        #expect(restored.sidebarWidth == InkribeShellMetrics.collapsedSidebarWidth)
        #expect(
            restored.sidebarToggleCenterX - (InkribeShellMetrics.toggleDiameter / 2)
                >= InkribeShellMetrics.trafficLightReserve
        )
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
