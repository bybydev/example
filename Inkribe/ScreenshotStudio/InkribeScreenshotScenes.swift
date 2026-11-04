#if DEBUG
import AppFoundation
import SwiftUI

enum InkribeScreenshotFeature: String, CaseIterable {
    case captioning, styles, editing, music, export

    var title: String {
        switch self {
        case .captioning: "Your words, captioned."
        case .styles: "Find your caption style."
        case .editing: "Get every word right."
        case .music: "Set the mood with music."
        case .export: "Ready to share."
        }
    }

    var headline: (String, String) {
        switch self {
        case .captioning: ("Your words,", "captioned.")
        case .styles: ("Find your", "caption style.")
        case .editing: ("Get every", "word right.")
        case .music: ("Set the mood", "with music.")
        case .export: ("Ready", "to share.")
        }
    }

    var subtitle: String {
        switch self {
        case .captioning: "Turn speech into captions\nright on your iPhone."
        case .styles: "Choose a template.\nMake it yours."
        case .editing: "Edit text, split captions,\nand fine-tune timing."
        case .music: "Add a soundtrack.\nBalance your audio."
        case .export: "Export captioned videos\nand subtitle files."
        }
    }
}

/// A fixed 440-point artboard scales as a unit to either catalog preset.
/// Equal vertical insets bound each composition; the artwork fills the remaining height.
/// Every feature below is a static SwiftUI composition, independent of the app session.
@MainActor
struct InkribeScreenshotScene: View {
    let feature: InkribeScreenshotFeature
    let theme: AppTheme
    let backgroundStyle: ScreenshotBackgroundStyle
    let backgroundIntensity: Double

    private var palette: InkribeScreenshotPalette { .init(theme: theme) }

    var body: some View {
        GeometryReader { proxy in
            let scale = max(proxy.size.width, 1) / 440
            ZStack(alignment: .topLeading) {
                ScreenshotBackground(style: backgroundStyle,
                    colors: [theme.backgroundColor, theme.accentColor.opacity(0.2), theme.backgroundColor],
                    intensity: backgroundIntensity)
                    .background(theme.backgroundColor)
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
        case .captioning: InkribeScreenshotCaptioning(palette: palette)
        case .styles: InkribeScreenshotStyles(palette: palette)
        case .editing: InkribeScreenshotEditing(palette: palette)
        case .music: InkribeScreenshotMusic(palette: palette)
        case .export: InkribeScreenshotExport(palette: palette)
        }
    }
}

@MainActor
private struct InkribeScreenshotCaptioning: View {
    let palette: InkribeScreenshotPalette

    var body: some View {
        InkribeScreenshotPanel(palette: palette) {
            VStack(spacing: 0) {
                InkribeScreenshotPanelTitle(title: "Morning walk", symbol: "ellipsis", palette: palette)
                InkribeScreenshotVideo(captionSize: 34, showsTime: true)
                InkribeScreenshotTransport(palette: palette)
                VStack(spacing: 7) {
                    InkribeScreenshotRuler(palette: palette)
                    InkribeScreenshotFilmstrip()
                    InkribeScreenshotCaptionTrack(palette: palette)
                }
                .overlay(alignment: .leading) {
                    Rectangle().fill(palette.accent).frame(width: 2).padding(.leading, 135)
                }
                .padding(.vertical, 12)
                InkribeScreenshotActionBar(palette: palette)
            }
        }
    }
}

@MainActor
private struct InkribeScreenshotStyles: View {
    let palette: InkribeScreenshotPalette

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 0) {
                Text("Make time for").foregroundStyle(.white)
                Text("what matters.").foregroundStyle(Color(red: 0.50, green: 0.90, blue: 1))
            }
            .font(.system(size: 35, weight: .heavy)).tracking(-1.5)
            .frame(maxWidth: .infinity, minHeight: 140, maxHeight: .infinity)
            .background(Color(red: 0.14, green: 0.30, blue: 0.31), in: RoundedRectangle(cornerRadius: 18))
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    styleCard("Classic", index: 0)
                    styleCard("Boxed", index: 1)
                }
                HStack(spacing: 12) {
                    styleCard("Pop", index: 2)
                    styleCard("Clean", index: 3)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            InkribeScreenshotPanel(palette: palette) {
                VStack(spacing: 0) {
                    InkribeScreenshotSettingRow(title: "Font", value: "Rounded", palette: palette, showsChevron: true)
                    palette.border.frame(height: 0.5)
                    HStack {
                        Text("Highlight color")
                        Spacer()
                        Circle().fill(palette.accent).frame(width: 22, height: 22)
                    }
                    .font(.system(size: 13)).foregroundStyle(palette.text).frame(height: 48)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func styleCard(_ title: String, index: Int) -> some View {
        VStack(spacing: 0) {
            Text(styleText(index))
            .multilineTextAlignment(.center)
            .font(.system(size: index == 1 ? 19 : 25, weight: index == 0 ? .regular : .heavy,
                          design: index == 0 ? .serif : .default))
            .tracking(-0.8)
            .foregroundStyle(index == 2 ? Color(red: 1, green: 0.94, blue: 0.36) : .white)
            .padding(.horizontal, 5)
            .padding(.vertical, index == 1 ? 8 : 0)
            .background(index == 1 ? Color.black.opacity(0.5) : .clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .frame(maxWidth: .infinity).frame(height: 112)
            .background(styleBackground(index))
            HStack {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
            }
            .foregroundStyle(palette.text).padding(.horizontal, 12).frame(height: 34)
            .background(palette.surface)
        }
        .clipShape(RoundedRectangle(cornerRadius: 13))
    }

    private func styleText(_ index: Int) -> String {
        switch index {
        case 0: "Make time\nfor what matters."
        case 1: "MAKE TIME\nFOR WHAT MATTERS."
        case 2: "MAKE TIME\nFOR WHAT\nMATTERS."
        default: "Make time.\nMake it count."
        }
    }

    private func styleBackground(_ index: Int) -> Color {
        switch index {
        case 0: Color(red: 0.38, green: 0.49, blue: 0.45)
        case 1: Color(red: 0.72, green: 0.80, blue: 0.82)
        case 2: Color(red: 0.72, green: 0.70, blue: 0.64)
        default: Color(red: 0.50, green: 0.62, blue: 0.59)
        }
    }
}

@MainActor
private struct InkribeScreenshotEditing: View {
    let palette: InkribeScreenshotPalette

    var body: some View {
        VStack(spacing: 14) {
            InkribeScreenshotPanel(palette: palette) {
                VStack(spacing: 0) {
                    InkribeScreenshotPanelTitle(title: "Captions", symbol: "arrow.uturn.backward", palette: palette)
                    InkribeScreenshotVideo(captionSize: 26)
                        .padding(.bottom, 12)
                    caption("00:04", text: "Slow down for a moment.")
                    caption("00:08", text: "Make time for what matters.", selected: true)
                    caption("00:12", text: "A little fresh air goes a long way.")
                }
            }
            InkribeScreenshotPanel(palette: palette) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Edit Caption").fontWeight(.semibold)
                        Spacer()
                        Text("Done").foregroundStyle(palette.accent)
                    }
                    Text("Make time for\nwhat matters.")
                        .font(.system(size: 16)).frame(maxWidth: .infinity, minHeight: 55, alignment: .topLeading)
                        .padding(12).background(palette.soft, in: RoundedRectangle(cornerRadius: 9))
                    HStack {
                        Text("00:08.00 — 00:11.20").monospacedDigit()
                        Spacer()
                        Label("Split", systemImage: "scissors").foregroundStyle(palette.accent)
                    }.font(.system(size: 12))
                }
                .font(.system(size: 14)).foregroundStyle(palette.text)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func caption(_ time: String, text: String, selected: Bool = false) -> some View {
        HStack(spacing: 10) {
            Text(time).font(.system(size: 11)).monospacedDigit().foregroundStyle(palette.secondary)
            VStack(alignment: .leading, spacing: 5) {
                if selected {
                    Label("Edit caption", systemImage: "pencil")
                        .font(.system(size: 10)).foregroundStyle(palette.accent)
                }
                Text(text).font(.system(size: 12)).foregroundStyle(palette.text)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 50).padding(.horizontal, 9)
        .background(selected ? palette.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }
}

@MainActor
private struct InkribeScreenshotMusic: View {
    let palette: InkribeScreenshotPalette

    var body: some View {
        VStack(spacing: 16) {
            InkribeScreenshotPanel(palette: palette) {
                VStack(spacing: 0) {
                    InkribeScreenshotPanelTitle(title: "Morning walk", symbol: "music.note", palette: palette)
                    InkribeScreenshotVideo(captionSize: 26)
                    InkribeScreenshotRuler(palette: palette).padding(.top, 18)
                    VStack(spacing: 8) {
                        lane("speaker.wave.2") { InkribeScreenshotFilmstrip(height: 32) }
                        lane("music.note") { InkribeScreenshotWaveform(palette: palette) }
                        lane("captions.bubble") {
                            InkribeScreenshotCaptionTrack(palette: palette, labels: ["Make time…", "Start again."])
                        }
                    }
                    HStack {
                        Text("Morning light.mp3 · Loop to fit")
                        Spacer()
                        Image(systemName: "repeat")
                    }
                    .font(.system(size: 11)).foregroundStyle(palette.secondary).padding(.top, 14)
                }
            }
            InkribeScreenshotPanel(palette: palette) {
                VStack(spacing: 0) {
                    HStack {
                        Text("Music volume")
                        Spacer()
                        Text("35%").foregroundStyle(palette.secondary)
                    }.padding(.vertical, 12)
                    GeometryReader { proxy in
                        Capsule().fill(palette.border).frame(height: 4)
                        Capsule().fill(palette.accent).frame(width: proxy.size.width * 0.35, height: 4)
                        Circle().fill(palette.accent).frame(width: 16, height: 16)
                            .offset(x: proxy.size.width * 0.35 - 8, y: -6)
                    }.frame(height: 16).padding(.bottom, 8)
                    HStack {
                        Text("Loop to fit")
                        Spacer()
                        Capsule().fill(palette.accent).frame(width: 34, height: 21)
                            .overlay(alignment: .trailing) { Circle().fill(.white).padding(3).frame(width: 21) }
                    }.frame(height: 42)
                    palette.border.frame(height: 0.5)
                    InkribeScreenshotSettingRow(title: "Fade in / Fade out", value: "1.0s / 1.0s", palette: palette)
                }.font(.system(size: 13)).foregroundStyle(palette.text)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func lane<Content: View>(_ symbol: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 16).foregroundStyle(palette.secondary)
            content()
        }
    }
}

@MainActor
private struct InkribeScreenshotExport: View {
    let palette: InkribeScreenshotPalette

    var body: some View {
        InkribeScreenshotPanel(palette: palette) {
            VStack(alignment: .leading, spacing: 0) {
                InkribeScreenshotPanelTitle(title: "Exports", symbol: "square.and.arrow.up", palette: palette)
                InkribeScreenshotVideo(captionSize: 32, captionBottom: 78)
                    .overlay(alignment: .bottomLeading) {
                        Label("Your video is ready", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.text)
                            .padding(12).background(palette.surface, in: RoundedRectangle(cornerRadius: 10))
                            .padding(12)
                    }
                InkribeScreenshotSettingRow(title: "Format", value: "MP4 Video", palette: palette)
                palette.border.frame(height: 0.5)
                InkribeScreenshotSettingRow(title: "Resolution", value: "1080p", palette: palette)
                Text("COMPLETED").font(.system(size: 10, weight: .semibold))
                    .tracking(1).foregroundStyle(palette.secondary).padding(.top, 16).padding(.bottom, 8)
                completed("MP4 · 1080p · Completed", symbol: "film")
                palette.border.frame(height: 0.5)
                completed("SRT · Subtitles · Completed", symbol: "doc.text")
            }
        }
    }

    private func completed(_ detail: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(palette.accent)
                .frame(width: 38, height: 42).background(palette.soft, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 5) {
                Text("Morning walk").font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.text)
                Text(detail).font(.system(size: 11)).foregroundStyle(palette.secondary)
            }
            Spacer()
            Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.accent)
        }.padding(.vertical, 12)
    }
}
#endif
