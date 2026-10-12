import AppFoundation
import Foundation
import Testing

@testable import BYOKchat

@Suite("BYOK Pro access")
struct BYOKProAccessTests {
  @Test("Free provider accounts stop at one")
  func providerAccountLimit() {
    #expect(BYOKProAccess.canCreateProviderAccount(currentCount: 0, hasPro: false))
    #expect(!BYOKProAccess.canCreateProviderAccount(currentCount: 1, hasPro: false))
    #expect(BYOKProAccess.canCreateProviderAccount(currentCount: 10, hasPro: true))
  }

  @Test("Free projects stop at one")
  func projectLimit() {
    #expect(BYOKProAccess.canCreateProject(currentCount: 0, hasPro: false))
    #expect(!BYOKProAccess.canCreateProject(currentCount: 1, hasPro: false))
    #expect(BYOKProAccess.canCreateProject(currentCount: 10, hasPro: true))
  }

  @Test("Free MCP servers stop at one")
  func mcpServerLimit() {
    #expect(BYOKProAccess.canCreateMCPServer(currentCount: 0, hasPro: false))
    #expect(!BYOKProAccess.canCreateMCPServer(currentCount: 1, hasPro: false))
    #expect(BYOKProAccess.canCreateMCPServer(currentCount: 10, hasPro: true))
  }

  @MainActor
  @Test("Midnight is the only free theme and the default")
  func freeThemes() {
    #expect(BYOKchatThemes.catalog.freeThemes.map(\.id) == ["midnight"])
    #expect(BYOKchatThemes.catalog.proThemes.count == 9)
    #expect(BYOKchatThemes.catalog.fallbackThemeID == "midnight")
    #expect(BYOKProAccess.freeThemeCount == 1)
  }

  @MainActor
  @Test("Theme defaults and saved Paper selections respect the new Free access")
  func midnightDefaultAndPaperAccess() {
    let suite = "BYOKProAccessTests.midnight.\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let store = UserDefaultsThemeStateStore(storageKey: "theme", suiteName: suite)
    let fresh = ThemeManager(
      catalog: BYOKchatThemes.catalog,
      stateStore: store,
      hasPro: false,
      previewBehavior: .disabled
    )
    #expect(fresh.effectiveTheme.id == "midnight")

    for hasPro in [false, true] {
      store.save(ThemeStoredState(
        selectedThemeID: "paper",
        lastKnownHasPro: hasPro,
        committedThemeID: "paper"
      ))
      let themes = ThemeManager(
        catalog: BYOKchatThemes.catalog,
        stateStore: store,
        hasPro: hasPro,
        previewBehavior: .disabled
      )
      #expect(themes.effectiveTheme.id == (hasPro ? "paper" : "midnight"))
    }
  }

  @Test("Feature comparison reflects analytics history entitlement")
  func comparisonRows() {
    #expect(BYOKProAccess.comparisonRows.count == 5)
    #expect(BYOKProAccess.comparisonRows.map(\.freeValue) == ["1", "1", "1", "Today", "Midnight"])
    #expect(BYOKProAccess.comparisonRows.map(\.proValue) == ["Unlimited", "Unlimited", "Unlimited", "All date ranges", "All themes"])
  }

  @MainActor
  @Test("Purchase manager provides all five features to Compare Plans and other Pro surfaces")
  func sharedPurchaseFeatureCatalog() {
    let manager = BYOKPurchaseStore().manager
    #expect(manager.features == BYOKProAccess.features)
    #expect(manager.features.map(\.id) == [
      "provider-accounts", "projects", "mcp-servers", "analytics-history", "themes",
    ])
    #expect(manager.features.map(\.freeValue) == ["1", "1", "1", "Today", "Midnight"])
    #expect(manager.features.map(\.proValue) == [
      "Unlimited", "Unlimited", "Unlimited", "All date ranges", "All themes",
    ])
    #expect(BYOKPurchaseStore.paywallConfiguration.features.isEmpty)
    #expect(BYOKProFeature.projects.upsellConfiguration.rows.isEmpty)
  }

  @Test("Free analytics always resolves to today even with a stale historical selection")
  func freeAnalyticsRange() {
    for range in UsageRange.allCases {
      #expect(range.accessible(hasPro: false) == .today)
      #expect(range.accessible(hasPro: true) == range)
      #expect(range.requiresPro == (range != .today))
    }
  }

  @Test("A stale All selection cannot access yesterday after entitlement expires")
  func analyticsDateBoundary() {
    let reference = Date(timeIntervalSince1970: 1_760_000_000)
    let freeRange = UsageRange.all.accessible(hasPro: false)
    #expect(freeRange.startDate(reference: reference) == Calendar.current.startOfDay(for: reference))
    #expect(UsageRange.all.accessible(hasPro: true).startDate(reference: reference) == nil)
  }

  #if DEBUG
  @MainActor
  @Test("AppFoundation 1.6.4 preserves simulated subscription and lifetime product types")
  func simulatedPurchasePlanTypes() {
    let manager = BYOKPurchaseStore.makeScreenshotPreviewManager()
    #expect(manager.features == BYOKProAccess.features)
    let products = manager.products
    #expect(products.count == 3)
    #expect(products.first(where: { $0.id == BYOKPurchaseStore.monthlyProductID })?.type == .autoRenewable)
    #expect(products.first(where: { $0.id == BYOKPurchaseStore.yearlyProductID })?.type == .autoRenewable)
    #expect(products.first(where: { $0.id == BYOKPurchaseStore.lifetimeProductID })?.type == .nonConsumable)

    // The same simulated catalog powers the iOS developer paywall and
    // the AppFoundation Screenshot Studio reviewer-paywall screenshot.
    let expectedPrices: [(id: String, price: Double, display: String)] = [
      (BYOKPurchaseStore.monthlyProductID, 6.99, "$6.99"),
      (BYOKPurchaseStore.yearlyProductID, 29.99, "$29.99"),
      (BYOKPurchaseStore.lifetimeProductID, 49.99, "$49.99"),
    ]
    for expected in expectedPrices {
      let product = products.first(where: { $0.id == expected.id })
      #expect(product?.price == expected.price)
      #expect(product?.displayPrice == expected.display)
    }
  }
  #endif
}
