import AppFoundation
import SwiftUI

/// A cancellable local field; only an explicit Save changes the shared project.
struct ClipRenameView: View {
    @Environment(\.dismiss) private var dismiss
    let session: EditorSession
    let clipID: UUID
    @State private var name: String
    @State private var error: String?
    @FocusState private var focused: Bool

    init(session: EditorSession, clipID: UUID) {
        self.session = session; self.clipID = clipID
        let clip = session.document?.clips.first { $0.id == clipID }
        _name = State(initialValue: clip.flatMap { session.document?.clipName($0) } ?? "")
    }
    private var normalizedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var validName: Bool { !normalizedName.isEmpty && normalizedName.count <= 256 }

    var body: some View {
        NavigationStack {
            Form {
                Section("Clip name") {
                    TextField("Clip name", text: $name).focused($focused)
                        .submitLabel(.done).onSubmit { if validName { save(normalizedName) } }
                    if normalizedName.count > 256 {
                        Text("Keep the name within 256 characters.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let document = session.document, let clip = document.clips.first(where: { $0.id == clipID }) {
                    Section {
                        LabeledContent("Original filename", value: document.originalClipName(clip))
                        Button("Use original filename") { save(nil) }
                    } footer: {
                        Text("Renaming this clip keeps your original file unchanged.")
                    }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .navigationTitle("Rename clip").navigationBarTitleDisplayMode(.inline).themedSurface()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(normalizedName) }.disabled(!validName)
                }
            }
            .task { focused = true }
            .onDisappear { Task { await session.flush() } }
        }
    }
    private func save(_ value: String?) {
        guard session.renameClip(clipID, to: value) else {
            error = session.commandError ?? "Couldn’t rename this clip. Try again."
            return
        }
        focused = false; dismiss()
    }
}
