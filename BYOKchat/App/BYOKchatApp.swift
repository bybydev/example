import AppFoundation
import BYOKchatProviderCore
import Foundation
import SwiftUI

@main
@MainActor
struct BYOKchatApp: App {
  @State private var model: AppModel
  private let purchases: BYOKPurchaseStore
  private let analytics = BYOKAppAnalytics.client

  init() {
    #if DEBUG
    BYOKScreenshotFixtures.prepareIfNeeded()
    #endif
    let appModel = AppModel()
    let purchaseStore = BYOKPurchaseStore()
    // Bind before preparing StoreKit so verified access and theme persistence
    // stay in sync even when the root view is not mounted yet.
    appModel.themeManager.bind(to: purchaseStore.manager)
    _model = State(initialValue: appModel)
    purchases = purchaseStore
  }

  var body: some Scene {
    WindowGroup {
      AppRootView(
        model: model,
        purchases: purchases,
        restartApp: { model = AppModel() }
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

  static var isEnabled: Bool {
    get { UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true }
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
    await client.setEnabled(enabled)
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
    }
  }
}
