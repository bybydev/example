#if DEBUG
import AppFoundation
import Observation
import SwiftUI

@MainActor
@Observable
final class InkribeScreenshotStudioSettings {
    var appearance = InkribeScreenshotAppearance.light
    var backgroundStyle = ScreenshotBackgroundStyle.spotlight
    var backgroundIntensity = 1.0

    var theme: AppTheme { appearance.theme }
}

enum InkribeScreenshotAppearance: String, CaseIterable, Identifiable {
    case light, graphite
    var id: Self { self }
    var title: String { self == .light ? "Light" : "Graphite" }

    var theme: AppTheme {
        let light = self == .light
        return AppTheme(
            id: "inkribe-screenshot-" + rawValue,
            title: title,
            symbolName: light ? "sun.max" : "moon.fill",
            access: .free,
            appearance: ThemeAppearance(
                background: ThemeColor(hex: light ? 0xEDF5F8 : 0x12191F),
                gradientStart: ThemeColor(hex: light ? 0xC4E9F8 : 0x173E51),
                gradientEnd: ThemeColor(hex: light ? 0xEDF5F8 : 0x12191F),
                accent: ThemeColor(hex: 0x279ED2),
                primaryForeground: ThemeColor(hex: light ? 0x12212B : 0xF6F8FA),
                secondaryForeground: ThemeColor(hex: light ? 0x4C6575 : 0xAEBDC8),
                surface: ThemeColor(hex: light ? 0xFFFFFF : 0x222C35),
                elevatedSurface: ThemeColor(hex: light ? 0xEDF2F5 : 0x2C3843),
                border: ThemeColor(hex: light ? 0xDCE5EB : 0x3A4651),
                shadow: .black.withAlpha(0.12),
                preferredColorScheme: light ? .light : .dark
            )
        )
    }
}

@MainActor
struct InkribeScreenshotStudioView: View {
    @State private var settings = InkribeScreenshotStudioSettings()

    var body: some View {
        ScreenshotStudio(catalog: makeCatalog()) { context in
            Section("Screenshot") {
                LabeledContent("Scene", value: context.selectedScreenshotTitle)
                LabeledContent("Content", value: context.selectedScreenshotID == "pro"
                    ? "AppFoundation paywall" : "Static example project")
            }
        } appConfigurationControls: { _ in
            InkribeScreenshotAppearanceControls(settings: settings)
        }
        .scrollContentBackground(.hidden)
        .background(settings.theme.backgroundColor)
        .tint(settings.theme.accentColor)
        .accessibilityIdentifier("screenshots.studio")
    }

    private func makeCatalog() -> ScreenshotCatalog {
        ScreenshotCatalog(
            appName: "Inkribe",
            presets: [.iPhone69Portrait, .iPhone65Portrait],
            locales: [.english],
            defaultPresetID: ScreenshotDevicePreset.iPhone69Portrait.id,
            defaultLocaleID: ScreenshotStudioLocale.english.id,
            defaultScreenshotID: InkribeScreenshotFeature.captioning.rawValue
        ) {
            for feature in InkribeScreenshotFeature.allCases {
                ScreenshotDefinition(id: feature.rawValue, title: feature.title, filename: feature.title) {
                    InkribeScreenshotScene(
                        feature: feature,
                        theme: settings.theme,
                        backgroundStyle: settings.backgroundStyle,
                        backgroundIntensity: settings.backgroundIntensity
                    )
                    .environment(\.appFoundationTheme, settings.theme)
                    .environment(\.colorScheme, settings.appearance == .light ? .light : .dark)
                    .dynamicTypeSize(.large)
                }
            }
            ScreenshotDefinition(id: "pro", title: "Inkribe Pro", filename: "Inkribe Pro") {
                InkribeScreenshotPaywall(theme: settings.theme)
                    .environment(\.appFoundationTheme, settings.theme)
                    .environment(\.colorScheme, settings.appearance == .light ? .light : .dark)
                    .dynamicTypeSize(.large)
            }
        }
    }
}

@MainActor
private struct InkribeScreenshotAppearanceControls: View {
    @Bindable var settings: InkribeScreenshotStudioSettings

    var body: some View {
        Section("Campaign Appearance") {
            Picker("Appearance", selection: $settings.appearance) {
                ForEach(InkribeScreenshotAppearance.allCases) { appearance in
                    Text(appearance.title).tag(appearance)
                }
            }
            Picker("Background", selection: $settings.backgroundStyle) {
                ForEach(ScreenshotBackgroundStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            LabeledContent("Background intensity",
                value: settings.backgroundIntensity.formatted(.number.precision(.fractionLength(2))))
            Slider(value: $settings.backgroundIntensity, in: 0.35...1.60, step: 0.05)
        }
    }
}

/// The real AF paywall gets its own nonpersistent, synchronously populated manager.
/// This child is constructed only when its ScreenshotDefinition is rendered.
@MainActor
private struct InkribeScreenshotPaywall: View {
    let theme: AppTheme
    @State private var purchases = PurchaseManager.screenshotPreview(
        configuration: Commerce.configuration,
        products: Commerce.simulatedProducts
    )

    var body: some View {
        ProPaywallScreenshotTemplate(
            purchases: purchases,
            configuration: Commerce.paywall,
            selectedProductID: Commerce.yearlyID
        )
        .tint(theme.accentColor)
    }
}
#endif
