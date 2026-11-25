import BYOKchatProviderCore
import Foundation
import MacAppFoundation

/// Bounded product counters shared by lifecycle, commerce, and macOS app actions.
/// Mirrors iOS `BYOKAppAnalytics`: ephemeral in-memory storage, runtime opt-out,
/// and fixed product categories only (never content or resource identifiers).
@MainActor
enum MacAppAnalytics {
  typealias Event = BYOKProductAnalyticsEvent
  typealias Dimension = BYOKProductAnalyticsDimension

  nonisolated static let preferenceKey = "byokchat.analytics.shareUsageData"

  /// Prevents unit tests, UI tests, and seeded runs from emitting network
  /// events to the production analytics endpoint.
  nonisolated static var isSuppressedForTesting: Bool {
    let processInfo = ProcessInfo.processInfo
    let env = processInfo.environment
    if env["XCTestConfigurationFilePath"] != nil
      || env["XCTestSessionIdentifier"] != nil
      || env["XCTestBundlePath"] != nil
      || env["BYOK_DISABLE_ANALYTICS"] == "1"
    {
      return true
    }

    let args = processInfo.arguments
    if args.contains("-BYOKDisableAnalytics")
      || args.contains("-BYOKSeedPreset")
      || args.contains("UI_TEST_SCREENSHOTS")
    {
      return true
    }
    return false
  }

  nonisolated static func shareUsageDataPreference(
    in defaults: UserDefaults = .standard
  ) -> Bool {
    defaults.object(forKey: preferenceKey) as? Bool ?? true
  }

  nonisolated static func isCollectionAllowed(
    in defaults: UserDefaults = .standard,
    ignoreTestSuppression: Bool = false
  ) -> Bool {
    if !ignoreTestSuppression && isSuppressedForTesting {
      return false
    }
    return shareUsageDataPreference(in: defaults)
  }

  static var isEnabled: Bool {
    get { isCollectionAllowed() }
    set { UserDefaults.standard.set(newValue, forKey: preferenceKey) }
  }

  nonisolated static func makeConfiguration(enabled: Bool) -> AppAnalyticsConfiguration {
    AppAnalyticsConfiguration(
      appID: "byokchat",
      appKey: Bundle.main.bundleIdentifier ?? "com.hoangbkit.byokchat",
      baseURL: URL(string: "https://analytics.133043.xyz")!,
      enabled: enabled,
      storageMode: .inMemory
    )
  }

  static let configuration = makeConfiguration(enabled: isEnabled)

  static let client = AppAnalyticsClient(configuration: configuration)

  private static var pendingTrack: Task<Void, Never>?

  static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) async {
    defaults.set(enabled, forKey: preferenceKey)
    if defaults === UserDefaults.standard {
      await client.setEnabled(isSuppressedForTesting ? false : enabled)
    }
  }

  static func reportError(
    _ code: String,
    component: String,
    severity: AppAnalyticsErrorSeverity = .error
  ) {
    guard isEnabled else { return }
    Task {
      guard isEnabled else { return }
      try? await client.trackError(code, component: component, severity: severity)
    }
  }

  static func track(_ event: Event, detail: String?) {
    guard isEnabled else { return }
    let previousTrack = pendingTrack
    pendingTrack = Task {
      await previousTrack?.value
      guard isEnabled else { return }
      try? await client.track(event.rawValue, dimension: detail)
    }
  }

  static func track(_ event: Event, dimension: Dimension? = nil) {
    guard isEnabled else { return }
    let previousTrack = pendingTrack
    pendingTrack = Task {
      await previousTrack?.value
      guard isEnabled else { return }
      try? await client.track(event.rawValue, dimension: dimension?.rawValue)
    }
  }
}

extension BYOKProductAnalyticsDimension {
  init(feature: MacProFeature) {
    switch feature {
    case .themes:
      self = .themes
    case .providerAccounts:
      self = .providers
    case .projects:
      self = .projects
    case .mcpServers:
      self = .mcp
    case .analytics:
      self = .analyticsHistory
    case .chatSearch:
      self = .chatSearch
    }
  }
}
