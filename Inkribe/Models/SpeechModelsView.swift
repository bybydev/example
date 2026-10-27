import AppFoundation
import SwiftUI

struct SpeechModelsView: View {
    @Environment(\.appFoundationTheme) private var theme
    @Environment(ProjectsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pendingRemoval: String?
    @State private var pendingSelection: String?

    var body: some View {
        let speech = model.transcription
        let models = speech.models
        NavigationStack {
            List {
                Group {
                    Section {
                        Text("Active: \(models.activeName)")
                        Text(SpeechModelCatalog.downloadsEnabled ? "Models run on this device. Download once, then transcribe offline. All transcription uses the active model." : "Speech models are included in this build and run entirely on this device.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text("New and resumed transcription use the active model. Switching cancels queued and running transcription; saved captions and edits stay available.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if !SpeechModelCatalog.downloadsEnabled {
                            Text("This build uses bundled models only.").font(.footnote)
                        }
                        if models.isLoading { ProgressView("Checking model storage…") }
                        if model.processing.lifecycle.isSwitchingModel { ProgressView("Switching model…") }
                    }
                    ForEach(SpeechModelCatalog.all) { variant in
                        Section {
                            Button {
                                if variant.id != models.activeID { pendingSelection = variant.id }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(variant.displayName).foregroundStyle(.primary)
                                        Text(ByteCountFormatter.string(fromByteCount: variant.byteCount, countStyle: .file))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if models.activeID == variant.id {
                                        Image(systemName: "checkmark.circle.fill").accessibilityLabel("Active")
                                    }
                                }
                            }
                            .disabled(models.isRemoving || model.processing.lifecycle.isSwitchingModel || !models.isAvailable(variant.id))
                            .accessibilityAddTraits(models.activeID == variant.id ? .isSelected : [])
                            .accessibilityHint(models.isAvailable(variant.id) ? "Available offline" :
                                SpeechModelCatalog.downloadsEnabled ? "Download this model before transcription" : "Not included in this build")
                            if models.inventory.bundled.contains(variant.id) {
                                Label("Included in app", systemImage: "shippingbox")
                            } else if models.inventory.downloaded.contains(variant.id) {
                                Label("Downloaded", systemImage: "checkmark.circle")
                            } else if models.inventory.cached.contains(variant.id) {
                                Text("Incomplete file. Remove it and download again.").font(.footnote)
                            } else {
                                Text("Not downloaded").foregroundStyle(.secondary)
                            }
                            if models.downloadingID == variant.id {
                                ProgressView(value: models.fraction) {
                                    Text(models.fraction >= 0.95 ? "Verifying model…" : "Downloading…")
                                }
                                .accessibilityValue("\(Int(models.fraction * 100)) percent")
                                Button("Cancel download", role: .cancel) { models.cancelDownload() }
                            } else if !models.isAvailable(variant.id) && SpeechModelCatalog.downloadsEnabled {
                                Button("Download model", systemImage: "arrow.down.circle") { models.download(variant.id) }
                                    .disabled(model.processing.lifecycle.isSwitchingModel || models.downloadingID != nil || models.isRemoving || speech.protectedModelIDs.contains(variant.id))
                            }
                            if models.inventory.cached.contains(variant.id) {
                                Button(role: .destructive) { pendingRemoval = variant.id } label: {
                                    Label("Remove download", systemImage: "trash")
                                }
                                    .disabled(model.processing.lifecycle.isSwitchingModel || models.isRemoving || models.downloadingID == variant.id || speech.protectedModelIDs.contains(variant.id) || speech.persistenceError != nil || speech.isAuthorizing)
                            }
                        }
                    }
                    Section {
                        LabeledContent("Downloaded model storage",
                            value: ByteCountFormatter.string(fromByteCount: models.inventory.cachedBytes, countStyle: .file))
                        Text("Downloads stay in app storage across launches and updates. Keep the app open during download; an interrupted download can be retried. Removing a download never deletes projects or captions. Models: Whisper / whisper.cpp, MIT license.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let error = models.errorMessage {
                        Section("Model problem") {
                            Text(error).foregroundStyle(.red)
                            Button("Refresh model storage") {
                                models.errorMessage = nil
                                Task { await models.refresh() }
                            }
                        }
                    }
                }
                .listRowBackground(theme.surfaceColor)
                .listRowSeparatorTint(theme.borderColor)
            }
            .navigationTitle("Speech Models")
            .themedSurface()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.disabled(model.processing.lifecycle.isSwitchingModel)
                }
            }
            .interactiveDismissDisabled(model.processing.lifecycle.isSwitchingModel)
            .task { speech.start(); await models.refresh() }
            .confirmationDialog("Switch active speech model?", isPresented: Binding(
                get: { pendingSelection != nil }, set: { if !$0 { pendingSelection = nil } }
            )) {
                Button("Switch model and cancel transcription", role: .destructive) {
                    guard let id = pendingSelection else { return }
                    pendingSelection = nil
                    Task {
                        do { try await model.processing.switchSpeechModel(to: id) }
                        catch { models.errorMessage = error.localizedDescription }
                    }
                }
                Button("Cancel", role: .cancel) { pendingSelection = nil }
            } message: {
                Text("All queued and running transcription tasks will be cancelled, and model downloads will stop. Exports continue unchanged. Saved captions and edits are kept. New and resumed transcription will use the active model.")
            }
            .confirmationDialog("Remove downloaded model?", isPresented: Binding(
                get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
            )) {
                Button("Remove download", role: .destructive) {
                    guard let id = pendingRemoval, !speech.isAuthorizing else { return }
                    pendingRemoval = nil
                    Task { await models.remove(id, protectedIDs: speech.protectedModelIDs, jobStorageError: speech.persistenceError) }
                }
            } message: {
                Text("You can download it again later. Bundled models, projects and captions are preserved.")
            }
        }
    }
}
