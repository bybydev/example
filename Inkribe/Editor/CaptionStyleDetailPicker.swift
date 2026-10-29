import AppFoundation
import SwiftUI

/// Native pushed forms edit the outer Cancel/Done transaction; preview stays in Style.
struct CaptionStyleDetailPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appFoundationTheme) private var theme
    let session: EditorSession
    let draft: CaptionStyleDraft
    let destination: CaptionStyleDestination
    @State private var rememberedOutline = 0.045
    private var controls: CaptionStyleFormControls { .init(session: session, draft: draft) }
    private var style: CaptionStyle { draft.style }

    var body: some View {
        Form {
            detailSections
                .listRowBackground(theme.surfaceColor)
                .listRowSeparatorTint(theme.borderColor)
                .disabled(session.access.isChecking || session.isSavingCaptionStyle)
            if let error = draft.error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.footnote) }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(destination.title).navigationBarTitleDisplayMode(.inline).themedSurface()
        .onAppear { if style.outlineWidth > 0 { rememberedOutline = style.outlineWidth } }
    }

    @ViewBuilder private var detailSections: some View {
        switch destination {
        case .font: fontChoices
        case .animation: animationChoices
        case .spacing: spacingControls
        case .outline: outlineControls
        case .background: backgroundControls
        case .shadow: shadowControls
        case .layout: layoutControls
        case .templates: EmptyView()
        }
    }
    private var fontChoices: some View {
        Section("Font") {
            ForEach(CaptionFont.allCases, id: \.self) { font in
                let next = fontStyle(font)
                choice(font.name, selected: style.font == font, next: next)
            }
        }
    }
    private var animationChoices: some View {
        Section("Animation") {
            ForEach(CaptionEffect.allCases, id: \.self) { effect in
                let next = effectStyle(effect)
                choice(effect.name, selected: style.effect == effect, next: next)
            }
        }
    }
    private func fontStyle(_ font: CaptionFont) -> CaptionStyle { var next = style; next.font = font; return next }
    private func effectStyle(_ effect: CaptionEffect) -> CaptionStyle {
        var next = style; next.effect = effect; next.formatVersion = 2; return next
    }
    private func choice(_ title: String, selected: Bool, next: CaptionStyle) -> some View {
        let locked = !session.access.canChangeStyle(from: style, to: next)
        return Button {
            if controls.set(next) { dismiss() }
        } label: {
            HStack(spacing: 10) {
                Text(title).foregroundStyle(.primary)
                Spacer(minLength: 8)
                if locked { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
                if selected { Image(systemName: "checkmark").foregroundStyle(theme.accentColor) }
            }
            .frame(minHeight: 30).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title + (locked ? ", Pro" : ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var spacingControls: some View {
        Section("Spacing") {
            slider("Letter spacing", key: \.tracking, range: -0.02...0.1)
            slider("Line spacing", key: \.lineSpacing, range: 0...0.8)
        }
    }
    private var outlineControls: some View {
        Section("Outline") {
            Toggle("Outline", isOn: Binding(get: { style.outlineWidth > 0 }, set: { enabled in
                var next = style
                if !enabled { rememberedOutline = max(0.005, style.outlineWidth) }
                next.outlineWidth = enabled ? rememberedOutline : 0
                controls.set(next)
            }))
            if style.outlineWidth > 0 {
                CaptionStyleColorRow(title: "Color", value: style.outlineColor, selection: controls.color(\.outlineColor))
                slider("Thickness", key: \.outlineWidth, range: 0.005...0.12)
            }
        }
    }
    private var backgroundControls: some View {
        Section("Caption background") {
            Toggle("Background", isOn: controls.value(\.backgroundEnabled))
            if style.backgroundEnabled {
                CaptionStyleColorRow(title: "Color", value: style.backgroundColor, selection: controls.color(\.backgroundColor))
                Picker("Shape", selection: controls.value(\.backgroundMode)) {
                    ForEach(CaptionBackgroundMode.allCases, id: \.self) { Text($0.name).tag($0) }
                }.pickerStyle(.menu)
                slider("Padding", key: \.backgroundPadding, range: 0...0.6)
                slider("Corner radius", key: \.backgroundRadius, range: 0...1)
            }
        }
    }
    private var shadowControls: some View {
        Section("Text shadow") {
            Toggle("Shadow", isOn: controls.value(\.shadowEnabled))
            if style.shadowEnabled {
                CaptionStyleColorRow(title: "Color", value: style.shadowColor, selection: controls.color(\.shadowColor))
                slider("Softness", key: \.shadowBlur, range: 0...1)
                DisclosureGroup("Offsets") {
                    slider("Horizontal", key: \.shadowOffsetX, range: -1...1)
                    slider("Vertical", key: \.shadowOffsetY, range: -1...1)
                }
            }
        }
    }
    @ViewBuilder private var layoutControls: some View {
        Section("Text layout") {
            Picker("Alignment", selection: controls.value(\.alignment)) {
                ForEach(CaptionAlignment.allCases, id: \.self) { Text($0.name).tag($0) }
            }.pickerStyle(.menu)
            Picker("Maximum lines", selection: controls.value(\.maximumLines)) {
                ForEach(1...8, id: \.self) { Text("\($0)").tag($0) }
            }.pickerStyle(.menu)
            slider("Text width", key: \.lineWidth, range: 0.4...1)
        }
        Section("Long captions") {
            Toggle("Auto-fit", isOn: Binding(get: { style.minimumScale < 1 }, set: { enabled in
                var next = style; next.minimumScale = enabled ? 0.65 : 1; controls.set(next)
            }))
            if style.minimumScale < 1 { slider("Minimum size", key: \.minimumScale, range: 0.5...1) }
        }
    }
    private func slider(_ title: String, key: WritableKeyPath<CaptionStyle, Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title, value: CaptionStyleFormValue.percent(style[keyPath: key]))
            Slider(value: controls.value(key), in: range)
                .accessibilityLabel(title).accessibilityValue(CaptionStyleFormValue.percent(style[keyPath: key]))
        }
    }
}
