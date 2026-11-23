import Testing
@testable import BYOKchatProviderCore

struct BYOKProPolicyTests {
  @Test("Catalog is shared and yearly is preferred")
  func catalog() {
    #expect(BYOKProCatalog.productIDs == [
      "com.hoangbkit.byokchat.pro.monthly",
      "com.hoangbkit.byokchat.pro.yearly",
      "com.hoangbkit.byokchat.pro.lifetime",
    ])
    #expect(BYOKProCatalog.preferredProductID == BYOKProCatalog.yearlyProductID)
  }

  @Test("Free limits match BYOK Pro policy")
  func freeLimits() {
    #expect(BYOKProPolicy.freeThemeCount == 2)
    #expect(BYOKProPolicy.freeProviderAccountLimit == 1)
    #expect(BYOKProPolicy.freeProjectLimit == 1)
    #expect(BYOKProPolicy.freeMCPServerLimit == 1)
  }

  @Test("Creation becomes unlimited with Pro")
  func creationPolicy() {
    #expect(!BYOKProPolicy.canCreateProviderAccount(currentCount: 1, hasPro: false))
    #expect(!BYOKProPolicy.canCreateProject(currentCount: 1, hasPro: false))
    #expect(!BYOKProPolicy.canCreateMCPServer(currentCount: 1, hasPro: false))

    #expect(BYOKProPolicy.canCreateProviderAccount(currentCount: 100, hasPro: true))
    #expect(BYOKProPolicy.canCreateProject(currentCount: 100, hasPro: true))
    #expect(BYOKProPolicy.canCreateMCPServer(currentCount: 100, hasPro: true))
  }

  @Test("Full-text chat search requires Pro")
  func fullTextSearchPolicy() {
    #expect(!BYOKProPolicy.canUseFullTextSearch(hasPro: false))
    #expect(BYOKProPolicy.canUseFullTextSearch(hasPro: true))
  }
}
