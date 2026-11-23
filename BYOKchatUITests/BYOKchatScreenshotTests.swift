import UIKit
import XCTest

final class BYOKchatScreenshotTests: XCTestCase {
  private var app: XCUIApplication!

  private var themeID: String {
    let raw = ProcessInfo.processInfo.environment["SCREENSHOT_THEME"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    return (raw?.isEmpty == false ? raw : nil) ?? "midnight"
  }

  private var presetID: String {
    let raw = ProcessInfo.processInfo.environment["SCREENSHOT_PRESET"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return (raw?.isEmpty == false ? raw : nil) ?? "showcase"
  }

  private var targetOrientation: UIDeviceOrientation {
    let raw = ProcessInfo.processInfo.environment["SCREENSHOT_ORIENTATION"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    return raw == "landscape" ? .landscapeLeft : .portrait
  }

  override func setUpWithError() throws {
    continueAfterFailure = false
    app = XCUIApplication()
  }

  override func tearDownWithError() throws {
    app?.terminate()
  }

  // MARK: - Tier 1: Core App Store Screens

  func test01ChatHero() throws {
    launchSeededApp()
    openChat(title: "Ship a native iOS AI client", expectedContent: "Launch readiness")
    capture("01_Chat_Hero")
  }

  func test02ChatRichRender() throws {
    launchSeededApp()
    openChat(title: "Sync architecture & cost model", expectedContent: "Direct request flow")
    // Allow Mermaid & LaTeX renderers a brief settle pass before capture.
    sleep(1)
    capture("02_Chat_RichRender")
  }

  func test03Providers() throws {
    launchSeededApp()
    openSidebar()
    tapSidebarDestination("AI Providers")
    XCTAssertTrue(app.navigationBars["AI Providers"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.staticTexts["Personal"].waitForExistence(timeout: 6))
    capture("03_Providers")
  }

  func test04ModelPicker() throws {
    launchSeededApp()
    openModelPicker()
    XCTAssertTrue(app.navigationBars["Model"].waitForExistence(timeout: 8))
    capture("04_Model_Picker")
  }

  func test05MCPServers() throws {
    launchSeededApp()
    openSidebar()
    tapSidebarDestination("MCP Servers")
    XCTAssertTrue(app.navigationBars["MCP Servers"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.staticTexts["GitHub"].waitForExistence(timeout: 6))
    capture("05_MCP_Servers")
  }

  func test06ProjectDetail() throws {
    launchSeededApp()
    openSidebar()
    tapSidebarDestination("Projects")
    let launchProject = app.staticTexts["Product Launch"]
    XCTAssertTrue(launchProject.waitForExistence(timeout: 8))
    launchProject.tap()
    XCTAssertTrue(
      app.staticTexts["Product Launch"].waitForExistence(timeout: 8)
        || app.navigationBars["Product Launch"].waitForExistence(timeout: 4)
    )
    capture("06_Project_Detail")
  }

  func test07Analytics() throws {
    launchSeededApp()
    openSidebar()
    tapSidebarDestination("Analytics")
    XCTAssertTrue(app.navigationBars["Analytics"].waitForExistence(timeout: 8))

    // Switch range from Today to 30D so multi-day telemetry and provider breakdown shine.
    let rangeMenu = app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Analytics date range")
    ).firstMatch
    if rangeMenu.waitForExistence(timeout: 5) {
      rangeMenu.tap()
      let thirtyDays = app.buttons["30D"]
      if thirtyDays.waitForExistence(timeout: 4) {
        thirtyDays.tap()
      }
    }
    XCTAssertTrue(app.staticTexts["Spend"].waitForExistence(timeout: 8))
    sleep(1)
    capture("07_Analytics")
  }

  func test08Sidebar() throws {
    launchSeededApp()
    openSidebar()
    capture("08_Sidebar")
  }

  func test09Library() throws {
    launchSeededApp()
    openSidebar()
    tapSidebarDestination("Library")
    XCTAssertTrue(app.staticTexts["latency-benchmark.png"].waitForExistence(timeout: 8))
    sleep(1)
    capture("09_Library")
  }

  // MARK: - Tier 2: Promo Video & Landing Page Cutaways

  func test10HomeNewChat() throws {
    launchSeededApp()
    capture("10_Home_NewChat")
  }

  func test11ProjectsList() throws {
    launchSeededApp()
    openSidebar()
    tapSidebarDestination("Projects")
    XCTAssertTrue(app.staticTexts["Product Launch"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.staticTexts["Core Architecture"].waitForExistence(timeout: 4))
    capture("11_Projects_List")
  }

  func test12ChatTools() throws {
    launchSeededApp()
    openChat(title: "Ship a native iOS AI client", expectedContent: "Launch readiness")
    let moreOptions = app.buttons["More options"]
    XCTAssertTrue(moreOptions.waitForExistence(timeout: 6))
    moreOptions.tap()

    let toolsButton = app.buttons["Tools"]
    XCTAssertTrue(toolsButton.waitForExistence(timeout: 6))
    toolsButton.tap()

    XCTAssertTrue(app.navigationBars["Tools"].waitForExistence(timeout: 8))
    capture("12_Chat_Tools")
  }

  func test13ReasoningSheet() throws {
    launchSeededApp()
    openChat(title: "Ship a native iOS AI client", expectedContent: "Launch readiness")

    let reasoningButton = app.buttons["Reasoning"].firstMatch
    ensureElementVisible(reasoningButton, scrollDownFirst: false)
    XCTAssertTrue(reasoningButton.waitForExistence(timeout: 6))
    reasoningButton.tap()

    XCTAssertTrue(app.navigationBars["Reasoning"].waitForExistence(timeout: 8))
    capture("13_Reasoning_Sheet")
  }

  func test14MessageInfo() throws {
    launchSeededApp()
    openChat(title: "Ship a native iOS AI client", expectedContent: "Launch readiness")

    let moreButton = app.buttons["More"].firstMatch
    ensureElementVisible(moreButton, scrollDownFirst: true)
    XCTAssertTrue(moreButton.waitForExistence(timeout: 6))
    moreButton.tap()

    let infoButton = app.buttons["Message Info"]
    XCTAssertTrue(infoButton.waitForExistence(timeout: 6))
    infoButton.tap()

    XCTAssertTrue(app.navigationBars["Message Info"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.staticTexts["Usage"].waitForExistence(timeout: 6))
    capture("14_Message_Info")
  }

  func test15SettingsThemes() throws {
    launchSeededApp()
    openSettings()
    XCTAssertTrue(app.staticTexts["Appearance"].waitForExistence(timeout: 6))
    capture("15_Settings_Themes")
  }

  func test16Paywall() throws {
    launchSeededApp(openPaywall: true)
    XCTAssertTrue(app.staticTexts["Upgrade to BYOK Pro"].waitForExistence(timeout: 12))
    capture("16_Paywall")
  }

  // MARK: - Helpers

  private func launchSeededApp(openPaywall: Bool = false) {
    XCUIDevice.shared.orientation = targetOrientation

    var arguments = [
      "-BYOKSeedPreset", presetID,
      "-BYOKSeedTheme", themeID,
      "-BYOKSeedPro", "true",
      "-BYOKDisableAnimations",
      "-AppleLanguages", "(en)",
      "-AppleLocale", "en_US",
    ]
    if openPaywall {
      arguments.append("-BYOKOpenPaywall")
    }

    app.launchArguments = arguments
    app.launch()

    if XCUIDevice.shared.orientation != targetOrientation {
      XCUIDevice.shared.orientation = targetOrientation
    }

    if !openPaywall {
      waitForHome()
    }
  }

  private func waitForHome() {
    XCTAssertTrue(app.staticTexts["How can I help?"].waitForExistence(timeout: 15))
  }

  private func openSidebar() {
    let sidebar = app.buttons["Open sidebar"]
    XCTAssertTrue(sidebar.waitForExistence(timeout: 8))
    sidebar.tap()
    XCTAssertTrue(app.buttons["AI Providers"].waitForExistence(timeout: 6))
    XCTAssertTrue(app.buttons["Ship a native iOS AI client"].waitForExistence(timeout: 6))
  }

  private func tapSidebarDestination(_ title: String) {
    let button = app.buttons[title]
    if !button.isHittable {
      app.scrollViews.firstMatch.swipeUp()
    }
    XCTAssertTrue(button.waitForExistence(timeout: 6))
    button.tap()
  }

  private func openChat(title: String, expectedContent: String) {
    openSidebar()
    let conversation = app.buttons[title]
    if !conversation.isHittable {
      app.scrollViews.firstMatch.swipeUp()
    }
    XCTAssertTrue(conversation.waitForExistence(timeout: 6))
    conversation.tap()

    let heading = app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS[c] %@", expectedContent)
    ).firstMatch
    XCTAssertTrue(heading.waitForExistence(timeout: 10))
  }

  private func openModelPicker() {
    let messageField = app.textViews["Message"].exists
      ? app.textViews["Message"]
      : app.textFields["Message"]
    XCTAssertTrue(messageField.waitForExistence(timeout: 6))
    messageField.tap()

    let targetButton = app.buttons["Model and reasoning"]
    XCTAssertTrue(targetButton.waitForExistence(timeout: 6))
    targetButton.tap()
  }

  private func openSettings() {
    openSidebar()
    let settings = app.buttons["Settings"]
    XCTAssertTrue(settings.waitForExistence(timeout: 6))
    settings.tap()
    XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 8))
  }

  private func ensureElementVisible(_ element: XCUIElement, scrollDownFirst: Bool) {
    guard !element.isHittable else { return }
    let container = app.collectionViews.firstMatch.exists
      ? app.collectionViews.firstMatch
      : app.tables.firstMatch
    guard container.exists else { return }

    for _ in 0..<4 {
      if element.exists && element.isHittable { return }
      if scrollDownFirst {
        container.swipeUp()
      } else {
        container.swipeDown()
      }
    }
    for _ in 0..<4 {
      if element.exists && element.isHittable { return }
      if scrollDownFirst {
        container.swipeDown()
      } else {
        container.swipeUp()
      }
    }
  }

  private func capture(_ name: String) {
    usleep(300_000)
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
