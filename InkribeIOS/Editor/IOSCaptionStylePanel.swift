import SwiftUI
import UIKit

struct IOSCaptionStylePanel: View {
    let session: IOSEditorSession
    private var style: IOSCaptionStyle { session.document?.effectiveCaptionStyle ?? .standard }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Caption style").font(.headline)
            Picker("Font", selection: value(\.font)) {
                ForEach(IOSCaptionFont.allCases, id: \.self) { font in Text(font.name).tag(font) }
            }
            .pickerStyle(.segmented)
            slider("Size", value: value(\.fontSize, control: .size), range: 0.025...0.12,
                   display: "\(Int((style.fontSize * 100).rounded()))%")
            ColorPicker("Text color", selection: color(\.textColor, control: .textColor), supportsOpacity: true)
            Picker("Animation", selection: value(\.effect)) {
                ForEach(IOSCaptionEffect.allCases, id: \.self) { effect in Text(effect.name).tag(effect) }
            }
            if style.effect == .highlight || style.effect == .karaoke {
                ColorPicker("Highlight color", selection: color(\.accentColor, control: .accentColor), supportsOpacity: true)
            }
            DisclosureGroup("Outline and background") {
                VStack(spacing: 14) {
                    slider("Outline", value: value(\.outlineWidth, control: .outlineWidth), range: 0...0.12,
                           display: style.outlineWidth == 0 ? "Off" : "\(Int((style.outlineWidth * 100).rounded()))%")
                    if style.outlineWidth > 0 {
                        ColorPicker("Outline color", selection: color(\.outlineColor, control: .outlineColor), supportsOpacity: true)
                    }
                    Toggle("Background", isOn: value(\.backgroundEnabled))
                    if style.backgroundEnabled {
                        ColorPicker("Background color", selection: color(\.backgroundColor, control: .backgroundColor), supportsOpacity: true)
                    }
                }
                .padding(.top, 12)
            }
            DisclosureGroup("Position") {
                VStack(alignment: .leading, spacing: 14) {
                    ViewThatFits(in: .horizontal) {
                        HStack { placementButtons }
                        VStack(alignment: .leading) { placementButtons }
                    }
                    slider("Horizontal", value: value(\.positionX, control: .horizontalPosition), range: 0...1,
                           display: "\(Int((style.positionX * 100).rounded()))%")
                    slider("Vertical", value: value(\.positionY, control: .verticalPosition), range: 0...1,
                           display: "\(Int((style.positionY * 100).rounded()))%")
                }
                .padding(.top, 12)
            }
            Button("Reset style", systemImage: "arrow.counterclockwise") { session.setCaptionStyle(.standard) }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onDisappear { session.endStyleEditing() }
    }

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
    private func value<T>(_ key: WritableKeyPath<IOSCaptionStyle, T>, control: IOSCaptionStyleControl? = nil) -> Binding<T> {
        Binding(get: { style[keyPath: key] }, set: { newValue in
            var next = style
            next[keyPath: key] = newValue
            session.setCaptionStyle(next, coalescing: control)
        })
    }
    private func color(_ key: WritableKeyPath<IOSCaptionStyle, IOSCaptionColor>, control: IOSCaptionStyleControl) -> Binding<Color> {
        Binding(get: {
            let color = style[keyPath: key]
            return Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
        }, set: { newColor in
            var red: CGFloat = 0; var green: CGFloat = 0; var blue: CGFloat = 0; var alpha: CGFloat = 0
            guard UIColor(newColor).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return }
            var next = style
            next[keyPath: key] = IOSCaptionColor(red: min(1, max(0, Double(red))),
                green: min(1, max(0, Double(green))), blue: min(1, max(0, Double(blue))),
                alpha: min(1, max(0, Double(alpha))))
            session.setCaptionStyle(next, coalescing: control)
        })
    }
}

struct IOSCaptionTemplatesPanel: View {
    let session: IOSEditorSession
    private var style: IOSCaptionStyle { session.document?.effectiveCaptionStyle ?? .standard }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Caption templates").font(.headline)
            Text("Choose a look, then play to preview it on your video.")
                .font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                ForEach(IOSCaptionTemplate.allCases) { template in
                    let look = positioned(template)
                    Button {
                        session.setCaptionStyle(look)
                    } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Image(systemName: "captions.bubble.fill")
                                    .foregroundStyle(Color(.sRGB, red: look.accentColor.red,
                                        green: look.accentColor.green, blue: look.accentColor.blue, opacity: 1))
                                Spacer()
                                if style == look { Image(systemName: "checkmark.circle.fill").foregroundStyle(.purple) }
                            }
                            Text(template.name).font(.headline)
                            Text("\(look.font.name) · \(look.effect.name)").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(style == look ? Color.purple : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(template.name), \(look.effect.name)")
                    .accessibilityAddTraits(style == look ? .isSelected : [])
                }
            }
        }
        .onDisappear { session.endStyleEditing() }
    }
    private func positioned(_ template: IOSCaptionTemplate) -> IOSCaptionStyle {
        var look = template.style
        // Changing the look preserves the user's chosen output placement.
        look.positionX = style.positionX; look.positionY = style.positionY
        return look
    }
}
