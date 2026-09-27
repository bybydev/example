import Foundation
import MacAppFoundation

enum MacAppAnalytics {
  static let client = AppAnalyticsClient(
    configuration: AppAnalyticsConfiguration(
      appID: "byokchat",
      appKey: Bundle.main.bundleIdentifier ?? "com.hoangbkit.byokchat",
      baseURL: URL(string: "https://analytics.133043.xyz")!,
      uploadInterval: 5 * 60
    )
  )

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
