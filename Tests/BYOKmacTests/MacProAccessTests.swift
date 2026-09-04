import Testing
@testable import BYOKmac

@MainActor
struct MacProAccessTests {
  @Test("Free theme access is limited to two themes")
  func themeLimit() {
    let themes = MacThemeID.allCases
    #expect(themes.count > MacProAccess.freeThemeCount)
    #expect(MacProAccess.canUseTheme(themes[0], hasPro: false))
    #expect(MacProAccess.canUseTheme(themes[1], hasPro: false))
    #expect(!MacProAccess.canUseTheme(themes[2], hasPro: false))
    #expect(MacProAccess.canUseTheme(themes[2], hasPro: true))
  }

  @Test("Free provider accounts stop at one")
  func providerAccountLimit() {
    #expect(MacProAccess.canCreateProviderAccount(currentCount: 0, hasPro: false))
    #expect(!MacProAccess.canCreateProviderAccount(currentCount: 1, hasPro: false))
    #expect(MacProAccess.canCreateProviderAccount(currentCount: 10, hasPro: true))
  }

  @Test("Free projects stop at one")
  func projectLimit() {
    #expect(MacProAccess.canCreateProject(currentCount: 0, hasPro: false))
    #expect(!MacProAccess.canCreateProject(currentCount: 1, hasPro: false))
    #expect(MacProAccess.canCreateProject(currentCount: 10, hasPro: true))
  }

  @Test("Free MCP servers stop at one")
  func mcpLimit() {
    #expect(MacProAccess.canCreateMCPServer(currentCount: 0, hasPro: false))
    #expect(!MacProAccess.canCreateMCPServer(currentCount: 1, hasPro: false))
    #expect(MacProAccess.canCreateMCPServer(currentCount: 10, hasPro: true))
  }

  @Test("Free Library has ten saved-file slots")
  func libraryLimit() {
    #expect(MacProAccess.canCreateLibraryItem(currentCount: 9, hasPro: false))
    #expect(!MacProAccess.canCreateLibraryItem(currentCount: 10, hasPro: false))
    #expect(MacProAccess.remainingLibraryCapacity(currentCount: 7, hasPro: false) == 3)
    #expect(MacProAccess.remainingLibraryCapacity(currentCount: 10, hasPro: false) == 0)
    #expect(MacProAccess.remainingLibraryCapacity(currentCount: 100, hasPro: true) == nil)
  }
}