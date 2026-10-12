#if DEBUG
import AppFoundation
import Foundation
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class BYOKScreenshotStudioSettings {
  var themeID = BYOKchatThemes.midnight.id
  var backgroundStyle: ScreenshotBackgroundStyle = .aurora
  var backgroundIntensity = 1.0

  var theme: AppTheme {
    BYOKchatThemes.catalog.theme(id: themeID) ?? BYOKchatThemes.catalog.fallbackTheme
  }

  var backgroundColors: [Color] {
    [
      theme.backgroundColor,
      theme.elevatedSurfaceColor,
      theme.accentColor,
    ]
  }
}

@MainActor
struct BYOKScreenshotStudioView: View {
  @State private var settings = BYOKScreenshotStudioSettings()

  var body: some View {
    ScreenshotStudio(
      catalog: makeCatalog()
    ) { context in
      BYOKSelectedScreenshotControls(context: context)
    } appConfigurationControls: { context in
      BYOKScreenshotConfigurationControls(settings: settings, context: context)
    }
    .scrollContentBackground(.hidden)
    .background(
      ScreenshotBackground(
        style: settings.backgroundStyle,
        colors: settings.backgroundColors,
        intensity: settings.backgroundIntensity
      )
    )
    .tint(settings.theme.accentColor)
  }

  // Internal for catalogue regression tests; Screenshot Studio remains Debug-only.
  func makeCatalog() -> ScreenshotCatalog {
    ScreenshotCatalog(
      appName: "BYOKchat",
      presets: [.iPhone69Portrait, .iPhone65Portrait],
      locales: [.english],
      defaultPresetID: ScreenshotDevicePreset.iPhone69Portrait.id,
      defaultLocaleID: ScreenshotStudioLocale.english.id,
      defaultScreenshotID: "chat"
    ) {
      ScreenshotDefinition(
        id: "chat",
        title: "Native AI Chat",
        filename: "Chat with any model"
      ) {
        lockedAppearance {
          BYOKScreenshotChatScene(settings: settings)
        }
      }

      ScreenshotDefinition(
        id: "providers",
        title: "BYOK Providers",
        filename: "Bring your own API keys"
      ) {
        lockedAppearance {
          BYOKScreenshotProvidersScene(settings: settings)
        }
      }

      ScreenshotDefinition(
        id: "mcp",
        title: "MCP Tools",
        filename: "Give every chat powerful tools"
      ) {
        lockedAppearance {
          BYOKScreenshotMCPScene(settings: settings)
        }
      }

      ScreenshotDefinition(
        id: "projects",
        title: "Projects",
        filename: "Keep every workspace organized"
      ) {
        lockedAppearance {
          BYOKScreenshotProjectsScene(settings: settings)
        }
      }

      ScreenshotDefinition(
        id: "analytics",
        title: "Usage Analytics",
        filename: "Know what every request costs"
      ) {
        lockedAppearance {
          BYOKScreenshotAnalyticsScene(settings: settings)
        }
      }

      ScreenshotDefinition(
        id: "pro",
        title: "BYOK Pro",
        filename: "Unlock BYOK Pro"
      ) {
        // Do not allocate StoreKit/preview purchase state when the Studio opens.
        // AppFoundation's real paywall is constructed only if this scene is selected.
        BYOKScreenshotPaywallScene(theme: settings.theme)
      }
    }
  }

  private func lockedAppearance<Content: View>(
    @ViewBuilder content: () -> Content
  ) -> some View {
    content()
      .environment(\.appFoundationTheme, settings.theme)
      .environment(
        \.colorScheme,
        settings.theme.appearance.preferredColorScheme == .light ? .light : .dark
      )
  }
}

/// Screenshot-only adapter for AppFoundation's production paywall.
///
/// The five product scenes are pure fixture views with no app environment,
/// navigation, mutations, or runtime model. The paywall is the sole explicit
/// exception: AppFoundation needs an isolated simulated PurchaseManager.
/// Keeping it in this child means opening Studio never creates that manager.
@MainActor
private struct BYOKScreenshotPaywallScene: View {
  let theme: AppTheme
  @State private var purchases = BYOKPurchaseStore.makeScreenshotPreviewManager()

  var body: some View {
    ProPaywallScreenshotTemplate(
      purchases: purchases,
      configuration: BYOKPurchaseStore.paywallConfiguration,
      selectedProductID: BYOKPurchaseStore.yearlyProductID
    )
    .environment(\.appFoundationTheme, theme)
    .environment(
      \.colorScheme,
      theme.appearance.preferredColorScheme == .light ? .light : .dark
    )
  }
}

@MainActor
private struct BYOKSelectedScreenshotControls: View {
  let context: ScreenshotStudioControlContext

  var body: some View {
    Section("Screenshot Details") {
      LabeledContent("Scene", value: context.selectedScreenshotTitle)
      LabeledContent(
        "Composition",
        value: context.selectedScreenshotID == "pro"
          ? "Full-canvas real paywall"
          : "AppFoundation responsive template"
      )
      LabeledContent("Device frame", value: "None")
    }
  }
}

@MainActor
private struct BYOKScreenshotConfigurationControls: View {
  @Bindable var settings: BYOKScreenshotStudioSettings
  let context: ScreenshotStudioControlContext

  var body: some View {
    Section("BYOK Appearance") {
      Picker("Theme", selection: $settings.themeID) {
        ForEach(BYOKchatThemes.catalog.themes) { theme in
          Label(theme.title, systemImage: theme.symbolName).tag(theme.id)
        }
      }

      Picker("Background", selection: $settings.backgroundStyle) {
        ForEach(ScreenshotBackgroundStyle.allCases) { style in
          Text(style.title).tag(style)
        }
      }

      LabeledContent(
        "Background intensity",
        value: settings.backgroundIntensity.formatted(.number.precision(.fractionLength(2)))
      )
      Slider(value: $settings.backgroundIntensity, in: 0.35...1.60, step: 0.05)
    }

    Section("Fixture") {
      if context.selectedScreenshotID == "pro" {
        LabeledContent("Paywall", value: "ProPaywallView")
        LabeledContent("Products", value: "Monthly · Yearly · Lifetime")
        LabeledContent("Selected plan", value: "Yearly")
      } else {
        LabeledContent("Source", value: "Screenshot-only deterministic data")
        LabeledContent("Network access", value: "None")
        LabeledContent("User data", value: "Never read")
      }
      LabeledContent("Selected output", value: context.preset.title)
    }
  }
}

enum BYOKScreenshotComposition {
  case hero
  case focus
  case splitLeading
  case splitTrailing
}

struct BYOKScreenshotCanvas<Feature: View>: View {
  let settings: BYOKScreenshotStudioSettings
  let eyebrow: String
  let title: String
  let subtitle: String
  let symbol: String
  let composition: BYOKScreenshotComposition
  private let feature: Feature

  init(
    settings: BYOKScreenshotStudioSettings,
    eyebrow: String,
    title: String,
    subtitle: String,
    symbol: String,
    composition: BYOKScreenshotComposition = .hero,
    @ViewBuilder feature: () -> Feature
  ) {
    self.settings = settings
    self.eyebrow = eyebrow
    self.title = title
    self.subtitle = subtitle
    self.symbol = symbol
    self.composition = composition
    self.feature = feature()
  }

  // AppFoundation owns margins, visual scale, and responsive export geometry.
  // Reuse its different compositions so the five shots form a campaign,
  // rather than repeating one identical hero layout five times.
  @ViewBuilder
  var body: some View {
    switch composition {
    case .hero:
      HeroScreenshotTemplate {
        background
      } brand: {
        brand
      } message: {
        message
      } visual: {
        visual
      } footer: {
        footer
      }
    case .focus:
      DeviceFocusScreenshotTemplate {
        background
      } brand: {
        brand
      } message: {
        message
      } visual: {
        visual
      } footer: {
        footer
      }
    case .splitLeading:
      SplitFeatureScreenshotTemplate(side: .leading) {
        background
      } brand: {
        brand
      } message: {
        message
      } visual: {
        visual
      } footer: {
        footer
      }
    case .splitTrailing:
      SplitFeatureScreenshotTemplate(side: .trailing) {
        background
      } brand: {
        brand
      } message: {
        message
      } visual: {
        visual
      } footer: {
        footer
      }
    }
  }

  private var background: some View {
    ScreenshotBackground(
      style: settings.backgroundStyle,
      colors: settings.backgroundColors,
      intensity: settings.backgroundIntensity
    ) {
      BYOKStudioBackgroundDecoration(theme: settings.theme)
    }
  }

  // App Store captions communicate the product; don't repeat the app name
  // above every headline. Retain the approved sculpted Midnight icon.
  private var brand: some View {
    BYOKScreenshotBrandIcon(theme: settings.theme)
      .frame(width: 32, height: 32)
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private var message: some View {
    ScreenshotTemplateMessage(
      title: title,
      subtitle: subtitle,
      foreground: settings.theme.primaryForegroundColor,
      secondaryForeground: settings.theme.secondaryForegroundColor,
      alignment: .leading
    )
  }

  private var visual: some View {
    feature
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      .clipped()
  }

  private var footer: some View {
    ScreenshotTemplateFooter(
      eyebrow,
      systemImage: symbol,
      tint: settings.theme.accentColor,
      foreground: settings.theme.primaryForegroundColor.opacity(0.86)
    )
  }
}

private struct BYOKScreenshotBrandIcon: View {
  let theme: AppTheme

  var body: some View {
    Group {
      if let image = BYOKScreenshotAppIconResource.image {
        Image(uiImage: image)
          .resizable()
          .scaledToFit()
      } else {
        ZStack {
          RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(theme.accentColor)
          Text("BYOK")
            .font(.system(size: 11, weight: .black, design: .rounded))
            .foregroundStyle(theme.backgroundColor)
        }
      }
    }
  }
}

@MainActor
private enum BYOKScreenshotAppIconResource {
  static let image: UIImage? = {
    if let image = UIImage(named: "AppIcon") {
      return image
    }

    for dictionaryKey in ["CFBundleIcons", "CFBundleIcons~ipad"] {
      guard
        let icons = Bundle.main.object(forInfoDictionaryKey: dictionaryKey) as? [String: Any],
        let primary = icons["CFBundlePrimaryIcon"] as? [String: Any]
      else {
        continue
      }

      if let filenames = primary["CFBundleIconFiles"] as? [String] {
        for filename in filenames.reversed() {
          if let image = UIImage(named: filename) {
            return image
          }
          if
            let path = Bundle.main.path(forResource: filename, ofType: nil),
            let image = UIImage(contentsOfFile: path)
          {
            return image
          }
        }
      }

      if
        let iconName = primary["CFBundleIconName"] as? String,
        let image = UIImage(named: iconName)
      {
        return image
      }
    }

    if
      let iconName = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String,
      let image = UIImage(named: iconName)
    {
      return image
    }

    let sourceIconURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Resources/AppIcon.icon/Assets/AppIcon-1024.png")
    return UIImage(contentsOfFile: sourceIconURL.path)
  }()
}

private struct BYOKStudioBackgroundDecoration: View {
  let theme: AppTheme

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        Circle()
          .fill(theme.accentColor.opacity(0.09))
          .frame(width: proxy.size.width * 0.74)
          .blur(radius: 30)
          .offset(x: proxy.size.width * 0.40, y: -proxy.size.height * 0.20)

        Image(systemName: "bubble.left.and.bubble.right.fill")
          .font(.system(size: 220, weight: .black))
          .foregroundStyle(theme.primaryForegroundColor.opacity(0.025))
          .rotationEffect(.degrees(-12))
          .offset(x: -proxy.size.width * 0.36, y: proxy.size.height * 0.38)
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}
#endif
