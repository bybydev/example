#if DEBUG
import AppFoundation
import Observation
import SwiftUI

/// Deterministic, developer-only App Store compositions.
@MainActor
@Observable
final class ReadAloudScreenshotSettings {
    var themeID = ReadAloudThemeCatalog.dark.id
    var backgroundStyle: ScreenshotBackgroundStyle = .aurora
    var intensity = 1.0

    var theme: AppTheme {
        ReadAloudThemeCatalog.catalog.theme(id: themeID)
            ?? ReadAloudThemeCatalog.catalog.fallbackTheme
    }

    var colors: [Color] {
        [theme.backgroundColor, theme.elevatedSurfaceColor, theme.accentColor]
    }
}

@MainActor
struct ReadAloudScreenshotStudioView: View {
    @State private var settings = ReadAloudScreenshotSettings()

    var body: some View {
        ScreenshotStudio(catalog: catalog) { context in
            Section("Composition") {
                LabeledContent("Scene", value: context.selectedScreenshotTitle)
                LabeledContent("Frame", value: context.selectedScreenshotID == "pro" ? "Real paywall" : "Clay iPhone")
                LabeledContent("Data", value: "Fixed preview fixtures")
            }
        } appConfigurationControls: { context in
            ReadAloudScreenshotAppearanceControls(settings: settings, context: context)
        }
        .scrollContentBackground(.hidden)
        .background(
            ScreenshotBackground(
                style: settings.backgroundStyle,
                colors: settings.colors,
                intensity: settings.intensity
            )
        )
        .tint(settings.theme.accentColor)
    }

    private var catalog: ScreenshotCatalog {
        ScreenshotCatalog(
            appName: "ReadAloud",
            presets: [.iPhone69Portrait, .iPhone65Portrait],
            locales: [.english],
            defaultPresetID: ScreenshotDevicePreset.iPhone69Portrait.id,
            defaultLocaleID: ScreenshotStudioLocale.english.id,
            defaultScreenshotID: "library"
        ) {
            ScreenshotDefinition(id: "library", title: "Your Library", filename: "01_Your Library") {
                ReadAloudMarketingScreenshot(settings: settings, kind: .library)
            }
            ScreenshotDefinition(id: "reader", title: "Listen & Read", filename: "02_Listen and Read") {
                ReadAloudMarketingScreenshot(settings: settings, kind: .reader)
            }
            ScreenshotDefinition(id: "import", title: "Import Anything", filename: "03_Import Anything") {
                ReadAloudMarketingScreenshot(settings: settings, kind: .imports)
            }
            ScreenshotDefinition(id: "voices", title: "Narrator Voices", filename: "04_Narrator Voices") {
                ReadAloudMarketingScreenshot(settings: settings, kind: .voices)
            }
            ScreenshotDefinition(id: "offline", title: "Offline Audio", filename: "05_Offline Audio") {
                ReadAloudMarketingScreenshot(settings: settings, kind: .offline)
            }
            ScreenshotDefinition(id: "pro", title: "ReadAloud Pro", filename: "06_ReadAloud Pro") {
                ReadAloudScreenshotPaywall(theme: settings.theme)
            }
        }
    }
}

@MainActor
private struct ReadAloudScreenshotAppearanceControls: View {
    @Bindable var settings: ReadAloudScreenshotSettings
    let context: ScreenshotStudioControlContext

    var body: some View {
        Section("ReadAloud Appearance") {
            Picker("Theme", selection: $settings.themeID) {
                ForEach(ReadAloudThemeCatalog.catalog.themes) { theme in
                    Label(theme.title, systemImage: theme.symbolName).tag(theme.id)
                }
            }
            Picker("Background", selection: $settings.backgroundStyle) {
                ForEach(ScreenshotBackgroundStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            Slider(value: $settings.intensity, in: 0.35...1.6, step: 0.05) {
                Text("Intensity")
            }
            LabeledContent("Output", value: context.preset.title)
        }
        Section("Safety") {
            LabeledContent("User library", value: "Never accessed")
            LabeledContent("Network", value: "None")
            LabeledContent("Purchase state", value: "Simulated in paywall only")
        }
    }
}

/// Deliberately initializes a separate simulated controller only when selected.
@MainActor
private struct ReadAloudScreenshotPaywall: View {
    let theme: AppTheme
    @State private var purchases = PurchaseManager.screenshotPreview(
        configuration: ReadAloudCommerce.purchaseConfiguration,
        products: ReadAloudCommerce.simulatedProducts
    )

    var body: some View {
        ProPaywallScreenshotTemplate(
            purchases: purchases,
            configuration: ReadAloudCommerce.paywallConfiguration,
            selectedProductID: ReadAloudCommerce.lifetimeProductID
        )
        .environment(\.appFoundationTheme, theme)
        .environment(
            \.colorScheme,
            theme.appearance.preferredColorScheme == .light ? .light : .dark
        )
    }
}

private enum ReadAloudScreenshotKind {
    case library, reader, imports, voices, offline

    var headline: String {
        switch self {
        case .library: "Your stories.\nAll in one place."
        case .reader: "Listen and read\nin perfect harmony."
        case .imports: "Turn almost anything\ninto listening."
        case .voices: "A voice for\nevery story."
        case .offline: "Take your stories\nanywhere."
        }
    }
}

@MainActor
private struct ReadAloudMarketingScreenshot: View {
    let settings: ReadAloudScreenshotSettings
    let kind: ReadAloudScreenshotKind

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ScreenshotBackground(
                    style: settings.backgroundStyle,
                    colors: settings.colors,
                    intensity: settings.intensity
                )

                VStack(spacing: 26) {
                    Text(kind.headline)
                        .font(.system(size: geometry.size.width * 0.080, weight: .heavy, design: .rounded))
                        .tracking(-1.1)
                        .foregroundStyle(settings.theme.primaryForegroundColor)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .minimumScaleFactor(0.8)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)

                    ScreenshotDeviceFrame(
                        style: .clay,
                        device: .iPhonePortrait,
                        frameColor: settings.theme.elevatedSurfaceColor,
                        rotation: .degrees(-2),
                        showsCameraCutout: false
                    ) {
                        ReadAloudScreenshotPhone(theme: settings.theme, kind: kind)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .padding(.horizontal, 37)
                .padding(.top, geometry.size.height * 0.095)
                .padding(.bottom, 8)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .environment(\.appFoundationTheme, settings.theme)
        .environment(
            \.colorScheme,
            settings.theme.appearance.preferredColorScheme == .light ? .light : .dark
        )
    }
}

private struct ReadAloudScreenshotPhone: View {
    let theme: AppTheme
    let kind: ReadAloudScreenshotKind

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("9:41").font(.system(size: 11, weight: .semibold))
                Spacer()
                Image(systemName: "cellularbars")
                Image(systemName: "wifi")
                Image(systemName: "battery.100percent")
            }
            .font(.system(size: 10))
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 13)

            HStack(alignment: .center) {
                Text(screenTitle)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Spacer()
                Image(systemName: "crown")
                Image(systemName: "gearshape")
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 13)

            VStack(alignment: .leading, spacing: 13) {
                switch kind {
                case .library:
                    libraryScene
                case .reader:
                    readerScene
                case .imports:
                    importScene
                case .voices:
                    voicesScene
                case .offline:
                    offlineScene
                }
            }
            .padding(.horizontal, 15)
            .frame(maxWidth: .infinity, alignment: .topLeading)

            Spacer(minLength: 4)
            HStack {
                Spacer()
                Capsule().fill(theme.primaryForegroundColor.opacity(0.4))
                    .frame(width: 95, height: 4)
                Spacer()
            }
            .padding(.bottom, 8)
        }
        .foregroundStyle(theme.primaryForegroundColor)
        .background(theme.backgroundColor)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var screenTitle: String {
        switch kind {
        case .library, .imports: "Library"
        case .reader: "Chapter 4"
        case .voices: "Voices"
        case .offline: "Offline Audio"
        }
    }

    private var libraryScene: some View {
        VStack(alignment: .leading, spacing: 13) {
            studioCard {
                VStack(alignment: .leading, spacing: 11) {
                    Text("KEEP LISTENING")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(theme.secondaryForegroundColor)

                    HStack(spacing: 12) {
                        bookCover("moon.stars.fill")
                            .frame(width: 74, height: 103)
                        VStack(alignment: .leading, spacing: 7) {
                            Text("The Quiet Atlas").font(.system(size: 16, weight: .bold))
                            Text("Chapter 4 · Finding North")
                                .font(.system(size: 10))
                                .foregroundStyle(theme.secondaryForegroundColor)
                            ProgressView(value: 0.62).tint(theme.accentColor)
                            Label("Continue Listening", systemImage: "play.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(theme.accentColor)
                        }
                    }
                }
            }
            HStack(spacing: 7) {
                pill("All", selected: true)
                pill("Books")
                pill("Articles")
                pill("Text")
            }
            Text("Your Library").font(.system(size: 17, weight: .bold))
            libraryRow("The Moonlit Garden", detail: "EPUB · 12 chapters", icon: "book.closed.fill")
            libraryRow("Ideas Worth Keeping", detail: "Web article", icon: "globe")
            libraryRow("Weekend Reading", detail: "PDF · 24 pages", icon: "doc.text.fill")
            HStack {
                Spacer()
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(theme.accentColor, in: Circle())
            }
        }
    }

    private var readerScene: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Label("Reading along", systemImage: "waveform")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.accentColor)
                Spacer()
                Image(systemName: "textformat.size")
            }
            .padding(.top, 7)
            Text("Finding North")
                .font(.system(size: 22, weight: .bold, design: .serif))
            Text("It was the sort of morning that made the whole world seem possible.")
                .font(.system(size: 17, design: .serif))
                .lineSpacing(5)
            Text("The light slipped gently between the trees, and every path seemed to lead toward something wonderful.")
                .font(.system(size: 17, design: .serif))
                .lineSpacing(5)
                .padding(9)
                .background(theme.accentColor.opacity(0.20), in: RoundedRectangle(cornerRadius: 10))
            Text("She opened her notebook and decided that today, at last, she would begin.")
                .font(.system(size: 17, design: .serif))
                .lineSpacing(5)
            studioCard {
                VStack(spacing: 11) {
                    HStack {
                        Image(systemName: "waveform").foregroundStyle(theme.accentColor)
                        Text("Clara · 1.0×").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text("04:18 / 18:42")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.secondaryForegroundColor)
                    }
                    ProgressView(value: 0.23).tint(theme.accentColor)
                    HStack(spacing: 28) {
                        Image(systemName: "gobackward.15")
                        Image(systemName: "pause.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(theme.accentColor)
                        Image(systemName: "goforward.15")
                    }
                    .font(.system(size: 20))
                }
            }
        }
    }

    private var importScene: some View {
        VStack(alignment: .leading, spacing: 13) {
            studioCard {
                VStack(alignment: .leading, spacing: 15) {
                    Text("Add to Library")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("Choose what you'd like to listen to.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryForegroundColor)
                    importOption("Add Files", detail: "EPUB, PDF, and documents", icon: "doc.badge.plus")
                    importOption("Add Web Article", detail: "Paste a link to an article", icon: "link")
                    importOption("Add Text", detail: "Turn your notes into audio", icon: "text.alignleft")
                }
            }
            Text("Made for your reading")
                .font(.system(size: 15, weight: .bold))
            libraryRow("The Quiet Atlas", detail: "Ready to listen", icon: "books.vertical.fill")
            libraryRow("The Best Small Habits", detail: "Web article", icon: "globe")
        }
    }

    private var voicesScene: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                Text("Search voices")
                Spacer()
            }
            .font(.system(size: 12))
            .foregroundStyle(theme.secondaryForegroundColor)
            .padding(10)
            .background(theme.elevatedSurfaceColor, in: RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 7) {
                pill("All", selected: true)
                pill("American")
                pill("British")
            }
            Text("28 voices")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.secondaryForegroundColor)
            voiceRow("Clara", detail: "American English · Female", selected: true, pro: false)
            voiceRow("Sophie", detail: "American English · Female", selected: false, pro: true)
            voiceRow("Lucas", detail: "American English · Male", selected: false, pro: true)
            voiceRow("Florence", detail: "British English · Female", selected: false, pro: true)
            voiceRow("Oliver", detail: "British English · Male", selected: false, pro: true)
        }
    }

    private var offlineScene: some View {
        VStack(alignment: .leading, spacing: 13) {
            studioCard {
                VStack(alignment: .leading, spacing: 11) {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(theme.accentColor)
                        Text("Prepare Audio Ahead").font(.system(size: 16, weight: .bold))
                        Spacer()
                        Text("PRO")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(theme.accentColor)
                    }
                    Text("Generate a chapter or full book for offline listening.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryForegroundColor)
                    HStack {
                        Image(systemName: "books.vertical")
                        Text("The Quiet Atlas")
                        Spacer()
                        Image(systemName: "chevron.down")
                    }
                    .font(.system(size: 12, weight: .semibold))
                }
            }
            Text("Generation Queue")
                .font(.system(size: 17, weight: .bold))
            studioCard {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Image(systemName: "waveform")
                            .foregroundStyle(theme.accentColor)
                        Text("Chapter 4 · Finding North")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                    }
                    ProgressView(value: 0.42).tint(theme.accentColor)
                    Text("Preparing audio · 42%")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.secondaryForegroundColor)
                }
            }
            libraryRow("Chapter 1 · The Beginning", detail: "Ready offline", icon: "checkmark.circle.fill")
            libraryRow("Chapter 2 · New Horizons", detail: "Ready offline", icon: "checkmark.circle.fill")
            libraryRow("Chapter 3 · The Long Road", detail: "Ready offline", icon: "checkmark.circle.fill")
        }
    }

    private func pill(_ title: String, selected: Bool = false) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(selected ? theme.backgroundColor : theme.primaryForegroundColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(selected ? theme.accentColor : theme.elevatedSurfaceColor, in: Capsule())
    }

    private func studioCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                theme.elevatedSurfaceColor,
                in: RoundedRectangle(cornerRadius: 17, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .strokeBorder(theme.borderColor, lineWidth: 0.6)
            }
    }

    private func bookCover(_ icon: String) -> some View {
        ZStack {
            LinearGradient(
                colors: [theme.accentColor.opacity(0.86), theme.backgroundColor],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(theme.primaryForegroundColor)
        }
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private func libraryRow(_ title: String, detail: String, icon: String) -> some View {
        HStack(spacing: 11) {
            bookCover(icon).frame(width: 40, height: 53)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.secondaryForegroundColor)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.secondaryForegroundColor)
        }
        .padding(.vertical, 4)
    }

    private func importOption(_ title: String, detail: String, icon: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundStyle(theme.accentColor)
                .frame(width: 34, height: 34)
                .background(theme.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.secondaryForegroundColor)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 10))
                .foregroundStyle(theme.secondaryForegroundColor)
        }
    }

    private func voiceRow(_ name: String, detail: String, selected: Bool, pro: Bool) -> some View {
        studioCard {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 17))
                    .foregroundStyle(theme.accentColor)
                    .frame(width: 35, height: 35)
                    .background(theme.accentColor.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.system(size: 13, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.secondaryForegroundColor)
                }
                Spacer(minLength: 4)
                if pro {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.accentColor)
                }
                Image(systemName: selected ? "checkmark.circle.fill" : "play.circle")
                    .foregroundStyle(theme.accentColor)
            }
        }
    }
}
#endif
