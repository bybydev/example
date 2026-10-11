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

  private static let isEnabled = false

  static let client = AppAnalyticsClient(
    configuration: AppAnalyticsConfiguration(
      appID: "byokchat",
      appKey: Bundle.main.bundleIdentifier ?? "com.hoangbkit.byokchat",
      baseURL: URL(string: "https://analytics.133043.xyz")!,
      enabled: false,
      uploadInterval: 60
    )
  )

  private static var pendingTrack: Task<Void, Never>?

  static func track(_ event: Event, dimension: Dimension? = nil) {
    guard isEnabled else { return }
    let previousTrack = pendingTrack
    pendingTrack = Task {
      await previousTrack?.value
      try? await client.track(event.rawValue, dimension: dimension?.rawValue)
    }
  }

  /// Records activation once on this installation after the first persisted
  /// successful response observed by this version of the app.
  static func trackFirstResponse() {
    guard isEnabled else { return }
    let key = "byokchat.analytics.firstResponseCompleted.v1"
    guard !UserDefaults.standard.bool(forKey: key) else { return }
    UserDefaults.standard.set(true, forKey: key)
    track(.firstResponseCompleted)
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
