import AppFoundation
import SwiftUI

/// Catalog-sized lazy browsing. Tiles are still samples, never independent
/// players or animation loops. Selection edits the parent draft and pops back.
struct CaptionTemplatesGrid: View {
    @Environment(\.appFoundationTheme) private var theme
    let session: EditorSession
    let draft: CaptionStyleDraft
    let onSelect: (CaptionPreset) -> Void
    private let presets = CaptionPreset.catalog
    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 180), spacing: 12, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                    ForEach(presets) { preset in tile(preset) }
                }
                if let error = draft.error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                }
            }
            .padding(16)
        }
        .navigationTitle("Templates").navigationBarTitleDisplayMode(.inline).themedSurface()
    }

    private func tile(_ preset: CaptionPreset) -> some View {
        let selected = draft.style.preset == preset.reference ||
            (draft.style.preset == nil && preset.matches(draft.style))
        let locked = !session.access.canChangeStyle(from: draft.style, to: preset.preservingPosition(of: draft.style))
        return Button { onSelect(preset) } label: {
            VStack(alignment: .leading, spacing: 8) {
                CaptionTemplateThumbnail(preset: preset)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(selected ? theme.accentColor : Color.clear, lineWidth: 2)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill").symbolRenderingMode(.palette)
                                .foregroundStyle(.white, theme.accentColor).padding(6)
                                .accessibilityHidden(true)
                        }
                    }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(preset.name).font(.caption.weight(.medium)).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if locked {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(session.access.isChecking)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(preset.name + (locked ? ", Pro" : ""))
        .accessibilityValue(selected ? "Selected" : preset.detail)
        .accessibilityHint("Select template and return to Style. Done saves the changes.")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
