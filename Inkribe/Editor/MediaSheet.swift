import AppFoundation
import SwiftUI

/// A controls-only, large native Form. The top scope row controls the entire
/// form below it; Cancel/swipe discards the draft and Done saves once.
struct MediaSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appFoundationTheme) private var theme
    let session: EditorSession
    @State private var draft: MediaDraft?
    @State private var saveError: String?
    @State private var saving = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            form
                .navigationTitle("Media").navigationBarTitleDisplayMode(.inline).themedSurface()
                .toolbar { sheetToolbar }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(saving)
        .onAppear {
            session.pause()
            if draft == nil, let document = session.document { draft = MediaDraft(document: document) }
        }
        .onDisappear {
            draft?.close()
            saveTask?.cancel()
        }
    }

    private var form: some View {
        Form {
            if let draft, let document = session.document {
                SettingsScopePicker(draft: draft, document: document)
                    .listRowBackground(theme.surfaceColor)
                if let clipID = draft.selectedClipID {
                    MediaPanel(draft: draft, clipID: clipID)
                        .id(clipID)
                        .listRowBackground(theme.surfaceColor)
                } else {
                    MediaProjectPanel(draft: draft)
                        .listRowBackground(theme.surfaceColor)
                }
                if let saveError {
                    Section {
                        Label(saveError, systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.orange)
                    }.listRowBackground(theme.surfaceColor)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .listRowSeparatorTint(theme.borderColor)
        .scrollDismissesKeyboard(.interactively)
        .disabled(saving)
    }

    @ToolbarContentBuilder private var sheetToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", role: .cancel) {
                draft?.close()
                saveTask?.cancel()
                dismiss()
            }.disabled(saving)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button(action: save) {
                if saving { ProgressView().accessibilityLabel("Saving media settings") }
                else { Text("Done").fontWeight(.semibold) }
            }
            .disabled(saving || draft == nil || !session.isReadyToEdit)
        }
    }
    private func save() {
        guard !saving, let draft, !draft.isClosed else { return }
        saving = true; saveError = nil
        saveTask = Task {
            defer {
                saving = false; saveTask = nil
                // Forced teardown can precede an admitted durable publication.
                // Reconcile again after it settles, even if onDismiss ran early.
                if draft.isClosed { Task { await session.refreshAfterMediaEditing() } }
            }
            do {
                try await session.saveMediaDraft(draft)
                if !draft.isClosed { dismiss() }
            } catch is CancellationError {
                // Dismissal cancels work that has not reached publication.
            } catch {
                if !draft.isClosed { saveError = error.localizedDescription }
            }
        }
    }
}

/// Project-only controls. Trimming is owned exclusively by timeline handles.
/// No framing, volume or inheritance controls are shown
/// in this scope, including for a project containing just one clip.
private struct MediaProjectPanel: View {
    @Bindable var draft: MediaDraft

    var body: some View {
        Section("Canvas") {
            Menu {
                if let original = originalCanvas {
                    Button("Original") { draft.canvas = original; draft.preset = .original }
                }
                Button("Portrait · 9:16") { aspect(.portrait) }
                Button("Square · 1:1") { aspect(.square) }
                Button("Landscape · 16:9") { aspect(.landscape) }
            } label: {
                LabeledContent("Aspect ratio", value: aspectTitle)
            }
        }
        Section {
            Toggle("Mute original audio", isOn: $draft.originalAudioMuted)
        } header: { Text("Original audio") } footer: {
            Text("Mutes all clips while preserving their volume settings. Background music is unaffected.")
        }

    }

    private var aspectTitle: String {
        switch draft.preset {
        case .original: "Original"
        case .portrait, .tiktok, .reels, .shorts, .stories: "Portrait · 9:16"
        case .square: "Square · 1:1"
        case .landscape: "Landscape · 16:9"
        case .custom: "\(draft.canvas.width) × \(draft.canvas.height)"
        }
    }
    private func aspect(_ preset: CanvasPreset) {
        guard let canvas = preset.canvas else { return }
        draft.canvas = canvas; draft.preset = preset
    }
    private var originalCanvas: ProjectCanvas? { draft.originalVideoCanvas }
}
