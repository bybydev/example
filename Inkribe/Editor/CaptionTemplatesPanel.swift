import SwiftUI

/// The editor summarizes saved values; sample browsing belongs to the sheet.
struct CaptionTemplatesPanel: View {
    let session: EditorSession
    let browse: () -> Void
    let customize: () -> Void
    private var style: CaptionStyle { session.editingCaptionStyle }
    private var reference: CaptionPreset {
        CaptionPreset.definition(for: style.preset) ?? CaptionPreset.matching(style) ?? .basic
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsScopePicker(session: session)
            Text(styleName).font(.headline)
            Text("\(style.font.name) · \(style.effect.name)").font(.subheadline).foregroundStyle(.secondary)
            Button("Browse animated styles", systemImage: "sparkles", action: browse)
                .buttonStyle(.borderedProminent).frame(minHeight: 44)
            Button("Customize captions", systemImage: "slider.horizontal.3", action: customize).frame(minHeight: 44)
            DisclosureGroup("Style details & resets") { details.padding(.top, 8) }
        }.studioCard()
    }

    private var styleName: String {
        guard let known = CaptionPreset.definition(for: style.preset) ?? CaptionPreset.matching(style) else { return "Customized" }
        return known.name + (known.matches(style) ? "" : " · Customized")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let saved = style.preset {
                Text("Saved preset · v\(saved.version)").font(.caption).foregroundStyle(.secondary)
                if CaptionPreset.definition(for: saved) == nil {
                    Text("This saved look is preserved. Its original reset preset is unavailable.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Position: \(Int((style.positionX * 100).rounded()))% across, \(Int((style.positionY * 100).rounded()))% down")
                .font(.caption).foregroundStyle(.secondary)
            Button("Reset look to \(reference.name)", systemImage: "arrow.counterclockwise") {
                session.endStyleEditing()
                session.setCaptionStyle(reference.preservingPosition(of: style), applyingPreset: true)
            }
            .disabled(session.access.isChecking || !session.access.canChangeStyle(from: style, to: reference.preservingPosition(of: style)))
            Button("Use \(reference.name) placement", systemImage: "viewfinder") {
                session.setCaptionStyle(style.resetting(.placement, to: reference.style))
            }
            if session.editingClipID != nil {
                Button("Reset captions to project defaults") { session.resetClipSettings() }
            }
            Button("Reset full style to Basic") {
                session.setCaptionStyle(CaptionPreset.basic.resolved, applyingPreset: true, preservingPlacement: false)
            }
        }
    }
}
