import AppFoundation
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

  @Test("Feature comparison matches the product table")
  func comparisonRows() {
    #expect(BYOKProAccess.comparisonRows.count == 5)
    #expect(BYOKProAccess.comparisonRows.map(\.freeValue) == ["2", "1", "1", "1", "Basic"])
    #expect(BYOKProAccess.comparisonRows.map(\.proValue) == ["All themes", "Unlimited", "Unlimited", "Unlimited", "Advanced"])
  }
}
