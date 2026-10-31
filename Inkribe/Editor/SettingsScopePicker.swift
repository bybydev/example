import SwiftUI

/// The first Form row owns the scope of every setting below it. Selection is
/// local to Media and never seeks playback or publishes a project edit.
struct SettingsScopePicker: View {
    @Bindable var draft: MediaDraft
    let document: ProjectDocument

    private var title: String {
        guard let id = draft.selectedClipID,
              let index = draft.clips.firstIndex(where: { $0.id == id }) else { return "Project" }
        return "Clip \(index + 1)"
    }
    private var accessibleTitle: String {
        guard let id = draft.selectedClipID,
              let clip = draft.clips.first(where: { $0.id == id }) else { return title }
        return title + " · " + document.clipName(clip)
    }

    var body: some View {
        Section {
            Menu {
                Picker("Settings for", selection: $draft.scope) {
                    Text("Project").tag(EditorSettingsScope.project)
                    ForEach(Array(draft.clips.enumerated()), id: \.element.id) { index, clip in
                        Text("Clip \(index + 1) · \(document.clipName(clip))")
                            .tag(EditorSettingsScope.clip(clip.id))
                    }
                }
            } label: {
                LabeledContent("Settings for") {
                    HStack(spacing: 6) {
                        Text(title).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .frame(minHeight: 24).contentShape(Rectangle())
            }
            .accessibilityLabel("Settings for")
            .accessibilityValue(accessibleTitle)
        } footer: {
            if let id = draft.selectedClipID, let clip = draft.clips.first(where: { $0.id == id }) {
                Text(document.clipName(clip))
            }
        }
    }
}
