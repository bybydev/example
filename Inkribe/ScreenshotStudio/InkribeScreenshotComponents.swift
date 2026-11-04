#if DEBUG
import AppFoundation
import SwiftUI

struct InkribeScreenshotPalette {
    let theme: AppTheme
    var text: Color { theme.primaryForegroundColor }
    var secondary: Color { theme.secondaryForegroundColor }
    var accent: Color { theme.accentColor }
    var surface: Color { theme.surfaceColor }
    var soft: Color { theme.elevatedSurfaceColor }
    var border: Color { theme.borderColor }
}

@MainActor
struct InkribeScreenshotPanel<Content: View>: View {
    let palette: InkribeScreenshotPalette
    private let content: Content

    init(palette: InkribeScreenshotPalette, @ViewBuilder content: () -> Content) {
        self.palette = palette
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 22))
            .shadow(color: .black.opacity(0.08), radius: 14, y: 8)
    }
}

@MainActor
struct InkribeScreenshotPanelTitle: View {
    let title: String
    let symbol: String
    let palette: InkribeScreenshotPalette

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

/// Authored artwork with fixed geometry. It reads no media and performs no work on appearance.
@MainActor
struct InkribeScreenshotScenery: View {
    var body: some View {
        Canvas(opaque: true, rendersAsynchronously: false) { context, size in
            let width = size.width, height = size.height
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                Gradient(colors: [Color(red: 0.60, green: 0.79, blue: 0.82),
                                  Color(red: 0.91, green: 0.83, blue: 0.63)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: height)))
            context.fill(Path(ellipseIn: CGRect(x: width * 0.57, y: height * 0.13,
                width: width * 0.31, height: width * 0.31)),
                with: .color(Color(red: 1, green: 0.93, blue: 0.70)))

            var distant = Path()
            distant.move(to: CGPoint(x: -width * 0.1, y: height * 0.75))
            distant.addQuadCurve(to: CGPoint(x: width * 1.1, y: height * 0.52),
                control: CGPoint(x: width * 0.40, y: height * 0.19))
            distant.addLine(to: CGPoint(x: width * 1.1, y: height))
            distant.addLine(to: CGPoint(x: -width * 0.1, y: height))
            distant.closeSubpath()
            context.fill(distant, with: .color(Color(red: 0.45, green: 0.59, blue: 0.54)))

            var near = Path()
            near.move(to: CGPoint(x: 0, y: height * 0.69))
            near.addCurve(to: CGPoint(x: width, y: height * 0.59),
                control1: CGPoint(x: width * 0.24, y: height * 0.22),
                control2: CGPoint(x: width * 0.67, y: height * 0.40))
            near.addLine(to: CGPoint(x: width, y: height))
            near.addLine(to: CGPoint(x: 0, y: height))
            near.closeSubpath()
            context.fill(near, with: .color(Color(red: 0.24, green: 0.42, blue: 0.38)))

            let body = CGRect(x: width * 0.44, y: height * 0.48,
                width: width * 0.14, height: height * 0.34)
            context.fill(Capsule().path(in: body),
                with: .color(Color(red: 0.79, green: 0.47, blue: 0.33)))
            context.fill(Capsule().path(in: CGRect(x: width * 0.56, y: height * 0.54,
                width: width * 0.055, height: height * 0.21)),
                with: .color(Color(red: 0.66, green: 0.62, blue: 0.45)))
            context.fill(Path(ellipseIn: CGRect(x: width * 0.48, y: height * 0.39,
                width: width * 0.06, height: height * 0.11)),
                with: .color(Color(red: 0.24, green: 0.19, blue: 0.16)))

            var foreground = Path()
            foreground.move(to: CGPoint(x: 0, y: height * 0.84))
            foreground.addQuadCurve(to: CGPoint(x: width, y: height * 0.78),
                control: CGPoint(x: width * 0.44, y: height * 0.59))
            foreground.addLine(to: CGPoint(x: width, y: height))
            foreground.addLine(to: CGPoint(x: 0, y: height))
            foreground.closeSubpath()
            context.fill(foreground, with: .color(Color(red: 0.13, green: 0.29, blue: 0.25)))
        }
        .accessibilityHidden(true)
    }
}

@MainActor
struct InkribeScreenshotVideo: View {
    var captionSize: CGFloat = 32
    var captionBottom: CGFloat = 24
    var showsTime = false

    var body: some View {
        InkribeScreenshotScenery()
            .overlay(alignment: .bottom) {
                VStack(spacing: 0) {
                    Text("Make time for").foregroundStyle(.white)
                    Text("what matters.").foregroundStyle(Color(red: 0.55, green: 0.89, blue: 1))
                }
                .font(.system(size: captionSize, weight: .heavy))
                .tracking(-0.8)
                .multilineTextAlignment(.center)
                .shadow(color: .black.opacity(0.2), radius: 3, y: 2)
                .padding(.horizontal, 10)
                .padding(.bottom, captionBottom)
            }
            .overlay(alignment: .topLeading) {
                if showsTime {
                    Text("00:08 / 00:24")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(Color(red: 0.09, green: 0.20, blue: 0.18).opacity(0.8),
                                    in: RoundedRectangle(cornerRadius: 7))
                        .padding(10)
                }
            }
            .frame(maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

@MainActor
struct InkribeScreenshotTransport: View {
    let palette: InkribeScreenshotPalette

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "backward.end")
            Image(systemName: "play")
            Image(systemName: "forward.end")
            Spacer(minLength: 8)
            Text("00:08 / 00:24").font(.system(size: 11)).monospacedDigit()
            Spacer(minLength: 8)
            Text("1×").font(.system(size: 12))
            Image(systemName: "arrow.up.left.and.arrow.down.right")
        }
        .font(.system(size: 14))
        .foregroundStyle(palette.secondary)
        .frame(height: 44)
    }
}

@MainActor
struct InkribeScreenshotRuler: View {
    let palette: InkribeScreenshotPalette

    var body: some View {
        HStack {
            Text("00:00")
            Spacer()
            Text("00:08")
            Spacer()
            Text("00:16")
            Spacer()
            Text("00:24")
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .foregroundStyle(palette.secondary)
        .padding(.bottom, 8)
    }
}

@MainActor
struct InkribeScreenshotFilmstrip: View {
    var height: CGFloat = 40

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<6, id: \.self) { _ in
                InkribeScreenshotScenery()
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

@MainActor
struct InkribeScreenshotCaptionTrack: View {
    let palette: InkribeScreenshotPalette
    var labels = ["Slow down.", "Make time…", "Start here."]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(labels.enumerated()), id: \.offset) { item in
                Text(item.element)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 7)
                    .frame(height: 25)
                    .foregroundStyle(palette.text)
                    .background(palette.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }
}

@MainActor
struct InkribeScreenshotWaveform: View {
    let palette: InkribeScreenshotPalette
    private let heights: [CGFloat] = [7, 12, 18, 10, 22, 14, 27, 18, 9, 16, 24, 12,
        20, 27, 15, 8, 19, 25, 13, 22, 10, 17, 25, 15, 8, 20, 27, 12, 19, 14, 23, 9, 16, 25, 12, 7]

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let step = size.width / CGFloat(heights.count)
            for (index, height) in heights.enumerated() {
                let rect = CGRect(x: CGFloat(index) * step + 2, y: (size.height - height) / 2,
                    width: max(1, step - 4), height: height)
                context.fill(RoundedRectangle(cornerRadius: 2).path(in: rect), with: .color(palette.accent))
            }
        }
        .frame(height: 34)
        .background(palette.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityHidden(true)
    }
}

@MainActor
struct InkribeScreenshotSettingRow: View {
    let title: String
    let value: String
    let palette: InkribeScreenshotPalette
    var showsChevron = false

    var body: some View {
        HStack(spacing: 10) {
            Text(title).foregroundStyle(palette.text)
            Spacer(minLength: 8)
            Text(value).foregroundStyle(palette.secondary)
            if showsChevron {
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(palette.secondary)
            }
        }
        .font(.system(size: 13))
        .frame(minHeight: 48)
    }
}

@MainActor
struct InkribeScreenshotActionBar: View {
    let palette: InkribeScreenshotPalette
    private let items = [("Clips", "film"), ("Captions", "captions.bubble"),
        ("Style", "sparkles"), ("Media", "slider.horizontal.3"), ("Export", "square.and.arrow.up")]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.0) { item in
                VStack(spacing: 7) {
                    Image(systemName: item.1).font(.system(size: 16))
                    Text(item.0).font(.system(size: 11))
                }
                .frame(maxWidth: .infinity)
                .foregroundStyle(item.0 == "Captions" ? palette.accent : palette.secondary)
            }
        }
        .padding(.top, 16)
        .padding(.bottom, 4)
        .overlay(alignment: .top) { palette.border.frame(height: 0.5) }
    }
}
#endif
