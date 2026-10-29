import Foundation
import SwiftUI
import UIKit

enum CaptionStyleDestination: Hashable {
    case templates, font, spacing, outline, background, shadow, layout, animation
    var title: String {
        switch self {
        case .templates: "Templates"
        case .font: "Font"
        case .spacing: "Spacing"
        case .outline: "Outline"
        case .background: "Background"
        case .shadow: "Shadow"
        case .layout: "Text layout"
        case .animation: "Animation"
        }
    }
}

/// All form controls share one admission boundary and edit only the local draft.
@MainActor
struct CaptionStyleFormControls {
    let session: EditorSession
    let draft: CaptionStyleDraft
    var style: CaptionStyle { draft.style }

    @discardableResult func set(_ value: CaptionStyle) -> Bool {
        let accepted = draft.setStyle(value, access: session.access)
        if !accepted, draft.error == nil { session.pause(); session.proUpsell = .styles }
        return accepted
    }
    func value<T>(_ key: WritableKeyPath<CaptionStyle, T>) -> Binding<T> {
        Binding(get: { style[keyPath: key] }, set: { newValue in
            var next = style
            next[keyPath: key] = newValue
            set(next)
        })
    }
    func color(_ key: WritableKeyPath<CaptionStyle, CaptionColor>) -> Binding<Color> {
        Binding(get: {
            let c = style[keyPath: key]
            return Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
        }, set: { color in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
            var next = style
            next[keyPath: key] = CaptionColor(red: min(1, max(0, Double(r))), green: min(1, max(0, Double(g))),
                blue: min(1, max(0, Double(b))), alpha: min(1, max(0, Double(a))))
            set(next)
        })
    }
}

enum CaptionStyleFormValue {
    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
    static func weight(_ value: CaptionFontWeight) -> String { value == .original ? "Default" : value.name }
    static func color(_ c: CaptionColor) -> String {
        let palette: [(String, CaptionColor)] = [("White", .white), ("Black", .black), ("Mint", .mint), ("Pink", .pink), ("Yellow", .yellow)]
        let name = palette.first { _, value in
            abs(c.red - value.red) < 0.03 && abs(c.green - value.green) < 0.03 && abs(c.blue - value.blue) < 0.03
        }?.0 ?? String(format: "#%02X%02X%02X", Int((c.red * 255).rounded()), Int((c.green * 255).rounded()), Int((c.blue * 255).rounded()))
        return c.alpha < 0.995 ? name + " · " + percent(c.alpha) : name
    }
    static func spacing(_ style: CaptionStyle) -> String {
        if abs(style.tracking) < 0.0001 && abs(style.lineSpacing - 0.1) < 0.0001 { return "Default" }
        return "Letters \(percent(style.tracking)) · Lines \(percent(style.lineSpacing))"
    }
    static func layout(_ style: CaptionStyle) -> String {
        style.alignment.name + " · \(style.maximumLines) " + (style.maximumLines == 1 ? "line" : "lines")
    }
    static func placement(_ style: CaptionStyle) -> String {
        guard abs(style.positionX - 0.5) < 0.001 else { return "Custom" }
        if abs(style.positionY - 0.18) < 0.001 { return "Top" }
        if abs(style.positionY - 0.5) < 0.001 { return "Center" }
        if abs(style.positionY - 0.82) < 0.001 { return "Bottom" }
        return "Custom"
    }
}

/// Native form sections below Template. Secondary settings are compound rows;
/// small menus and the inline Size control avoid unnecessary navigation.
struct CaptionStylePanel: View {
    let session: EditorSession
    let draft: CaptionStyleDraft
    private var controls: CaptionStyleFormControls { .init(session: session, draft: draft) }
    private var style: CaptionStyle { draft.style }

    var body: some View {
        Group { textSection; colorSection; appearanceSection; layoutSection; motionSection }
            .disabled(session.access.isChecking)
    }
    private var textSection: some View {
        Section("Text") {
            NavigationLink(value: CaptionStyleDestination.font) { LabeledContent("Font", value: style.font.name) }
            Picker("Weight", selection: controls.value(\.weight)) {
                ForEach(CaptionFontWeight.allCases, id: \.self) { weight in
                    Text(CaptionStyleFormValue.weight(weight)).tag(weight)
                }
            }.pickerStyle(.menu)
            DisclosureGroup {
                Slider(value: controls.value(\.fontSize), in: 0.025...0.12)
                    .accessibilityLabel("Text size").accessibilityValue(CaptionStyleFormValue.percent(style.fontSize))
            } label: { LabeledContent("Size", value: CaptionStyleFormValue.percent(style.fontSize)) }
            NavigationLink(value: CaptionStyleDestination.spacing) {
                LabeledContent("Spacing", value: CaptionStyleFormValue.spacing(style))
            }
        }
    }
    private var colorSection: some View {
        Section("Colors") {
            CaptionStyleColorRow(title: "Text", value: style.textColor, selection: controls.color(\.textColor))
            if [.highlight, .karaoke, .emphasis, .underline].contains(style.effect) {
                CaptionStyleColorRow(title: "Highlight", value: style.accentColor, selection: controls.color(\.accentColor))
            }
        }
    }
    private var appearanceSection: some View {
        Section("Appearance") {
            NavigationLink(value: CaptionStyleDestination.outline) {
                LabeledContent("Outline", value: style.outlineWidth == 0 ? "Off" :
                    CaptionStyleFormValue.color(style.outlineColor) + " · " + CaptionStyleFormValue.percent(style.outlineWidth))
            }
            NavigationLink(value: CaptionStyleDestination.background) {
                LabeledContent("Background", value: style.backgroundEnabled ?
                    CaptionStyleFormValue.color(style.backgroundColor) + " · " + style.backgroundMode.name : "Off")
            }
            NavigationLink(value: CaptionStyleDestination.shadow) {
                LabeledContent("Shadow", value: style.shadowEnabled ?
                    CaptionStyleFormValue.color(style.shadowColor) + " · " + CaptionStyleFormValue.percent(style.shadowBlur) : "Off")
            }
        }
    }
    private var layoutSection: some View {
        Section("Layout") {
            NavigationLink(value: CaptionStyleDestination.layout) {
                LabeledContent("Text layout", value: CaptionStyleFormValue.layout(style))
            }
            Menu {
                Button("Top") { placeCaptions(y: 0.18) }
                Button("Center") { placeCaptions(y: 0.5) }
                Button("Bottom") { placeCaptions(y: 0.82) }
            } label: {
                LabeledContent("Caption placement", value: CaptionStyleFormValue.placement(style))
            }
            DisclosureGroup {
                placementSlider("Horizontal", key: \.positionX)
                placementSlider("Vertical", key: \.positionY)
            } label: {
                LabeledContent("Fine position", value:
                    "X \(CaptionStyleFormValue.percent(style.positionX)) · Y \(CaptionStyleFormValue.percent(style.positionY))")
            }
        }
    }
    private func placeCaptions(y: Double) {
        var next = style
        next.positionX = 0.5; next.positionY = y
        controls.set(next)
    }
    private func placementSlider(_ title: String, key: WritableKeyPath<CaptionStyle, Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title, value: CaptionStyleFormValue.percent(style[keyPath: key]))
            Slider(value: controls.value(key), in: 0...1)
                .accessibilityLabel("Caption " + title.lowercased())
                .accessibilityValue(CaptionStyleFormValue.percent(style[keyPath: key]))
        }
    }
    private var motionSection: some View {
        Section("Motion") {
            NavigationLink(value: CaptionStyleDestination.animation) { LabeledContent("Animation", value: style.effect.name) }
        }
    }
}

struct CaptionStyleColorRow: View {
    let title: String
    let value: CaptionColor
    let selection: Binding<Color>
    var body: some View {
        ColorPicker(selection: selection, supportsOpacity: true) {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                Text(CaptionStyleFormValue.color(value)).foregroundStyle(.secondary).font(.subheadline)
            }
        }
        .accessibilityValue(CaptionStyleFormValue.color(value))
    }
}
