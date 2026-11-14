#if DEBUG
import AppFoundation
import Observation
import SwiftUI

@MainActor
@Observable
final class InkribeScreenshotStudioSettings {
    var themeID = FoundationThemes.sunset.id
    var backgroundStyle = ScreenshotBackgroundStyle.spotlight
    var backgroundIntensity = 0.9

    var theme: AppTheme {
        InkribeThemes.catalog.theme(id: themeID) ?? FoundationThemes.sunset
    }

    var colorScheme: ColorScheme {
        theme.appearance.preferredColorScheme.colorScheme ?? .dark
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
                    ? "AppFoundation paywall" : "Static app screen")
            }
        } appConfigurationControls: { _ in
            InkribeScreenshotAppearanceControls(settings: settings)
        }
        .scrollContentBackground(.hidden)
        .background(settings.theme.backgroundColor)
        .environment(\.colorScheme, settings.colorScheme)
        .foregroundStyle(settings.theme.primaryForegroundColor)
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
                    .environment(\.colorScheme, settings.colorScheme)
                    .dynamicTypeSize(.large)
                }
            }
            ScreenshotDefinition(id: "pro", title: "Inkribe Pro", filename: "Inkribe Pro") {
                InkribeScreenshotPaywall(theme: settings.theme)
                    .environment(\.appFoundationTheme, settings.theme)
                    .environment(\.colorScheme, settings.colorScheme)
                    .dynamicTypeSize(.large)
            }
        }
    }
}

@MainActor
private struct InkribeScreenshotAppearanceControls: View {
    @Bindable var settings: InkribeScreenshotStudioSettings

    var body: some View {
        Section("Campaign") {
            Picker("Theme", selection: $settings.themeID) {
                ForEach(InkribeThemes.catalog.themes) { theme in
                    Label(theme.title, systemImage: theme.symbolName).tag(theme.id)
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
