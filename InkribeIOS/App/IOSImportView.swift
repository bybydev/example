import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// User reviews the media, canvas, and transaction boundary before any
/// project is published. Originals are adopted only after the import is committed.
struct IOSImportView: View {
    @Environment(IOSProjectsModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var photosSelection: [PhotosPickerItem] = []
    @State private var isPickingFiles = false
    @State private var disposition: IOSImportDisposition = .combineAsClips
    @State private var preset: IOSCanvasPreset = .original
    @State private var customWidth = "1080"
    @State private var customHeight = "1920"
    @State private var mediaURL = ""
    @State private var confirmRights = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhotosPicker(selection: $photosSelection, maxSelectionCount: 0,
                                 matching: .videos) {
                        Label("Choose videos from Photos", systemImage: "photo.on.rectangle")
                    }
                    Button("Choose media from Files", systemImage: "folder") {
                        isPickingFiles = true
                    }
                } header: {
                    Text("Media sources")
                } footer: {
                    Text("Files supports local files, iCloud Drive and compatible document providers. Originals are copied into your device's private library.")
                }
                .disabled(model.isImporting || model.isPreparingPhotos)

                if model.isPreparingPhotos {
                    Section { ProgressView("Preparing videos from Photos…") }
                }

                if !model.selectedSources.isEmpty {
                    Section("Review selected media (\(model.selectedSources.count))") {
                        ForEach(model.selectedSources) { file in
                            HStack {
                                Image(systemName: "film")
                                    .foregroundStyle(.indigo)
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
                                Text("One project, ordered clips").tag(IOSImportDisposition.combineAsClips)
                                Text("Separate projects").tag(IOSImportDisposition.separateProjects)
                            }
                            .pickerStyle(.inline)
                        }
                    }
                }

                Section("Project format") {
                    Picker("Canvas", selection: $preset) {
                        Text("Original media").tag(IOSCanvasPreset.original)
                        Text("Portrait 9:16").tag(IOSCanvasPreset.portrait)
                        Text("Square 1:1").tag(IOSCanvasPreset.square)
                        Text("Landscape 16:9").tag(IOSCanvasPreset.landscape)
                        Text("TikTok").tag(IOSCanvasPreset.tiktok)
                        Text("Reels").tag(IOSCanvasPreset.reels)
                        Text("Shorts").tag(IOSCanvasPreset.shorts)
                        Text("Stories").tag(IOSCanvasPreset.stories)
                        Text("Custom").tag(IOSCanvasPreset.custom)
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
                        TextField("https://example.com/video.mp4", text: $mediaURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        Toggle("I have the rights to import this media", isOn: $confirmRights)
                        Button("Import direct media URL", systemImage: "arrow.down.circle") {
                            model.beginURLImport(text: mediaURL, rightsConfirmed: confirmRights,
                                                 preset: preset)
                        }
                        .disabled(model.isImporting || model.isPreparingPhotos || !confirmRights || mediaURL.isEmpty
                                  || preset == .custom)
                    } header: {
                        Text("Direct HTTPS media URL")
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
                        Button("Create project" + (disposition == .separateProjects ? "s" : ""),
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
                    }
                }
            }
            .navigationTitle("Import media")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(model.isImporting ? "Importing…" : "Done") {
                        model.clearSelection()
                        dismiss()
                    }
                    .disabled(model.isImporting)
                }
            }
            .interactiveDismissDisabled(model.isImporting)
            .onChange(of: photosSelection) { _, picked in
                guard !picked.isEmpty else { return }
                photosSelection = []
                Task { await model.addPhotos(picked) }
            }
            .fileImporter(
                isPresented: $isPickingFiles,
                allowedContentTypes: [.movie, .audio],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls): model.addFiles(urls)
                case .failure(let error): model.alertMessage = error.localizedDescription
                }
            }
            .onDisappear {
                if !model.isImporting { model.clearSelection() }
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

    private func submit() {
        let dimensions: IOSCanvas?
        if preset == .custom {
            guard let width = Int(customWidth), let height = Int(customHeight),
                  width > 0, height > 0 else {
                model.alertMessage = "Enter valid positive canvas dimensions."
                return
            }
            dimensions = IOSCanvas(width: width, height: height)
        } else {
            dimensions = nil
        }
        model.beginImport(disposition: disposition, preset: preset, canvas: dimensions)
    }
}
