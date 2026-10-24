import SwiftUI
import AppFoundation
import UIKit

enum CaptionStyleSection: String, CaseIterable, Hashable, Identifiable {
    case typography = "Text", colors = "Colors", outline = "Backdrop", layout = "Layout", position = "Position", motion = "Motion"
    var id: Self { self }
}

struct CaptionStylePanel: View {
    let session: EditorSession
    let section: CaptionStyleSection
    private var style: CaptionStyle { session.editingCaptionStyle }
    private var baseline: CaptionStyle { CaptionPreset.definition(for: style.preset)?.style ?? .standard }
    private var resetName: String { CaptionPreset.definition(for: style.preset)?.name ?? "Basic" }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(section.rawValue).font(.headline)
            controls
            if let id = session.editingClipID, let document = session.document {
                Label(document.settings(for: id).captions.isCustomized(resetKind) ? "Customized" : "Using project defaults",
                      systemImage: document.settings(for: id).captions.isCustomized(resetKind) ? "slider.horizontal.3" : "link")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Reset section to project defaults", systemImage: "arrow.counterclockwise") {
                    session.resetClipSettings(captions: resetKind)
                }
            } else {
                Button("Reset \(section.rawValue.lowercased()) to \(resetName)", systemImage: "arrow.counterclockwise") { resetSection() }
            }
        }
        .studioCard()
        .onDisappear { session.endStyleEditing() }
    }

    @ViewBuilder
    private var controls: some View {
        switch section {
        case .typography:
            Picker("Font", selection: value(\.font)) {
                ForEach(CaptionFont.allCases, id: \.self) { font in
                    Text(font.name + (!session.access.hasPro && font != .modern ? " · Pro" : "")).tag(font)
                }
            }
            .disabled(session.access.isChecking)
            Picker("Weight", selection: value(\.weight)) {
                ForEach(CaptionFontWeight.allCases, id: \.self) { weight in
                    Text(weight.name + (!session.access.hasPro && weight != .original ? " · Pro" : "")).tag(weight)
                }
            }
            .disabled(session.access.isChecking)
            slider("Letter spacing · Pro", value: value(\.tracking, control: .tracking), range: -0.02...0.1,
                display: "\(Int((style.tracking * 100).rounded()))%")
            slider("Size", value: value(\.fontSize, control: .size), range: 0.025...0.12,
                display: "\(Int((style.fontSize * 100).rounded()))%")
        case .colors:
            ColorPicker("Text color", selection: color(\.textColor, control: .textColor), supportsOpacity: true)
            if [.highlight, .karaoke, .emphasis, .underline].contains(style.effect) {
                ColorPicker("Highlight color", selection: color(\.accentColor, control: .accentColor), supportsOpacity: true)
            }
        case .outline: backdropControls
        case .layout: layoutControls
        case .position:
            ViewThatFits(in: .horizontal) {
                HStack { placementButtons }
                VStack(alignment: .leading) { placementButtons }
            }
            slider("Horizontal", value: value(\.positionX, control: .horizontalPosition), range: 0...1,
                display: "\(Int((style.positionX * 100).rounded()))%")
            slider("Vertical", value: value(\.positionY, control: .verticalPosition), range: 0...1,
                display: "\(Int((style.positionY * 100).rounded()))%")
        case .motion:
            Picker("Animation", selection: value(\.effect, modern: true)) {
                ForEach(CaptionEffect.allCases, id: \.self) { effect in
                    Text(effect.name + (!session.access.hasPro && effect != .none ? " · Pro" : "")).tag(effect)
                }
            }
            .disabled(session.access.isChecking)
            Text("Play or scrub to inspect motion. Phrase-timed captions animate as whole phrases.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var backdropControls: some View {
        VStack(alignment: .leading, spacing: 18) {
            slider("Outline", value: value(\.outlineWidth, control: .outlineWidth), range: 0...0.12,
                display: style.outlineWidth == 0 ? "Off" : "\(Int((style.outlineWidth * 100).rounded()))%")
            if style.outlineWidth > 0 {
                ColorPicker("Outline color", selection: color(\.outlineColor, control: .outlineColor), supportsOpacity: true)
            }
            Toggle("Background", isOn: value(\.backgroundEnabled))
            if style.backgroundEnabled {
                ColorPicker("Background color", selection: color(\.backgroundColor, control: .backgroundColor), supportsOpacity: true)
            }
            Picker("Background shape · Pro", selection: value(\.backgroundMode)) {
                ForEach(CaptionBackgroundMode.allCases, id: \.self) { Text($0.name).tag($0) }
            }
            slider("Box padding · Pro", value: value(\.backgroundPadding, control: .backgroundPadding), range: 0...0.6,
                display: "\(Int((style.backgroundPadding * 100).rounded()))%")
            slider("Corner radius · Pro", value: value(\.backgroundRadius, control: .backgroundRadius), range: 0...1,
                display: "\(Int((style.backgroundRadius * 100).rounded()))%")
            Toggle("Text shadow · Pro", isOn: value(\.shadowEnabled))
            if style.shadowEnabled {
                ColorPicker("Shadow color", selection: color(\.shadowColor, control: .shadowColor), supportsOpacity: true)
                slider("Shadow softness", value: value(\.shadowBlur, control: .shadowBlur), range: 0...1,
                    display: "\(Int((style.shadowBlur * 100).rounded()))%")
                slider("Shadow horizontal", value: value(\.shadowOffsetX, control: .shadowX), range: -1...1,
                    display: "\(Int((style.shadowOffsetX * 100).rounded()))%")
                slider("Shadow vertical", value: value(\.shadowOffsetY, control: .shadowY), range: -1...1,
                    display: "\(Int((style.shadowOffsetY * 100).rounded()))%")
            }
        }
    }

    private var layoutControls: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !session.access.hasPro { Label("Pro layout controls", systemImage: "lock").font(.caption).foregroundStyle(.secondary) }
            Picker("Alignment", selection: value(\.alignment)) {
                ForEach(CaptionAlignment.allCases, id: \.self) { Text($0.name).tag($0) }
            }
            Picker("Maximum lines", selection: value(\.maximumLines)) {
                ForEach(1...8, id: \.self) { Text("\($0)").tag($0) }
            }
            slider("Text width", value: value(\.lineWidth, control: .lineWidth), range: 0.4...1,
                display: "\(Int((style.lineWidth * 100).rounded()))%")
            slider("Line spacing", value: value(\.lineSpacing, control: .lineSpacing), range: 0...0.8,
                display: "\(Int((style.lineSpacing * 100).rounded()))%")
            Toggle("Fit long captions · Pro", isOn: Binding(get: { style.minimumScale < 1 }, set: {
                var next = style; next.minimumScale = $0 ? 0.65 : 1; session.setCaptionStyle(next)
            }))
            if style.minimumScale < 1 {
                slider("Minimum size", value: value(\.minimumScale, control: .minimumScale), range: 0.5...1,
                    display: "\(Int((style.minimumScale * 100).rounded()))% of chosen size")
            }
            Text("Wrapping changes the look without splitting your captions. Long captions stop shrinking at the minimum size.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var resetKind: CaptionStyleReset {
        switch section {
        case .typography: .typography
        case .colors: .colors
        case .outline: .backdrop
        case .layout: .layout
        case .position: .placement
        case .motion: .motion
        }
    }
    private func resetSection() { session.setCaptionStyle(style.resetting(resetKind, to: baseline)) }

    private var placementButtons: some View {
        Group {
            Button("Top") { place(0.18) }
            Button("Center") { place(0.5) }
            Button("Bottom") { place(0.82) }
        }
        .buttonStyle(.bordered)
    }
    private func place(_ y: Double) {
        var next = style
        next.positionX = 0.5; next.positionY = y
        session.setCaptionStyle(next)
    }
    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, display: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title); Spacer(); Text(display).monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: value, in: range, onEditingChanged: { _ in session.endStyleEditing() })
                .accessibilityLabel(title)
                .accessibilityValue(display)
        }
    }
    private func value<T>(_ key: WritableKeyPath<CaptionStyle, T>, control: CaptionStyleControl? = nil, modern: Bool = false) -> Binding<T> {
        Binding(get: { style[keyPath: key] }, set: { newValue in
            var next = style
            next[keyPath: key] = newValue
            if modern { next.formatVersion = 2 }
            session.setCaptionStyle(next, coalescing: control)
        })
    }
    private func color(_ key: WritableKeyPath<CaptionStyle, CaptionColor>, control: CaptionStyleControl) -> Binding<Color> {
        Binding(get: {
            let color = style[keyPath: key]
            return Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
        }, set: { newColor in
            var red: CGFloat = 0; var green: CGFloat = 0; var blue: CGFloat = 0; var alpha: CGFloat = 0
            guard UIColor(newColor).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return }
            var next = style
            next[keyPath: key] = CaptionColor(red: min(1, max(0, Double(red))),
                green: min(1, max(0, Double(green))), blue: min(1, max(0, Double(blue))),
                alpha: min(1, max(0, Double(alpha))))
            session.setCaptionStyle(next, coalescing: control)
        })
    }
}
