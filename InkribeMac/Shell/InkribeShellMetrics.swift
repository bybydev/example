import CoreGraphics
import MacAppFoundation

enum InkribeShellMetrics {
    static let titlebarHeight = MacAppWindowChromeMetrics.titlebarHeight
    static let trafficLightReserve = MacAppWindowChromeMetrics.trafficLightReserve
    static let expandedSidebarWidth: CGFloat = 220
    static let collapsedSidebarWidth: CGFloat = 0
    static let dividerWidth: CGFloat = 1
    static let toggleDiameter: CGFloat = 26
    static let titlebarLeadingSpacing: CGFloat = 8
    static let statusBarHeight: CGFloat = 30
    static let minimumWindowWidth: CGFloat = 760
    static let minimumWindowHeight: CGFloat = 520
    static let sidebarAnimationDuration = 0.22
}
