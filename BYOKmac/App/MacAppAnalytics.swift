import BYOKchatProviderCore
import Foundation
import MacAppFoundation

struct MacAnalyticsGatedTransport: AppAnalyticsTransport {
  let base: any AppAnalyticsTransport
  let isAllowed: @Sendable () -> Bool

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    guard isAllowed() else {
      throw CancellationError()
    }
    return try await base.data(for: request)
  }
}

actor MacAnalyticsGatedStateStore: AppAnalyticsStateStoring {
  private let base: any AppAnalyticsStateStoring
  private let isAllowed: @Sendable () -> Bool

  init(
    base: any AppAnalyticsStateStoring,
    isAllowed: @escaping @Sendable () -> Bool
  ) {
    self.base = base
    self.isAllowed = isAllowed
  }

  func load() async throws -> Data? {
    guard isAllowed() else { return nil }
    return try await base.load()
  }

  func save(_ data: Data) async throws {
    guard isAllowed() else { return }
    try await base.save(data)
  }

  func remove() async throws {
    try await base.remove()
  }
}

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

  private static let configuration = AppAnalyticsConfiguration(
    appID: "byokchat",
    appKey: Bundle.main.bundleIdentifier ?? "com.hoangbkit.byokchat",
    baseURL: URL(string: "https://analytics.133043.xyz")!,
    uploadInterval: 5 * 60
  )

  static let client = AppAnalyticsClient(
    configuration: configuration,
    transport: MacAnalyticsGatedTransport(
      base: URLSessionAppAnalyticsTransport(),
      isAllowed: { isCollectionAllowed() }
    ),
    stateStore: MacAnalyticsGatedStateStore(
      base: UserDefaultsAppAnalyticsStateStore(storageKey: configuration.stateStorageKey),
      isAllowed: { isCollectionAllowed() }
    )
  )

  private static var pendingTrack: Task<Void, Never>?

  static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) async {
    defaults.set(enabled, forKey: preferenceKey)
    if !enabled, defaults === UserDefaults.standard {
      try? await client.resetLocalState()
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

  static func trackFirstResponse() {
    guard isEnabled else { return }
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
    guard isEnabled else { return }
    Task {
      guard isEnabled else { return }
      try? await client.trackError(code, component: component, severity: severity)
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
