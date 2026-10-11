import BYOKchatProviderCore
import Foundation
import MacAppFoundation

@MainActor
enum MacAppAnalytics {
  typealias Event = BYOKProductAnalyticsEvent
  typealias Dimension = BYOKProductAnalyticsDimension

  static let client = AppAnalyticsClient(
    configuration: AppAnalyticsConfiguration(
      appID: "byokchat",
      appKey: Bundle.main.bundleIdentifier ?? "com.hoangbkit.byokchat",
      baseURL: URL(string: "https://analytics.133043.xyz")!,
      uploadInterval: 5 * 60
    )
  )

  private static var isProductTrackingEnabled: Bool {
    #if DEBUG
    let environment = ProcessInfo.processInfo.environment
    return environment["XCTestConfigurationFilePath"] == nil
      && environment["XCTestBundlePath"] == nil
    #else
    return true
    #endif
  }

  private static var pendingTrack: Task<Void, Never>?

  static func track(_ event: Event, dimension: Dimension? = nil) {
    guard isProductTrackingEnabled else { return }
    let previousTrack = pendingTrack
    pendingTrack = Task {
      await previousTrack?.value
      try? await client.track(event.rawValue, dimension: dimension?.rawValue)
    }
  }

  static func trackFirstResponse() {
    guard isProductTrackingEnabled else { return }
    let key = "byokchat.analytics.firstResponseCompleted.v1"
    guard !UserDefaults.standard.bool(forKey: key) else { return }
    UserDefaults.standard.set(true, forKey: key)
    track(.firstResponseCompleted)
  }

  static func reportError(
    _ code: String,
    component: String,
    severity: AppAnalyticsErrorSeverity = .error
  ) {
    Task {
      try? await client.trackError(code, component: component, severity: severity)
    }
  }
}
