import CoreGraphics
import MacAppFoundation

enum InkribeShellMetrics {
    static let titlebarHeight = MacAppWindowChromeMetrics.titlebarHeight
    static let trafficLightReserve = MacAppWindowChromeMetrics.trafficLightReserve
    static let expandedSidebarWidth: CGFloat = 220
    static let dividerWidth: CGFloat = 1
    static let toggleDiameter: CGFloat = 26
    static let collapsedToggleClearance: CGFloat = 4

    /// The navigation content itself collapses completely. The structural rail
    /// remains wide enough to keep the native traffic lights on the sidebar side
    /// of the continuous divider and the divider-attached toggle outside the
    /// traffic-light reserve.
    static let collapsedSidebarWidth =
        trafficLightReserve
        + (toggleDiameter / 2)
        + collapsedToggleClearance

    static let statusBarHeight: CGFloat = 30
    static let minimumWindowWidth: CGFloat = 760
    static let minimumWindowHeight: CGFloat = 520
    static let sidebarAnimationDuration = 0.22
}
