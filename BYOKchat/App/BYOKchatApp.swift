import AppFoundation
import BYOKchatProviderCore
import Foundation
import SwiftUI

@main
@MainActor
struct BYOKchatApp: App {
  @State private var model: AppModel
  @State private var purchases: BYOKPurchaseStore
  private let analytics = BYOKAppAnalytics.client

  init() {
    #if DEBUG
    BYOKSeedLaunchOptions.prepareLaunchIfNeeded()
    #endif
    let appModel = AppModel()
    let purchaseStore = BYOKPurchaseStore()
    // Bind before preparing StoreKit so verified access and theme persistence
    // stay in sync even when the root view is not mounted yet.
    appModel.themeManager.bind(to: purchaseStore.manager)
    _model = State(initialValue: appModel)
    _purchases = State(initialValue: purchaseStore)
  }

  var body: some Scene {
    WindowGroup {
      AppRootView(
        model: model,
        purchases: purchases,
        restartApp: {
          let newModel = AppModel()
          let newPurchases = BYOKPurchaseStore()
          newModel.themeManager.bind(to: newPurchases.manager)
          purchases = newPurchases
          model = newModel
        }
      )
      .id(ObjectIdentifier(model))
      .appFoundationTheme(model.themeManager, purchaseManager: purchases.manager)
      .environment(model)
      .environment(purchases.manager)
      .managesAnalytics(analytics)
    }
  }
}

/// Bounded product counters shared by lifecycle, commerce and iOS app actions.
/// User content and resource identifiers cannot be passed as event dimensions.
@MainActor
enum BYOKAppAnalytics {
  typealias Event = BYOKProductAnalyticsEvent
  typealias Dimension = BYOKProductAnalyticsDimension

  static let preferenceKey = "byokchat.analytics.shareUsageData"

  /// Prevents unit tests, UI tests, and seeded screenshot runs from emitting
  /// network events to the production analytics endpoint.
  static var isSuppressedForTesting: Bool {
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

  static var isEnabled: Bool {
    get {
      guard !isSuppressedForTesting else { return false }
      return UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true
    }
    set { UserDefaults.standard.set(newValue, forKey: preferenceKey) }
  }

  static let client = AppAnalyticsClient(
    configuration: AppAnalyticsConfiguration(
      appID: "byokchat",
      appKey: Bundle.main.bundleIdentifier ?? "com.hoangbkit.byokchat",
      baseURL: URL(string: "https://analytics.133043.xyz")!,
      enabled: isEnabled,
      storageMode: .inMemory
    )
  )

  static func setEnabled(_ enabled: Bool) async {
    isEnabled = enabled
    await client.setEnabled(isSuppressedForTesting ? false : enabled)
  }

  static func reportError(
    _ code: String,
    component: String,
    severity: AppAnalyticsErrorSeverity = .error
  ) {
    guard isEnabled else { return }
    Task {
      try? await client.trackError(code, component: component, severity: severity)
    }
  }

  static func track(_ event: Event, detail: String?) {
    guard isEnabled else { return }
    let previousTrack = pendingTrack
    pendingTrack = Task {
      await previousTrack?.value
      try? await client.track(event.rawValue, dimension: detail)
    }
  }

  private static var pendingTrack: Task<Void, Never>?

  static func track(_ event: Event, dimension: Dimension? = nil) {
    guard isEnabled else { return }
    let previousTrack = pendingTrack
    pendingTrack = Task {
      await previousTrack?.value
      try? await client.track(event.rawValue, dimension: dimension?.rawValue)
    }
  }
}

extension BYOKProductAnalyticsDimension {
  init(feature: BYOKProFeature) {
    switch feature {
    case .themes: self = .themes
    case .providerAccounts: self = .providers
    case .projects: self = .projects
    case .mcpServers: self = .mcp
    case .analytics: self = .analyticsHistory
    case .chatSearch: self = .chatSearch
    }
  }
}
