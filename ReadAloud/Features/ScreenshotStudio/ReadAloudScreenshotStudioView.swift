#if DEBUG
import AppFoundation
import Observation
import SwiftUI

/// Campaign settings are isolated from the app's persisted appearance.
@MainActor
@Observable
final class ReadAloudScreenshotSettings {
    var themeID = ReadAloudThemeCatalog.light.id
    var backgroundStyle: ScreenshotBackgroundStyle = .spotlight
    var intensity = 1.0

    var theme: AppTheme {
        ReadAloudThemeCatalog.catalog.theme(id: themeID)
            ?? ReadAloudThemeCatalog.light
    }
}

@MainActor
struct ReadAloudScreenshotStudioView: View {
    @State private var settings = ReadAloudScreenshotSettings()

    var body: some View {
        ScreenshotStudio(catalog: catalog) { context in
            Section("Screenshot") {
                LabeledContent("Scene", value: context.selectedScreenshotTitle)
                LabeledContent("Content", value: context.selectedScreenshotID == "pro"
                    ? "AppFoundation paywall" : "Static reading example")
            }
        } appConfigurationControls: { context in
            ReadAloudScreenshotAppearanceControls(settings: settings, context: context)
        }
        .scrollContentBackground(.hidden)
        .background(settings.theme.backgroundColor)
        .tint(settings.theme.accentColor)
        .accessibilityIdentifier("screenshots.studio")
    }

    private var catalog: ScreenshotCatalog {
        ScreenshotCatalog(
            appName: "ReadAloud",
            presets: [.iPhone69Portrait, .iPhone65Portrait],
            locales: [.english],
            defaultPresetID: ScreenshotDevicePreset.iPhone69Portrait.id,
            defaultLocaleID: ScreenshotStudioLocale.english.id,
            defaultScreenshotID: ReadAloudScreenshotFeature.reader.rawValue
        ) {
            for feature in ReadAloudScreenshotFeature.allCases {
                ScreenshotDefinition(id: feature.rawValue, title: feature.title, filename: feature.filename) {
                    ReadAloudMarketingScreenshot(settings: settings, feature: feature)
                        .dynamicTypeSize(.large)
                }
            }
            ScreenshotDefinition(id: "pro", title: "ReadAloud Pro", filename: "06_ReadAloud Pro") {
                ReadAloudScreenshotPaywall(theme: settings.theme)
                    .dynamicTypeSize(.large)
            }
        }
    }
}

@MainActor
private struct ReadAloudScreenshotAppearanceControls: View {
    @Bindable var settings: ReadAloudScreenshotSettings
    let context: ScreenshotStudioControlContext

    var body: some View {
        Section("Campaign Appearance") {
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
            LabeledContent("Background intensity",
                value: settings.intensity.formatted(.number.precision(.fractionLength(2))))
            Slider(value: $settings.intensity, in: 0.35...1.6, step: 0.05)
            LabeledContent("Output", value: context.preset.title)
        }
    }
}

/// Constructed only when selected; never uses the app's purchase manager.
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
        .environment(\.colorScheme,
            theme.appearance.preferredColorScheme == .light ? .light : .dark)
    }
}

private enum ReadAloudScreenshotFeature: String, CaseIterable {
    // Keep the existing scene IDs while leading with the core listening benefit.
    case reader
    case imports = "import"
    case voices, library, offline

    var title: String {
        switch self {
        case .reader: "Your words, read aloud."
        case .imports: "Bring your reading."
        case .voices: "A voice for every story."
        case .library: "Your library, ready to play."
        case .offline: "Take your stories anywhere."
        }
    }

    var headline: (String, String) {
        switch self {
        case .reader: ("Your words,", "read aloud.")
        case .imports: ("Bring your", "reading.")
        case .voices: ("A voice for", "every story.")
        case .library: ("Your library,", "ready to play.")
        case .offline: ("Take your stories", "anywhere.")
        }
    }

    var subtitle: String {
        switch self {
        case .reader: "Listen to your books.\nFollow along as you read."
        case .imports: "EPUBs, PDFs, documents,\nweb articles, and your own text."
        case .voices: "28 English voices.\nFind your favorite narrator."
        case .library: "Books, articles, and notes.\nPick up where you left off."
        case .offline: "Prepare audio ahead with Pro.\nListen without a connection."
        }
    }

    var filename: String {
        switch self {
        case .reader: "01_Your words read aloud"
        case .imports: "02_Bring your reading"
        case .voices: "03_A voice for every story"
        case .library: "04_Your library ready to play"
        case .offline: "05_Take your stories anywhere"
        }
    }
}

/// Matches Inkribe's fixed 440-point artboard and equal 33-point vertical insets.
/// The selected preset scales the entire composition, not individual text sizes.
@MainActor
private struct ReadAloudMarketingScreenshot: View {
    let settings: ReadAloudScreenshotSettings
    let feature: ReadAloudScreenshotFeature

    private var palette: ReadAloudScreenshotPalette { .init(theme: settings.theme) }

    var body: some View {
        GeometryReader { proxy in
            let scale = max(proxy.size.width, 1) / 440
            ZStack(alignment: .topLeading) {
                ScreenshotBackground(style: settings.backgroundStyle,
                    colors: [settings.theme.backgroundColor, palette.accent.opacity(0.2),
                             settings.theme.backgroundColor],
                    intensity: settings.intensity)
                    .background(settings.theme.backgroundColor)
                VStack(alignment: .leading, spacing: 26) {
                    header.padding(.horizontal, 31)
                    content.padding(.horizontal, 22)
                        .frame(maxHeight: .infinity)
                }
                .padding(.vertical, 33)
                .frame(width: 440, height: proxy.size.height / scale, alignment: .topLeading)
                .scaleEffect(scale, anchor: .topLeading)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
        }
        .environment(\.appFoundationTheme, settings.theme)
        .environment(\.colorScheme,
            settings.theme.appearance.preferredColorScheme == .light ? .light : .dark)
        .allowsHitTesting(false)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(feature.headline.0).foregroundStyle(palette.text).frame(height: 52, alignment: .leading)
            Text(feature.headline.1).foregroundStyle(palette.accent).frame(height: 52, alignment: .leading)
            Text(feature.subtitle)
                .font(.system(size: 16))
                .tracking(0)
                .lineSpacing(4)
                .foregroundStyle(palette.secondary)
                .padding(.top, 14)
        }
        .font(.system(size: 48, weight: .heavy))
        .tracking(-1.5)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var content: some View {
        switch feature {
        case .reader: ReadAloudScreenshotReader(palette: palette)
        case .imports: ReadAloudScreenshotImports(palette: palette)
        case .voices: ReadAloudScreenshotVoices(palette: palette)
        case .library: ReadAloudScreenshotLibrary(palette: palette)
        case .offline: ReadAloudScreenshotOffline(palette: palette)
        }
    }
}

private struct ReadAloudScreenshotPalette {
    let theme: AppTheme
    var text: Color { theme.primaryForegroundColor }
    var secondary: Color { theme.secondaryForegroundColor }
    var accent: Color { theme.accentColor }
    var surface: Color { theme.surfaceColor }
    var soft: Color { theme.elevatedSurfaceColor }
    var border: Color { theme.borderColor }
}

@MainActor
private struct ReadAloudScreenshotPanel<Content: View>: View {
    let palette: ReadAloudScreenshotPalette
    private let content: Content

    init(palette: ReadAloudScreenshotPalette, @ViewBuilder content: () -> Content) {
        self.palette = palette
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .foregroundStyle(palette.text)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 22))
            .shadow(color: .black.opacity(0.08), radius: 14, y: 8)
    }
}

@MainActor
private struct ReadAloudScreenshotPanelTitle: View {
    let title: String
    let symbol: String
    let palette: ReadAloudScreenshotPalette

    var body: some View {
        HStack {
            Text(title).font(.system(size: 15, weight: .semibold))
            Spacer(minLength: 12)
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(palette.secondary)
        }
        .foregroundStyle(palette.text)
        .padding(.bottom, 16)
    }
}

/// Original, synchronous book artwork; no file loading or native view wrappers.
@MainActor
private struct ReadAloudScreenshotBookCover: View {
    let palette: ReadAloudScreenshotPalette
    var title = "THE QUIET\nATLAS"
    var alternate = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(colors: [palette.accent.opacity(alternate ? 0.65 : 0.25),
                                        palette.theme.appearance.gradientEnd.color],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(palette.surface.opacity(0.75))
                    .frame(width: proxy.size.width * 0.58)
                    .offset(x: proxy.size.width * 0.20, y: -proxy.size.height * 0.07)
                Ellipse().fill(palette.text.opacity(0.18))
                    .frame(width: proxy.size.width * 1.5, height: proxy.size.height * 0.65)
                    .rotationEffect(.degrees(-25)).offset(y: proxy.size.height * 0.42)
                Ellipse().fill(palette.text.opacity(0.15))
                    .frame(width: proxy.size.width * 1.6, height: proxy.size.height * 0.55)
                    .rotationEffect(.degrees(20)).offset(y: proxy.size.height * 0.50)
                Text(title)
                    .font(.system(size: proxy.size.width * 0.15, weight: .semibold, design: .serif))
                    .tracking(proxy.size.width * 0.015)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(palette.text)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, proxy.size.height * 0.16)
                    .padding(.horizontal, 5)
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel(title.replacingOccurrences(of: "\n", with: " "))
    }
}

@MainActor
private struct ReadAloudScreenshotTransport: View {
    let palette: ReadAloudScreenshotPalette

    var body: some View {
        VStack(spacing: 15) {
            HStack {
                Text("Clara · 1×")
                Spacer()
                Label("Sleep", systemImage: "moon.zzz")
            }
            .font(.system(size: 12)).foregroundStyle(palette.secondary)
            GeometryReader { proxy in
                Capsule().fill(palette.border).frame(height: 4)
                Capsule().fill(palette.accent).frame(width: proxy.size.width * 0.23, height: 4)
                Circle().fill(palette.accent).frame(width: 12, height: 12)
                    .offset(x: proxy.size.width * 0.23 - 6, y: -4)
            }.frame(height: 4)
            HStack {
                Text("04:18")
                Spacer()
                Text("18:42")
            }.font(.system(size: 11)).monospacedDigit().foregroundStyle(palette.secondary)
            HStack(spacing: 32) {
                Image(systemName: "gobackward.15")
                Image(systemName: "pause.fill")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(palette.theme.backgroundColor)
                    .frame(width: 60, height: 60).background(palette.accent, in: Circle())
                Image(systemName: "goforward.15")
            }
            .font(.system(size: 25)).foregroundStyle(palette.text)
            .frame(maxWidth: .infinity)
        }
    }
}

@MainActor
private struct ReadAloudScreenshotReader: View {
    let palette: ReadAloudScreenshotPalette

    var body: some View {
        ReadAloudScreenshotPanel(palette: palette) {
            VStack(alignment: .leading, spacing: 0) {
                ReadAloudScreenshotPanelTitle(title: "The Quiet Atlas", symbol: "textformat.size", palette: palette)
                HStack {
                    Text("CHAPTER 4")
                    Spacer()
                    Image(systemName: "list.bullet")
                }
                .font(.system(size: 11, weight: .semibold)).tracking(1)
                .foregroundStyle(palette.secondary).padding(.top, 8)
                Text("Finding North")
                    .font(.system(size: 28, weight: .semibold, design: .serif))
                    .padding(.top, 16).padding(.bottom, 22)
                VStack(alignment: .leading, spacing: 18) {
                    Text("It was the sort of morning that made the whole world seem possible.")
                    Text("The light slipped gently between the trees, and every path seemed to lead toward something wonderful.")
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(palette.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
                    Text("She opened her notebook and decided that today, at last, she would begin.")
                }
                .font(.system(size: 20, design: .serif)).lineSpacing(6)
                Spacer(minLength: 22)
                palette.border.frame(height: 0.5).padding(.bottom, 20)
                ReadAloudScreenshotTransport(palette: palette)
            }
        }
    }
}

@MainActor
private struct ReadAloudScreenshotImports: View {
    let palette: ReadAloudScreenshotPalette

    var body: some View {
        VStack(spacing: 14) {
            ReadAloudScreenshotPanel(palette: palette) {
                VStack(alignment: .leading, spacing: 0) {
                    ReadAloudScreenshotPanelTitle(title: "Add to Library", symbol: "plus", palette: palette)
                    source("Add EPUB", detail: "Your next chapter starts here.", symbol: "book.closed")
                    palette.border.frame(height: 0.5)
                    source("Add PDF", detail: "Make time for longer reads.", symbol: "doc.richtext")
                    palette.border.frame(height: 0.5)
                    source("Add Document", detail: "Bring your documents along.", symbol: "doc.text")
                    palette.border.frame(height: 0.5)
                    source("Add Web Article", detail: "Save an article from a link.", symbol: "link")
                    palette.border.frame(height: 0.5)
                    source("Add Text", detail: "Give your own words a voice.", symbol: "doc.on.clipboard")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            ReadAloudScreenshotPanel(palette: palette) {
                HStack(spacing: 20) {
                    ReadAloudScreenshotBookCover(palette: palette)
                        .aspectRatio(0.72, contentMode: .fit)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("The Quiet Atlas").font(.system(size: 19, weight: .semibold, design: .serif))
                        Text("EPUB · 12 chapters").font(.system(size: 12)).foregroundStyle(palette.secondary)
                        Label("Listen", systemImage: "play.fill")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.accent)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func source(_ title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(palette.accent)
                .frame(width: 46, height: 46)
                .background(palette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(palette.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(palette.secondary)
        }.padding(.vertical, 16)
    }
}

@MainActor
private struct ReadAloudScreenshotVoices: View {
    let palette: ReadAloudScreenshotPalette

    var body: some View {
        VStack(spacing: 14) {
            ReadAloudScreenshotPanel(palette: palette) {
                VStack(alignment: .leading, spacing: 0) {
                    ReadAloudScreenshotPanelTitle(title: "Voices", symbol: "line.3.horizontal.decrease.circle", palette: palette)
                    HStack(spacing: 8) {
                        ReadAloudScreenshotPill(title: "All", selected: true, palette: palette)
                        ReadAloudScreenshotPill(title: "American", palette: palette)
                        ReadAloudScreenshotPill(title: "British", palette: palette)
                    }.padding(.bottom, 10)
                    voice("Clara", detail: "American English · Female", selected: true)
                    palette.border.frame(height: 0.5)
                    voice("Sophie", detail: "American English · Female", pro: true)
                    palette.border.frame(height: 0.5)
                    voice("Lucas", detail: "American English · Male", pro: true)
                    palette.border.frame(height: 0.5)
                    voice("Florence", detail: "British English · Female", pro: true)
                    palette.border.frame(height: 0.5)
                    voice("Oliver", detail: "British English · Male", pro: true)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            ReadAloudScreenshotPanel(palette: palette) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Preview Text").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Image(systemName: "play.circle.fill").font(.system(size: 26)).foregroundStyle(palette.accent)
                    }
                    Text("A new chapter. A quiet moment.\nA voice that feels like yours.")
                        .font(.system(size: 19, design: .serif)).lineSpacing(5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func voice(_ name: String, detail: String, selected: Bool = false, pro: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform").font(.system(size: 19)).foregroundStyle(palette.accent)
                .frame(width: 42, height: 42).background(palette.accent.opacity(0.10), in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(name).font(.system(size: 16, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(palette.secondary)
            }
            Spacer(minLength: 4)
            if pro {
                Image(systemName: "crown.fill").font(.system(size: 11)).foregroundStyle(palette.accent)
            }
            Image(systemName: selected ? "checkmark.circle.fill" : "play.circle")
                .font(.system(size: 22)).foregroundStyle(palette.accent)
        }.padding(.vertical, 16)
    }
}

@MainActor
private struct ReadAloudScreenshotPill: View {
    let title: String
    var selected = false
    let palette: ReadAloudScreenshotPalette

    var body: some View {
        Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? palette.accent : palette.secondary)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(selected ? palette.accent.opacity(0.10) : .clear, in: Capsule())
            .overlay { Capsule().strokeBorder(selected ? palette.accent.opacity(0.4) : palette.border, lineWidth: 0.5) }
    }
}

@MainActor
private struct ReadAloudScreenshotLibrary: View {
    let palette: ReadAloudScreenshotPalette

    var body: some View {
        ReadAloudScreenshotPanel(palette: palette) {
            VStack(alignment: .leading, spacing: 0) {
                ReadAloudScreenshotPanelTitle(title: "Library", symbol: "gearshape", palette: palette)
                HStack(spacing: 18) {
                    ReadAloudScreenshotBookCover(palette: palette).frame(width: 78, height: 104)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("KEEP LISTENING").font(.system(size: 10, weight: .semibold)).tracking(1)
                            .foregroundStyle(palette.secondary)
                        Text("The Quiet Atlas").font(.system(size: 19, weight: .semibold, design: .serif))
                        Text("Chapter 4 · Finding North").font(.system(size: 11)).foregroundStyle(palette.secondary)
                        ProgressView(value: 0.62).tint(palette.accent)
                        Label("Continue Listening", systemImage: "play.fill")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.accent)
                    }
                }
                .padding(12).background(palette.soft, in: RoundedRectangle(cornerRadius: 16))
                HStack(spacing: 8) {
                    ReadAloudScreenshotPill(title: "All", selected: true, palette: palette)
                    ReadAloudScreenshotPill(title: "EPUB", palette: palette)
                    ReadAloudScreenshotPill(title: "PDF", palette: palette)
                    ReadAloudScreenshotPill(title: "Articles", palette: palette)
                }.padding(.vertical, 14)
                HStack {
                    Text("Your Library").font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Image(systemName: "arrow.up.arrow.down").foregroundStyle(palette.secondary)
                }.padding(.bottom, 8)
                row("The Moonlit Garden", detail: "EPUB · 12 chapters", symbol: "book.closed", cover: true)
                palette.border.frame(height: 0.5)
                row("Ideas Worth Keeping", detail: "Web article", symbol: "globe")
                palette.border.frame(height: 0.5)
                row("Weekend Reading", detail: "PDF · 24 pages", symbol: "doc.richtext")
                Spacer(minLength: 8)
                HStack {
                    Spacer()
                    Image(systemName: "plus").font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(palette.theme.backgroundColor)
                        .frame(width: 44, height: 44).background(palette.accent, in: Circle())
                }
            }
        }
    }

    private func row(_ title: String, detail: String, symbol: String, cover: Bool = false) -> some View {
        HStack(spacing: 13) {
            if cover {
                ReadAloudScreenshotBookCover(palette: palette, title: "MOONLIT\nGARDEN", alternate: true)
                    .frame(width: 40, height: 50)
            } else {
                Image(systemName: symbol).font(.system(size: 23)).foregroundStyle(palette.accent)
                    .frame(width: 40, height: 50).background(palette.soft, in: RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(palette.secondary)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(palette.secondary)
        }.padding(.vertical, 8)
    }
}

@MainActor
private struct ReadAloudScreenshotOffline: View {
    let palette: ReadAloudScreenshotPalette

    var body: some View {
        VStack(spacing: 14) {
            ReadAloudScreenshotPanel(palette: palette) {
                VStack(spacing: 18) {
                    HStack(spacing: 20) {
                        ReadAloudScreenshotBookCover(palette: palette).frame(width: 96, height: 132)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("The Quiet Atlas").font(.system(size: 23, weight: .semibold, design: .serif))
                            Text("Chapter 4 · Finding North").font(.system(size: 12)).foregroundStyle(palette.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    ReadAloudScreenshotTransport(palette: palette)
                }
            }
            ReadAloudScreenshotPanel(palette: palette) {
                VStack(alignment: .leading, spacing: 0) {
                    ReadAloudScreenshotPanelTitle(title: "Offline Audio", symbol: "arrow.down.circle", palette: palette)
                    ready("Chapter 1 · The Beginning")
                    palette.border.frame(height: 0.5)
                    ready("Chapter 2 · New Horizons")
                    palette.border.frame(height: 0.5)
                    HStack {
                        Label("Generate Remaining", systemImage: "waveform")
                        Spacer()
                        Label("Pro", systemImage: "crown.fill")
                    }
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.accent)
                    .padding(.top, 16)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func ready(_ title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 22)).foregroundStyle(palette.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text("Ready offline").font(.system(size: 11)).foregroundStyle(palette.secondary)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 10)
    }
}
#endif
