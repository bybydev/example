import BYOKchatProviderCore
import Foundation
import MacAppFoundation
import Observation
import SwiftUI

@MainActor
enum MacWindowID {
  static let proPaywall = "byokchat.pro-paywall"
}

enum MacSettingsTab: String, CaseIterable, Hashable, Sendable {
  case general
  case data
  case theme
  case plan
  case about
}

/// Routes requests from anywhere in the app to a specific Settings tab, using
/// the same request-ID pattern as `MacProGateCenter` so an already-open
/// Settings window still reacts.
@MainActor
@Observable
final class MacSettingsRouter {
  static let shared = MacSettingsRouter()

  private(set) var requestID = 0
  private(set) var requestedTab: MacSettingsTab?

  private init() {}

  func request(_ tab: MacSettingsTab) {
    requestedTab = tab
    requestID &+= 1
  }

  func consumeRequestedTab() -> MacSettingsTab? {
    defer { requestedTab = nil }
    return requestedTab
  }
}

enum MacProEntitlementAccess: Sendable, Equatable {
  case checking
  case free
  case pro
}

enum MacProGateDecision: Sendable, Equatable {
  case allowed
  case checking
  case requiresPro
}

@MainActor
enum MacPurchaseStore {
  static let monthlyProductID = BYOKProCatalog.monthlyProductID
  static let yearlyProductID = BYOKProCatalog.yearlyProductID
  static let lifetimeProductID = BYOKProCatalog.lifetimeProductID

  #if DEBUG
  static let simulatedModeKey = "byokchat.mac.developer.simulatedPurchases"
  #endif

  static let features: [PurchaseFeature] = [
    PurchaseFeature(
      id: "provider-accounts",
      systemImage: "key.horizontal.fill",
      title: "Provider accounts",
      message: "Connect as many provider accounts as you need instead of the single free account.",
      freeValue: "1",
      proValue: "Unlimited"
    ),
    PurchaseFeature(
      id: "projects",
      systemImage: "folder.fill",
      title: "Projects",
      message: "Organize chats, files, prompts, models, and tools across unlimited projects.",
      freeValue: "1",
      proValue: "Unlimited"
    ),
    PurchaseFeature(
      id: "mcp-servers",
      systemImage: "shippingbox.fill",
      title: "MCP servers",
      message: "Connect unlimited remote MCP servers instead of the single free server.",
      freeValue: "1",
      proValue: "Unlimited"
    ),
    PurchaseFeature(
      id: "analytics-history",
      systemImage: "chart.bar.xaxis",
      title: "Usage analytics",
      message: "All analytics features are free for today. Pro unlocks 7-day, 30-day, monthly, and all-time history.",
      freeValue: "Today",
      proValue: "All date ranges"
    ),
    PurchaseFeature(
      id: "chat-search",
      systemImage: "magnifyingglass",
      title: "Chat search",
      message: "Search chat titles for free. Pro unlocks fast full-text search across every message and attachment name.",
      freeValue: "Titles",
      proValue: "Full-text search"
    ),
    PurchaseFeature(
      id: "themes",
      systemImage: "paintpalette.fill",
      title: "Themes",
      message: "Basic themes are free. Pro unlocks every built-in theme.",
      freeValue: "Basic",
      proValue: "All themes"
    ),
  ]

  static let configuration = PurchaseConfiguration(
    productIDs: BYOKProCatalog.productIDs,
    preferredProductID: BYOKProCatalog.preferredProductID,
    features: features
  )

  static let appStoreID = "6799335915"
  static let writeReviewURL = URL(string: "https://apps.apple.com/app/id\(appStoreID)?action=write-review")!
  static let websiteURL = URL(string: "https://spokiostudio.com/byokchat")!
  static let contactURL = URL(string: "https://spokiostudio.com/byokchat/contact")!
  static let privacyURL = URL(string: "https://spokiostudio.com/byokchat/privacy")!
  static let termsURL = URL(string: "https://spokiostudio.com/byokchat/terms")!

  static let simulatedProducts: [StoreProduct] = [
    StoreProduct(
      id: monthlyProductID,
      displayName: "BYOK Pro Monthly",
      description: "BYOK Pro for one month",
      displayPrice: "$6.99",
      price: 6.99,
      subscriptionPeriod: .init(value: 1, unit: .month)
    ),
    StoreProduct(
      id: yearlyProductID,
      displayName: "BYOK Pro Yearly",
      description: "BYOK Pro for one year",
      displayPrice: "$29.99",
      price: 29.99,
      subscriptionPeriod: .init(value: 1, unit: .year)
    ),
    StoreProduct(
      id: lifetimeProductID,
      displayName: "BYOK Pro Lifetime",
      description: "Pay once and keep BYOK Pro forever",
      displayPrice: "$49.99",
      price: 49.99,
      subscriptionPeriod: nil
    ),
  ]

  static let manager: PurchaseManager = {
    #if DEBUG
    let startsSimulated = UserDefaults.standard.bool(forKey: simulatedModeKey)
    #else
    let startsSimulated = false
    #endif

    return PurchaseManager(
      configuration: configuration,
      simulated: startsSimulated,
      simulatedProducts: simulatedProducts,
      simulatedPersistenceKey: "byokchat.mac.simulatedPurchases"
    )
  }()

  static let paywallConfiguration = ProPaywallConfiguration(
    title: "BYOK Pro",
    subtitle: "Unlock every theme, full-text search, unlimited configurations, and your full analytics history.",
    highlightedProductID: yearlyProductID,
    highlightedProductBadge: "BEST VALUE",
    termsURL: termsURL,
    privacyURL: privacyURL,
    showsRedeemCode: true
  )

  static let planConfiguration = ProPlanPaneConfiguration(appName: "BYOKchat")

  #if DEBUG
  static var developerConfiguration: FoundationDeveloperConfiguration {
    FoundationDeveloperConfiguration(
      replays: [
        FoundationDeveloperReplay(
          id: "paywall",
          title: "Pro Paywall",
          systemImage: "crown.fill"
        ) { dismiss in
          ProPaywallView(
            purchaseManager: manager,
            configuration: paywallConfiguration,
            onPurchased: { _ in dismiss() },
            onRestored: dismiss,
            onClose: dismiss
          )
        }
      ]
    )
  }
  #endif
}

struct MacProComparisonRow: Identifiable, Equatable, Sendable {
  let id: String
  let systemImage: String
  let feature: String
  let freeValue: String
  let proValue: String
  let isHighlighted: Bool
}

struct MacProUpsellContent: Equatable, Sendable {
  let title: String
  let headline: String
  let summary: String
  let systemImage: String
  let comparisonTitle: String
  let comparisonFootnote: String
  let rows: [MacProComparisonRow]
  let primaryActionTitle: String
  let secondaryActionTitle: String
}

enum MacProFeature: String, CaseIterable, Identifiable, Sendable {
  case providerAccounts
  case projects
  case mcpServers
  case analytics
  case chatSearch
  case themes

  var id: String { rawValue }

  var title: String {
    switch self {
    case .providerAccounts:
      "Provider accounts"
    case .projects:
      "Projects"
    case .mcpServers:
      "MCP servers"
    case .analytics:
      "Usage analytics"
    case .chatSearch:
      "Chat search"
    case .themes:
      "Themes"
    }
  }

  var headline: String {
    switch self {
    case .providerAccounts:
      "Free includes 1 connection"
    case .projects:
      "Free includes 1 project"
    case .mcpServers:
      "Free includes 1 MCP server"
    case .analytics:
      "Unlock analytics history"
    case .chatSearch:
      "Unlock full-text chat search"
    case .themes:
      "Unlock every theme"
    }
  }

  var summary: String {
    switch self {
    case .providerAccounts:
      "Keep your existing connection, or upgrade to BYOK Pro to add unlimited cloud, local, and custom provider accounts."
    case .projects:
      "Keep your existing project, or upgrade to BYOK Pro to organize chats, sources, prompts, and tool defaults across unlimited projects."
    case .mcpServers:
      "Keep your existing server, or upgrade to BYOK Pro to connect unlimited remote MCP servers."
    case .analytics:
      "Every analytics view is free for today. Upgrade to BYOK Pro to explore usage, cost, performance, and reliability across 7-day, 30-day, monthly, and all-time history."
    case .chatSearch:
      "Search chat titles for free. Upgrade to BYOK Pro for fast full-text search across every message and attachment name in your history."
    case .themes:
      "Basic themes are free. Upgrade to BYOK Pro to unlock every built-in macOS theme."
    }
  }

  var systemImage: String {
    switch self {
    case .providerAccounts:
      "key.horizontal.fill"
    case .projects:
      "folder.fill"
    case .mcpServers:
      "shippingbox.fill"
    case .analytics:
      "chart.bar.xaxis"
    case .chatSearch:
      "magnifyingglass"
    case .themes:
      "paintpalette.fill"
    }
  }

  var freeComparisonValue: String {
    switch self {
    case .providerAccounts:
      "1"
    case .projects:
      "1"
    case .mcpServers:
      "1"
    case .analytics:
      "Today"
    case .chatSearch:
      "Titles"
    case .themes:
      "Basic"
    }
  }

  var proComparisonValue: String {
    switch self {
    case .providerAccounts:
      "Unlimited"
    case .projects:
      "Unlimited"
    case .mcpServers:
      "Unlimited"
    case .analytics:
      "All date ranges"
    case .chatSearch:
      "Full-text search"
    case .themes:
      "All themes"
    }
  }

  var comparisonRows: [MacProComparisonRow] {
    Self.allCases.map { item in
      MacProComparisonRow(
        id: item.id,
        systemImage: item.systemImage,
        feature: item.title,
        freeValue: item.freeComparisonValue,
        proValue: item.proComparisonValue,
        isHighlighted: item == self
      )
    }
  }

  var upsellContent: MacProUpsellContent {
    MacProUpsellContent(
      title: title,
      headline: headline,
      summary: summary,
      systemImage: systemImage,
      comparisonTitle: "Free vs Pro",
      comparisonFootnote: "Saved data is always preserved if Pro expires; access to Pro-only features and historical analytics is locked.",
      rows: comparisonRows,
      primaryActionTitle: "See BYOK Pro Plans",
      secondaryActionTitle: "Not Now"
    )
  }
}

@MainActor
@Observable
final class MacProGateCenter {
  static let shared = MacProGateCenter()

  /// Observed by `BYOKmacApp` to open `MacWindowID.proPaywall`. Only incremented
  /// when the user chooses to view Pro plans or an explicit paywall open is requested.
  private(set) var requestID = 0
  /// Observed by active windows/sheets to present the contextual `MacProUpsellSheet`
  /// before opening the paywall window.
  private(set) var upsellRequestID = 0
  private(set) var feature: MacProFeature?

  @ObservationIgnored private var handledUpsellRequestID = 0
  @ObservationIgnored private var handledPaywallRequestID = 0

  init() {}

  func request(_ feature: MacProFeature) {
    MacAppAnalytics.track(.upgradeRequested, dimension: .init(feature: feature))
    self.feature = feature
    upsellRequestID &+= 1
  }

  /// Atomically claims the latest pending contextual upsell so only one open
  /// window presents `MacProUpsellSheet` for a given request.
  func claimPendingUpsell() -> MacProFeature? {
    guard handledUpsellRequestID != upsellRequestID, let feature else {
      return nil
    }
    handledUpsellRequestID = upsellRequestID
    return feature
  }

  func openPaywall() {
    requestID &+= 1
  }

  /// Atomically claims the latest paywall open request so duplicate scene
  /// modifiers do not invoke `openWindow` twice for the same request.
  func claimPendingPaywallOpen() -> Bool {
    guard handledPaywallRequestID != requestID else { return false }
    handledPaywallRequestID = requestID
    return true
  }
}

@MainActor
enum MacProAccess {
  static let freeProviderAccountLimit = BYOKProPolicy.freeProviderAccountLimit
  static let freeProjectLimit = BYOKProPolicy.freeProjectLimit
  static let freeMCPServerLimit = BYOKProPolicy.freeMCPServerLimit

  static var entitlementAccess: MacProEntitlementAccess {
    switch MacPurchaseStore.manager.entitlementState {
    case .checking:
      .checking
    case .inactive:
      .free
    case .active:
      .pro
    }
  }

  static var hasPro: Bool { entitlementAccess == .pro }
  static var isCheckingEntitlement: Bool { entitlementAccess == .checking }

  static func canCreateProviderAccount(currentCount: Int, hasPro: Bool) -> Bool {
    BYOKProPolicy.canCreateProviderAccount(currentCount: currentCount, hasPro: hasPro)
  }

  static func canCreateProject(currentCount: Int, hasPro: Bool) -> Bool {
    BYOKProPolicy.canCreateProject(currentCount: currentCount, hasPro: hasPro)
  }

  static func canCreateMCPServer(currentCount: Int, hasPro: Bool) -> Bool {
    BYOKProPolicy.canCreateMCPServer(currentCount: currentCount, hasPro: hasPro)
  }

  static func canUseChatSearch(hasPro: Bool) -> Bool {
    BYOKProPolicy.canUseFullTextSearch(hasPro: hasPro)
  }

  static func canUseTheme(_ themeID: MacAppThemeID, hasPro: Bool) -> Bool {
    hasPro || !MacThemeFoundation.isProTheme(themeID)
  }

  static func chatSearchDecision(
    entitlement: MacProEntitlementAccess? = nil
  ) -> MacProGateDecision {
    let access = entitlement ?? entitlementAccess
    switch access {
    case .pro:
      return .allowed
    case .checking:
      return .checking
    case .free:
      return .requiresPro
    }
  }

  static func themeDecision(
    _ themeID: MacAppThemeID,
    entitlement: MacProEntitlementAccess? = nil
  ) -> MacProGateDecision {
    if !MacThemeFoundation.isProTheme(themeID) {
      return .allowed
    }
    let access = entitlement ?? entitlementAccess
    switch access {
    case .pro:
      return .allowed
    case .checking:
      return .checking
    case .free:
      return .requiresPro
    }
  }

  static func providerAccountCapacityDecision(
    currentCount: Int,
    entitlement: MacProEntitlementAccess? = nil
  ) -> MacProGateDecision {
    capacityDecision(
      currentCount: currentCount,
      limit: freeProviderAccountLimit,
      entitlement: entitlement ?? entitlementAccess
    )
  }

  static func projectCapacityDecision(
    currentCount: Int,
    entitlement: MacProEntitlementAccess? = nil
  ) -> MacProGateDecision {
    capacityDecision(
      currentCount: currentCount,
      limit: freeProjectLimit,
      entitlement: entitlement ?? entitlementAccess
    )
  }

  static func mcpServerCapacityDecision(
    currentCount: Int,
    entitlement: MacProEntitlementAccess? = nil
  ) -> MacProGateDecision {
    capacityDecision(
      currentCount: currentCount,
      limit: freeMCPServerLimit,
      entitlement: entitlement ?? entitlementAccess
    )
  }

  static func providerConfigurationImportDecision(
    existingIDs: [ProviderAccountID],
    importedIDs: [ProviderAccountID],
    strategy: ProviderImportStrategy,
    entitlement: MacProEntitlementAccess? = nil
  ) -> MacProGateDecision {
    let projectedCount: Int
    switch strategy {
    case .replaceExisting:
      projectedCount = Set(importedIDs).count
    case .keepExisting:
      projectedCount = Set(existingIDs).union(importedIDs).count
    }

    let access = entitlement ?? entitlementAccess
    if access == .pro || projectedCount <= freeProviderAccountLimit { return .allowed }
    return access == .checking ? .checking : .requiresPro
  }

  static func requireProviderAccountCapacity(currentCount: Int) -> Bool {
    requireCapacity(
      decision: providerAccountCapacityDecision(currentCount: currentCount),
      feature: .providerAccounts
    )
  }

  static func requireProjectCapacity(currentCount: Int) -> Bool {
    requireCapacity(
      decision: projectCapacityDecision(currentCount: currentCount),
      feature: .projects
    )
  }

  static func requireMCPServerCapacity(currentCount: Int) -> Bool {
    requireCapacity(
      decision: mcpServerCapacityDecision(currentCount: currentCount),
      feature: .mcpServers
    )
  }

  static func requestUpgrade(_ feature: MacProFeature) {
    guard entitlementAccess == .free else { return }
    MacProGateCenter.shared.request(feature)
  }

  static func blockedMessage(freeMessage: String) -> String {
    isCheckingEntitlement
      ? "Checking your BYOK Pro status. Try again in a moment."
      : freeMessage
  }

  private static func capacityDecision(
    currentCount: Int,
    limit: Int,
    entitlement: MacProEntitlementAccess
  ) -> MacProGateDecision {
    if entitlement == .pro || currentCount < limit { return .allowed }
    return entitlement == .checking ? .checking : .requiresPro
  }

  private static func requireCapacity(
    decision: MacProGateDecision,
    feature: MacProFeature
  ) -> Bool {
    switch decision {
    case .allowed:
      return true
    case .checking:
      return false
    case .requiresPro:
      MacProGateCenter.shared.request(feature)
      return false
    }
  }
}

struct MacProUpsellSheet: View {
  let feature: MacProFeature
  var onSeePlans: (() -> Void)? = nil

  @Environment(\.dismiss) private var dismiss
  @Environment(\.openWindow) private var openWindow
  @Environment(PurchaseManager.self) private var purchaseManager: PurchaseManager?

  private var content: MacProUpsellContent {
    feature.upsellContent
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 18)

      Divider()

      comparisonSection
        .padding(.horizontal, 24)
        .padding(.vertical, 18)

      Divider()

      footer
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
    .frame(width: 500)
    .background(MacDesignTokens.Colors.canvas)
    .onChange(of: purchaseManager?.hasPro ?? false) { _, hasPro in
      if hasPro {
        dismiss()
      }
    }
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: content.systemImage)
        .font(.system(size: 20, weight: .semibold))
        .foregroundStyle(MacDesignTokens.Colors.accent)
        .frame(width: 44, height: 44)
        .background(
          MacDesignTokens.Colors.accentSoft,
          in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.medium, style: .continuous)
        )
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 5) {
          Image(systemName: "crown.fill")
            .font(.system(size: 10, weight: .semibold))
          Text("BYOK PRO")
            .font(.system(size: 10.5, weight: .bold))
            .tracking(0.8)
        }
        .foregroundStyle(MacDesignTokens.Colors.accent)

        Text(content.headline)
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(MacDesignTokens.Colors.textPrimary)

        Text(content.summary)
          .font(.callout)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var comparisonSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(content.comparisonTitle)
        .font(.system(size: 12.5, weight: .semibold))
        .foregroundStyle(MacDesignTokens.Colors.textPrimary)

      VStack(spacing: 0) {
        HStack(spacing: 12) {
          Text("Feature")
            .frame(maxWidth: .infinity, alignment: .leading)
          Text("Free")
            .frame(width: 102, alignment: .trailing)
          Text("Pro")
            .frame(width: 112, alignment: .trailing)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)

        Rectangle()
          .fill(MacDesignTokens.Colors.separator.opacity(0.75))
          .frame(height: 1)

        ForEach(Array(content.rows.enumerated()), id: \.element.id) { index, row in
          if index > 0 {
            Rectangle()
              .fill(MacDesignTokens.Colors.separator.opacity(0.45))
              .frame(height: 1)
          }

          HStack(spacing: 12) {
            HStack(spacing: 8) {
              Image(systemName: row.systemImage)
                .font(.system(size: 12, weight: row.isHighlighted ? .semibold : .medium))
                .foregroundStyle(
                  row.isHighlighted
                    ? MacDesignTokens.Colors.accent
                    : MacDesignTokens.Colors.textMuted
                )
                .frame(width: 16)

              Text(row.feature)
                .font(.system(size: 12.5, weight: row.isHighlighted ? .semibold : .regular))
                .foregroundStyle(MacDesignTokens.Colors.textPrimary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(row.freeValue)
              .font(.system(size: 12))
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
              .lineLimit(1)
              .frame(width: 102, alignment: .trailing)

            Text(row.proValue)
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(
                row.isHighlighted
                  ? MacDesignTokens.Colors.accent
                  : MacDesignTokens.Colors.textPrimary
              )
              .lineLimit(1)
              .frame(width: 112, alignment: .trailing)
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 9)
          .background(
            row.isHighlighted
              ? MacDesignTokens.Colors.accentSoft.opacity(0.65)
              : Color.clear
          )
        }
      }
      .background(
        MacDesignTokens.Colors.surface,
        in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.medium, style: .continuous)
      )
      .clipShape(
        RoundedRectangle(cornerRadius: MacDesignTokens.Radius.medium, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: MacDesignTokens.Radius.medium, style: .continuous)
          .stroke(MacDesignTokens.Colors.separator.opacity(0.82), lineWidth: 1)
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("BYOK Free and Pro feature comparison")

      Text(content.comparisonFootnote)
        .font(.caption)
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var footer: some View {
    HStack(spacing: 10) {
      Spacer(minLength: 0)

      Button(content.secondaryActionTitle) {
        dismiss()
      }
      .buttonStyle(MacActionButtonStyle(.secondary))
      .keyboardShortcut(.cancelAction)

      Button(content.primaryActionTitle) {
        dismiss()
        if let onSeePlans {
          onSeePlans()
        } else {
          openWindow(id: MacWindowID.proPaywall)
        }
      }
      .buttonStyle(MacActionButtonStyle(.primary))
      .keyboardShortcut(.defaultAction)
    }
  }
}

@MainActor
private struct MacProUpsellPresenterModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .background {
        MacProUpsellPresenterHost()
      }
  }
}

@MainActor
private struct MacProUpsellPresenterHost: View {
  @Environment(MacProGateCenter.self) private var proGateCenter: MacProGateCenter?
  @Environment(\.controlActiveState) private var controlActiveState
  @State private var activeFeature: MacProFeature?

  var body: some View {
    Color.clear
      .allowsHitTesting(false)
      .accessibilityHidden(true)
      .onChange(of: proGateCenter?.upsellRequestID ?? 0) { _, _ in
        guard controlActiveState == .key,
          let claimed = proGateCenter?.claimPendingUpsell()
        else { return }
        activeFeature = claimed
      }
      .sheet(item: $activeFeature) { feature in
        MacProUpsellSheet(feature: feature)
      }
  }
}

extension View {
  @MainActor
  func macProUpsellPresenter() -> some View {
    modifier(MacProUpsellPresenterModifier())
  }
}

struct MacProPaywallWindow: View {
  let purchaseManager: PurchaseManager

  @Environment(\.dismissWindow) private var dismissWindow

  var body: some View {
    ProPaywallView(
      purchaseManager: purchaseManager,
      configuration: MacPurchaseStore.paywallConfiguration,
      onPurchased: { _ in close() },
      onRestored: close,
      onClose: close
    )
  }

  private func close() {
    dismissWindow(id: MacWindowID.proPaywall)
  }
}