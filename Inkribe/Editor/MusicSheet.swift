import AppFoundation
import SwiftUI
import UniformTypeIdentifiers

/// A controls-only sheet. Listening happens back in the main editor after Done.
struct MusicSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appFoundationTheme) private var theme
    let initialInput: ImportInput?
    @State private var draft: MusicDraft
    @State private var choosingFile = false
    @State private var didImportInitialFile = false
    @FocusState private var editingNumber: Bool

    init(draft: MusicDraft, initialInput: ImportInput? = nil) {
        self.initialInput = initialInput
        _draft = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack {
            form
                .navigationTitle("Music")
                .navigationBarTitleDisplayMode(.inline)
                .themedSurface()
                .toolbar { toolbar }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(draft.saving)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url): draft.importFile(ImportInput(localURL: url, origin: .files))
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { draft.error = error.localizedDescription }
            }
        }
        .onAppear {
            draft.session.pause()
            guard !didImportInitialFile else { return }
            didImportInitialFile = true
            if let initialInput { draft.importFile(initialInput) }
        }
    }

    private var form: some View {
        Form {
            if draft.importing {
                Section { HStack(spacing: 12) { ProgressView(); Text("Importing music…") } }
                    .listRowBackground(theme.surfaceColor)
            }
            if let music = draft.music {
                fileSection(music)
                volumeSection
                timingSection
                fadeSection
                Section {
                    Button("Remove music", systemImage: "trash", role: .destructive) {
                        editingNumber = false; draft.remove()
                    }
                }.listRowBackground(theme.surfaceColor)
            } else if !draft.importing {
                Section {
                    Button("Add music", systemImage: "plus") { choosingFile = true }
                }.listRowBackground(theme.surfaceColor)
            }
            if let error = draft.error {
                Section { Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange) }
            }
        }
        .scrollContentBackground(.hidden)
        .listRowSeparatorTint(theme.borderColor)
        .scrollDismissesKeyboard(.interactively)
        .disabled(draft.saving || draft.importing)
    }

    private func fileSection(_ music: ProjectMusic) -> some View {
        Section("Audio file") {
            LabeledContent {
                Text(music.asset.displayName).lineLimit(2).multilineTextAlignment(.trailing)
            } label: { Label("File", systemImage: "music.note") }
            LabeledContent("Duration", value: EditorTime.display(music.asset.metadata.duration))
            Button("Replace music", systemImage: "arrow.triangle.2.circlepath") {
                editingNumber = false; choosingFile = true
            }
        }.listRowBackground(theme.surfaceColor)
    }

    private var volumeSection: some View {
        Section("Audio") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Volume", value: "\(Int((draft.volume * 100).rounded()))%")
                Slider(value: $draft.volume, in: 0...1, step: 0.01).accessibilityLabel("Music volume")
            }
            Toggle("Mute music", isOn: $draft.isMuted)
        }.listRowBackground(theme.surfaceColor)
    }

    private var timingSection: some View {
        Section {
            secondsField("Song start", value: $draft.sourceStart)
            secondsField("Song end", value: $draft.sourceEnd)
            secondsField("Start in video", value: $draft.outputStart)
            Toggle("Loop to fit video", isOn: $draft.loopToFit)
        } header: { Text("Timing") }
        footer: { Text("Times are in seconds. The selected song section repeats when looping is on. Music stops at the video’s end.") }
        .listRowBackground(theme.surfaceColor)
    }

    private var fadeSection: some View {
        Section("Fades") {
            fadeControl("Fade in", value: $draft.fadeIn, maximum: max(5, draft.expected?.fadeIn ?? 0))
            fadeControl("Fade out", value: $draft.fadeOut, maximum: max(5, draft.expected?.fadeOut ?? 0))
        }.listRowBackground(theme.surfaceColor)
    }

    private func secondsField(_ label: String, value: Binding<String>) -> some View {
        LabeledContent {
            TextField(label, text: value)
                .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                .frame(maxWidth: 140).focused($editingNumber)
                .accessibilityLabel(label + " in seconds")
        } label: { Text(label) }
    }

    private func fadeControl(_ label: String, value: Binding<Double>, maximum: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent(label, value: value.wrappedValue == 0 ? "Off" : String(format: "%.1f s", value.wrappedValue))
            Slider(value: value, in: 0...maximum, step: 0.1).accessibilityLabel(label)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", role: .cancel) { dismiss() }.disabled(draft.saving)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button {
                editingNumber = false
                Task { if await draft.save() { dismiss() } }
            } label: {
                if draft.saving { ProgressView().accessibilityLabel("Saving music") }
                else { Text("Done").fontWeight(.semibold) }
            }
            .disabled(draft.saving || draft.importing || !draft.session.isReadyToEdit ||
                draft.session.isLoading || draft.session.isPreparingPreview)
        }
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("Done") { editingNumber = false }
        }
    }
}
