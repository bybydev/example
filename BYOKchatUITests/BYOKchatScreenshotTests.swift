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

  /// Captures screens 01–15 inside a single seeded app launch so CI does not
  /// pay 15x cold-boot, seeding, and simulator teardown overhead.
  func test01ShowcaseScreenshots() throws {
    launchSeededApp(openPaywall: false)

    // 10_Home_NewChat
    capture("10_Home_NewChat")

    // 04_Model_Picker
    openModelPicker()
    assertExists(app.navigationBars["Model"], timeout: 8, context: "04_Model_Picker")
    capture("04_Model_Picker")
    dismissTopSheet()

    // 08_Sidebar
    openSidebar()
    capture("08_Sidebar")

    // 01_Chat_Hero (sidebar is already open)
    tapChatInOpenSidebar(title: "Ship a native iOS AI client", expectedContent: "Launch readiness")
    capture("01_Chat_Hero")

    // 13_Reasoning_Sheet
    let reasoningButton = app.buttons["Reasoning"].firstMatch
    ensureElementVisible(reasoningButton, scrollDownFirst: false)
    assertExists(reasoningButton, timeout: 6, context: "13_Reasoning_Sheet button")
    reasoningButton.tap()
    assertExists(app.navigationBars["Reasoning"], timeout: 8, context: "13_Reasoning_Sheet")
    capture("13_Reasoning_Sheet")
    dismissTopSheet()

    // 14_Message_Info
    let moreButton = app.buttons["More"].firstMatch
    ensureElementVisible(moreButton, scrollDownFirst: true)
    assertExists(moreButton, timeout: 6, context: "14_Message_Info More button")
    moreButton.tap()
    let infoButton = app.buttons["Message Info"]
    assertExists(infoButton, timeout: 6, context: "14_Message_Info menu item")
    infoButton.tap()
    assertExists(app.navigationBars["Message Info"], timeout: 8, context: "14_Message_Info")
    assertExists(app.staticTexts["Usage"], timeout: 6, context: "14_Message_Info Usage")
    capture("14_Message_Info")
    dismissTopSheet()

    // 12_Chat_Tools
    let moreOptions = app.buttons["More options"]
    assertExists(moreOptions, timeout: 6, context: "12_Chat_Tools More options")
    moreOptions.tap()
    let toolsButton = app.buttons["Tools"]
    assertExists(toolsButton, timeout: 6, context: "12_Chat_Tools menu item")
    toolsButton.tap()
    assertExists(app.navigationBars["Tools"], timeout: 8, context: "12_Chat_Tools")
    capture("12_Chat_Tools")
    dismissTopSheet()

    // 02_Chat_RichRender
    openSidebar()
    tapChatInOpenSidebar(title: "Sync architecture & cost model", expectedContent: "Direct request flow")
    sleep(1)
    capture("02_Chat_RichRender")

    // 03_Providers
    openSidebar()
    tapSidebarDestination("AI Providers")
    assertExists(app.navigationBars["AI Providers"], timeout: 8, context: "03_Providers")
    assertExists(app.staticTexts["Personal"], timeout: 6, context: "03_Providers Personal")
    capture("03_Providers")

    // 05_MCP_Servers
    openSidebar()
    tapSidebarDestination("MCP Servers")
    assertExists(app.navigationBars["MCP Servers"], timeout: 8, context: "05_MCP_Servers")
    assertExists(app.staticTexts["GitHub"], timeout: 6, context: "05_MCP_Servers GitHub")
    capture("05_MCP_Servers")

    // 11_Projects_List
    openSidebar()
    tapSidebarDestination("Projects")
    let launchProject = app.staticTexts["Product Launch"]
    assertExists(launchProject, timeout: 8, context: "11_Projects_List Product Launch")
    assertExists(app.staticTexts["Core Architecture"], timeout: 4, context: "11_Projects_List Core Architecture")
    capture("11_Projects_List")

    // 06_Project_Detail
    launchProject.tap()
    XCTAssertTrue(
      app.staticTexts["Product Launch"].waitForExistence(timeout: 8)
        || app.navigationBars["Product Launch"].waitForExistence(timeout: 4),
      "06_Project_Detail failed. Visible screen: \(visibleScreenSummary())"
    )
    capture("06_Project_Detail")
    navigateBackIfNeeded()

    // 07_Analytics
    openSidebar()
    tapSidebarDestination("Analytics")
    assertExists(app.navigationBars["Analytics"], timeout: 8, context: "07_Analytics")
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
    assertExists(app.staticTexts["Spend"], timeout: 8, context: "07_Analytics Spend")
    sleep(1)
    capture("07_Analytics")

    // 09_Library
    openSidebar()
    tapSidebarDestination("Library")
    assertExists(app.staticTexts["latency-benchmark.png"], timeout: 8, context: "09_Library")
    sleep(1)
    capture("09_Library")

    // 15_Settings_Themes
    openSidebar()
    let settings = app.buttons["Settings"]
    assertExists(settings, timeout: 6, context: "15_Settings_Themes button")
    settings.tap()
    assertExists(app.navigationBars["Settings"], timeout: 8, context: "15_Settings_Themes")
    assertExists(app.staticTexts["Appearance"], timeout: 6, context: "15_Settings_Themes Appearance")
    capture("15_Settings_Themes")
  }

  /// Launches directly into the full Paywall sheet while keeping the selected theme.
  func test02PaywallScreenshot() throws {
    launchSeededApp(openPaywall: true)
    assertExists(app.staticTexts["Upgrade to BYOK Pro"], timeout: 15, context: "16_Paywall")
    capture("16_Paywall")
  }

  // MARK: - Helpers

  private func launchSeededApp(openPaywall: Bool) {
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
      assertExists(app.staticTexts["How can I help?"], timeout: 15, context: "waitForHome")
    }
  }

  private func openSidebar() {
    let sidebar = app.buttons["Open sidebar"]
    assertExists(sidebar, timeout: 8, context: "Open sidebar")
    sidebar.tap()
    assertExists(app.buttons["AI Providers"], timeout: 6, context: "Sidebar AI Providers")
    assertExists(app.buttons["Ship a native iOS AI client"], timeout: 6, context: "Sidebar hero chat")
  }

  private func tapSidebarDestination(_ title: String) {
    let button = app.buttons[title]
    if !button.isHittable {
      app.scrollViews.firstMatch.swipeUp()
    }
    assertExists(button, timeout: 6, context: "Sidebar destination \(title)")
    button.tap()
  }

  private func tapChatInOpenSidebar(title: String, expectedContent: String) {
    let conversation = app.buttons[title]
    if !conversation.isHittable {
      app.scrollViews.firstMatch.swipeUp()
    }
    assertExists(conversation, timeout: 6, context: "Sidebar chat \(title)")
    conversation.tap()

    let heading = app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS[c] %@", expectedContent)
    ).firstMatch
    assertExists(heading, timeout: 10, context: "Chat content \(expectedContent)")
  }

  private func openModelPicker() {
    let messageField = app.textViews["Message"].exists
      ? app.textViews["Message"]
      : app.textFields["Message"]
    assertExists(messageField, timeout: 6, context: "Message composer field")
    messageField.tap()

    let targetButton = app.buttons["Model and reasoning"]
    assertExists(targetButton, timeout: 6, context: "Model and reasoning button")
    targetButton.tap()
  }

  private func dismissTopSheet() {
    let navBar = app.navigationBars.firstMatch
    for label in ["Done", "Close", "Cancel"] {
      let navButton = navBar.buttons[label]
      if navButton.exists && navButton.isHittable {
        navButton.tap()
        usleep(250_000)
        return
      }
      let button = app.buttons[label].firstMatch
      if button.exists && button.isHittable {
        button.tap()
        usleep(250_000)
        return
      }
    }
    app.swipeDown()
    usleep(250_000)
  }

  private func navigateBackIfNeeded() {
    let back = app.navigationBars.buttons.element(boundBy: 0)
    if back.exists && back.isHittable && !app.buttons["Open sidebar"].exists {
      back.tap()
      usleep(250_000)
    }
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

  private func assertExists(
    _ element: XCUIElement,
    timeout: TimeInterval,
    context: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertTrue(
      element.waitForExistence(timeout: timeout),
      "[\(context)] Expected element did not appear. Visible screen: \(visibleScreenSummary())",
      file: file,
      line: line
    )
  }

  private func visibleScreenSummary() -> String {
    let navTitles = app.navigationBars.allElementsBoundByIndex
      .map { $0.identifier }
      .filter { !$0.isEmpty }
    let texts = app.staticTexts.allElementsBoundByIndex
      .prefix(12)
      .map { $0.label }
      .filter { !$0.isEmpty }
    return "navBars=\(navTitles), staticTexts=\(texts)"
  }

  private func capture(_ name: String) {
    usleep(300_000)
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
