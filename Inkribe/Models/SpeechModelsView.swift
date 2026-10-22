import SwiftUI

struct SpeechModelsView: View {
    @Environment(ProjectsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pendingRemoval: String?

    var body: some View {
        let speech = model.transcription
        let models = speech.models
        NavigationStack {
            List {
                Section {
                    Text("Selected: \(models.selectedName)")
                    Text("Models run on this device. Download once, then transcribe offline. Choosing another model affects future transcriptions; saved captions stay unchanged.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !SpeechModelCatalog.downloadsEnabled {
                        Text("This build uses bundled models only.").font(.footnote)
                    }
                    if models.isLoading { ProgressView("Checking model storage…") }
                }
                ForEach(SpeechModelCatalog.all) { variant in
                    Section {
                        Button {
                            models.select(variant.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(variant.displayName).foregroundStyle(.primary)
                                    Text(ByteCountFormatter.string(fromByteCount: variant.byteCount, countStyle: .file))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if models.selectedID == variant.id {
                                    Image(systemName: "checkmark.circle.fill").accessibilityLabel("Selected")
                                }
                            }
                        }
                        .disabled(models.isRemoving || (!SpeechModelCatalog.downloadsEnabled && !models.inventory.bundled.contains(variant.id)))
                        .accessibilityAddTraits(models.selectedID == variant.id ? .isSelected : [])
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
                                .disabled(models.downloadingID != nil || models.isRemoving || speech.protectedModelIDs.contains(variant.id))
                        }
                        if models.inventory.cached.contains(variant.id) {
                            Button(role: .destructive) { pendingRemoval = variant.id } label: {
                                Label("Remove download", systemImage: "trash")
                            }
                                .disabled(models.isRemoving || models.downloadingID == variant.id || speech.protectedModelIDs.contains(variant.id) || speech.persistenceError != nil || speech.isAuthorizing)
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
            .navigationTitle("Speech Models")
            .themedSurface()
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task { speech.start(); await models.refresh() }
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
