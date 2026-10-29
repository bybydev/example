import SwiftUI

/// Scope stays explicit while playback crosses clip boundaries.
struct SettingsScopePicker: View {
    let session: EditorSession
    var body: some View {
        if let document = session.document {
            VStack(alignment: .leading, spacing: 8) {
                EditorSettingsScopeMenu(session: session)
                if let id = session.editingClipID {
                    let customized = !document.settings(for: id).media.isEmpty
                    Label(customized ? "Customized" : "Using project defaults", systemImage: customized ? "slider.horizontal.3" : "link")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Reset media settings to project defaults", systemImage: "arrow.counterclockwise") {
                        session.resetClipSettings(media: true)
                    }.disabled(!customized)
                } else {
                    Text("Clips inherit framing and audio unless customized.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .onChange(of: document.clips.map(\.id)) { _, ids in
                if let id = session.editingClipID, !ids.contains(id) { session.selectSettingsScope(.project) }
            }
        }
    }
}

/// Menu items do not participate in the editor's width measurement. Only this
/// bounded label is laid out; full clip names remain in the menu/VoiceOver value.
struct EditorSettingsScopeMenu: View {
    let session: EditorSession

    private var title: String {
        guard let document = session.document, let id = session.editingClipID,
              let clip = document.clips.first(where: { $0.id == id }) else { return "Project defaults" }
        return document.editorClipTitle(clip)
    }
    private var accessibleTitle: String {
        guard let document = session.document, let id = session.editingClipID,
              let clip = document.clips.first(where: { $0.id == id }) else { return "Project defaults" }
        return document.clipName(clip)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Apply to").font(.caption).foregroundStyle(.secondary)
            Menu {
                Picker("Apply settings to", selection: Binding(get: { session.workspace.settingsScope }, set: { session.selectSettingsScope($0) })) {
                    Text("Project defaults").tag(EditorSettingsScope.project)
                    if let document = session.document {
                        ForEach(Array(document.orderedClips.enumerated()), id: \.element.id) { index, clip in
                            Text("Clip \(index + 1) · \(document.clipName(clip))").tag(EditorSettingsScope.clip(clip.id))
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(title).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Apply settings to")
            .accessibilityValue(accessibleTitle)
        }
    }
}

