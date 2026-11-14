#if DEBUG
import AppFoundation
import SwiftUI

struct InkribeScreenshotPalette {
    let theme: AppTheme
    var background: Color { theme.backgroundColor }
    var text: Color { theme.primaryForegroundColor }
    var secondary: Color { theme.secondaryForegroundColor }
    var accent: Color { theme.accentColor }
    var surface: Color { theme.surfaceColor }
    var soft: Color { theme.elevatedSurfaceColor }
    var border: Color { theme.borderColor }
    var gradient: LinearGradient { theme.gradient }
}

/// Poster copy block. Every value is fixed at build time, so export never
/// depends on a live app session, task or animation.
@MainActor
struct InkribeScreenshotPosterHeader: View {
    let eyebrow: String
    let headline: (String, String)
    let subtitle: String
    let palette: InkribeScreenshotPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(palette.gradient)
                    .frame(width: 6, height: 6)
                Text(eyebrow.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(palette.accent)
            }

            VStack(alignment: .leading, spacing: -6) {
                Text(headline.0)
                    .foregroundStyle(palette.text)
                Text(headline.1)
                    .foregroundStyle(palette.gradient)
            }
            .font(.system(size: 40, weight: .heavy))
            .tracking(-1.6)
            .padding(.top, 9)

            Text(subtitle)
                .font(.system(size: 15.5))
                .lineSpacing(3)
                .foregroundStyle(palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum InkribeScreenshotPhoneMetrics {
    static let screenWidth: CGFloat = 314
    static let screenHeight: CGFloat = 682
    static let bezel: CGFloat = 6
    static let outerWidth: CGFloat = screenWidth + bezel * 2
    static let outerHeight: CGFloat = screenHeight + bezel * 2
}

/// A fixed iPhone mockup. The bezel, island and home indicator are SwiftUI
/// shapes; the app screen is a synchronous composition supplied by the caller.
@MainActor
struct InkribeScreenshotPhone<Content: View>: View {
    let palette: InkribeScreenshotPalette
    private let content: Content

    init(palette: InkribeScreenshotPalette, @ViewBuilder content: () -> Content) {
        self.palette = palette
        self.content = content()
    }

    var body: some View {
        ZStack {
            sideButtons

            RoundedRectangle(cornerRadius: 52, style: .continuous)
                .fill(Color(red: 0.055, green: 0.05, blue: 0.055))
                .frame(width: InkribeScreenshotPhoneMetrics.outerWidth,
                       height: InkribeScreenshotPhoneMetrics.outerHeight)
                .overlay {
                    RoundedRectangle(cornerRadius: 52, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.42), .white.opacity(0.06), .white.opacity(0.18)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
                .shadow(color: .black.opacity(0.5), radius: 30, y: 20)

            content
                .frame(width: InkribeScreenshotPhoneMetrics.screenWidth,
                       height: InkribeScreenshotPhoneMetrics.screenHeight)
                .background { AppThemeBackground(theme: palette.theme) }
                .clipShape(RoundedRectangle(cornerRadius: 46, style: .continuous))
                .overlay(alignment: .top) { dynamicIsland.padding(.top, 7) }
                .overlay(alignment: .bottom) { homeIndicator.padding(.bottom, 7) }
                .overlay {
                    RoundedRectangle(cornerRadius: 46, style: .continuous)
                        .strokeBorder(.black.opacity(0.55), lineWidth: 1.5)
                }
        }
        .frame(width: InkribeScreenshotPhoneMetrics.outerWidth,
               height: InkribeScreenshotPhoneMetrics.outerHeight)
    }

    private var sideButtons: some View {
        ZStack {
            Capsule().frame(width: 3, height: 11).offset(x: -164, y: -164)
            Capsule().frame(width: 3, height: 25).offset(x: -164, y: -132)
            Capsule().frame(width: 3, height: 25).offset(x: -164, y: -100)
            Capsule().frame(width: 3, height: 38).offset(x: 164, y: -118)
        }
        .foregroundStyle(.white.opacity(0.22))
    }

    private var dynamicIsland: some View {
        Capsule()
            .fill(.black)
            .frame(width: 88, height: 25)
            .overlay(alignment: .trailing) {
                Circle()
                    .fill(Color(red: 0.05, green: 0.08, blue: 0.12))
                    .frame(width: 5, height: 5)
                    .padding(.trailing, 7)
            }
    }

    private var homeIndicator: some View {
        Capsule()
            .fill(palette.text.opacity(0.75))
            .frame(width: 104, height: 4)
    }
}

enum InkribeScreenshotNavLeading {
    case back(String)
    case text(String)
}

/// Status bar, optional sheet grabber, navigation bar and a fixed content area.
@MainActor
struct InkribeScreenshotAppScreen<Content: View>: View {
    let palette: InkribeScreenshotPalette
    let title: String
    var leading: InkribeScreenshotNavLeading?
    var trailing: String?
    var showsGrabber = true
    private let content: Content

    init(
        palette: InkribeScreenshotPalette,
        title: String,
        leading: InkribeScreenshotNavLeading? = nil,
        trailing: String? = nil,
        showsGrabber: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.palette = palette
        self.title = title
        self.leading = leading
        self.trailing = trailing
        self.showsGrabber = showsGrabber
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            if showsGrabber { grabber }
            navigationBar
            content
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var statusBar: some View {
        HStack(spacing: 0) {
            Text("9:41")
                .font(.system(size: 11.5, weight: .semibold))
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Image(systemName: "cellularbars")
                Image(systemName: "wifi")
                Image(systemName: "battery.75")
            }
            .font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(palette.text)
        .padding(.horizontal, 18)
        .frame(height: 38)
    }

    private var grabber: some View {
        Capsule()
            .fill(palette.text.opacity(0.25))
            .frame(width: 34, height: 4)
            .padding(.top, 2)
            .padding(.bottom, 3)
    }

    private var navigationBar: some View {
        ZStack {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(palette.text)
            HStack(spacing: 0) {
                leadingView
                Spacer(minLength: 6)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(palette.accent)
                }
            }
        }
        .frame(height: 34)
        .padding(.horizontal, 12)
    }

    @ViewBuilder private var leadingView: some View {
        if let leading {
            switch leading {
            case .back(let label):
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                    Text(label)
                        .font(.system(size: 11))
                }
                .foregroundStyle(palette.accent)
            case .text(let label):
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.accent)
            }
        }
    }
}

/// Grouped form section matching the native sheets used by the editor.
@MainActor
struct InkribeScreenshotFormSection<Content: View>: View {
    let title: String?
    let palette: InkribeScreenshotPalette
    private let content: Content

    init(
        _ title: String? = nil,
        palette: InkribeScreenshotPalette,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.palette = palette
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 8.5, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(palette.secondary)
                    .padding(.horizontal, 11)
            }
            VStack(spacing: 0) { content }
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
struct InkribeScreenshotFormRow: View {
    let palette: InkribeScreenshotPalette
    let label: String
    var icon: String? = nil
    let value: String
    var showsChevron = false
    var valueColor: Color? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(palette.secondary)
                    .frame(width: 14)
            }
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(palette.text)
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(valueColor ?? palette.secondary)
                .lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7.5, weight: .semibold))
                    .foregroundStyle(palette.secondary)
            }
        }
        .frame(height: 34)
        .padding(.horizontal, 11)
    }
}

@MainActor
struct InkribeScreenshotFormDivider: View {
    let palette: InkribeScreenshotPalette

    var body: some View {
        palette.border
            .frame(height: 0.5)
            .padding(.leading, 11)
    }
}

@MainActor
struct InkribeScreenshotToggle: View {
    let palette: InkribeScreenshotPalette
    let isOn: Bool

    var body: some View {
        Capsule()
            .fill(isOn ? palette.accent : palette.border)
            .frame(width: 28, height: 17)
            .overlay(alignment: isOn ? Alignment.trailing : Alignment.leading) {
                Circle()
                    .fill(.white)
                    .frame(width: 13, height: 13)
                    .padding(2)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
            }
    }
}

@MainActor
struct InkribeScreenshotToggleRow: View {
    let palette: InkribeScreenshotPalette
    let label: String
    let isOn: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(palette.text)
            Spacer(minLength: 6)
            InkribeScreenshotToggle(palette: palette, isOn: isOn)
        }
        .frame(height: 34)
        .padding(.horizontal, 11)
    }
}

@MainActor
struct InkribeScreenshotSliderRow: View {
    let palette: InkribeScreenshotPalette
    let label: String
    let value: String
    let fraction: Double

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Text(label)
                Spacer(minLength: 6)
                Text(value).foregroundStyle(palette.secondary)
            }
            .font(.system(size: 11))
            .foregroundStyle(palette.text)
            InkribeScreenshotSlider(palette: palette, fraction: fraction)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
    }
}

@MainActor
struct InkribeScreenshotSlider: View {
    let palette: InkribeScreenshotPalette
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let filled = max(0, min(width, width * CGFloat(fraction)))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(palette.border)
                    .frame(height: 3)
                Capsule()
                    .fill(palette.accent)
                    .frame(width: filled, height: 3)
                Circle()
                    .fill(.white)
                    .frame(width: 12, height: 12)
                    .overlay { Circle().strokeBorder(palette.border, lineWidth: 0.5) }
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                    .offset(x: max(0, min(width - 12, filled - 6)))
            }
        }
        .frame(height: 12)
    }
}

@MainActor
struct InkribeScreenshotPrimaryButton: View {
    let palette: InkribeScreenshotPalette
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            Text(title).font(.system(size: 11.5, weight: .semibold))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .frame(height: 34)
        .background(palette.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Renderer-backed video sample. The snapshot is built synchronously in init,
/// unlike `CaptionTemplateThumbnail` whose `.task` may not finish before export.
@MainActor
struct InkribeScreenshotSampleFrame: View {
    private let snapshot: CaptionSnapshot?
    private let time: MediaTime?
    private let phase: Double

    init(style: CaptionStyle, seconds: Double = 3.5) {
        snapshot = try? CaptionStyleSample.snapshot(style: style)
        time = try? EditorTime.stamp(seconds)
        phase = seconds / CaptionStyleSample.duration
    }

    var body: some View {
        ZStack {
            CaptionSampleScenery(phase: phase)
            if let snapshot, let time {
                StyledCaptionOverlay(
                    snapshot: snapshot,
                    time: time,
                    mediaSize: CGSize(width: 1280, height: 720),
                    onError: { _ in }
                )
            }
        }
    }
}

/// A real catalog preset, rendered with the same synchronous sample pipeline
/// as the template grid but without a live session or lazy task.
@MainActor
struct InkribeScreenshotTemplateTile: View {
    let preset: CaptionPreset
    let palette: InkribeScreenshotPalette
    let selected: Bool
    private let snapshot: CaptionSnapshot?
    private let time: MediaTime?

    init(preset: CaptionPreset, palette: InkribeScreenshotPalette, selected: Bool) {
        self.preset = preset
        self.palette = palette
        self.selected = selected
        snapshot = try? CaptionStyleSample.snapshot(style: preset.resolved, thumbnail: true)
        time = try? EditorTime.stamp(CaptionStyleSample.previewSeconds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                CaptionSampleScenery(
                    phase: CaptionStyleSample.previewSeconds / CaptionStyleSample.duration
                )
                if let snapshot, let time {
                    StyledCaptionOverlay(
                        snapshot: snapshot,
                        time: time,
                        mediaSize: CGSize(width: 720, height: 720),
                        onError: { _ in }
                    )
                }
            }
            .frame(width: 90, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        selected ? palette.accent : palette.border.opacity(0.55),
                        lineWidth: selected ? 1.5 : 0.5
                    )
            }
            .overlay(alignment: .bottomTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, palette.accent)
                        .font(.system(size: 11))
                        .padding(4)
                }
            }

            Text(preset.name)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(palette.text)
                .lineLimit(1)
        }
        .frame(width: 90, alignment: .leading)
    }
}
#endif
