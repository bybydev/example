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
  @Test("Only Paper and Midnight are free themes")
  func freeThemes() {
    #expect(BYOKchatThemes.catalog.freeThemes.map(\.id) == ["paper", "midnight"])
    #expect(BYOKchatThemes.catalog.proThemes.count == 8)
  }

  @Test("Feature comparison reflects analytics history entitlement")
  func comparisonRows() {
    #expect(BYOKProAccess.comparisonRows.count == 6)
    #expect(BYOKProAccess.comparisonRows.map(\.freeValue) == ["2", "1", "1", "1", "10", "Today"])
    #expect(BYOKProAccess.comparisonRows.map(\.proValue) == ["All themes", "Unlimited", "Unlimited", "Unlimited", "Unlimited", "All date ranges"])
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
    let products = BYOKPurchaseStore.makeScreenshotPreviewManager().products
    #expect(products.count == 3)
    #expect(products.first(where: { $0.id == BYOKPurchaseStore.monthlyProductID })?.type == .autoRenewable)
    #expect(products.first(where: { $0.id == BYOKPurchaseStore.yearlyProductID })?.type == .autoRenewable)
    #expect(products.first(where: { $0.id == BYOKPurchaseStore.lifetimeProductID })?.type == .nonConsumable)
  }
  #endif
}
