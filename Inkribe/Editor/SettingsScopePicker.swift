import SwiftUI

/// Scope stays explicit while playback crosses clip boundaries.
struct SettingsScopePicker: View {
    let session: EditorSession
    var body: some View {
        if let document = session.document {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Apply settings to", selection: Binding(get: { session.workspace.settingsScope }, set: { session.selectSettingsScope($0) })) {
                    Text("Project defaults").tag(EditorSettingsScope.project)
                    ForEach(Array(document.orderedClips.enumerated()), id: \.element.id) { index, clip in
                        Text("This clip · \(index + 1): \(document.clipName(clip))").tag(EditorSettingsScope.clip(clip.id))
                    }
                }
                if let id = session.editingClipID {
                    let customized = document.settings(for: id).hasOverrides
                    Label(customized ? "Customized" : "Using project defaults", systemImage: customized ? "slider.horizontal.3" : "link")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Reset all settings to project defaults", systemImage: "arrow.counterclockwise") {
                        session.resetClipSettings(all: true)
                    }.disabled(!customized)
                } else {
                    Text("Clips inherit these values unless a setting is customized.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .onChange(of: document.clips.map(\.id)) { _, ids in
                if let id = session.editingClipID, !ids.contains(id) { session.selectSettingsScope(.project) }
            }
        }
    }
}
