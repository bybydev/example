import XCTest

final class BYOKchatScreenshotTests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = [
      "UI_TEST_SCREENSHOTS",
      "-AppleLanguages", "(en)",
      "-AppleLocale", "en_US",
    ]
    app.launch()
    waitForHome()
  }

  override func tearDownWithError() throws {
    app.terminate()
  }

  func test01Home() throws {
    capture("01_Home")
  }

  func test02Sidebar() throws {
    openSidebar()
    capture("02_Sidebar")
  }

  func test03Chat() throws {
    openSidebar()
    let conversation = app.buttons["Ship a polished iOS launch"]
    XCTAssertTrue(conversation.waitForExistence(timeout: 5))
    conversation.tap()

    let heading = app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS[c] %@", "Launch readiness")
    ).firstMatch
    XCTAssertTrue(heading.waitForExistence(timeout: 8))
    capture("03_Chat")
  }

  func test04Projects() throws {
    openSidebar()
    let projects = app.buttons["Projects"]
    XCTAssertTrue(projects.waitForExistence(timeout: 5))
    projects.tap()

    XCTAssertTrue(app.staticTexts["BYOK Launch"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.staticTexts["Model Research"].exists)
    capture("04_Projects")
  }

  func test05Providers() throws {
    openSettings()

    let providers = app.staticTexts["Providers & Accounts"]
    XCTAssertTrue(providers.waitForExistence(timeout: 5))
    providers.tap()

    XCTAssertTrue(app.navigationBars["Providers"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.staticTexts["Personal"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Research"].exists)
    capture("05_Providers")
  }

  func test06MCPServers() throws {
    openSettings()

    let mcpServers = app.staticTexts["MCP Servers"]
    XCTAssertTrue(mcpServers.waitForExistence(timeout: 5))
    mcpServers.tap()

    XCTAssertTrue(app.navigationBars["MCP Servers"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.staticTexts["GitHub"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Web Search"].exists)
    capture("06_MCP")
  }

  func test07Themes() throws {
    openSettings()

    XCTAssertTrue(app.staticTexts["Appearance"].waitForExistence(timeout: 5))
    let paper = app.staticTexts["Paper"]
    let midnight = app.staticTexts["Midnight"]
    XCTAssertTrue(paper.waitForExistence(timeout: 5) || midnight.waitForExistence(timeout: 5))
    capture("07_Themes")
  }

  func test08Paywall() throws {
    openSidebar()

    let upgrade = app.buttons["Upgrade to Pro"]
    XCTAssertTrue(upgrade.waitForExistence(timeout: 5))
    upgrade.tap()

    XCTAssertTrue(app.staticTexts["Upgrade to BYOK Pro"].waitForExistence(timeout: 8))
    capture("08_Paywall")
  }

  private func waitForHome() {
    XCTAssertTrue(app.staticTexts["How can I help?"].waitForExistence(timeout: 12))

    let modelTarget = app.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS[c] %@", "Claude Sonnet 5")
    ).firstMatch
    XCTAssertTrue(modelTarget.waitForExistence(timeout: 10))
  }

  private func openSidebar() {
    let sidebar = app.buttons["Open sidebar"]
    XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
    sidebar.tap()
    XCTAssertTrue(app.buttons["Projects"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Ship a polished iOS launch"].waitForExistence(timeout: 5))
  }

  private func openSettings() {
    openSidebar()
    let settings = app.buttons["Settings"]
    XCTAssertTrue(settings.waitForExistence(timeout: 5))
    settings.tap()
    XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 8))
  }

  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
