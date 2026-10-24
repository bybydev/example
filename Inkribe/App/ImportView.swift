import PhotosUI
import AppFoundation
import SwiftUI
import UniformTypeIdentifiers

/// User reviews the media, canvas, and transaction boundary before any
/// project is published. Originals are adopted only after the import is committed.
struct ImportView: View {
    @Environment(\.appFoundationTheme) private var theme
    @Environment(ProjectsModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var photosSelection: [PhotosPickerItem] = []
    @State private var isPickingFiles = false
    @State private var fileSelectionID: UUID?
    @State private var disposition: ImportDisposition = .combineAsClips
    @State private var preset: CanvasPreset = .original
    @State private var customWidth = "1080"
    @State private var customHeight = "1920"
    @State private var mediaURL = ""
    @State private var confirmRights = false
    @State private var handedOff = false
    var onImported: ([UUID]) -> Void = { _ in }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        Label("Start with your media", systemImage: "captions.bubble").font(.headline)
                        Text("Choose video or audio. Transcription begins only when you ask for it in the project.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Section {
                        PhotosPicker(selection: $photosSelection, maxSelectionCount: 0,
                                     matching: .videos) {
                            Label("Choose videos from Photos", systemImage: "photo.on.rectangle")
                        }
                        Button("Choose media from Files", systemImage: "folder") {
                            fileSelectionID = model.importSelectionID
                            isPickingFiles = true
                        }
                    } header: {
                        Text("Media sources")
                    } footer: {
                        Text("Files supports local files, iCloud Drive and compatible document providers. Originals are copied into your device's private library.")
                    }
                    .disabled(model.isImporting || model.isPreparingPhotos)

                    if model.isPreparingPhotos {
                        Section {
                            ProgressView("Preparing videos from Photos…")
                            Button("Cancel preparation", role: .cancel) {
                                model.cancelPhotoPreparation()
                            }
                        }
                    }

                    if !model.selectedSources.isEmpty {
                        Section("Review selected media (\(model.selectedSources.count))") {
                            ForEach(model.selectedSources) { file in
                                HStack {
                                    Image(systemName: "film")
                                        .foregroundStyle(theme.accentColor)
                                    Text(file.displayName)
                                        .font(.subheadline)
                                        .lineLimit(2)
                                    Spacer()
                                    if !model.isImporting && !model.isPreparingPhotos {
                                        Button(role: .destructive) {
                                            model.removeSource(file.id)
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                        }
                                        .buttonStyle(.borderless)
                                        .accessibilityLabel("Remove \(file.displayName)")
                                    }
                                }
                            }
                        }
                        if model.selectedSources.count > 1 {
                            Section("How should these files be imported?") {
                                Picker("Mode", selection: $disposition) {
                                    Text("One project, ordered clips").tag(ImportDisposition.combineAsClips)
                                    Text("Separate projects").tag(ImportDisposition.separateProjects)
                                }
                                .pickerStyle(.inline)
                            }
                        }
                    }

                    Section("Project format") {
                        Picker("Canvas", selection: $preset) {
                            Text("Original media").tag(CanvasPreset.original)
                            Text("Portrait 9:16").tag(CanvasPreset.portrait)
                            Text("Square 1:1").tag(CanvasPreset.square)
                            Text("Landscape 16:9").tag(CanvasPreset.landscape)
                            Text("TikTok").tag(CanvasPreset.tiktok)
                            Text("Reels").tag(CanvasPreset.reels)
                            Text("Shorts").tag(CanvasPreset.shorts)
                            Text("Stories").tag(CanvasPreset.stories)
                            Text("Custom").tag(CanvasPreset.custom)
                        }
                        if preset == .custom {
                            HStack {
                                TextField("Width", text: $customWidth)
                                    .keyboardType(.numberPad)
                                    .accessibilityLabel("Canvas width in pixels")
                                Text("×")
                                TextField("Height", text: $customHeight)
                                    .keyboardType(.numberPad)
                                    .accessibilityLabel("Canvas height in pixels")
                            }
                            .accessibilityElement(children: .contain)
                            Text("Custom dimensions set the project aspect ratio. Adjust framing in Media; export scales to 720p or 1080p.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(model.isImporting || model.isPreparingPhotos)

                    if model.selectedSources.isEmpty {
                        Section {
                            DisclosureGroup("Import from a direct URL") {
                                TextField("https://example.com/video.mp4", text: $mediaURL)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .keyboardType(.URL)
                                Toggle("I have the rights to import this media", isOn: $confirmRights)
                                Button("Import direct media URL", systemImage: "arrow.down.circle") {
                                    submitURL()
                                }
                                .disabled(model.isImporting || model.isPreparingPhotos || !confirmRights || mediaURL.isEmpty)
                            }
                        } header: {
                            Text("Other sources")
                        } footer: {
                            Text("Only direct downloadable media. This does not download streaming services, DRM content or webpage videos.")
                        }
                    }

                    if model.isImporting {
                        Section {
                            ProgressView("Copying, validating and saving media…")
                            Button("Cancel import", role: .destructive) { model.cancelImport() }
                        }
                    } else if !model.selectedSources.isEmpty {
                        Section {
                            Button(model.importCompletion?.hasFailures == true ? "Retry remaining files" : "Create project" + (disposition == .separateProjects && model.selectedSources.count > 1 ? "s" : ""),
                                   systemImage: "checkmark.circle") {
                                submit()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.selectedSources.isEmpty || model.isPreparingPhotos)
                        }
                    }

                    if let message = model.importMessage {
                        Section("Import result") {
                            Text(message)
                                .font(.footnote)
                                .textSelection(.enabled)
                            if let completion = model.importCompletion, !completion.projectIDs.isEmpty {
                                Button(completion.projectIDs.count == 1 ? "Open imported project" : "View imported projects") {
                                    finish(completion)
                                }
                            }
                        }
                    }
                }
                .listRowBackground(theme.surfaceColor)
                .listRowSeparatorTint(theme.borderColor)
            }
            .navigationTitle("New Project")
            .themedSurface()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(model.isImporting ? "Importing…" : "Done") {
                        if let completion = model.importCompletion, !completion.projectIDs.isEmpty { finish(completion) }
                        else { dismiss() }
                    }
                    .disabled(model.isImporting || model.isPreparingPhotos)
                }
            }
            .interactiveDismissDisabled(model.isImporting || model.isPreparingPhotos)
            .onChange(of: model.importCompletion?.id) { _, _ in
                guard let completion = model.importCompletion, !completion.hasFailures,
                      !completion.projectIDs.isEmpty else { return }
                finish(completion)
            }
            .onChange(of: photosSelection) { _, picked in
                guard !picked.isEmpty else { return }
                photosSelection = []
                model.beginPhotoPreparation(picked)
            }
            .fileImporter(
                isPresented: $isPickingFiles,
                allowedContentTypes: [.movie, .audio],
                allowsMultipleSelection: true
            ) { result in
                guard let fileSelectionID, fileSelectionID == model.importSelectionID else { return }
                switch result {
                case .success(let urls): model.addFiles(urls, selectionID: fileSelectionID)
                case .failure(let error):
                    let failure = error as NSError
                    if failure.domain != NSCocoaErrorDomain || failure.code != NSUserCancelledError {
                        model.alertMessage = error.localizedDescription
                    }
                }
            }
            .alert("Import problem", isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } }
            )) {
                Button("OK", role: .cancel) { model.alertMessage = nil }
            } message: {
                Text(model.alertMessage ?? "")
            }
        }
    }

    private func finish(_ completion: ImportCompletion) {
        guard !handedOff else { return }
        handedOff = true
        onImported(completion.projectIDs)
        dismiss()
    }

    private func dimensions() throws -> ProjectCanvas? {
        guard preset == .custom else { return nil }
        guard let width = Int(customWidth), let height = Int(customHeight) else {
            throw ProjectStoreError.invalidDocument("Enter canvas dimensions between 64 and 8192 pixels.")
        }
        let canvas = ProjectCanvas(width: width, height: height)
        try canvas.validate()
        return canvas
    }

    private func submitURL() {
        do {
            model.beginURLImport(text: mediaURL, rightsConfirmed: confirmRights, preset: preset, canvas: try dimensions())
        } catch { model.alertMessage = error.localizedDescription }
    }

    private func submit() {
        do {
            model.beginImport(disposition: disposition, preset: preset, canvas: try dimensions())
        } catch { model.alertMessage = error.localizedDescription }
    }
}
