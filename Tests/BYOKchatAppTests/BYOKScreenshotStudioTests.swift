#if DEBUG
import AppFoundation
import Testing

@testable import BYOKchat

@Suite("BYOKchat Screenshot Studio")
struct BYOKScreenshotStudioTests {
  @MainActor
  @Test("Five product shots and one reviewer paywall have stable export order")
  func sixShotCatalog() {
    let catalog = BYOKScreenshotStudioView().makeCatalog()
    let ids = catalog.screenshots.map(\.id)

    #expect(ids == ["chat", "providers", "mcp", "projects", "analytics", "pro"])
    #expect(Set(ids).count == 6)
    #expect(Set(catalog.screenshots.map(\.filename)).count == 6)
    #expect(catalog.defaultScreenshotID == "chat")
    #expect(catalog.locales.map(\.id) == [ScreenshotStudioLocale.english.id])
  }

  @MainActor
  @Test("Studio exports both App Store iPhone sizes for all six scenes")
  func appStoreOutputPresets() {
    let catalog = BYOKScreenshotStudioView().makeCatalog()
    #expect(catalog.presets.map(\.id) == [
      ScreenshotDevicePreset.iPhone69Portrait.id,
      ScreenshotDevicePreset.iPhone65Portrait.id
    ])
    #expect(catalog.defaultPresetID == ScreenshotDevicePreset.iPhone69Portrait.id)

    for preset in catalog.presets {
      #expect(catalog.screenshots.allSatisfy { $0.supports(preset) })
    }

    #expect(ScreenshotDevicePreset.iPhone69Portrait.pixelSize.width == 1320)
    #expect(ScreenshotDevicePreset.iPhone69Portrait.pixelSize.height == 2868)
    #expect(ScreenshotDevicePreset.iPhone65Portrait.pixelSize.width == 1242)
    #expect(ScreenshotDevicePreset.iPhone65Portrait.pixelSize.height == 2688)
  }

  @MainActor
  @Test("Opening the default Chat scene can render without a live app model")
  func defaultChatPreviewRenders() throws {
    let catalog = BYOKScreenshotStudioView().makeCatalog()
    let chat = try #require(catalog.screenshots.first { $0.id == "chat" })
    let preset = ScreenshotDevicePreset.iPhone65Portrait
    let exported = try ScreenshotStudioEngine().render(
      definition: chat,
      preset: preset,
      colorScheme: .dark
    )
    defer { try? FileManager.default.removeItem(at: exported.url) }
    #expect(exported.screenshotID == "chat")
    #expect(exported.pixelSize == preset.pixelSize)
    #expect(FileManager.default.fileExists(atPath: exported.url.path))
  }

  @MainActor
  @Test("Studio starts on Midnight without requiring an existing app theme")
  func independentDefaultTheme() {
    let settings = BYOKScreenshotStudioSettings()
    #expect(settings.themeID == BYOKchatThemes.midnight.id)
    #expect(settings.theme.id == BYOKchatThemes.midnight.id)
  }
}
#endif
