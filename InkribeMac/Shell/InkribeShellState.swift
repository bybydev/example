import CoreGraphics
import Foundation
import InkribeCore
import Observation

@MainActor
@Observable
final class InkribeShellState {
    static let sidebarExpandedDefaultsKey = "Inkribe.shell.sidebarExpanded"

    private let defaults: UserDefaults

    private(set) var isSidebarExpanded: Bool
    private(set) var route: InkribeShellRoute

    init(
        defaults: UserDefaults = .standard,
        initialRoute: InkribeShellRoute = .library
    ) {
        self.defaults = defaults
        if defaults.object(forKey: Self.sidebarExpandedDefaultsKey) == nil {
            self.isSidebarExpanded = true
        } else {
            self.isSidebarExpanded = defaults.bool(forKey: Self.sidebarExpandedDefaultsKey)
        }
        self.route = initialRoute
    }

    var sidebarWidth: CGFloat {
        isSidebarExpanded
            ? InkribeShellMetrics.expandedSidebarWidth
            : InkribeShellMetrics.collapsedSidebarWidth
    }

    var dividerX: CGFloat { sidebarWidth }
    var sidebarToggleCenterX: CGFloat { dividerX }

    func toggleSidebar() {
        setSidebarExpanded(!isSidebarExpanded)
    }

    func setSidebarExpanded(_ expanded: Bool) {
        guard expanded != isSidebarExpanded else { return }
        isSidebarExpanded = expanded
        defaults.set(expanded, forKey: Self.sidebarExpandedDefaultsKey)
    }

    func select(_ destination: InkribeShellDestination) {
        switch destination {
        case .library: route = .library
        case .record: route = .record
        case .import: route = .import
        }
    }

    func openTranscript(_ id: TranscriptID) {
        route = .transcript(id)
    }
}
